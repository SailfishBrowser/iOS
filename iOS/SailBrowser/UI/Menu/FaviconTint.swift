import UIKit

// The site's colour as the page menu shows it: the favicon's most common hue among its clearly coloured pixels,
// averaged. White, black and greys are not a colour here, so a favicon of only those gives none.
nonisolated enum FaviconTint {
    private static let hueBins = 12
    private static let minimumSaturation: CGFloat = 0.3
    private static let minimumBrightness: CGFloat = 0.2
    private static let minimumAlpha: CGFloat = 0.5

    static func dominant(in image: UIImage) -> UIColor? {
        // At the icon's own pixels (the store keeps them at 64 or fewer a side), so no resampling blends its colours.
        let icon = image.cgImage!
        var pixels = [UInt8](repeating: 0, count: icon.width * icon.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: icon.width, height: icon.height, bitsPerComponent: 8,
                bytesPerRow: icon.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            .draw(icon, in: CGRect(x: 0, y: 0, width: icon.width, height: icon.height))
        }
        var bins = [(count: Int, red: CGFloat, green: CGFloat, blue: CGFloat)](
            repeating: (0, 0, 0, 0), count: hueBins)
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[pixel + 3]) / 255
            guard alpha >= minimumAlpha else { continue }
            let red = CGFloat(pixels[pixel]) / 255 / alpha
            let green = CGFloat(pixels[pixel + 1]) / 255 / alpha
            let blue = CGFloat(pixels[pixel + 2]) / 255 / alpha
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            UIColor(red: red, green: green, blue: blue, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation >= minimumSaturation, brightness >= minimumBrightness else { continue }
            let bin = min(Int(hue * CGFloat(hueBins)), hueBins - 1)
            bins[bin].count += 1
            bins[bin].red += red
            bins[bin].green += green
            bins[bin].blue += blue
        }
        let top = bins.max { $0.count < $1.count }!
        guard top.count > 0 else { return nil }
        let count = CGFloat(top.count)
        return UIColor(red: top.red / count, green: top.green / count, blue: top.blue / count, alpha: 1)
    }
}
