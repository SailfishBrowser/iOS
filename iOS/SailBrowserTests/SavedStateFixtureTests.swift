import Foundation
import Testing
@testable import SailBrowser

private nonisolated final class FixtureBundle {}

nonisolated func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle(for: FixtureBundle.self).url(forResource: name, withExtension: "json")!)
}

// A state.json and history.json in an earlier saved-state format, with the ids the app happened to generate. From
// format 2 the archive is in its own archive.json.
nonisolated struct SavedFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let tabIDs: [String]
    let archivedID: String
    var hasArchiveFile = false

    var testDescription: String { name }

    func data(_ file: String) throws -> Data {
        try fixtureData("\(name)-\(file)")
    }

    static let all = [
        SavedFixture(
            name: "format1a",
            tabIDs: ["B1425D7C-8B52-450F-901B-C782C4C09235", "1ECF4A7E-4DED-4234-9978-4386D9F17CB5", "11F93677-7CC9-40BF-8BFF-F7EB9926F386"],
            archivedID: "4D3A7458-D74D-4EC3-91D6-CB51806DBEBD"),
        SavedFixture(
            name: "format1b",
            tabIDs: ["677C1043-019E-45CC-A130-08DD224AAAFE", "B5D87258-7F32-47B1-9956-CF99FFFBC0C5", "2890873A-F10D-45F7-9FD7-87B7B4305073"],
            archivedID: "0B39BBF2-7998-4830-8845-0F5DBF960093"),
        SavedFixture(
            name: "format2",
            tabIDs: ["5B91C4FD-FA4A-4A45-A7F0-2E148723390F", "A11F8E28-C68F-421A-A47B-785FE6698A5F", "28455E6A-D819-4D23-B1F9-EB15D06A4E85"],
            archivedID: "68718F9E-532E-45D2-916E-8C8F598CB99B", hasArchiveFile: true),
    ]
}

struct SavedStateFixtureTests {
    let directories = AppDirectories.temporary()

