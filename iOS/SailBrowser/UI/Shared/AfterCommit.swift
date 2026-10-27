import CoreFoundation

// Runs work on the main run loop's turn after its next Core Animation commit, so what was set up before it is committed
// while the work holds the main thread. A block sent to the main queue from a touch runs before that turn's commit instead.
enum AfterCommit {
    // Core Animation commits at order 2000000 as the run loop is about to wait.
    private static let order = 2_000_001

    static func run(_ work: @escaping () -> Void) {
        let main = CFRunLoopGetMain()
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity([.beforeWaiting, .exit]).rawValue, false, order
        ) { _, _ in
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue, work)
            CFRunLoopWakeUp(main)
        }
        CFRunLoopAddObserver(main, observer, .commonModes)
        // Called from inside a commit, the observer waits for the run loop's next pass, which this wake-up brings at once.
        CFRunLoopWakeUp(main)
    }

}
