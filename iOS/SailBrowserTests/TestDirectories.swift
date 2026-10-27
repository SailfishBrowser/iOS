import Foundation
@testable import SailBrowser

extension AppDirectories {
    nonisolated static func temporary() -> AppDirectories {
        let root = FileManager.default.temporaryDirectory.appending(path: "SailBrowser-\(UUID().uuidString)")
        return AppDirectories(
            support: root.appending(path: "support"), caches: root.appending(path: "caches"),
            documents: root.appending(path: "documents"))
    }
}