    private func install(_ file: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: directories.support, withIntermediateDirectories: true)
        try data.write(to: directories.support.appending(path: file))
    }

    private func install(state: Data, history: Data) throws {
        try install("state.json", state)
        try install("history.json", history)
    }

    private func install(_ fixture: SavedFixture) throws {
        try install(state: fixture.data("state"), history: fixture.data("history"))
        if fixture.hasArchiveFile {
            try install("archive.json", fixture.data("archive"))
        }
    }

    private func supportFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directories.support.path(percentEncoded: false)))
    }

    // Everything saved comes back, every setting added since takes the value a fresh install has, and the
    // archive ends up in archive.json whichever format it was saved in.
    private func expectWhole(_ fixture: SavedFixture) async throws {
        let store = BrowserStore(directories: directories)
        let history = HistoryStore(directories: directories)
        let saved = { (seconds: TimeInterval) in Date(timeIntervalSinceReferenceDate: seconds) }
        let ids = fixture.tabIDs.map { UUID(uuidString: $0)! }

        #expect(store.tabs == [
            Tab(id: ids[0], url: URL(string: "https://mail.example.com/inbox")!, title: "Inbox", isPinned: true,
                prefersDesktop: false, createdAt: saved(782_900_000), lastActiveAt: saved(782_900_000),
                tint: CodableColor(red: 0.2, green: 0.4, blue: 0.8)),
            Tab(id: ids[1], url: URL(string: "https://news.example.com/")!, title: "News", isPinned: false,
                prefersDesktop: true, createdAt: saved(782_900_060), lastActiveAt: saved(782_900_180), tint: nil),
            Tab(id: ids[2], url: URL(string: "https://docs.example.com/guide?section=2")!, title: "Guide", isPinned: false,
                prefersDesktop: false, createdAt: saved(782_900_180), lastActiveAt: saved(782_900_180), tint: nil),
        ])
        #expect(store.activeTabID == ids[1])
        let archived = [
            ArchivedTab(id: UUID(uuidString: fixture.archivedID)!, url: URL(string: "https://old.example.com/page")!,
                        title: "Old Page", archivedAt: saved(782_900_180)),
        ]
        #expect(store.archived == archived)

        var settings = BrowserSettings()
        settings.archiveInterval = .sevenDays
        // The first format's single blocking switch carries into all three blocking settings.
        settings.blocksAds = false
        settings.blocksTrackers = false
        settings.blocksCookieBanners = false
        settings.zoomByHost = ["news.example.com": 1.25]
        #expect(store.settings == settings)
        #expect(store.settings.displayOptionsExpanded)
        #expect(store.settings.opensAppLinksInApp)
        #expect(store.settings.autoOpenKeyboard)
        #expect(store.settings.searchEngine == .google)

        #expect(history.entries == [
            HistoryEntry(url: URL(string: "https://news.example.com/story")!, title: "Story", visitCount: 1,
                         lastVisit: saved(782_900_180)),
        ])
        // Nothing was moved aside as undecodable, and an archive saved inside state.json has moved to its own file.
        await store.flush()
        #expect(try supportFiles() == ["state.json", "history.json", "archive.json"])
        #expect(try JSONDecoder().decode([ArchivedTab].self, from: Data(contentsOf: directories.support.appending(path: "archive.json"))) == archived)
        #expect(BrowserStore(directories: directories).archived == archived)
    }

    @Test(arguments: SavedFixture.all)
    func aStateSavedInAnEarlierFormatLoadsWhole(_ fixture: SavedFixture) async throws {
        try install(fixture)
        try await expectWhole(fixture)
    }

    // A file written by a later build, read by this one, still loads: keys it does not know are skipped, at every level.
    @Test func aStateWithKeysFromAFutureBuildStillLoads() async throws {
        let fixture = SavedFixture.all[1]
        var state = try JSONSerialization.jsonObject(with: fixture.data("state")) as! [String: Any]
        state["futureKey"] = ["nested": true]
        var settings = state["settings"] as! [String: Any]
        settings["futureSetting"] = "on"
        state["settings"] = settings
        state["tabs"] = (state["tabs"] as! [[String: Any]]).map { $0.merging(["futureTabKey": 1]) { $1 } }
        state["archived"] = (state["archived"] as! [[String: Any]]).map { $0.merging(["futureArchiveKey": 1]) { $1 } }
        let history = (try JSONSerialization.jsonObject(with: fixture.data("history")) as! [[String: Any]])
            .map { $0.merging(["futureHistoryKey": 1]) { $1 } }
        try install(
            state: JSONSerialization.data(withJSONObject: state), history: JSONSerialization.data(withJSONObject: history))
        try await expectWhole(fixture)
    }

    // A later build's archive.json with keys this one does not know loads whole too.
    @Test func anArchiveWithKeysFromAFutureBuildStillLoads() async throws {
        let fixture = SavedFixture.all[2]
        try install(fixture)
        let archive = (try Self.object(fixture.data("archive")) as! [[String: Any]])
            .map { $0.merging(["futureArchiveKey": 1]) { $1 } }
        try install("archive.json", JSONSerialization.data(withJSONObject: archive))
        try await expectWhole(fixture)
    }

    private static func object(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    static let savedSites = [
        "script.example.com": SiteSettings(blocksTrackers: true, allowsJavaScript: false),
        "tracker.example.com": SiteSettings(blocksTrackers: false, allowsJavaScript: true),
        "strict.example.com": SiteSettings(blocksTrackers: false, allowsJavaScript: false),
    ]

    // The file predates the camera and microphone settings, so every site loads with both at Ask.
    @Test func savedSiteSettingsLoadWhole() throws {
        try install("site-settings.json", fixtureData("saved-site-settings"))
        let sites = SiteSettingsStore(directories: directories).byHost
        #expect(sites == Self.savedSites)
        #expect(sites.values.allSatisfy { $0.camera == .ask && $0.microphone == .ask })
        #expect(try supportFiles() == ["site-settings.json"])
    }

    @Test func siteSettingsWithAFutureKeyLoad() throws {
        var sites = try Self.object(fixtureData("saved-site-settings")) as! [String: [String: Any]]
        for host in sites.keys {
            sites[host]!["futureSiteKey"] = 1
        }
        try install("site-settings.json", JSONSerialization.data(withJSONObject: sites))
        #expect(SiteSettingsStore(directories: directories).byHost == Self.savedSites)
        #expect(try supportFiles() == ["site-settings.json"])
    }

    private func expectMovedAside(_ name: String) throws {
        let files = try supportFiles()
        #expect(files.count == 1)
        #expect(files.allSatisfy { $0.hasPrefix("\(name).corrupt-") && $0.hasSuffix(".json") })
    }

    // A site entry the decoder rejects sets the whole file aside, as state.json is, and the store starts empty.
    @Test func undecodableSiteSettingsAreMovedAside() throws {
        var sites = try Self.object(fixtureData("saved-site-settings")) as! [String: [String: Any]]
        sites["tracker.example.com"]!["blocksTrackers"] = "yes"
        try install("site-settings.json", JSONSerialization.data(withJSONObject: sites))
        #expect(SiteSettingsStore(directories: directories).byHost.isEmpty)
        try expectMovedAside("site-settings")
    }

    @Test func undecodableDownloadsAreMovedAside() throws {
        var records = try Self.object(fixtureData("saved-downloads")) as! [[String: Any]]
        records[1].removeValue(forKey: "id")
        try install("downloads.json", JSONSerialization.data(withJSONObject: records))
        #expect(DownloadStore(directories: directories).records.isEmpty)
        try expectMovedAside("downloads")
    }

    static func savedDownloads() throws -> [DownloadRecord] {
        let ids = (try object(fixtureData("saved-downloads")) as! [[String: Any]]).map { UUID(uuidString: $0["id"] as! String)! }
        let saved = { (seconds: TimeInterval) in Date(timeIntervalSinceReferenceDate: seconds) }
        return [
            // A download still running when the app quit comes back failed.
            DownloadRecord(
                id: ids[0], filename: "photo.jpg", sourceURL: nil, bytes: 1024, total: 8192, state: .failed,
                date: saved(783_000_200)),
            DownloadRecord(
                id: ids[1], filename: "big.zip", sourceURL: URL(string: "https://files.example.com/big.zip")!,
                bytes: 4096, total: 1_048_576, state: .failed, date: saved(783_000_100)),
            DownloadRecord(
                id: ids[2], filename: "report.pdf", sourceURL: URL(string: "https://docs.example.com/report.pdf")!,
                bytes: 2048, total: 2048, state: .finished, date: saved(783_000_000)),
        ]
    }

    // A finished record is kept only while its file is still in Downloads.
    private func installDownloads(_ data: Data) throws {
        try install("downloads.json", data)
        let folder = directories.documents.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 2048).write(to: folder.appending(path: "report.pdf"))
    }

    @Test func savedDownloadsLoadWhole() throws {
        try installDownloads(fixtureData("saved-downloads"))
        #expect(try DownloadStore(directories: directories).records == Self.savedDownloads())
        #expect(try supportFiles() == ["downloads.json"])
    }

    // No record key has been added since downloads shipped; the coverage test below makes any later one decode with a
    // default. The saved photo record already has no sourceURL.
    @Test func downloadsWithAFutureKeyLoad() throws {
        let records = (try Self.object(fixtureData("saved-downloads")) as! [[String: Any]])
            .map { $0.merging(["futureDownloadKey": 1]) { $1 } }
        try installDownloads(JSONSerialization.data(withJSONObject: records))
        #expect(try DownloadStore(directories: directories).records == Self.savedDownloads())
        #expect(try supportFiles() == ["downloads.json"])
    }

    private static func values(_ value: some Any) -> [(label: String, value: String)] {
        Mirror(reflecting: value).children.map { ($0.label!, "\($0.value)") }
    }

    // Checks a saved type's explicit decoder against its stored properties. `required` lists the keys every file has
    // carried since that file first shipped: decoding without one must throw. Every other property must decode when its
    // key is missing, to its entry in `defaults`, and `sample` must hold a value away from that default, so a property
    // added later fails here until it has a decodeIfPresent line.
    private func expectEveryKeyDecodes<Value: Codable & Equatable>(
        _ sample: Value, required: Set<String>, defaults: [String: String]
    ) throws {
        let values = Self.values(sample)
        #expect(Set(values.map(\.label)) == required.union(defaults.keys))
        #expect(required.isDisjoint(with: defaults.keys))

        let encoded = try JSONEncoder().encode(sample)
        // A decoder that skips a property would hand back its default here.
        #expect(try JSONDecoder().decode(Value.self, from: encoded) == sample)

        let object = try Self.object(encoded) as! [String: Any]
        #expect(Set(object.keys) == Set(values.map(\.label)))
        for key in required {
            var missing = object
            missing.removeValue(forKey: key)
            #expect(throws: DecodingError.self, "missing \(key)") {
                try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: missing))
            }
        }
        for (index, property) in values.enumerated() where !required.contains(property.label) {
            let fallback = try #require(defaults[property.label], "\(property.label) is in neither list")
            #expect(property.value != fallback, "\(property.label) needs a non-default value in the sample")
            var missing = object
            missing.removeValue(forKey: property.label)
            let decoded = try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: missing))
            var expected = values.map(\.value)
            expected[index] = fallback
            #expect(Self.values(decoded).map(\.value) == expected, "missing \(property.label)")
        }
    }

    private static func defaults(_ value: some Any, except required: Set<String>) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values(value).filter { !required.contains($0.label) })
    }

    @Test func everyStoredSettingIsDecodedAndOnlyFirstFormatKeysAreRequired() throws {
        var settings = BrowserSettings()
        settings.archiveInterval = .thirtyDays
        settings.blocksAds = false
        settings.blocksTrackers = false
        settings.blocksCookieBanners = false
        settings.zoomByHost = ["a.test": 1.5]
        settings.displayOptionsExpanded = false
        settings.opensAppLinksInApp = false
        settings.autoOpenKeyboard = false
        settings.searchEngine = .kagi
        // Every saved state has carried these since the first format. Its adBlockingEnabled is no longer written; the
        // decoder reads it only as the blocking settings' fallback.
        let required: Set = ["archiveInterval", "zoomByHost"]
        try expectEveryKeyDecodes(settings, required: required, defaults: Self.defaults(BrowserSettings(), except: required))
    }

    @Test func everySiteSettingIsDecodedAndTheShippedKeysAreRequired() throws {
        // Every site-settings.json has carried both since the file shipped. Camera and microphone came later.
        let required: Set = ["blocksTrackers", "allowsJavaScript"]
        try expectEveryKeyDecodes(
            SiteSettings(blocksTrackers: false, allowsJavaScript: false, camera: .allow, microphone: .deny),
            required: required,
            defaults: Self.defaults(SiteSettings(), except: required))
    }

    @Test func everyDownloadKeyIsDecodedAndOnlyTheFirstOnesAreRequired() throws {
        let record = DownloadRecord(
            id: UUID(), filename: "a.zip", sourceURL: URL(string: "https://a.test/a.zip")!, bytes: 1, total: 2,
            state: .finished, date: Date(timeIntervalSinceReferenceDate: 1))
        // Every downloads.json has carried these since downloads shipped. sourceURL is written only when it is known.
        let required: Set = ["id", "filename", "bytes", "total", "state", "date"]
        try expectEveryKeyDecodes(record, required: required, defaults: ["sourceURL": "nil"])
    }
}
