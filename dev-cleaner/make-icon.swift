// Draws the DevCleaner app icon (1024x1024 PNG) using only AppKit.
import Cocoa

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow()
sh.shadowColor = NSColor.black.withAlphaComponent(0.30); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -14)
sh.set(); rgb(30, 120, 160).setFill(); bg.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(92, 214, 210), rgb(40, 160, 190), rgb(28, 98, 168)])!.draw(in: bg, angle: -90)
NSGraphicsContext.saveGraphicsState()
bg.addClip()
NSGradient(starting: NSColor.white.withAlphaComponent(0.25), ending: NSColor.white.withAlphaComponent(0))!
    .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
NSGraphicsContext.restoreGraphicsState()

let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white, rgb(255, 255, 255, 0.75)]))
if let sym = NSImage(systemSymbolName: "bubbles.and.sparkles.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = sym.size
    let scale = min(560 / s.width, 560 / s.height)
    let w = s.width * scale, h = s.height * scale
    NSGraphicsContext.saveGraphicsState()
    let s2 = NSShadow()
    s2.shadowColor = rgb(10, 50, 90, 0.35); s2.shadowBlurRadius = 24; s2.shadowOffset = NSSize(width: 0, height: -8)
    s2.set()
    sym.draw(in: NSRect(x: 512 - w / 2, y: 512 - h / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
