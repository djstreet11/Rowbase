// Draws the Rowbase app icon (macOS squircle, Big Sur grid) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (from native/)
import AppKit

let S: CGFloat = 1024
func draw(_ ctx: CGContext) {
    // macOS icon grid: 824×824 rounded rect centred, radius ≈ 185
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    // soft drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    // background gradient: deep indigo → blue
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.10, green: 0.17, blue: 0.45, alpha: 1).cgColor,
        NSColor(srgbRed: 0.16, green: 0.38, blue: 0.93, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    // top sheen
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 600), options: [])
    // the "rows" glyph: a card with a header row and three data rows, one highlighted
    let card = CGRect(x: 232, y: 262, width: 560, height: 500)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 64, cornerHeight: 64, transform: nil))
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 64, cornerHeight: 64, transform: nil)); ctx.clip()
    // header band
    ctx.setFillColor(NSColor(srgbRed: 0.84, green: 0.89, blue: 1.0, alpha: 1).cgColor)
    ctx.fill(CGRect(x: card.minX, y: card.maxY - 112, width: card.width, height: 112))
    // highlighted row (selection)
    let rowH: CGFloat = (card.height - 112) / 3
    ctx.setFillColor(NSColor(srgbRed: 0.18, green: 0.43, blue: 0.96, alpha: 1).cgColor)
    ctx.fill(CGRect(x: card.minX, y: card.minY + rowH, width: card.width, height: rowH))
    // row separators
    ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.17, blue: 0.45, alpha: 0.14).cgColor)
    for i in 1...2 { ctx.fill(CGRect(x: card.minX, y: card.minY + rowH * CGFloat(i) - 2, width: card.width, height: 4)) }
    // column divider
    ctx.fill(CGRect(x: card.minX + 190, y: card.minY, width: 4, height: card.height))
    // "text" pills in cells
    func pill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: NSColor) {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
        ctx.setFillColor(c.cgColor); ctx.fillPath()
    }
    let ink = NSColor(srgbRed: 0.10, green: 0.17, blue: 0.45, alpha: 0.55)
    let headInk = NSColor(srgbRed: 0.10, green: 0.17, blue: 0.45, alpha: 0.75)
    pill(card.minX + 56, card.maxY - 71, 90, headInk); pill(card.minX + 236, card.maxY - 71, 200, headInk)
    for (i, y) in [card.minY + rowH * 2 + rowH / 2 - 15, card.minY + rowH / 2 - 15].enumerated() {
        pill(card.minX + 56, y, 70, ink); pill(card.minX + 236, y, i == 0 ? 250 : 180, ink)
    }
    let sel = NSColor.white.withAlphaComponent(0.92)
    pill(card.minX + 56, card.minY + rowH * 1.5 - 15, 70, sel); pill(card.minX + 236, card.minY + rowH * 1.5 - 15, 220, sel)
    ctx.restoreGState()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
draw(NSGraphicsContext.current!.cgContext)
NSGraphicsContext.restoreGraphicsState()

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = NSImage(size: NSSize(width: S, height: S)); master.addRepresentation(rep)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = pt * scale
    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
    NSGraphicsContext.current!.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! r.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"))
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Resources/AppIcon.icns written" : "iconutil failed")
