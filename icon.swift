// Draws the app icon: swift icon.swift icon.png  (build.sh turns it into AppIcon.icns)
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt rounded square centered in 1024, with a soft shadow.
let card = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: card, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.set()
NSColor.black.setFill(); path.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.45, alpha: 1), NSColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 1)])!
    .draw(in: path, angle: 90)

func symbol(_ name: String, _ pt: CGFloat, _ color: NSColor, center: NSPoint) {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .medium).applying(.init(paletteColors: [color]))
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    img.draw(in: NSRect(x: center.x - img.size.width / 2, y: center.y - img.size.height / 2,
                        width: img.size.width, height: img.size.height))
}
// Two monitors: the watched one lit, the other dimmed; the eye below does the choosing.
symbol("display", 230, .white.withAlphaComponent(0.3), center: NSPoint(x: 345, y: 610))
symbol("display", 230, .white, center: NSPoint(x: 679, y: 610))
symbol("eye.fill", 210, NSColor(red: 1, green: 0.8, blue: 0.3, alpha: 1), center: NSPoint(x: 512, y: 300))

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
