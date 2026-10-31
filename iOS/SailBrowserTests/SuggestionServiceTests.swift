import Foundation
import Synchronization
import Testing
@testable import SailBrowser

nonisolated final class StubSuggestProtocol: URLProtocol {
    private final class Held: @unchecked Sendable {
        let load: StubSuggestProtocol
        init(_ load: StubSuggestProtocol) { self.load = load }
    }

    private static let bodies = Mutex<[String: Data]>([:])
    private static let cookies = Mutex<[String: String]>([:])
    private static let requests = Mutex<[String: URLRequest]>([:])
    private static let failures = Mutex<[String: URLError]>([:])
    private static let holds = Mutex<Set<String>>([])
    private static let held = Mutex<[String: Held]>([:])
    private static let stops = Mutex<Set<String>>([])

    // An answer, with a Set-Cookie header when given.
    static func answer(_ query: String, with body: String, setCookie: String? = nil) {
        bodies.withLock { $0[query] = Data(body.utf8) }
        cookies.withLock { $0[query] = setCookie }
    }

    // The request for this query fails as it does offline, or with the given error.
    static func fail(_ query: String, with error: URLError = URLError(.notConnectedToInternet)) {
        failures.withLock { $0[query] = error }
    }

    // The request for this query is parked until release(_:) or the loader's stop.
    static func hold(_ query: String) {
        holds.withLock { _ = $0.insert(query) }
    }

    // Answers a held request that was not stopped; a stopped one gets nothing, as a loader must not speak after stop.
    static func release(_ query: String) {
        holds.withLock { _ = $0.remove(query) }
        guard let load = held.withLock({ $0.removeValue(forKey: query) })?.load else { return }
        load.respond(to: query)
    }

    // The queries whose loads the session stopped at the transport.
    static var stopped: Set<String> {
        stops.withLock { $0 }
    }

    static func request(for query: String) -> URLRequest? {
        requests.withLock { $0[query] }
    }

    static func session() -> URLSession {
        let configuration = SuggestionService.configuration()
        configuration.protocolClasses = [StubSuggestProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var query: String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
    }

    override func startLoading() {
        let query = query
        Self.requests.withLock { $0[query] = request }
        if let error = Self.failures.withLock({ $0[query] }) {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if Self.holds.withLock({ $0.contains(query) }) {
            Self.held.withLock { $0[query] = Held(self) }
            return
        }
        respond(to: query)
    }

    private func respond(to query: String) {
        guard let body = Self.bodies.withLock({ $0[query] }) else {
            Issue.record("StubSuggestProtocol has no answer for \"\(query)\"")
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        var headers = ["Content-Type": "text/javascript; charset=UTF-8"]
        headers["Set-Cookie"] = Self.cookies.withLock { $0[query] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        let query = query
        Self.held.withLock { _ = $0.removeValue(forKey: query) }
        Self.stops.withLock { _ = $0.insert(query) }
    }
}

// A sleep the test controls: holding false returns at once; holding true parks every sleeper until release().
nonisolated final class HeldSleep: Sendable {
    private struct State {
        var requested: [Duration] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
        var released = false
    }

    private let state = Mutex(State())
    private let holding: Bool

    init(holding: Bool) {
        self.holding = holding
    }

    var requested: [Duration] {
        state.withLock { $0.requested }
    }

    func release() {
        let waiting = state.withLock { s in
            s.released = true
            defer { s.waiting = [] }
            return s.waiting
        }
        waiting.forEach { $0.resume() }
    }

    @Sendable func sleep(_ duration: Duration) async throws {
        state.withLock { $0.requested.append(duration) }
        guard holding else { return }
        await withCheckedContinuation { continuation in
            let resumes = state.withLock { s in
                if s.released { return true }
                s.waiting.append(continuation)
                return false
            }
            if resumes {
                continuation.resume()
            }
        }
    }
}

func stubService(language: String = "en", sleep: @escaping @Sendable (Duration) async throws -> Void = HeldSleep(holding: false).sleep) -> SuggestionService {
    SuggestionService(session: StubSuggestProtocol.session(), language: language, sleep: sleep)
}

struct SuggestionServiceTests {
    static let swiftSample = #"["swift",["swiftx tracking","swift","swift transportation","swift code","swifter","swiftly","swiftlane","swift bird","swyft filings","swift solar"],[],{"google:suggestsubtypes":[[512],[512],[512],[512],[512],[512],[512],[512],[512,10,11,433],[512]]}]"#
    static let cafeSample = #"["café",["café carrusel menu","café de la presse menu","café beaujolais"],[],{"google:suggestsubtypes":[[512],[512],[512]]}]"#

    @Test func decodesFirefoxClientShape() async throws {
        let swift = try SuggestionService.decode(Data(Self.swiftSample.utf8))
        #expect(swift.query == "swift")
        #expect(swift.suggestions.count == 10)
        #expect(swift.suggestions.first == "swiftx tracking")

        StubSuggestProtocol.answer("café", with: Self.cafeSample)
        let service = stubService(language: "fr")
        let cafe = try await service.suggestions(for: "café", engine: .google)
        #expect(cafe.query == "café")
        #expect(cafe.suggestions == ["café carrusel menu", "café de la presse menu", "café beaujolais"])
    }

    @Test func requestEncodesQueryLanguageAndTimeout() async throws {
        StubSuggestProtocol.answer("c++ & go #1", with: #"["c++ & go #1",[]]"#)
        let service = stubService(language: "de")

        _ = try await service.suggestions(for: "c++ & go #1", engine: .google)

        let request = try #require(StubSuggestProtocol.request(for: "c++ & go #1"))
        #expect(request.url?.absoluteString
            == "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&hl=de&q=c%2B%2B%20%26%20go%20%231")
        #expect(request.timeoutInterval == 2)
    }

    @Test func rejectsMalformedBodies() {
        #expect(throws: (any Error).self) { try SuggestionService.decode(Data(#"{"q":"swift"}"#.utf8)) }
        #expect(throws: (any Error).self) { try SuggestionService.decode(Data(#"["swift",[1,2]]"#.utf8)) }
    }

    // A private query can never be linked to a normal one by a cookie the search host set: the service's session neither
    // sends a cookie back nor keeps it. Proven on the wire against a local host, since the stub never sees the Cookie
    // header a session adds, and the shared store is asked only for this run's cookie: it is the app's own jar, which
    // the simulator keeps between runs, with real cookies from visits to the search host.
    @Test func aSetCookieAnswerIsNeverSentBack() async throws {
        let name = "tau\(UUID().uuidString.prefix(8))"
        let server = try await LocalPageServer()
        var second: [String] = []
        server.routes["/a"] = { _ in LocalPageServer.Reply(headers: ["Set-Cookie": "\(name)=1; Path=/"], body: Data()) }
        server.routes["/b"] = { request in
            second.append(request)
            return LocalPageServer.Reply(headers: [:], body: Data())
        }

        // The service's session, then one that keeps cookies: the second proves the header shows on the wire.
        for session in [SuggestionService().session, URLSession(configuration: .ephemeral)] {
            _ = try await session.data(from: server.url("/a"))
            _ = try await session.data(from: server.url("/b"))
        }

        try #require(second.count == 2)
        #expect(!second[0].contains("\r\nCookie:"))
        #expect(second[1].contains("\r\nCookie: \(name)=1"))
        #expect(HTTPCookieStorage.shared.cookies(for: server.url("/b"))?.contains { $0.name == name } != true)
    }

    @Test func aCancelledSleepNeverSendsARequest() async throws {
        let held = HeldSleep(holding: true)
        let service = stubService(sleep: held.sleep)
        let task = Task { try await service.suggestions(for: "cancelled x", engine: .google) }
        try await waitUntil { held.requested.count == 1 }

        task.cancel()
        held.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(StubSuggestProtocol.request(for: "cancelled x") == nil)
    }
}
