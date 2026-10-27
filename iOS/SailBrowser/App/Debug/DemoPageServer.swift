#if DEBUG
import Foundation
import Network

// Serves demo pages over loopback HTTP, so they have a host for the page zoom and enter history like any visited
// site. A page's path is its background colour.
nonisolated final class DemoPageServer: Sendable {
    private static let requestLimit = 65_536
    private static let loopback = "127.0.0.1"
    private let listener: NWListener
    private let port: NWEndpoint.Port

    init(page: @escaping @Sendable (String) -> String) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(Self.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.respond(on: connection, page: page)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!)
                case .failed(let error), .waiting(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        self.listener = listener
    }

    func url(_ colour: String) -> URL {
        URL(string: "http://\(Self.loopback):\(port.rawValue)/\(colour)")!
    }

    func stop() {
        listener.cancel()
    }

    private static func respond(on connection: NWConnection, page: @escaping @Sendable (String) -> String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: requestLimit) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let colour = request.split(separator: " ", maxSplits: 2).dropFirst().first?.dropFirst() ?? ""
            let found = colour.count == 6 && colour.allSatisfy(\.isHexDigit)
            let body = found ? Data(page(String(colour)).utf8) : Data()
            let head =
                "HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(
                content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
