import Foundation
import WebKit

// Why a provisional load failed, in plain words, and the URL a retry loads.
nonisolated struct LoadError: Equatable, Sendable {
    enum Reason: Equatable, Sendable, CaseIterable {
        case offline, cannotFindHost, cannotConnect, timedOut, tooManyRedirects, notSecure, cannotOpen, crashed

        // The path coming back online may fix these; the rest are the site's or the page's own.
        var retriesOnReconnect: Bool {
            switch self {
            case .offline, .cannotFindHost, .cannotConnect, .timedOut: true
            case .tooManyRedirects, .notSecure, .cannotOpen, .crashed: false
            }
        }

        var symbol: String {
            switch self {
            case .offline: "wifi.slash"
            case .cannotFindHost: "questionmark.circle"
            case .cannotConnect: "exclamationmark.triangle"
            case .timedOut: "clock"
            case .tooManyRedirects: "arrow.triangle.2.circlepath"
            case .notSecure: "lock.slash"
            case .cannotOpen: "xmark.circle"
            case .crashed: "memorychip"
            }
        }

        var title: String {
            switch self {
            case .offline: "You're offline"
            case .cannotFindHost: "Can't find that site"
            case .cannotConnect: "Can't connect to the site"
            case .timedOut: "The site took too long"
            case .tooManyRedirects: "The site keeps sending you round in circles"
            case .notSecure: "This connection isn't secure"
            case .cannotOpen: "Can't open this page"
            case .crashed: "This page used too much memory"
            }
        }

        var button: String {
            self == .crashed ? "Reload" : "Try Again"
        }

        fileprivate init(_ error: NSError) {
            guard error.domain == NSURLErrorDomain else {
                self = .cannotOpen
                return
            }
            guard error.userInfo[NSURLErrorNetworkUnavailableReasonKey] == nil else {
                self = .offline
                return
            }
            switch URLError.Code(rawValue: error.code) {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: self = .offline
            case .cannotFindHost, .dnsLookupFailed: self = .cannotFindHost
            case .cannotConnectToHost, .networkConnectionLost, .resourceUnavailable, .badServerResponse, .zeroByteResource,
                .cannotParseResponse:
                self = .cannotConnect
            case .timedOut: self = .timedOut
            case .httpTooManyRedirects: self = .tooManyRedirects
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                self = .notSecure
            default: self = .cannotOpen
            }
        }
    }

    let reason: Reason
    let url: URL

    // Nil for a cancellation, a policy change (a download, WebKitErrorDomain 102) or a content-process termination
    // (the termination callback owns that case), and when nothing names a URL to retry.
    init?(_ error: any Error, fallbackURL: URL?) {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSURLErrorDomain, NSURLErrorCancelled), ("WebKitErrorDomain", 102),
            (WKErrorDomain, WKError.webContentProcessTerminated.rawValue):
            return nil
        default: break
        }
        let reason = Reason(nsError)
        let failing = Self.failingURL(of: error)
        // A redirect loop's failing URL is the last hop; the retry re-enters at the original request.
        guard let url = reason == .tooManyRedirects ? fallbackURL ?? failing : failing ?? fallbackURL else { return nil }
        self.reason = reason
        self.url = url
    }

    private init(reason: Reason, url: URL) {
        self.reason = reason
        self.url = url
    }

    static func crashed(url: URL) -> LoadError {
        LoadError(reason: .crashed, url: url)
    }

    // Foundation deprecated NSURLErrorFailingURLStringErrorKey in iOS 18.4; WebKit still writes the string form under its value.
    private static let failingURLStringKey = "NSErrorFailingURLStringKey"

    // WebKit puts the string form under its own key, beside Foundation's URL key.
    static func failingURL(of error: any Error) -> URL? {
        let info = (error as NSError).userInfo
        if let url = info[NSURLErrorFailingURLErrorKey] as? URL {
            return url
        }
        return (info[failingURLStringKey] as? String).flatMap(URL.init(string:))
    }

    var host: String? {
        url.host()
    }
}
