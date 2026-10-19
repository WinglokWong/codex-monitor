#!/usr/bin/env swift
// Rebuild the original, geometric application icon with macOS system frameworks.
// Usage from any directory: swift /path/to/monitor/scripts/generate-icon.swift
// Optional first argument overrides the Assets output directory.
import AppKit
import Foundation

private let manager = FileManager.default
private let sourceURL = URL(fileURLWithPath: #filePath).standardizedFileURL
private let assetsURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
    : sourceURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Assets", isDirectory: true)
private let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: rgb, components: [r, g, b, a])!
}

private func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: locations)!
}

private func drawIcon(in context: CGContext, pixels: Int) {
    context.saveGState()
    defer { context.restoreGState() }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let small = pixels <= 32
    let tile = CGPath(roundedRect: CGRect(x: 86, y: 86, width: 852, height: 852),
                      cornerWidth: 190, cornerHeight: 190, transform: nil)

    // A restrained native macOS-style lift, with transparent canvas beyond it.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: small ? 12 : 24,
                      color: color(0.02, 0.04, 0.05, 0.30))
    context.addPath(tile)
    context.setFillColor(color(0.065, 0.085, 0.095))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(gradient([
        color(0.125, 0.165, 0.180), color(0.065, 0.088, 0.105)
    ], [0, 1]), start: CGPoint(x: 200, y: 940), end: CGPoint(x: 850, y: 80), options: [])
    if !small {
        context.drawRadialGradient(gradient([
            color(0.32, 0.64, 0.50, 0.10), color(0.32, 0.64, 0.50, 0)
        ], [0, 1]), startCenter: CGPoint(x: 400, y: 750), startRadius: 0,
                                   endCenter: CGPoint(x: 400, y: 750), endRadius: 650, options: [])
    }
    context.restoreGState()

    if !small {
        context.addPath(CGPath(roundedRect: CGRect(x: 88, y: 88, width: 848, height: 848),
                               cornerWidth: 188, cornerHeight: 188, transform: nil))
        context.setStrokeColor(color(0.71, 0.86, 0.88, 0.10))
        context.setLineWidth(3)
        context.strokePath()
    }

    // Ring = remaining quota. The open upper-right sector gives an unmistakable
    // progress-meter silhouette even when reduced to a 16 px Dock/menu icon.
    let center = CGPoint(x: 512, y: 514)
    let radius: CGFloat = 273
    let ringWidth: CGFloat = small ? 64 : 55
    context.setLineWidth(ringWidth)
    context.setStrokeColor(color(0.54, 0.91, 0.71, small ? 0.19 : 0.13))
    context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2))

    context.saveGState()
    context.addArc(center: center, radius: radius,
                   startAngle: 78 * .pi / 180, endAngle: 374 * .pi / 180, clockwise: false)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(gradient([
        color(0.39, 0.78, 0.59), color(0.66, 0.98, 0.79)
    ], [0, 1]), start: CGPoint(x: 260, y: 190), end: CGPoint(x: 700, y: 850), options: [])
    context.restoreGState()

    // A single purpose-drawn waveform (not an SF Symbol or third-party asset).
    // Small sizes use a slightly heavier stroke without extra decorative detail.
    let waveform = CGMutablePath()
    waveform.move(to: CGPoint(x: 339, y: 506))
    waveform.addLine(to: CGPoint(x: 415, y: 506))
    waveform.addLine(to: CGPoint(x: 468, y: 636))
    waveform.addLine(to: CGPoint(x: 553, y: 389))
    waveform.addLine(to: CGPoint(x: 606, y: 506))
    waveform.addLine(to: CGPoint(x: 685, y: 506))
    context.addPath(waveform)
    context.setLineWidth(small ? 54 : 47)
    context.setStrokeColor(color(0.65, 0.97, 0.78))
    context.strokePath()
}

private func iconImage(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: pixels * 4, space: rgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(in: context, pixels: pixels)
    return context.makeImage()!
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try png.write(to: url, options: .atomic)
}

private func writePreview(to url: URL) throws {
    let width = 848
    let height = 360
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: rgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color(0.93, 0.94, 0.94))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let variants: [(Int, CGFloat)] = [(16, 72), (32, 176), (64, 304), (128, 464), (256, 692)]
    for (size, x) in variants {
        context.draw(iconImage(pixels: size), in: CGRect(x: x - CGFloat(size) / 2,
                     y: 188 - CGFloat(size) / 2, width: CGFloat(size), height: CGFloat(size)))
        let label = "\(size) px" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.31, green: 0.37, blue: 0.39, alpha: 1)
        ]
        let labelSize = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: x - labelSize.width / 2, y: 24), withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    try writePNG(context.makeImage()!, to: url)
}

do {
    try manager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    let scratch = manager.temporaryDirectory.appendingPathComponent("codex-monitor-icon-\(UUID().uuidString)")
    let iconset = scratch.appendingPathComponent("AppIcon.iconset")
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: scratch) }

    for size in [16, 32, 128, 256, 512] {
        try writePNG(iconImage(pixels: size), to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
        try writePNG(iconImage(pixels: size * 2),
                     to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
    try writePNG(iconImage(pixels: 1024), to: assetsURL.appendingPathComponent("AppIcon.png"))
    try writePreview(to: assetsURL.appendingPathComponent("AppIcon-preview.png"))

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output",
                          assetsURL.appendingPathComponent("AppIcon.icns").path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw NSError(domain: "IconGeneration", code: Int(iconutil.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "iconutil conversion failed"])
    }
    print("Generated AppIcon.icns, AppIcon.png (1024 px), and AppIcon-preview.png in \(assetsURL.path)")
} catch {
    fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
