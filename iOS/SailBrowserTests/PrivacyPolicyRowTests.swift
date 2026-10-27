import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

// Settings links the privacy policy from inside the app (App Store guideline 5.1.1(i)), in Acknowledgements' group.
struct PrivacyPolicyRowTests {
    // The row sits with Acknowledgements, above it, and is labelled as the policy page is. SwiftUI draws a row's text
    // itself and builds no accessibility tree in a unit test, so the rows are read as pixels: the group's two rows
    // drawn in Settings match the same two rows drawn on their own.
    @Test func theSettingsSheetListsPrivacyPolicyAboveAcknowledgements() async throws {
        let env = makeEnvironment()
        let settings = try await host(SettingsView(blocklistVersion: "1").environment(env))
        defer { settings.window.isHidden = true }
        let reference = try await host(
            NavigationStack {
                Form {
                    Section {
                        Button("Privacy Policy") {}
                        NavigationLink("Acknowledgements") { EmptyView() }
                    }
                }
            })
        defer { reference.window.isHidden = true }
        let list = settings.list
        let group = list.numberOfSections - 2
        list.scrollToItem(at: IndexPath(item: 0, section: list.numberOfSections - 1), at: .bottom, animated: false)
        list.layoutIfNeeded()

        #expect(list.numberOfItems(inSection: group) == 2)
        for item in 0..<2 {
            let drawn = try #require(list.cellForItem(at: IndexPath(item: item, section: group)))
            let expected = try #require(reference.list.cellForItem(at: IndexPath(item: item, section: 0)))
            let matches = Bitmap(drawn.contentView) == Bitmap(expected.contentView)
            #expect(matches, "row \(item)")
        }
    }

    // The policy is a web page: the row opens it in a new tab in front and the sheet gives way to the page, as a
    // restored tab does.
    @Test func openingThePolicyPutsItInANewTabAndClosesTheSheetOntoIt() {
        let env = makeEnvironment()
        env.open(page("a"))
        env.ui.setDeck(1, animated: false)
        #expect(env.ui.open(.settings))

        env.openPrivacyPolicy()

        #expect(env.browser.tabs.map(\.url) == [page("a"), Theme.Links.privacyPolicy])
        #expect(env.browser.activeTab?.url == URL(string: "https://www.sail.fish/privacy")!)
        #expect(env.activeController?.tabID == env.browser.activeTabID)
        #expect(env.ui.overlay == .none)
        #expect(env.ui.deckProgress == 0)
        #expect(env.haptics.records.last?.interaction == .settingsOpen)
    }

    // A sheet in a phone-sized window at the default text size, with its list's first cells drawn.
    private func host(_ sheet: some View) async throws -> (window: UIWindow, list: UICollectionView) {
        let controller = UIHostingController(rootView: sheet)
        let window = makeWindow(at: .large)
        window.rootViewController = controller
        controller.view.layoutIfNeeded()
        try await waitUntil { !descendants(of: controller.view, UICollectionView.self).flatMap(\.visibleCells).isEmpty }
        return (window, descendants(of: controller.view, UICollectionView.self).first!)
    }
}
