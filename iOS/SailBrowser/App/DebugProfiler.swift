#if DEBUG
import QuartzCore
import UIKit
import os

final class DebugProfiler {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "profile")
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier!, category: .pointsOfInterest)
    private static let lateFactor = 1.5
    private static let workTurn: CFTimeInterval = 0.0005
    private static var active: DebugProfiler?

    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var busyStart: CFTimeInterval?
    private var busy: CFTimeInterval = 0
    private var frames: [CFTimeInterval] = []
    private var frameTimes: [CFTimeInterval] = []
    private var intervals: [CFTimeInterval] = []
    private var updates: [CFTimeInterval] = []
    private var progressTrace: [(time: CFTimeInterval, progress: CGFloat)] = []
    private var firstDeckFrame: CFTimeInterval?
    private var lastTimestamp: CFTimeInterval?
    private var started: CFTimeInterval = 0
    private var startedAt = ContinuousClock.now
    private var turns: [CFTimeInterval] = []
    private var onFrame: ((CFTimeInterval) -> Void)?
    private let passive = UserDefaults.standard.bool(forKey: "SailProfilePassive")

    static func report(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static var maximumFramesPerSecond: Int {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first!.maximumFramesPerSecond
    }

    static func markDeckFrame(at time: ContinuousClock.Instant) {
        guard let profiler = active, profiler.firstDeckFrame == nil else { return }
        profiler.firstDeckFrame = (time - profiler.startedAt) / .seconds(1)
    }

    static func markUpdate(progress: CGFloat) {
        let now = CACurrentMediaTime()
        active?.progressTrace.append((now - (active?.started ?? now), progress))
        active?.updates.append(now)
    }

    func measure(_ name: String, for duration: Duration, onFrame: ((CFTimeInterval) -> Void)? = nil) async throws {
        let state = Self.signposter.beginInterval("phase", "\(name, privacy: .public)")
        frames = []
        progressTrace = []
        firstDeckFrame = nil
        frameTimes = []
        intervals = []
        updates = []
        turns = []
        lastTimestamp = nil
        busy = 0
        busyStart = nil
        self.onFrame = onFrame
        Self.active = self
        start()
        defer { stop() }
        try await Task.sleep(for: duration)
        Self.active = nil
        Self.signposter.endInterval("phase", state)
        Self.report(summary(name))
    }

    private func summary(_ name: String) -> String {
        let nominal = 1 / Double(Self.maximumFramesPerSecond)
        let ms = { (values: [CFTimeInterval]) in values.map { $0 * 1000 }.sorted() }
        let main = ms(Array(frames.dropFirst()))
        let gaps = ms(intervals)
        let updateGaps = ms(zip(updates.dropFirst(), updates).map(-))
        let late = intervals.filter { $0 > nominal * Self.lateFactor }.count
        let fps = Double(intervals.count) / intervals.reduce(0, +)
        let updateSpan = (updates.last ?? 0) - (updates.first ?? 0)
        let updateFPS = updates.count > 1 ? Double(updates.count - 1) / updateSpan : 0
        let head = "PROFILE \(name)\(passive ? " passive" : "") fps=\(fixed(fps)) frames=\(intervals.count) late=\(late)"
        let interval =
            " interval p50=\(fixed(percentile(gaps, 0.5))) p95=\(fixed(percentile(gaps, 0.95))) max=\(fixed(gaps.last ?? 0))"
        let busy = " main p50=\(fixed(percentile(main, 0.5))) p95=\(fixed(percentile(main, 0.95))) max=\(fixed(main.last ?? 0))"
        let animation = " updates=\(updates.count) updateFps=\(fixed(updateFPS)) updateMax=\(fixed(updateGaps.last ?? 0))"
        let timing = turnText + " mainMaxAt=\(fixed(longestFrameTime() * 1000))ms firstDeckFrameAt=\(firstFrameText)ms"
        return head + interval + busy + animation + timing + (name.hasPrefix("zoom") ? progressText : "")
    }

    // A main run loop turn that works for half a millisecond or more ends in a Core Animation commit, while idle
    // wake-ups (WebKit's messages, timers) take a few hundredths. In passive mode, with no profiler link waking the
    // loop, the working turns' cadence is the app's commit cadence: 8.33 ms for motion the app plays at 120 Hz, 16.67 ms
    // at 60, and a handful of turns for motion that runs on the render server.
    private var turnText: String {
        guard passive else { return "" }
        let gaps = zip(turns.dropFirst(), turns).map { ($0 - $1) * 1000 }.sorted()
        return " workTurns=\(turns.count) workTurnP50=\(fixed(percentile(gaps, 0.5)))"
    }

    private var firstFrameText: String {
        firstDeckFrame.map { fixed($0 * 1000) } ?? "none"
    }

    private var progressText: String {
        let samples: [String] = progressTrace.map { sample in
            fixed(sample.time * 1000) + ":" + String(format: "%.3f", sample.progress)
        }
        return " progress=" + samples.joined(separator: ",")
    }

    private func longestFrameTime() -> CFTimeInterval {
        frames.indices.dropFirst().max { frames[$0] < frames[$1] }.map { frameTimes[$0] } ?? 0
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * fraction)]
    }

    private func fixed(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func start() {
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [unowned self] _, activity in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    busyStart = now
                } else if let begin = busyStart {
                    if now - begin >= Self.workTurn {
                        turns.append(begin)
                    }
                    busy += now - begin
                    busyStart = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        started = CACurrentMediaTime()
        startedAt = .now
        guard !passive else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = Theme.Latency.frameRateRange
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        observer = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let begin = busyStart {
            let now = CACurrentMediaTime()
            busy += now - begin
            busyStart = now
        }
        frames.append(busy)
        frameTimes.append(CACurrentMediaTime() - started)
        busy = 0
        if let lastTimestamp {
            intervals.append(link.timestamp - lastTimestamp)
        }
        lastTimestamp = link.timestamp
        onFrame?(link.timestamp - started)
    }
}
#endif
