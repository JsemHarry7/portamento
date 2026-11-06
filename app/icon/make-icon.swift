// Draws the Portamento app icon (the "Ligatura" mark: a slur over two notes,
// the second one a play triangle) into an .iconset folder for iconutil.
//
// Usage: swift app/icon/make-icon.swift <out.iconset>
// The mark is designed on a 72-unit grid (body 68 units with 16-unit corners,
// inset 2) and scaled onto Apple's 1024 px icon grid (824 px body, 100 px margin).
import AppKit

let background = NSColor(srgbRed: 0xF4 / 255, green: 0xF0 / 255, blue: 0xF0 / 255, alpha: 1)
let accent = NSColor(srgbRed: 0xA6 / 255, green: 0x59 / 255, blue: 0x5B / 255, alpha: 1)
let deep = NSColor(srgbRed: 0x27 / 255, green: 0x1C / 255, blue: 0x1C / 255, alpha: 1)

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let canvas: CGFloat = 1024, body: CGFloat = 824, margin = (canvas - body) / 2
        let unit = body / 68
        ctx.scaleBy(x: size / canvas, y: size / canvas)
        // design units -> canvas pixels (the body starts at unit 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: margin + (x - 2) * unit, y: margin + (y - 2) * unit) }

        let shape = CGPath(roundedRect: CGRect(x: margin, y: margin, width: body, height: body),
                           cornerWidth: 16 * unit, cornerHeight: 16 * unit, transform: nil)
        ctx.addPath(shape)
        ctx.setFillColor(background.cgColor)
        ctx.fillPath()
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(4)
        ctx.strokePath()

        // the slur
        ctx.move(to: p(14, 34))
        ctx.addCurve(to: p(58, 34), control1: p(24, 14), control2: p(48, 14))
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(4 * unit)
        ctx.setLineCap(.round)
        ctx.strokePath()

        // the first note, tilted like a notehead
        ctx.saveGState()
        ctx.translateBy(x: p(20, 48).x, y: p(20, 48).y)
        ctx.rotate(by: -20 * .pi / 180)
        ctx.addEllipse(in: CGRect(x: -7 * unit, y: -5 * unit, width: 14 * unit, height: 10 * unit))
        ctx.setFillColor(accent.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // the second note is "play"
        ctx.move(to: p(45, 39))
        ctx.addLine(to: p(58, 47))
        ctx.addLine(to: p(45, 55))
        ctx.closePath()
        ctx.setFillColor(deep.cgColor)
        ctx.fillPath()
        return true
    }
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try writePNG(drawIcon(size: CGFloat(pixels)), pixels: pixels, to: out.appending(path: name))
    }
}
