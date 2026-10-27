import Foundation
import WebKit
import os

// Holds the compiled lists and PageShield, and gives each attached web view's controller the lists and scripts of the
// categories that are on, while that controller's site setting allows blocking.
final class ContentBlocker {
    private final class Attachment {
        var wantsBlocking = true
        var host = ""
        var applied: Set<BlockingCategory> = []
        var scriptedHost = ""
        var scripts: [WKUserScript] = []
        // A page decided while the lists were not on yet.
        var missedPage = false
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "blocking")

    let manifest: BlocklistManifest
    private(set) var isReady = false
    private(set) var categories: Set<BlockingCategory>
    // A controller whose page was decided before the lists were on, reported once they are; the pool reloads it.
    var onMissedPage: ((WKUserContentController) -> Void)?

    private let attachments = NSMapTable<WKUserContentController, Attachment>.weakToStrongObjects()
    private let store: WKContentRuleListStore
    private let bundle: Bundle
    private var loaded: [String: WKContentRuleList] = [:]
    private var lists: [BlockingCategory: [WKContentRuleList]] = [:]
    private var shield: PageShield?

    init(categories: Set<BlockingCategory>, store: WKContentRuleListStore = .default(), bundle: Bundle = .main) {
        self.categories = categories
        self.store = store
        self.bundle = bundle
        manifest = BlocklistManifest.bundled(in: bundle)
    }

    func prepare() async {
        await loadCachedLists()
        await compileMissingLists()
    }

    // The lists an earlier run compiled, fetched together. With every list there, blocking is on when this returns, so
    // the first page can wait for it: the usual launch has them all.
    func loadCachedLists() async {
        await fetch(missingLists, compiling: false)
        if missingLists.isEmpty {
            await finish()
        }
    }

    // Compiles the lists the store lacks, together: a first run or a new blocklist, seconds a list on a phone. A list
    // that fails to compile is logged and left out; blocking is on with the rest when this returns.
    func compileMissingLists() async {
        let missing = missingLists
        if !missing.isEmpty {
            await fetch(missing, compiling: true)
        }
        if !missing.isEmpty || !isReady {
            await finish()
        }
    }

    func setCategories(_ categories: Set<BlockingCategory>) {
        self.categories = categories
        applyToAll()
    }

    func attach(_ controller: WKUserContentController) {
        attachments.setObject(Attachment(), forKey: controller)
        apply(to: controller)
    }

    // A site's setting and the host its scripts are built for, applied when a main frame navigation is decided.
    func setBlocking(_ on: Bool, host: String, on controller: WKUserContentController) {
        let attachment = attachments.object(forKey: controller)!
        attachment.wantsBlocking = on
        attachment.host = host
        attachment.missedPage = on && !isReady && !host.isEmpty
        apply(to: controller)
    }

    func blockedCategories(_ controller: WKUserContentController) -> Set<BlockingCategory> {
        attachments.object(forKey: controller)!.applied
    }

    func isBlocking(_ controller: WKUserContentController) -> Bool {
        !blockedCategories(controller).isEmpty
    }

    // The lists an attached controller's pages are under now, for a web view of their own such as the reader.
    func ruleLists(for controller: WKUserContentController) -> [WKContentRuleList] {
        BlockingCategory.allCases.filter(blockedCategories(controller).contains).flatMap { lists[$0, default: []] }
    }

    private var missingLists: [BlocklistManifest.List] {
        manifest.lists.filter { loaded[manifest.identifier(for: $0)] == nil }
    }

    // Fetches the lists from the store together: as compiled by an earlier run, or compiled now from the bundled JSON.
    private func fetch(_ lists: [BlocklistManifest.List], compiling: Bool) async {
        let fetches = lists.map { list in Task { @MainActor in await self.fetch(list, compiling: compiling) } }
        for fetch in fetches {
            await fetch.value
        }
    }

    private func fetch(_ list: BlocklistManifest.List, compiling: Bool) async {
        let id = manifest.identifier(for: list)
        if compiling {
            do {
                loaded[id] = try await compile(list, id: id)
            } catch {
                Self.logger.error("\(list.name) did not compile: \(error)")
            }
        } else if let cached = try? await store.contentRuleList(forIdentifier: id) {
            loaded[id] = cached
        }
    }

    private func compile(_ list: BlocklistManifest.List, id: String) async throws -> WKContentRuleList {
        let json = try await Self.read(bundle.url(forResource: list.name, withExtension: "json")!)
        return try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)!
    }

    // The lists go on, in the manifest's order, with PageShield's scripts, to every attached controller, and a page
    // decided before they were on is reported for its reload.
    private func finish() async {
        lists = [:]
        for list in manifest.lists {
            if let rules = loaded[manifest.identifier(for: list)] {
                lists[list.category, default: []].append(rules)
            }
        }
        if shield == nil {
            do {
                shield = try await PageShield.bundled(in: bundle)
            } catch {
                Self.logger.error("PageShield unavailable: \(error)")
                return
            }
        }
        do {
            try await removeStaleLists()
        } catch {
            Self.logger.error("Stale rule lists remain: \(error)")
        }
        isReady = true
        applyToAll()
        for controller in attached {
            let attachment = attachments.object(forKey: controller)!
            guard attachment.missedPage else { continue }
            attachment.missedPage = false
            if !attachment.applied.isEmpty {
                onMissedPage?(controller)
            }
        }
    }

    private func removeStaleLists() async throws {
        let current = Set(manifest.lists.map(manifest.identifier(for:)))
        for stale in await store.availableIdentifiers() ?? [] where !current.contains(stale) {
            try await store.removeContentRuleList(forIdentifier: stale)
        }
    }

    @concurrent private static func read(_ url: URL) async throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private var attached: [WKUserContentController] {
        attachments.keyEnumerator().allObjects as! [WKUserContentController]
    }

    private func applyToAll() {
        attached.forEach(apply(to:))
    }

    // Scriptlets share the page world with other features' scripts, so those are put back after the swap.
    private func apply(to controller: WKUserContentController) {
        let attachment = attachments.object(forKey: controller)!
        let target = isReady && attachment.wantsBlocking ? categories : []
        guard target != attachment.applied || (!target.isEmpty && attachment.host != attachment.scriptedHost)
        else { return }
        if target != attachment.applied {
            controller.removeAllContentRuleLists()
            for category in target {
                lists[category, default: []].forEach(controller.add)
            }
        }
        let others = controller.userScripts.filter { script in !attachment.scripts.contains { $0 === script } }
        attachment.scripts = shield!.scripts(for: attachment.host, categories: target)
        controller.removeAllUserScripts()
        (others + attachment.scripts).forEach(controller.addUserScript)
        attachment.applied = target
        attachment.scriptedHost = attachment.host
    }
}
