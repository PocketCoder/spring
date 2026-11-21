// Draws Resources/AppIcon.icns (design C: "Sp" in Courier Prime with a blue caret).
// Run: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let fontURL = URL(filePath: "Resources/Fonts/CourierPrime-Bold.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)
    // Rounded square on the macOS icon grid (824 of 1024), dark graphite.
    NSColor(srgbRed: 0.122, green: 0.122, blue: 0.118, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
    // "Sp", baseline at 372 from the bottom (652 from the top in the design).
    let font = NSFont(name: "CourierPrime-Bold", size: 400) ?? NSFont(name: "Courier Prime Bold", size: 400)!
    let text = NSAttributedString(string: "Sp", attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0.984, green: 0.984, blue: 0.98, alpha: 1)])
    text.draw(at: NSPoint(x: 248, y: 372 + font.descender))
    // The writing caret.
    NSColor(srgbRed: 0.498, green: 0.663, blue: 0.839, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 738, y: 1024 - 682, width: 26, height: 330), xRadius: 4, yRadius: 4).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(filePath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: out.appending(path: "icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: out.appending(path: "icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(out.path)")
