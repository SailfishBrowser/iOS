import SwiftUI

// Scales on touch-down and springs back on release; the press edge only prepares the control's haptic.
struct PressStyle: ButtonStyle {
    let scale: CGFloat
    let preparing: Interaction

    func makeBody(configuration: Configuration) -> some View {
        PressedLabel(configuration: configuration, scale: scale, preparing: preparing)
    }
}

private struct PressedLabel: View {
    @Environment(AppEnvironment.self) private var env
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    let preparing: Interaction

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .scaleEffect(pressed ? scale : 1)
            .animation((pressed ? Theme.Motion.press : Theme.Motion.pressRelease).animation, value: pressed)
            .onChange(of: pressed) { _, isPressed in
                FrameRateVote.hold(isPressed ? Theme.Motion.press : Theme.Motion.pressRelease)
                if isPressed {
                    env.haptics.prepare(preparing)
                }
            }
    }
}
