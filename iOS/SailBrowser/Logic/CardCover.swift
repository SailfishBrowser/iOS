import CoreGraphics
import Foundation

nonisolated struct CardCover: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case none, zoom, hold, waiting, waitingToCut, fading }

    private(set) var tabID: UUID?
    private(set) var phase: Phase = .none

    // A submitted tab cuts in: it shows the moment its first paint is proven, with no cover over it.
    mutating func activated(_ id: UUID, progress: CGFloat, revealable: Bool, cutsIn: Bool = false) {
        tabID = cutsIn && revealable ? nil : id
        phase = switch (cutsIn, revealable) {
        case (true, true): .none
        case (true, false): .waitingToCut
        case (false, false): .waiting
        case (false, true): progress > 0 ? .zoom : .hold
        }
    }

    mutating func becameRevealable(_ id: UUID) {
        guard id == tabID else { return }
        switch phase {
        case .waiting: phase = .fading
        case .waitingToCut:
            tabID = nil
            phase = .none
        case .none, .zoom, .hold, .fading: break
        }
    }

    mutating func holdElapsed(_ id: UUID) {
        if id == tabID, phase == .hold {
            phase = .fading
        }
    }

    mutating func fadeFinished(_ id: UUID) {
        if id == tabID, phase == .fading {
            tabID = nil
            phase = .none
        }
    }

    mutating func switcherOpened() {
        if phase == .zoom {
            tabID = nil
            phase = .none
        }
    }

    var waitsToCut: Bool {
        phase == .waitingToCut
    }

    func opacity(for id: UUID, progress: CGFloat) -> CGFloat {
        guard id == tabID else { return 0 }
        switch phase {
        case .none, .fading: return 0
        case .hold, .waiting, .waitingToCut: return 1
        case .zoom: return max(0, min(1, progress / Theme.Motion.coverZoomFade))
        }
    }
}
