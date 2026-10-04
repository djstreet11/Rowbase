// GitHub social preview (1280×640): icon + name + tagline + real screenshot. Run from repo root:
//   swift docs/assets/make-social.swift
import AppKit

let W: CGFloat = 1280, H: CGFloat = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// background: same indigo → blue gradient as the app icon
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 0.10, green: 0.17, blue: 0.45, alpha: 1).cgColor,
    NSColor(srgbRed: 0.16, green: 0.38, blue: 0.93, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H), options: [])

// screenshot on the right, rounded, with shadow, bleeding off the edge
let shot = NSImage(contentsOfFile: "docs/assets/table-inspector.png")!
let sw: CGFloat = 760, sh = sw * shot.size.height / shot.size.width
let srect = CGRect(x: 600, y: (H - sh) / 2 - 10, width: sw, height: sh)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(CGPath(roundedRect: srect, cornerWidth: 18, cornerHeight: 18, transform: nil))
ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: srect, cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.clip()
shot.draw(in: srect)
ctx.restoreGState()

// icon + text on the left
NSImage(contentsOfFile: "native/Resources/AppIcon-1024.png")!.draw(in: NSRect(x: 50, y: 432, width: 150, height: 150))
// unflipped context: the text block starts at the TOP of its rect, so rects are sized to their content
func text(_ s: String, _ font: NSFont, _ color: NSColor, _ x: CGFloat, _ y: CGFloat, width: CGFloat = 520, height: CGFloat) {
    let p = NSMutableParagraphStyle(); p.lineSpacing = 4
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        .draw(with: NSRect(x: x, y: y, width: width, height: height), options: [.usesLineFragmentOrigin])
}
text("Rowbase", .systemFont(ofSize: 76, weight: .bold), .white, 62, 320, height: 95)
text("Fast, safe database client\nfor humans and AI agents", .systemFont(ofSize: 34, weight: .semibold), NSColor.white.withAlphaComponent(0.92), 66, 205, height: 95)
text("MySQL · PostgreSQL · SQLite · MCP server\nmacOS · Linux · Windows — open source", .systemFont(ofSize: 20, weight: .medium),
     NSColor.white.withAlphaComponent(0.75), 68, 90, height: 60)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/assets/social-preview.png"))
print("docs/assets/social-preview.png")
