// Draws Quill's app icon and writes Resources/AppIcon.icns.
// Run: swift tools/make-icon.swift
import AppKit

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // The standard macOS icon grid: the shape fills 80% of the canvas.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor(red: 0.36, green: 0.38, blue: 0.95, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.42, green: 0.45, blue: 0.99, alpha: 1).cgColor,
        NSColor(red: 0.50, green: 0.30, blue: 0.90, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // A soft light from above.
    let glow = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.22).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX, y: body.maxY + body.height * 0.05), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.maxY + body.height * 0.05), endRadius: body.height * 0.75, options: [])

    // The voice: five bars, tallest in the middle, tilted like a nib's cut.
    let heights: [CGFloat] = [0.22, 0.42, 0.62, 0.36, 0.16]
    let barWidth = body.width * 0.085
    let gap = body.width * 0.055
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.014,
                  color: NSColor(red: 0.2, green: 0.1, blue: 0.5, alpha: 0.35).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    for h in heights {
        let height = body.height * h
        let bar = CGRect(x: x, y: body.midY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
        x += barWidth + gap
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("build-icon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try render(pixels: px).write(to: iconset.appendingPathComponent(name + ".png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try fm.removeItem(at: iconset)
print("wrote \(output.path)")
