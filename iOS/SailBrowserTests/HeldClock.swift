import QuartzCore

// Holds a layer tree's animation time still and moves it on by set steps, so a test reads drawn values at exact animation
// times however late its turns run under load.
@MainActor struct HeldClock {
    let layer: CALayer

    init(_ layer: CALayer) {
        self.layer = layer
        hold()
    }

    // Held, Core Animation never delivers an animation's end, even one already passed.
    func hold() {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = now
    }

    // Lets the time creep on at a thousandth of real time: the ends already passed are delivered, and an end even a
    // few milliseconds on stays seconds of real time away.
    func creep() {
        let held = layer.timeOffset
        layer.beginTime = CACurrentMediaTime()
        layer.timeOffset = held
        layer.speed = 0.001
    }

    var now: CFTimeInterval {
        layer.timeOffset
    }

    // Only while held.
    // Committed at once: a presentation read goes by the committed time, not the one just set.
    func step(by interval: CFTimeInterval = 1.0 / 60) {
        layer.timeOffset += interval
        CATransaction.flush()
    }

    // Lets the tree's time run on in real time from where it is held.
    func resume() {
        let held = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - held
    }

    // Whether every animation on the layer has run its full duration in the layer's own time. The flush commits any
    // animation added this turn, which until then has no begin time and would read as ended.
    static func hasEnded(_ layer: CALayer) -> Bool {
        CATransaction.flush()
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        return (layer.animationKeys() ?? []).allSatisfy {
            let animation = layer.animation(forKey: $0)!
            return animation.beginTime + animation.duration <= now
        }
    }
}
