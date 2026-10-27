import Foundation

nonisolated struct AppDirectories: Sendable {
    let support: URL
    let caches: URL
    let documents: URL

    static func live() -> AppDirectories {
        AppDirectories(support: .applicationSupportDirectory, caches: .cachesDirectory, documents: .documentsDirectory)
    }
}
