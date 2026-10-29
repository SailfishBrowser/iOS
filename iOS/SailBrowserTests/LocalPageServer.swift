import Foundation
import Network

// A loopback HTTP server answering each path from its route, given the request's full text.
final class LocalPageServer {
    struct Reply {
        var headers: [String: String]
        var body: Data
    }

    var routes: [String: (String) -> Reply] = [:]
    private let listener: NWListener

    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.serve(connection) }
        }
        listener.start(queue: .main)
        try await waitUntil { if case .ready = listener.state { true } else { false } }
    }

    deinit {
        listener.cancel()
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                let lines = data.map { String(decoding: $0, as: UTF8.self).split(separator: "\r\n") } ?? []
                guard let self, let line = lines.first, let route = self.routes[String(line.split(separator: " ")[1])] else {
                    return connection.cancel()
                }
                let reply = route(lines.joined(separator: "\r\n"))
                var headers = reply.headers
                headers["Content-Length"] = String(reply.body.count)
                headers["Connection"] = "close"
                let head = "HTTP/1.1 200 OK\r\n" + headers.map { "\($0): \($1)\r\n" }.joined() + "\r\n"
                connection.send(content: Data(head.utf8) + reply.body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
