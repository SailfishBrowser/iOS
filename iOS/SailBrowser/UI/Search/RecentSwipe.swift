import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// The recent being swiped, as the rows draw it: its offset is how far it has moved left.
@Observable final class RecentSwipe {
    private(set) var row: Suggestion?
    private(set) var offset: CGFloat = 0
    private(set) var armed = false

    func offset(for suggestion: Suggestion) -> CGFloat {
        row == suggestion ? offset : 0
    }

    func isArmed(_ suggestion: Suggestion) -> Bool {
        row == suggestion && armed
    }

    // A frame of the row's spring home.
    func place(_ offset: CGFloat) {
        self.offset = offset
        armed = false
    }

    func follow(_ row: Suggestion, _ swipe: RowSwipe) {
        self.row = row
        offset = swipe.offset
        armed = swipe.removes
    }

    func clear() {
        row = nil
        offset = 0
        armed = false
    }
}

extension Transaction {
    private struct RecentSwipeMotion: TransactionKey {
        static let defaultValue = false
    }

    // The rows strip animations from every other change; a swipe's return and removal keep theirs.
    var recentSwipeMotion: Bool {
        get { self[RecentSwipeMotion.self] }
        set { self[RecentSwipeMotion.self] = newValue }
    }
}

// A swiped recent slides left and a red "Remove" capsule grows in the space it leaves. The label scales with the
// capsule while it grows, and moves to its leading side at the arm, where the haptic plays.
struct RecentSwipeReveal: ViewModifier {
    let swipe: RecentSwipe
    let suggestion: Suggestion

    func body(content: Content) -> some View {
        let offset = swipe.offset(for: suggestion)
        let size = RemoveCapsule.size(travel: offset)
        let armed = swipe.isArmed(suggestion)
        content
            .offset(x: -offset)
            .overlay(alignment: .trailing) {
                Text("Remove")
                    .font(Theme.Typography.recentRemoveLabel)
                    .foregroundStyle(.white)
                    .fixedSize()
                    .scaleEffect(size.height / Theme.Metrics.recentRemoveHeight)
                    .padding(.leading, armed ? Theme.Metrics.recentRemoveLabelInset : 0)
                    .frame(maxWidth: .infinity, alignment: armed ? .leading : .center)
                    .animation(Theme.Motion.recentLabel.animation, value: armed)
                    .frame(width: size.width, height: size.height)
                    .background(Theme.Palette.recentRemove, in: Capsule())
                    .padding(.trailing, Theme.Metrics.recentRemoveInset)
            }
    }
}

// A leftward drag on the rows, told from the sheet's vertical one by RowSwipe.starts. Its travel is the leftward pull
// counted from where it started, so the row moves from that frame on.
// Only the first finger counts: a second one landing mid-swipe moves nothing.
final class RowSwipeRecognizer: UIGestureRecognizer {
    private(set) var start = CGPoint.zero
    private(set) var travel: CGFloat = 0
    // The pull's speed at the release, leftward positive.
    private(set) var releaseVelocity: CGFloat = 0
    private var lock: CGFloat = 0
    private var finger: UITouch?
    private var flick = FlickVelocity()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if finger == nil {
            finger = touches.first
            start = finger!.location(in: view)
        }
        for touch in Self.ignored(touches, tracking: finger!) {
            ignore(touch, for: event)
        }
    }

    // Every touch but the tracked finger goes back to UIKit, so the swipe never waits on a second one.
    static func ignored(_ touches: Set<UITouch>, tracking finger: UITouch) -> [UITouch] {
        touches.filter { $0 !== finger }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.contains(finger!) else { return }
        let point = finger!.location(in: view)
        let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
        guard state == .possible else {
            travel = lock - translation.width
            flick.add(travel, at: finger!.timestamp)
            state = .changed
            return
        }
        switch RowSwipe.starts(translation) {
        case true?:
            lock = translation.width
            flick.add(0, at: finger!.timestamp)
            state = .began
        case false?:
            state = .failed
        case nil:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.contains(finger!) else { return }
        releaseVelocity = flick.release(at: finger!.timestamp)
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.contains(finger!) else { return }
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        travel = 0
        releaseVelocity = 0
        lock = 0
        finger = nil
        flick = FlickVelocity()
    }
}
