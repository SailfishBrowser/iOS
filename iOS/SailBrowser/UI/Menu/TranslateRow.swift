import SwiftUI

// No row while the page's language is unknown, already the device's, or a pair the Translation framework lacks.
enum TranslateRow {
    struct Look: Equatable {
        let title: String
        // The language the tap leads to; nil while translating, when a spinner shows instead.
        let detail: String?
        let isEnabled: Bool
    }

    // The row shows `source`, the menu's copy of the translator's, which can trail it while a closing menu holds its
    // height; until they agree the row cannot be tapped.
    static func rows(for translator: PageTranslator, source: Locale.Language?, env: AppEnvironment) -> [MenuRow] {
        guard let source else { return [] }
        let look = look(translator.state, source: source, target: translator.target)
        return [
            MenuRow(
                id: "translate", icon: "globe.americas.fill", title: look.title, accessory: .status(look.detail),
                action: { tap(translator, firing: .menuTranslate, closingMenu: true, env: env) },
                isEnabled: look.isEnabled && translator.source == source)
        ]
    }

    static func look(_ state: PageTranslator.State, source: Locale.Language, target: Locale.Language) -> Look {
        switch state {
        case .idle, .failed: Look(title: "Translate", detail: name(of: target), isEnabled: true)
        case .translating: Look(title: "Translate", detail: nil, isEnabled: false)
        case .translated: Look(title: "Show Original", detail: name(of: source), isEnabled: true)
        }
    }

    static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)!
    }

    // The row's and the bar button's tap. Nothing in the turn between a reset and the next render, when the offer is
    // gone but the control still shows: a run then would have no language.
    static func tap(_ translator: PageTranslator, firing interaction: Interaction, closingMenu: Bool, env: AppEnvironment) {
        let isTranslated = if case .translated = translator.state { true } else { false }
        guard translator.source != nil || isTranslated else { return }
        env.haptics.fire(interaction)
        if closingMenu {
            env.ui.close()
        }
        if isTranslated {
            Task { await translator.showOriginal() }
        } else {
            env.translation.request(translator)
        }
    }
}
