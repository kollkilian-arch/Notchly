import AppKit

enum ArtworkColor {
    /// A vivid colour that represents the artwork, tuned to read well on the notch's black.
    /// Returns `nil` for greyscale or very dark artwork (the UI then stays white).
    static func accent(for image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // Downsample to 32×32 so this is cheap and averages out noise.
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        // Vote for a hue (12 bins), weighting each pixel by how vivid it is.
        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var sum = [[Double]](repeating: [0, 0, 0], count: bins)
        var totalVivid = 0.0

        for i in 0..<(size * size) {
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let b = Double(pixels[i * 4 + 2]) / 255
            let (h, s, v) = hsv(r, g, b)
            guard s > 0.2, v > 0.25 else { continue }     // skip greys, blacks and washed-out pixels
            let w = s * v
            let bin = min(Int(h * Double(bins)), bins - 1)
            weight[bin] += w
            sum[bin][0] += r * w; sum[bin][1] += g * w; sum[bin][2] += b * w
            totalVivid += w
        }

        // Need at least ~1.5% vivid area, otherwise the art is effectively greyscale.
        guard totalVivid > 15, let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0 else {
            return nil
        }

        let w = weight[best]
        let avg = NSColor(srgbRed: sum[best][0] / w, green: sum[best][1] / w, blue: sum[best][2] / w, alpha: 1)

        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        avg.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        // Keep the hue, but make it bright and saturated enough to stand out on black.
        return NSColor(hue: hue, saturation: min(max(sat, 0.45), 0.9), brightness: max(bri, 0.85), alpha: 1)
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
        guard d > 0 else { return (0, 0, maxC) }
        var h: Double
        switch maxC {
        case r: h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
        if h < 0 { h += 1 }
        return (h, d / maxC, maxC)
    }
}
