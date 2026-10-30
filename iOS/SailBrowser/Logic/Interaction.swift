import SwiftUI
import UIKit

nonisolated enum Interaction: String, CaseIterable, Sendable {
    case launch, foregroundRaise
    case tabStackTap, tabStackFlick, pinchSwitcher
    case deckCardTap, deckBackgroundTap, deckScroll, deckSettle
    case cardLift, cardArchiveArm, cardThrow, cardReturn, deckEmptied
    case plusTap, searchTyping, searchClear, suggestionTap, searchSubmit
    case searchDragDismiss, searchDragReturn, searchDimTap, searchGrabDuringOpen
    case pullTick, pullArm, pullRelease, refreshLand
    case barHide, barShow, barIntro, barSwipe, barSwipeTick, barSwipeSettle
    case chevronTap, chevronLongPress
    case barTranslate
    case menuDragDismiss, menuDragReturn, menuGrabDuringOpen, menuDimTap
    case menuNav, menuCopyLink, menuAddressEdit, menuAddressSubmit
    case pin, unpin, menuFind, menuShare, zoomStep, desktopToggle, displayOptionsToggle, menuTranslate, restorePage
    case readerOpen, readerClose, readerDragDismiss, readerDragReturn
    case archiveOpen, settingsOpen, archiveRestore, archiveDelete, settingsChange, clearData, sheetDone
    case macTabsOpen, macTabsPick
    case webEdgeSwipe
    case recentArm, recentRemove, recentReturn
    case permissionAnswer
    case privateToggle
}

nonisolated enum LatencyBudget: Equatable, Sendable {
    case frames(Int), timed, system
}

nonisolated enum MotionToken: Equatable, Sendable {
    case spring(duration: TimeInterval, bounce: Double)
    case physical(mass: Double, stiffness: Double, damping: Double)
    case curve(duration: TimeInterval, UnitCurve)
    case keyboard
}

extension MotionToken {
    nonisolated var spring: Spring {
        switch self {
        case .spring(let duration, let bounce): Spring(duration: duration, bounce: bounce)
        case .physical(let mass, let stiffness, let damping): Spring(mass: mass, stiffness: stiffness, damping: damping)
        case .keyboard: Spring(duration: Theme.Motion.keyboardDuration, bounce: 0)
        case .curve: preconditionFailure("A curve token has no spring")
        }
    }

    // How long the token's motion runs: a spring until it settles, a curve for its duration.
    nonisolated var settlingDuration: TimeInterval {
        switch self {
        case .curve(let duration, _): duration
        case .spring, .physical, .keyboard: spring.settlingDuration
        }
    }

    var animation: Animation {
        switch self {
        case .spring(let duration, let bounce): .spring(duration: duration, bounce: bounce)
        case .keyboard: .spring(duration: Theme.Motion.keyboardDuration, bounce: 0)
        case .physical: .interpolatingSpring(spring)
        case .curve(let duration, let curve):
            switch curve {
            case .easeOut: .easeOut(duration: duration)
            case .easeIn: .easeIn(duration: duration)
            case .easeInOut: .easeInOut(duration: duration)
            case .linear: .linear(duration: duration)
            default: preconditionFailure("No named animation for \(curve)")
            }
        }
    }

    func animation(initialVelocity: Double) -> Animation {
        switch self {
        case .spring(let duration, let bounce):
            .interpolatingSpring(duration: duration, bounce: bounce, initialVelocity: initialVelocity)
        case .physical: .interpolatingSpring(spring, initialVelocity: initialVelocity)
        case .keyboard:
            .interpolatingSpring(
                duration: Theme.Motion.keyboardDuration, bounce: 0, initialVelocity: initialVelocity)
        case .curve: preconditionFailure("A curve token carries no velocity")
        }
    }

    @MainActor func animate(
        initialVelocity: CGFloat, _ changes: @escaping () -> Void, completion: @escaping (Bool) -> Void
    ) {
        animate(after: 0, initialVelocity: initialVelocity, changes, completion: completion)
    }

