import QuartzCore

// Runs work on a transition's own display frames: frame k is drawn k / 60 s after its animations begin, so a
// step lands on its measured frame whatever the main thread's timing. Frames are counted in
// the animated layer's own time, where its animations' begin is.
final class CloseClock {
    private let begin: CFTimeInterval
    private let layer: CALayer
    private var steps: [(frame: Int, run: () -> Void)]
    private var clock: FrameClock?

    init(begin: CFTimeInterval, in layer: CALayer, steps: [(frame: Int, run: () -> Void)]) {
        self.begin = begin
        self.layer = layer
        self.steps = steps
    }

    // A step runs on the link tick nearest its own time, up to half a link frame early or late at any rate. At 120 Hz a
    // display frame falls halfway between two measured 60 Hz frames.
    static func frame(at timestamp: CFTimeInterval, since begin: CFTimeInterval, linkFrame: CFTimeInterval) -> Int {
        Int(((timestamp - begin + linkFrame / 2) / Theme.Motion.searchCloseFrame).rounded(.down))
    }

    func start() {
        clock = FrameClock(in: layer) { [weak self] time, linkFrame in
            guard let self else { return false }
            advance(to: time, linkFrame: linkFrame)
            return !steps.isEmpty
        }
    }

    func cancel() {
        clock?.stop()
    }

    func advance(to timestamp: CFTimeInterval, linkFrame: CFTimeInterval) {
        let now = Self.frame(at: timestamp, since: begin, linkFrame: linkFrame)
        while let step = steps.first, step.frame <= now {
            steps.removeFirst()
            step.run()
        }
    }
}
