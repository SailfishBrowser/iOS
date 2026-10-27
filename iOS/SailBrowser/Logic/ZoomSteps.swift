import Foundation

nonisolated enum ZoomSteps {
    static let all: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    private static let tolerance = 0.001

    static func next(after zoom: Double) -> Double? {
        all.first { $0 > zoom + tolerance }
    }

    static func previous(before zoom: Double) -> Double? {
        all.last { $0 < zoom - tolerance }
    }
}
