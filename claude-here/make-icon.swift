// Draws the ClaudeHere app icon (1024x1024 PNG) using only AppKit.
// Usage: swift make-icon.swift <output.png>
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

// Background squircle (standard macOS icon grid: 824pt tile, 100pt margin)
let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
rgb(200, 90, 55).setFill()
bg.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(242, 148, 102), rgb(222, 110, 70), rgb(186, 78, 44)])!.draw(in: bg, angle: -90)

// Soft top highlight
NSGraphicsContext.saveGraphicsState()
bg.addClip()
NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
    .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Folder: back panel + tab
let back = NSBezierPath(roundedRect: NSRect(x: 232, y: 290, width: 560, height: 400), xRadius: 46, yRadius: 46)
back.append(NSBezierPath(roundedRect: NSRect(x: 232, y: 640, width: 230, height: 90), xRadius: 34, yRadius: 34))
rgb(255, 236, 224, 0.85).setFill()
back.fill()

// Folder: front panel with a shadow
let frontRect = NSRect(x: 232, y: 270, width: 560, height: 360)
let front = NSBezierPath(roundedRect: frontRect, xRadius: 46, yRadius: 46)
NSGraphicsContext.saveGraphicsState()
let s2 = NSShadow()
s2.shadowColor = rgb(120, 40, 15, 0.35)
s2.shadowBlurRadius = 24
s2.shadowOffset = NSSize(width: 0, height: -8)
s2.set()
NSColor.white.setFill()
front.fill()
NSGraphicsContext.restoreGraphicsState()

// Terminal prompt ">_" on the folder
let font = NSFont.monospacedSystemFont(ofSize: 230, weight: .heavy)
let text = NSAttributedString(string: ">_", attributes: [.font: font, .foregroundColor: rgb(196, 82, 46)])
let size = text.size()
text.draw(at: NSPoint(x: frontRect.midX - size.width / 2, y: frontRect.midY - size.height / 2 + 6))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
