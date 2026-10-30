import CloudKit
import Foundation
import Observation
import UIKit
import os

nonisolated struct MacDevice: Codable, Identifiable, Equatable, Sendable {
    // The Device record name.
    let id: String
    var name: String
    var modified: Date
    var spaceIDs: [String]
    var current: String?
}

nonisolated struct MacTabsCache: Codable, Sendable {
    var userRecordID: String?
    // The zone's CKServerChangeToken, archived with NSKeyedArchiver.
    var token: Data?
    var isSubscribed = false
    var devices: [MacDevice] = []
    var spaces: [String: MacSpace] = [:]
    var shownMacID: String?
}

// The spaces the user's Macs publish to the private database, read only. The phone's one write is its subscription.
@Observable final class MacTabsStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "sync")
    private static let zoneID = CKRecordZone.ID(zoneName: "MacTabs")

    // The shown Mac's current space when the sheet last opened, and the space of the page last viewed there.
    var sheetCurrent: String?
    var sheetPage: String?
    private var cache: MacTabsCache
    @ObservationIgnored private let container: CKContainer
    @ObservationIgnored private let writer: DebouncedWriter<MacTabsCache>
    @ObservationIgnored private var fetching: Task<Void, Never>?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(directories: AppDirectories, container: CKContainer) {
        let fileURL = directories.support.appending(path: "mac-tabs.json")
        cache = JSONFile.load(MacTabsCache.self, from: fileURL) ?? MacTabsCache()
        writer = DebouncedWriter(fileURL: fileURL)
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.start() }
            }
        }
    }

    isolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // Newest first.
    var macs: [MacDevice] {
        cache.devices
    }

    // The stored choice while that Mac exists, or the newest Mac.
    var shownMacID: String? {
        get { macs.first { $0.id == cache.shownMacID }?.id ?? macs.first?.id }
        set {
            cache.shownMacID = newValue
            writer.schedule(cache)
        }
    }

    // In the Mac's order, the cached ones only.
    func spaces(of mac: MacDevice) -> [(id: String, space: MacSpace)] {
        mac.spaceIDs.compactMap { id in cache.spaces[id].map { (id: id, space: $0) } }
    }

    // A different account than the cache's starts from an empty cache, so its subscription is saved again.
    func start() async {
        let user: String
        do {
            user = try await container.userRecordID().recordName
        } catch {
            Self.logger.error("User record: \(error, privacy: .public)")
            return
        }
        if user != cache.userRecordID {
            cache = MacTabsCache(userRecordID: user)
            writer.schedule(cache)
        }
        UIApplication.shared.registerForRemoteNotifications()
        if !cache.isSubscribed {
            await subscribe()
        }
        await fetch()
    }

    // A call made while a fetch runs waits for that one.
    func fetch() async {
        if let fetching {
            await fetching.value
            return
        }
        let task = Task { await fetchChanges() }
        fetching = task
        await task.value
        fetching = nil
    }

    func flush() async {
        await writer.flush()
    }

    private func subscribe() async {
        let subscription = CKDatabaseSubscription(subscriptionID: "mac-tabs")
        subscription.recordType = "Device"
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await container.privateCloudDatabase.save(subscription)
            cache.isSubscribed = true
            writer.schedule(cache)
        } catch {
            Self.logger.error("Subscription: \(error, privacy: .public)")
        }
    }

    private func fetchChanges() async {
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                Self.logger.info("Account status \(status.rawValue, privacy: .public)")
                return
            }
        } catch {
            Self.logger.error("Account status: \(error, privacy: .public)")
            return
        }
        while true {
            do {
                try await fetchZone()
                break
            } catch let error as CKError where error.code == .changeTokenExpired {
                cache.token = nil
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                cache.devices = []
                cache.spaces = [:]
                cache.token = nil
                break
            } catch {
                Self.logger.error("Zone changes: \(error, privacy: .public)")
                return
            }
        }
        // Written at once: a silent push's fetch may be followed by suspension.
        writer.schedule(cache)
        await writer.flush()
    }

    // Without a token the server sends every record and no deletions, so the result replaces the cache.
    private func fetchZone() async throws {
        let database = container.privateCloudDatabase
        var token = try cache.token.flatMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        var devices: [String: MacDevice] = [:]
        var spaces: [String: MacSpace] = [:]
        if token != nil {
            devices = Dictionary(uniqueKeysWithValues: cache.devices.map { ($0.id, $0) })
            spaces = cache.spaces
        }
        var moreComing = true
        while moreComing {
            let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
            for (id, result) in changes.modificationResultsByID {
                switch result {
                case .success(let modification):
                    Self.apply(modification.record, devices: &devices, spaces: &spaces)
                case .failure(let error):
                    Self.logger.error("Record \(id.recordName, privacy: .public): \(error, privacy: .public)")
                }
            }
            for deletion in changes.deletions {
                devices[deletion.recordID.recordName] = nil
                spaces[deletion.recordID.recordName] = nil
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        cache.devices = devices.values.sorted { $0.modified > $1.modified }
        cache.spaces = spaces
        cache.token = try token.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    // CloudKit drops an empty list, so a Device record without spaces lists none.
    private static func apply(_ record: CKRecord, devices: inout [String: MacDevice], spaces: inout [String: MacSpace]) {
        let id = record.recordID.recordName
        switch record.recordType {
        case "Device":
            guard let name = record.encryptedValues["name"] as? String else {
                logger.error("Device \(id, privacy: .public) has no name")
                return
            }
            devices[id] = MacDevice(
                id: id, name: name, modified: record.modificationDate!,
                spaceIDs: record.encryptedValues["spaces"] as? [String] ?? [],
                current: record.encryptedValues["current"] as? String)
        case "Space":
            guard let content = record.encryptedValues["content"] as? Data else {
                logger.error("Space \(id, privacy: .public) has no content")
                return
            }
            do {
                spaces[id] = try JSONDecoder().decode(MacSpace.self, from: content)
            } catch {
                logger.error("Space \(id, privacy: .public): \(error, privacy: .public)")
            }
        default:
            logger.error("Unknown record type \(record.recordType, privacy: .public)")
        }
    }
}
