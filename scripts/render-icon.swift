import AppKit

// Renders dabterm's icon (1024x1024, full-bleed: iOS masks the corners) and the launch glyph.
let outDir = CommandLine.arguments[1]

func render(size: CGFloat, background: Bool, glyphScale: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    let s = size / 1024

    if background {
        // Deep gradient with a faint lighter band at the top, like a screen catching light.
        let colors = [CGColor(red: 0.075, green: 0.086, blue: 0.11, alpha: 1), CGColor(red: 0.02, green: 0.024, blue: 0.035, alpha: 1)] as CFArray
        let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
        // A soft cyan glow behind the glyph.
        let glow = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.19, green: 0.84, blue: 0.95, alpha: 0.22), CGColor(red: 0.19, green: 0.84, blue: 0.95, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512 * s, y: 512 * s), startRadius: 0, endCenter: CGPoint(x: 512 * s, y: 512 * s), endRadius: 420 * s, options: [])
    }

    // Glyph: a chevron and a block cursor, centred.
    ctx.saveGState()
    ctx.translateBy(x: 512 * s, y: 512 * s)
    ctx.scaleBy(x: glyphScale, y: glyphScale)
    ctx.translateBy(x: -512 * s, y: -512 * s)

    // The caret is a capital D for dab, built from a bar and the prompt chevron: | >
    let cyan = CGColor(red: 0.19, green: 0.84, blue: 0.95, alpha: 1)
    ctx.setStrokeColor(cyan)
    ctx.setLineWidth(104 * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 272 * s, y: 300 * s))
    ctx.addLine(to: CGPoint(x: 272 * s, y: 724 * s))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 420 * s, y: 724 * s))
    ctx.addLine(to: CGPoint(x: 624 * s, y: 512 * s))
    ctx.addLine(to: CGPoint(x: 420 * s, y: 300 * s))
    ctx.strokePath()

    // Cursor block, slightly lighter, on the baseline after the d.
    ctx.setFillColor(CGColor(red: 0.90, green: 0.96, blue: 0.98, alpha: 1))
    let cursor = CGRect(x: 716 * s, y: 300 * s, width: 140 * s, height: 212 * s)
    ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: 22 * s, cornerHeight: 22 * s, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print("wrote", name, img.width)
}

write(render(size: 1024, background: true, glyphScale: 1), "AppIcon-1024.png")
write(render(size: 1024, background: true, glyphScale: 1), "AppIcon-1024-dark.png")
// Launch glyph: transparent, three scales of a 240pt image.
for (scale, suffix) in [(1, "@1x"), (2, "@2x"), (3, "@3x")] {
    write(render(size: CGFloat(240 * scale), background: false, glyphScale: 0.9), "LaunchGlyph\(suffix).png")
}
