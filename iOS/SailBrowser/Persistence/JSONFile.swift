import Foundation
import os

nonisolated enum JSONFile {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "persistence")

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let name = url.deletingPathExtension().lastPathComponent
            let corrupt = url.deletingLastPathComponent()
                .appending(path: "\(name).corrupt-\(Int(Date().timeIntervalSince1970)).json")
            logger.error("Undecodable \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            do {
                try FileManager.default.moveItem(at: url, to: corrupt)
            } catch {
                logger.error("Could not move aside \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
            return nil
        }
    }

    @concurrent static func write(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
