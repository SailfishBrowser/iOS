// Resigning while the keyboard is still showing can fail, or leave the keyboard drawn with no field focused
// until the next open, so a resign asked for mid-show waits for the show to end.
struct KeyboardResign {
    private(set) var showing = false
    private var waiting = false

    mutating func willShow() {
        showing = true
    }

    mutating func willHide() {
        showing = false
    }

    mutating func didShow() -> Bool {
        showing = false
        defer { waiting = false }
        return waiting
    }

    mutating func resignNow() -> Bool {
        waiting = showing
        return !showing
    }

    mutating func refocus() {
        waiting = false
    }
}
