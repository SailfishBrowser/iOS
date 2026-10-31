import SwiftUI

// A Settings row's name beside a white symbol on a colored square.
struct SettingsLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    init(_ title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(Theme.Typography.settingsIconGlyph)
                .foregroundStyle(.white)
                .frame(width: Theme.Metrics.settingsIcon, height: Theme.Metrics.settingsIcon)
                .background(color, in: .rect(cornerRadius: Theme.Metrics.settingsIconRadius, style: .continuous))
        }
    }
}
