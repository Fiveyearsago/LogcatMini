import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func drawIcon(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.15, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
    let mint = NSColor(calibratedRed: 0.39, green: 0.87, blue: 0.72, alpha: 1)
    for (index, width) in [460, 340, 410].enumerated() {
        let y = CGFloat(650 - index * 145)
        mint.withAlphaComponent(index == 0 ? 1 : 0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: 220, y: y, width: 52, height: 52), xRadius: 16, yRadius: 16).fill()
        NSColor(calibratedWhite: index == 0 ? 0.95 : 0.6, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 330, y: y + 5, width: CGFloat(width), height: 42), xRadius: 18, yRadius: 18).fill()
    }
    mint.setFill(); NSBezierPath(ovalIn: NSRect(x: 727, y: 178, width: 62, height: 62)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for points in [16, 32, 128, 256, 512] {
    try drawIcon(points).write(to: destination.appendingPathComponent("icon_\(points)x\(points).png"))
    try drawIcon(points * 2).write(to: destination.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
