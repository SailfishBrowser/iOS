import Testing
@testable import SailBrowser

struct KeyboardResignTests {
    @Test func aResignDuringTheShowWaitsForTheShowToEnd() {
        var keyboard = KeyboardResign()
        keyboard.willShow()
        let midShow = keyboard.resignNow()
        let atShown = keyboard.didShow()
        let atNextShow = keyboard.didShow()
        #expect(!midShow)
        #expect(atShown)
        #expect(!atNextShow)
    }

    @Test func aResignWithNoShowInFlightRunsAtOnce() {
        var keyboard = KeyboardResign()
        let idle = keyboard.resignNow()
        keyboard.willShow()
        _ = keyboard.didShow()
        let shown = keyboard.resignNow()
        #expect(idle)
        #expect(shown)
    }

    @Test func aRefocusCancelsTheWaitingResign() {
        var keyboard = KeyboardResign()
        keyboard.willShow()
        let midShow = keyboard.resignNow()
        keyboard.refocus()
        let atShown = keyboard.didShow()
        #expect(!midShow)
        #expect(!atShown)
    }
}
