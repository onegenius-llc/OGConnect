// Draws the OGConnect app icons and writes them into the two asset catalogs.
// Run from the project root:  swift Tools/make-icons.swift

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let orange = CGColor(srgbRed: 0.867, green: 0.404, blue: 0.106, alpha: 1)
let blue = CGColor(srgbRed: 0.16, green: 0.12, blue: 0.95, alpha: 1)
let blueEdge = CGColor(srgbRed: 0.09, green: 0.05, blue: 0.62, alpha: 1)
let green = CGColor(srgbRed: 0.45, green: 0.95, blue: 0.22, alpha: 1)
let greenEdge = CGColor(srgbRed: 0.24, green: 0.62, blue: 0.08, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

/// All drawing below is in a 1024-point square with the origin at the top left.
func makeContext(size: Int) -> CGContext {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    return context
}

/// Strokes a path twice — a darker, slightly wider pass underneath — to give the logo its rim.
func strokeRimmed(_ context: CGContext, _ path: CGPath, width: CGFloat, color: CGColor, edge: CGColor) {
    for (lineWidth, lineColor) in [(width + 8, edge), (width, color)] {
        context.addPath(path)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(lineColor)
        context.strokePath()
    }
}

/// The OneGenius mark: a blue power-symbol O interlocked with a green G.
func drawLogo(_ context: CGContext) {
    let oCenter = CGPoint(x: 405, y: 255)
    let gCenter = CGPoint(x: 597, y: 255)
    let radius: CGFloat = 125

    let o = CGMutablePath()
    o.addArc(center: oCenter, radius: radius, startAngle: radians(-55), endAngle: radians(235), clockwise: false)
    o.move(to: CGPoint(x: 405, y: 110))
    o.addLine(to: CGPoint(x: 405, y: 198))

    let g = CGMutablePath()
    g.addArc(center: gCenter, radius: radius, startAngle: radians(25), endAngle: radians(333), clockwise: false)
    g.move(to: CGPoint(x: 652, y: 252))
    g.addLine(to: CGPoint(x: 750, y: 252))

    strokeRimmed(context, g, width: 32, color: green, edge: greenEdge)
    strokeRimmed(context, o, width: 34, color: blue, edge: blueEdge)

    // Where the rings cross at the bottom the G passes back over the O, linking them.
    // The fill runs a little past the rim at each end so the patch blends into the ring below it.
    context.saveGState()
    context.setLineCap(.butt)
    for (width, color, start, end) in [(CGFloat(40), greenEdge, CGFloat(114), CGFloat(158)), (32, green, 111, 161)] {
        context.addArc(center: gCenter, radius: radius, startAngle: radians(start), endAngle: radians(end), clockwise: false)
        context.setLineWidth(width)
        context.setStrokeColor(color)
        context.strokePath()
    }
    context.restoreGState()
}

/// The classic arrow pointer, with its tip at `tip`.
func pointerPath(tip: CGPoint, scale: CGFloat) -> CGPath {
    let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 16.4), (4.1, 12.6), (7.0, 19.0), (9.7, 17.8), (6.9, 11.6), (12.3, 11.6)]
    let path = CGMutablePath()
    for (index, point) in points.enumerated() {
        let p = CGPoint(x: tip.x + point.0 * scale, y: tip.y + point.1 * scale)
        if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

func fillPointer(_ context: CGContext, tip: CGPoint, scale: CGFloat) {
    let path = pointerPath(tip: tip, scale: scale)
    context.addPath(path)
    context.setFillColor(white)
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(white)
    context.setLineWidth(scale * 0.9)
    context.strokePath()
}

/// iPad app: a Mac window, with its pointer, held inside a tablet.
func drawClientGlyph(_ context: CGContext) {
    context.setStrokeColor(white)
    context.setFillColor(white)

    context.setLineWidth(34)
    context.addPath(CGPath(roundedRect: CGRect(x: 172, y: 480, width: 680, height: 418), cornerWidth: 58, cornerHeight: 58, transform: nil))
    context.strokePath()

    // The Mac window's three title-bar buttons.
    for x in stride(from: CGFloat(242), through: 342, by: 50) {
        context.fillEllipse(in: CGRect(x: x - 15, y: 548 - 15, width: 30, height: 30))
    }
    fillPointer(context, tip: CGPoint(x: 470, y: 590), scale: 13.5)
}

/// Mac server: a display casting its screen.
func drawServerGlyph(_ context: CGContext) {
    context.setStrokeColor(white)
    context.setFillColor(white)

    context.setLineWidth(34)
    context.addPath(CGPath(roundedRect: CGRect(x: 182, y: 472, width: 660, height: 348), cornerWidth: 46, cornerHeight: 46, transform: nil))
    context.strokePath()

    // Stand.
    context.move(to: CGPoint(x: 512, y: 838))
    context.addLine(to: CGPoint(x: 512, y: 892))
    context.move(to: CGPoint(x: 392, y: 902))
    context.addLine(to: CGPoint(x: 632, y: 902))
    context.strokePath()

    // Cast waves spreading from the screen's corner.
    let origin = CGPoint(x: 252, y: 752)
    context.fillEllipse(in: CGRect(x: origin.x - 20, y: origin.y - 20, width: 40, height: 40))
    context.setLineWidth(28)
    for radius in [CGFloat(78), 146, 214] {
        context.addArc(center: origin, radius: radius, startAngle: radians(-90), endAngle: radians(0), clockwise: false)
        context.strokePath()
    }
    fillPointer(context, tip: CGPoint(x: 640, y: 560), scale: 8.5)
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(path)") }
}

/// iOS wants a full-bleed, fully opaque square; the system rounds the corners.
func renderIOS(size: Int) -> CGImage {
    let context = makeContext(size: size)
    context.setFillColor(orange)
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    drawLogo(context)
    drawClientGlyph(context)
    return context.makeImage()!
}

/// macOS icons carry their own shape: a rounded square inset from the canvas, with a soft shadow.
func renderMac(size: Int) -> CGImage {
    let context = makeContext(size: size)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * CGFloat(size) / 1024), blur: 24 * CGFloat(size) / 1024,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
    context.addPath(shape)
    context.setFillColor(orange)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.translateBy(x: tile.minX, y: tile.minY)
    context.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    drawLogo(context)
    drawServerGlyph(context)
    context.restoreGState()
    return context.makeImage()!
}

let fileManager = FileManager.default

let iosSet = "OGConnect/Assets.xcassets/AppIcon.appiconset"
try fileManager.createDirectory(atPath: iosSet, withIntermediateDirectories: true)
write(renderIOS(size: 1024), to: "\(iosSet)/icon-1024.png")
try """
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

""".write(toFile: "\(iosSet)/Contents.json", atomically: true, encoding: .utf8)

let macSet = "OGConnectServer/Assets.xcassets/AppIcon.appiconset"
try fileManager.createDirectory(atPath: macSet, withIntermediateDirectories: true)
try """
{
  "info" : { "author" : "xcode", "version" : 1 }
}

""".write(toFile: "OGConnectServer/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)

var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-\(points)@\(scale)x.png"
        write(renderMac(size: points * scale), to: "\(macSet)/\(name)")
        entries.append("    { \"filename\" : \"\(name)\", \"idiom\" : \"mac\", \"scale\" : \"\(scale)x\", \"size\" : \"\(points)x\(points)\" }")
    }
}
try """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

""".write(toFile: "\(macSet)/Contents.json", atomically: true, encoding: .utf8)

print("Wrote icons to \(iosSet) and \(macSet)")
