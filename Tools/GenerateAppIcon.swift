import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift GenerateAppIcon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let pixelSize = 1_024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Unable to create the app-icon canvas")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
NSColor.clear.setFill()
canvas.fill()

let tile = canvas.insetBy(dx: 58, dy: 58)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 215, yRadius: 215)
tilePath.addClip()

let background = NSGradient(colors: [
    NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.32, alpha: 1),
    NSColor(calibratedRed: 0.90, green: 0.26, blue: 0.56, alpha: 1),
    NSColor(calibratedRed: 0.40, green: 0.26, blue: 0.86, alpha: 1)
])!
background.draw(in: tilePath, angle: -42)

let glow = NSGradient(starting: NSColor.white.withAlphaComponent(0.28),
                      ending: NSColor.white.withAlphaComponent(0))!
glow.draw(fromCenter: NSPoint(x: 340, y: 760),
          radius: 10,
          toCenter: NSPoint(x: 340, y: 760),
          radius: 520,
          options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])

func strokedArc(radius: CGFloat, start: CGFloat, end: CGFloat, alpha: CGFloat, width: CGFloat) {
    let path = NSBezierPath()
    path.appendArc(
        withCenter: NSPoint(x: 512, y: 510),
        radius: radius,
        startAngle: start,
        endAngle: end
    )
    path.lineWidth = width
    path.lineCapStyle = .round
    NSColor.white.withAlphaComponent(alpha).setStroke()
    path.stroke()
}

// Closed rings: sound placed all around the listener, from any app.
strokedArc(radius: 330, start: 0, end: 360, alpha: 0.22, width: 26)
strokedArc(radius: 250, start: 0, end: 360, alpha: 0.40, width: 30)

let barHeights: [CGFloat] = [152, 248, 330, 248, 152]
let barWidth: CGFloat = 62
let gap: CGFloat = 29
let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
var x = (CGFloat(pixelSize) - totalWidth) / 2

NSColor.white.setFill()
for height in barHeights {
    let rect = NSRect(x: x, y: 510 - height / 2, width: barWidth, height: height)
    NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

for point in [NSPoint(x: 512, y: 840), NSPoint(x: 512, y: 180), NSPoint(x: 182, y: 510), NSPoint(x: 842, y: 510)] {
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(ovalIn: NSRect(x: point.x - 21, y: point.y - 21, width: 42, height: 42)).fill()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode the app icon")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
