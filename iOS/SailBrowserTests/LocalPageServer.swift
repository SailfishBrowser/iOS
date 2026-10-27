import Foundation
import Network

final class LocalPageServer {
    private static let pixel = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!

    // A route's answer. With holdsOpen, the body is sent and the connection stays open, so the response never ends.
    // With pieces above one, the body goes out in that many sends, one per gap, so a download sees that many chunks.
    struct Reply {
        var status = "200 OK"
        var headers: [String: String]
        var body: Data
        var holdsOpen = false
        var pieces = 1
        var gap: TimeInterval = 0
    }

    private(set) var requestedPaths: [String] = []
    // Answers by path, given the request's full text.
    // A route that answers nil accepts the connection and closes it with no reply: the client sees it lost.
    var routes: [String: (String) -> Reply?] = [:]
    private let listener: NWListener
    private let page: (String) -> String
    private let signIn: String?
    private var held: [NWConnection] = []

    // With a "user:password" sign-in, pages answer 401 with a Basic challenge until a request carries it.
    init(signIn: String? = nil, page: @escaping (String) -> String) async throws {
        self.page = page
        self.signIn = signIn
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.serve(connection) }
        }
        listener.start(queue: .main)
        try await waitUntil { if case .ready = listener.state { true } else { false } }
    }

    deinit {
        listener.cancel()
        held.forEach { $0.cancel() }
    }

    // Ends every held-open response.
    func closeHeld() {
        held.forEach { $0.cancel() }
        held = []
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                let lines = data.map { String(decoding: $0, as: UTF8.self).split(separator: "\r\n") } ?? []
                guard let self, let line = lines.first else { return connection.cancel() }
                let path = String(line.split(separator: " ")[1])
                self.requestedPaths.append(path)
                // "/redirect-x" answers a 302 to "/page-x".
                if path.hasPrefix("/redirect") {
                    let location = path.replacing("/redirect", with: "/page")
                    return self.send(Reply(status: "302 Found", headers: ["Location": location], body: Data()), on: connection)
                }
                if let route = self.routes[path] {
                    guard let reply = route(lines.joined(separator: "\r\n")) else { return connection.cancel() }
                    return self.send(reply, on: connection)
                }
                let isPage = path.hasPrefix("/page")
                if isPage, let signIn = self.signIn, !lines.contains(where: {
                    $0.lowercased().hasPrefix("authorization:") && $0.hasSuffix("Basic \(Data(signIn.utf8).base64EncodedString())")
                }) {
                    let head = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"sail\"\r\n"
                        + "Content-Length: 0\r\nConnection: close\r\n\r\n"
                    return connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
                let body = isPage ? Data(self.page(path).utf8) : Self.pixel
                self.send(Reply(headers: ["Content-Type": isPage ? "text/html" : "image/gif"], body: body), on: connection)
            }
        }
    }

    private func send(_ reply: Reply, on connection: NWConnection) {
        var headers = reply.headers
        headers["Cache-Control"] = "no-store"
        headers["Content-Length"] = headers["Content-Length"] ?? String(reply.body.count)
        if !reply.holdsOpen {
            headers["Connection"] = "close"
        }
        let head = "HTTP/1.1 \(reply.status)\r\n" + headers.map { "\($0): \($1)\r\n" }.joined() + "\r\n"
        guard !reply.holdsOpen else {
            held.append(connection)
            return connection.send(content: Data(head.utf8) + reply.body, completion: .contentProcessed { _ in })
        }
        guard reply.pieces > 1 else {
            return connection.send(content: Data(head.utf8) + reply.body, completion: .contentProcessed { _ in connection.cancel() })
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        sendPieces(reply.body, count: reply.pieces, every: reply.gap, on: connection)
    }

    private func sendPieces(_ body: Data, count: Int, every gap: TimeInterval, on connection: NWConnection) {
        let size = (body.count + count - 1) / count
        let rest = Data(body.dropFirst(size))
        connection.send(content: body.prefix(size), completion: .contentProcessed { _ in
            MainActor.assumeIsolated {
                guard !rest.isEmpty else { return connection.cancel() }
                Task {
                    try await Task.sleep(for: .seconds(gap))
                    self.sendPieces(rest, count: count - 1, every: gap, on: connection)
                }
            }
        })
    }
}

extension LocalPageServer {
    // An attachment a download can be cancelled from and resumed against: the first response stalls after `partial`
    // bytes, held open; a later request with a Range header gets the rest as 206, as a resumed download asks, and one
    // without gets the whole body. The validators let WebKit resume rather than start over.
    static func resumable(_ body: Data, named name: String, stallingAfter partial: Int) -> (String) -> Reply? {
        var stalled = false
        return { request in
            var headers = [
                "Content-Type": "application/zip", "Content-Disposition": "attachment; filename=\(name)",
                "ETag": "\"v1\"", "Accept-Ranges": "bytes", "Last-Modified": "Wed, 21 Oct 2026 07:28:00 GMT",
            ]
            if let range = request.firstMatch(of: /Range: bytes=(\d+)-/) {
                let start = Int(range.1)!
                headers["Content-Range"] = "bytes \(start)-\(body.count - 1)/\(body.count)"
                return Reply(status: "206 Partial Content", headers: headers, body: body[start...])
            }
            guard !stalled else { return Reply(headers: headers, body: body) }
            stalled = true
            headers["Content-Length"] = String(body.count)
            return Reply(headers: headers, body: body[..<partial], holdsOpen: true)
        }
    }
}
