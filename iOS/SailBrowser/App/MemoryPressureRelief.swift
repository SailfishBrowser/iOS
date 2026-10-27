import Dispatch

// Tells the pool when the system's memory pressure is back to normal, so a warning's block on prewarming ends without
// waiting for a foreground or a new tab.
struct MemoryPressureRelief {
    // Starts watching; calls `relieved` on the main actor each time pressure returns to normal. The result stops the
    // watch.
    var watch: @MainActor (_ relieved: @escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)

    static let live = MemoryPressureRelief(watch: { relieved in
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .normal, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { relieved() } }
        source.resume()
        return { source.cancel() }
    })
}
