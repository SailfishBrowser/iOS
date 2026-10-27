import Foundation
import Testing
import WebKit
@testable import SailBrowser

struct LoadErrorTests {
    private let page = URL(string: "https://example.test/page")!
    private let fallback = URL(string: "https://example.test/fallback")!

    private func urlError(_ code: URLError.Code, userInfo: [String: Any]) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    @Test func policyChangeAndCancellationYieldNoError() {
        #expect(LoadError(NSError(domain: "WebKitErrorDomain", code: 102), fallbackURL: fallback) == nil)
        #expect(LoadError(URLError(.cancelled), fallbackURL: fallback) == nil)
        #expect(LoadError(WKError(.webContentProcessTerminated), fallbackURL: fallback) == nil)
        #expect(LoadError(NSError(domain: "WebKitErrorDomain", code: 101), fallbackURL: fallback)?.reason == .cannotOpen)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive])
    func everyConnectivityCodeIsOffline(code: URLError.Code) {
        #expect(LoadError(URLError(code), fallbackURL: fallback)?.reason == .offline)
        #expect(LoadError(URLError(code), fallbackURL: fallback)?.reason.retriesOnReconnect == true)
    }

    @Test func otherCodesReachTheirReasons() {
        let cases: [(URLError.Code, LoadError.Reason)] = [
            (.cannotFindHost, .cannotFindHost), (.dnsLookupFailed, .cannotFindHost),
            (.cannotConnectToHost, .cannotConnect), (.networkConnectionLost, .cannotConnect),
            (.resourceUnavailable, .cannotConnect), (.badServerResponse, .cannotConnect),
            (.zeroByteResource, .cannotConnect), (.cannotParseResponse, .cannotConnect),
            (.timedOut, .timedOut), (.httpTooManyRedirects, .tooManyRedirects),
            (.secureConnectionFailed, .notSecure), (.serverCertificateUntrusted, .notSecure),
            (.clientCertificateRequired, .notSecure), (.appTransportSecurityRequiresSecureConnection, .notSecure),
            (.unsupportedURL, .cannotOpen), (.fileDoesNotExist, .cannotOpen),
        ]
        for (code, reason) in cases {
            #expect(LoadError(URLError(code), fallbackURL: fallback)?.reason == reason, "\(code)")
        }
        #expect(LoadError(NSError(domain: "Other", code: 7), fallbackURL: fallback)?.reason == .cannotOpen)
        #expect(LoadError(URLError(.cannotFindHost), fallbackURL: fallback)?.reason != .offline)
        let retrying: Set<LoadError.Reason> = [.offline, .cannotFindHost, .cannotConnect, .timedOut]
        for reason in LoadError.Reason.allCases {
            #expect(reason.retriesOnReconnect == retrying.contains(reason), "\(reason)")
        }
    }

    @Test func networkUnavailableReasonIsOffline() {
        let error = urlError(
            .resourceUnavailable,
            userInfo: [NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.constrained.rawValue])
        #expect((error as? URLError)?.networkUnavailableReason == .constrained)
        #expect(LoadError(error, fallbackURL: fallback)?.reason == .offline)
    }

    @Test func failingURLBeatsTheFallback() {
        let withURL = urlError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: page])
        #expect(LoadError.failingURL(of: withURL) == page)
        #expect(LoadError(withURL, fallbackURL: fallback)?.url == page)
        let withString = urlError(.timedOut, userInfo: ["NSErrorFailingURLStringKey": page.absoluteString])
        #expect(LoadError.failingURL(of: withString) == page)
        #expect(LoadError(withString, fallbackURL: fallback)?.url == page)
        #expect(LoadError.failingURL(of: URLError(.timedOut)) == nil)
        #expect(LoadError(URLError(.timedOut), fallbackURL: fallback)?.url == fallback)
        #expect(LoadError(URLError(.timedOut), fallbackURL: nil) == nil)
        #expect(LoadError(withURL, fallbackURL: nil)?.host == "example.test")
    }

    @Test func aRedirectLoopRetriesTheOriginalRequest() {
        let loopA = URL(string: "https://example.test/loop-a")!
        let loopB = URL(string: "https://example.test/loop-b")!
        let loop = urlError(.httpTooManyRedirects, userInfo: [NSURLErrorFailingURLErrorKey: loopB])
        #expect(LoadError(loop, fallbackURL: loopA)?.url == loopA)
        #expect(LoadError(loop, fallbackURL: nil)?.url == loopB)
        #expect(LoadError(URLError(.redirectToNonExistentLocation), fallbackURL: fallback)?.reason == .cannotOpen)
    }

    @Test func crashedIsOnlyMadeByHand() {
        let crashed = LoadError.crashed(url: page)
        #expect(crashed.reason == .crashed)
        #expect(crashed.url == page)
        #expect(crashed.reason.symbol == "memorychip")
        #expect(!crashed.reason.retriesOnReconnect)
    }

    @Test func copyNamesNoProtocols() {
        let symbols: [LoadError.Reason: String] = [
            .offline: "wifi.slash", .cannotFindHost: "questionmark.circle", .cannotConnect: "exclamationmark.triangle",
            .timedOut: "clock", .tooManyRedirects: "arrow.triangle.2.circlepath", .notSecure: "lock.slash",
            .cannotOpen: "xmark.circle", .crashed: "memorychip",
        ]
        for reason in LoadError.Reason.allCases {
            for word in ["DNS", "TLS", "SSL", "HTTP", "redirect", "URL", "error code"] {
                #expect(!reason.title.localizedCaseInsensitiveContains(word), "\(reason) names \(word)")
            }
            #expect(!reason.title.isEmpty && !reason.title.hasSuffix("."), "\(reason)")
            #expect(reason.button == (reason == .crashed ? "Reload" : "Try Again"), "\(reason)")
            #expect(reason.symbol == symbols[reason], "\(reason)")
        }
        #expect(LoadError.Reason.offline.title == "You're offline")
        #expect(LoadError.Reason.crashed.title == "This page used too much memory")
    }

    @Test func cookielessKeepsNothingAndFailsFast() {
        let configuration = SessionConfiguration.cookieless(requestTimeout: 3, resourceTimeout: 7)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.allowsConstrainedNetworkAccess)
        #expect(configuration.allowsExpensiveNetworkAccess)
        #expect(!configuration.waitsForConnectivity)
        #expect(configuration.timeoutIntervalForRequest == 3)
        #expect(configuration.timeoutIntervalForResource == 7)
    }
}
