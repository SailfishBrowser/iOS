import CoreGraphics

// What UIKit's interactive dismissal did to the keyboard during a drag, read from the notifications it posts, so a
// returning release knows whether the sheet rides the keyboard back. A keyboard the finger never reached never moved,
// and nothing comes back.
struct KeyboardRide {
    let grabbed: Bool
    private(set) var moved = false

    init(grabbed: Bool) {
        self.grabbed = grabbed
    }

    // Any frame the keyboard is heading for during the drag that is not its rest means UIKit has it; a frame back to
    // rest afterwards is UIKit reverting on its own, and the ride stays.
    mutating func keyboardWillChangeFrame(to end: CGRect, rest: CGRect) {
        guard grabbed, end != rest else { return }
        moved = true
    }

    // UIKit completed the dismissal; the keyboard is asked for again on the return and the sheet rides it up.
    mutating func keyboardWillHide() {
        guard grabbed else { return }
        moved = true
    }

    var returnRidesKeyboard: Bool {
        grabbed && moved
    }
}
