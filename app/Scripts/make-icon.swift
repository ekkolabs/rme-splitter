// Draws the app icon and writes a 1024px PNG. Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background tile on the standard macOS icon grid.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(shape)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.20, green: 0.21, blue: 0.25, alpha: 1).cgColor,
                                   NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

func bars(x: CGFloat, midY: CGFloat, heights: [CGFloat], width: CGFloat, gap: CGFloat, color: NSColor) {
    ctx.setFillColor(color.cgColor)
    for (i, h) in heights.enumerated() {
        let r = CGRect(x: x + CGFloat(i) * (width + gap), y: midY - h / 2, width: width, height: h)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
    }
    ctx.fillPath()
}

// One multichannel waveform on the left…
bars(x: 196, midY: 512, heights: [150, 330, 520, 400, 250, 440, 300], width: 30, gap: 18, color: .white)

// …split into separate tracks on the right.
let lanes: [(CGFloat, NSColor, [CGFloat])] = [
    (712, NSColor(red: 1.00, green: 0.62, blue: 0.10, alpha: 1), [50, 110, 150, 90, 130, 70]),
    (512, NSColor(red: 0.25, green: 0.80, blue: 0.95, alpha: 1), [90, 150, 70, 130, 110, 50]),
    (312, NSColor(red: 0.98, green: 0.84, blue: 0.20, alpha: 1), [70, 50, 130, 150, 90, 110]),
]
for (y, color, heights) in lanes {
    bars(x: 590, midY: y, heights: heights, width: 24, gap: 16, color: color)
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
