import QuartzCore
import Testing
import UIKit
@testable import SailBrowser

// The close's springs against measured per-frame tables of the sheet's top and the field's collapse. Entry k is the
// value (k + 1) / 60 s after the motion starts, 0 before it. Every presented frame must sit within 2 pt of the table at
// its time, or within the values the table passes through a frame either side.
@MainActor @Suite(.serialized)
struct CloseFidelityTests {
    private static let tapTop: [CGFloat] = [
        0.0625, 0.1415, 0.226, 0.334, 0.4223, 0.510, 0.5915, 0.6653, 0.7365, 0.7995, 0.8508, 0.8915, 0.9238, 0.9485,
        0.9655, 0.9785, 0.9875, 0.993, 0.9968, 0.9993, 1,
    ]
    private static let releaseTop: [CGFloat] = [
        0.133, 0.237, 0.337, 0.458, 0.564, 0.659, 0.740, 0.806, 0.860, 0.902, 0.933, 0.957, 0.973, 0.984, 0.992, 0.996,
        0.999, 1,
    ]
    private static let collapse: [CGFloat] = [
        0.040, 0.122, 0.219, 0.343, 0.459, 0.567, 0.662, 0.743, 0.808, 0.861, 0.902, 0.933, 0.957, 0.973, 0.984, 0.991,
        0.996, 0.999, 1,
    ]
    private static let frame = Theme.Motion.searchCloseFrame

    private func opened() async throws -> (SearchSheetController, UIWindow) {
        let (controller, window) = hostedSearchSheet()
        try await waitUntil { controller.keyboardShown }
        try await Task.sleep(for: .milliseconds(300))
        return (controller, window)
    }

    private static func expected(_ table: [CGFloat], at time: CFTimeInterval, after lag: Int = 0) -> CGFloat {
        let position = time / frame - Double(lag)
        guard position > 0 else { return 0 }
        guard position < Double(table.count) else { return table.last! }
        let index = Int(position.rounded(.down))
        let before = index == 0 ? 0 : table[index - 1]
        return before + (table[index] - before) * CGFloat(position - Double(index))
    }

    // Misses as (seconds since begin, presented, expected) for samples outside 2 pt and outside a frame either side.
    private static func misses(
        _ samples: [(time: CFTimeInterval, value: CGFloat)], _ table: [CGFloat], scale: CGFloat, after lag: Int = 0
    ) -> [(CFTimeInterval, CGFloat, CGFloat)] {
        samples.compactMap { sample in
            let now = expected(table, at: sample.time, after: lag) * scale
            let early = expected(table, at: sample.time - frame, after: lag) * scale
            let late = expected(table, at: sample.time + frame, after: lag) * scale
            let near = abs(sample.value - now) <= 2 || (min(early, late)...max(early, late)).contains(sample.value)
            return near ? nil : (sample.time, sample.value, now)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func theTappedCloseFollowsTheMeasuredTopAndCollapse() async throws {
        let (controller, window) = try await opened()
        let startTop = controller.container.layer.presentation()!.frame.minY
        let fullWidth = controller.capsule.layer.presentation()!.bounds.width
        controller.setActive(false, submitting: false)
        let begin = controller.container.layer.animation(forKey: "transform")!.beginTime
        let travel = controller.container.transform.ty
        let trace = PresentedTrace<(CGFloat, CGFloat)>(begin: begin) {
            (controller.container.layer.presentation()!.frame.minY - startTop,
             fullWidth - controller.capsule.layer.presentation()!.bounds.width)
        }
        try await waitUntil(timeout: .seconds(2)) { controller.container.isHidden }
        trace.stop()
        // The sheet is drawn until its hand-off frame; after it the bar is.
        let shown = trace.samples.filter {
            $0.time <= Double(Theme.Motion.searchTapCloseFrames) * Self.frame
        }
        #expect(shown.count > 10)
        let top = Self.misses(shown.map { ($0.time, $0.values.0) }, Self.tapTop, scale: travel)
        let narrowing = fullWidth - Theme.Metrics.pillSize.width
        let width = Self.misses(
            shown.map { ($0.time, $0.values.1) }, Self.collapse, scale: narrowing,
            after: Theme.Motion.searchTapCollapseLag)
        #expect(top.isEmpty, "\(top)")
        #expect(width.isEmpty, "\(width)")
        window.isHidden = true
    }

    @Test(.timeLimit(.minutes(1)))
    func aReleaseFollowsTheMeasuredTopAndCollapse() async throws {
        let (controller, window) = try await opened()
        let fullWidth = controller.capsule.layer.presentation()!.bounds.width
        controller.dragBegan()
        controller.dragChanged(240)
        // The release takes the sheet from where it is drawn, so the drag's last write is on screen first.
        try await Task.sleep(for: .milliseconds(50))
        let startTop = controller.container.layer.presentation()!.frame.minY
        controller.dragEnded(translation: 240, velocity: 1500)
        let begin = try #require(controller.container.layer.animation(forKey: "transform")).beginTime
        let travel = controller.container.transform.ty
        let trace = PresentedTrace<(CGFloat, CGFloat)>(begin: begin) {
            (controller.container.layer.presentation()!.frame.minY - startTop,
             fullWidth - controller.capsule.layer.presentation()!.bounds.width)
        }
        try await waitUntil(timeout: .seconds(2)) { controller.container.isHidden }
        trace.stop()
        let shown = trace.samples.filter {
            $0.time <= Double(Theme.Motion.searchReleaseCloseFrames) * Self.frame
        }
        let top = Self.misses(shown.map { ($0.time, $0.values.0) }, Self.releaseTop, scale: travel)
        let width = Self.misses(
            shown.map { ($0.time, $0.values.1) }, Self.collapse, scale: fullWidth - Theme.Metrics.pillSize.width)
        #expect(top.isEmpty, "\(top)")
        #expect(width.isEmpty, "\(width)")
        window.isHidden = true
    }
}

// Samples presented values on every display frame, with the time since a motion's begin.
@MainActor private final class PresentedTrace<Values>: NSObject {
    private(set) var samples: [(time: CFTimeInterval, values: Values)] = []
    private let begin: CFTimeInterval
    private let read: () -> Values
    private var link: CADisplayLink?

    init(begin: CFTimeInterval, read: @escaping () -> Values) {
        self.begin = begin
        self.read = read
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
    }

    @objc private func tick(_ link: CADisplayLink) {
        samples.append((CACurrentMediaTime() - begin, read()))
    }
}
