import UIKit

// The pixel readers the chrome's look tests share. A backdrop is captured only by drawHierarchy(afterScreenUpdates:)
// of the whole key window (layer.render(in:) and ImageRenderer draw none), so hand Bitmap the window, with the colour
// "page" in the same window, and assert on differences and ranges, never on absolute levels: the simulator's materials
// differ from the phone's.

// A view drawn at twice its points, read as grey levels.
@MainActor struct Bitmap: Equatable {
    private static let scale: CGFloat = 2
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let grey: [UInt8]
    let height: CGFloat

    init(_ view: UIView) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.scale
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.cgImage!
        pixelWidth = image.width
        pixelHeight = image.height
        height = CGFloat(image.height) / Self.scale
        var grey = [UInt8](repeating: 0, count: image.width * image.height)
        grey.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.grey = grey
    }

    // The grey level at a point.
    func luma(x: CGFloat, y: CGFloat) -> Int {
        Int(grey[Int(y * Self.scale) * pixelWidth + Int(x * Self.scale)])
    }

    // Max minus min in grey levels over a region, in points.
    func range(in rect: CGRect) -> Int {
        var low = 255, high = 0
        for y in Int(rect.minY * Self.scale)..<Int(rect.maxY * Self.scale) {
            for x in Int(rect.minX * Self.scale)..<Int(rect.maxX * Self.scale) {
                let value = Int(grey[y * pixelWidth + x])
                low = min(low, value)
                high = max(high, value)
            }
        }
        return high - low
    }

    // The stretches, in points, along a column or a row where the pixels pass.
    func runs(column x: CGFloat, where pass: (UInt8) -> Bool) -> [ClosedRange<CGFloat>] {
        let pixel = Int(x * Self.scale)
        return runs(count: pixelHeight) { pass(grey[$0 * pixelWidth + pixel]) }
    }

    // The stretches along y where any pixel of the row between the columns passes, inside `rows`.
    func runs(
        down columns: ClosedRange<CGFloat>, within rows: ClosedRange<CGFloat>, where pass: (UInt8) -> Bool
    ) -> [ClosedRange<CGFloat>] {
        let pixels = Int(columns.lowerBound * Self.scale)..<Int(columns.upperBound * Self.scale)
        let first = Int(rows.lowerBound * Self.scale)
        let count = Int(rows.upperBound * Self.scale) - first
        return runs(count: count) { y in pixels.contains { pass(grey[(first + y) * pixelWidth + $0]) } }
            .map { ($0.lowerBound + CGFloat(first) / Self.scale)...($0.upperBound + CGFloat(first) / Self.scale) }
    }

    func runs(row y: CGFloat, where pass: (UInt8) -> Bool) -> [ClosedRange<CGFloat>] {
        let pixel = Int(y * Self.scale)
        return runs(count: pixelWidth) { pass(grey[pixel * pixelWidth + $0]) }
    }

    // The stretches along x where any pixel of the column between the rows passes.
    func runs(across rows: ClosedRange<CGFloat>, where pass: (UInt8) -> Bool) -> [ClosedRange<CGFloat>] {
        let pixels = Int(rows.lowerBound * Self.scale)..<Int(rows.upperBound * Self.scale)
        return runs(count: pixelWidth) { x in pixels.contains { pass(grey[$0 * pixelWidth + x]) } }
    }

    private func runs(count: Int, _ pass: (Int) -> Bool) -> [ClosedRange<CGFloat>] {
        var found: [ClosedRange<CGFloat>] = []
        var start: Int?
        for index in 0...count {
            let passes = index < count && pass(index)
            if passes, start == nil {
                start = index
            } else if !passes, let first = start {
                found.append(CGFloat(first) / Self.scale...CGFloat(index) / Self.scale)
                start = nil
            }
        }
        return found
    }
}

// One point of the window as drawn, RGB 0 to 255, through the drawHierarchy path BarPillTests.render reads the bar by.
@MainActor func rgb(of window: UIWindow, at point: CGPoint) -> (red: Int, green: Int, blue: Int) {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }.cgImage!.cropping(to: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1))!
    var pixel = [UInt8](repeating: 0, count: 4)
    CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    .draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
}

extension UIView {
    // Every view of the type below this one, depth first.
    func descendants<T: UIView>(_ type: T.Type) -> [T] {
        subviews.flatMap { [$0 as? T].compactMap { $0 } + $0.descendants(type) }
    }
}

// 1 pt black and white rows: the sharpest page a blur can be asked to flatten.
final class StripesView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        UIColor.white.setFill()
        UIRectFill(rect)
        UIColor.black.setFill()
        for y in stride(from: CGFloat(0), to: bounds.height, by: 2) {
            UIRectFill(CGRect(x: 0, y: y, width: bounds.width, height: 1))
        }
    }
}
