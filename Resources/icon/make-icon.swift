// Renders the LazyBoard app icon: a sage-green macOS squircle, a white keyboard, and a sloth
// sitting on its corner. Usage: swiftc make-icon.swift -o make-icon && ./make-icon out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // macOS icon grid: the squircle sits inside ~10% margins.
    let inset: CGFloat = size * 0.1
    let box = rect.insetBy(dx: inset, dy: inset)
    let radius = box.width * 0.225
    let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    // Soft shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.58, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Sage gradient, lighter at the top.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.66, green: 0.80, blue: 0.68, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.60, blue: 0.47, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    // Subtle inner highlight along the top edge.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: NSRect(x: box.minX, y: box.maxY - box.height * 0.35, width: box.width, height: box.height * 0.35), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Keyboard glyph.
    if let kb = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size * 0.42, weight: .medium)) {
        let tinted = NSImage(size: kb.size, flipped: false) { r in
            kb.draw(in: r)
            NSColor.white.withAlphaComponent(0.96).set()
            r.fill(using: .sourceAtop)
            return true
        }
        let w = box.width * 0.62
        let h = w * (kb.size.height / kb.size.width)
        let kbRect = NSRect(x: box.midX - w / 2, y: box.midY - h / 2 + box.height * 0.06, width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        let kbShadow = NSShadow()
        kbShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        kbShadow.shadowBlurRadius = size * 0.015
        kbShadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
        kbShadow.set()
        tinted.draw(in: kbRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    // The sloth, hanging off the bottom-right corner.
    let sloth = NSAttributedString(string: "🦥", attributes: [.font: NSFont.systemFont(ofSize: size * 0.30)])
    let s = sloth.size()
    sloth.draw(at: NSPoint(x: box.maxX - s.width * 0.86, y: box.minY - s.height * 0.05))
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
