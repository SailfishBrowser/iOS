import Foundation
import Observation

// Per-host settings, in their own file so the browser state's format stays as it is.
@Observable final class SiteSettingsStore {
    private(set) var byHost: [String: SiteSettings]
    // A change made from a private tab: private tabs read it before the saved settings, and it dies with the session.
    private var privateByHost: [String: SiteSettings] = [:]
    @ObservationIgnored private let writer: DebouncedWriter<[String: SiteSettings]>

    init(directories: AppDirectories) {
        let fileURL = directories.support.appending(path: "site-settings.json")
        byHost = JSONFile.load([String: SiteSettings].self, from: fileURL) ?? [:]
        writer = DebouncedWriter(fileURL: fileURL)
    }

    subscript(host: String) -> SiteSettings {
        get { byHost[host] ?? SiteSettings() }
        // Only overrides are kept: a site back at the defaults has no entry.
        set {
            byHost[host] = newValue == SiteSettings() ? nil : newValue
            writer.schedule(byHost)
        }
    }

    func settings(forHost host: String, isPrivate: Bool) -> SiteSettings {
        (isPrivate ? privateByHost[host] : nil) ?? self[host]
    }

    func set(_ settings: SiteSettings, forHost host: String, isPrivate: Bool) {
        if isPrivate {
            privateByHost[host] = settings
        } else {
            self[host] = settings
        }
    }

    func endPrivateSession() {
        privateByHost = [:]
    }

    func resetPermissions(forHost host: String) {
        var settings = self[host]
        settings.camera = .ask
        settings.microphone = .ask
        self[host] = settings
    }

    func resetAllPermissions() {
        for host in byHost.keys {
            resetPermissions(forHost: host)
        }
    }

    func flush() async {
        await writer.flush()
    }
}