    // UIKit refuses touches on a view while one of its block animations runs unless the animation allows them, which
    // left a rising sheet ungrabbable until its open settled; every token's motion takes touches. In practice this
    // changes only the search sheet's rise, reopen and return: the loading ring takes no touches, and a closing sheet
    // routes its own.
    @MainActor func animate(
        after delay: TimeInterval, initialVelocity: CGFloat, _ changes: @escaping () -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        switch self {
        case .spring(let duration, let bounce):
            UIView.animate(
                springDuration: duration, bounce: bounce, initialSpringVelocity: initialVelocity, delay: delay,
                options: .allowUserInteraction, animations: changes, completion: completion)
        case .physical(let mass, let stiffness, let damping):
            let timing = UISpringTimingParameters(
                mass: mass, stiffness: stiffness, damping: damping,
                initialVelocity: CGVector(dx: initialVelocity, dy: initialVelocity))
            let animator = UIViewPropertyAnimator(duration: 0, timingParameters: timing)
            animator.addAnimations(changes)
            animator.addCompletion { completion($0 == .end) }
            animator.startAnimation(afterDelay: delay)
        case .curve(let duration, let curve):
            precondition(initialVelocity == 0, "A curve token carries no velocity")
            UIView.animate(
                withDuration: duration, delay: delay, options: Self.options(for: curve).union(.allowUserInteraction),
                animations: changes, completion: completion)
        case .keyboard:
            UIView.animate(
                withDuration: Theme.Motion.keyboardDuration, delay: delay,
                options: Theme.Motion.keyboardCurve.union(.allowUserInteraction), animations: changes,
                completion: completion)
        }
    }

    // Core Animation runs a token on the render server whatever UIKit's animation state: a SwiftUI pass that applies
    // a change with UIKit animations off cannot jump it. The caller sets the model value; this runs from `from` to it,
    // asking for the deck's frame rate. A spring's velocity is relative to the distance, as SwiftUI's is.
    @MainActor func layerAnimation(keyPath: String, from: Any, initialVelocity: CGFloat = 0) -> CABasicAnimation {
        let animation: CABasicAnimation
        switch self {
        case .curve(let duration, let curve):
            precondition(initialVelocity == 0, "A curve token carries no velocity")
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: Self.timingName(for: curve))
        case .spring, .physical, .keyboard:
            // A physical token is the oscillator itself and plays as given. A bounce token goes through SwiftUI's
            // parameters, which describe its curve only for a bounce of 0 or more.
            let (mass, stiffness, damping) =
                if case .physical(let mass, let stiffness, let damping) = self {
                    (mass, stiffness, damping)
                } else {
                    (spring.mass, spring.stiffness, spring.damping)
                }
            let springAnimation = CASpringAnimation(keyPath: keyPath)
            springAnimation.mass = mass
            springAnimation.stiffness = stiffness
            springAnimation.damping = damping
            springAnimation.initialVelocity = initialVelocity
            springAnimation.duration = spring.settlingDuration
            animation = springAnimation
        }
        animation.fromValue = from
        animation.preferredFrameRateRange = Theme.Latency.frameRateRange
        return animation
    }

    // A property animator for what only UIKit can animate, such as a visual effect view's effect.
    @MainActor func propertyAnimator(_ changes: @escaping () -> Void) -> UIViewPropertyAnimator {
        guard case .curve(let duration, let curve) = self else {
            preconditionFailure("A property animator here takes a curve token")
        }
        let animator = UIViewPropertyAnimator(
            duration: duration, timingParameters: UICubicTimingParameters(animationCurve: Self.uiCurve(for: curve)))
        animator.addAnimations(changes)
        return animator
    }

    private static func uiCurve(for curve: UnitCurve) -> UIView.AnimationCurve {
        switch curve {
        case .easeOut: .easeOut
        case .easeIn: .easeIn
        case .easeInOut: .easeInOut
        case .linear: .linear
        default: preconditionFailure("UIKit has no curve for \(curve)")
        }
    }

    private static func timingName(for curve: UnitCurve) -> CAMediaTimingFunctionName {
        switch curve {
        case .easeOut: .easeOut
        case .easeIn: .easeIn
        case .easeInOut: .easeInEaseOut
        case .linear: .linear
        default: preconditionFailure("Core Animation has no named timing for \(curve)")
        }
    }

    private static func options(for curve: UnitCurve) -> UIView.AnimationOptions {
        switch curve {
        case .easeOut: .curveEaseOut
        case .easeIn: .curveEaseIn
        case .easeInOut: .curveEaseInOut
        case .linear: .curveLinear
        default: preconditionFailure("UIKit has no option for \(curve)")
        }
    }
}
