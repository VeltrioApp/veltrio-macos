// Renders the Veltrio app icon into AppIcon.appiconset at every size macOS
// asks for. Run from the repo root:
//   swift scripts/make-icon.swift Veltrio/Assets.xcassets/AppIcon.appiconset
//
// The mark: an amber chevron — a "V" that also reads as a play arrow turned
// downward — on the app's black canvas, with the hairline frame the UI
// uses everywhere.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Veltrio/Assets.xcassets/AppIcon.appiconset")

let amber = CGColor(srgbRed: 0xE6 / 255, green: 0xA8 / 255, blue: 0x4B / 255, alpha: 1)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824pt body centred on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [CGColor(gray: 0.13, alpha: 1), CGColor(gray: 0.02, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Soft amber glow behind the mark.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [amber.copy(alpha: 0.28)!, amber.copy(alpha: 0)!] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])

    // Chevron "V": an outer triangle minus an inner one.
    let v = CGMutablePath()
    v.move(to: CGPoint(x: 268, y: 720))
    v.addLine(to: CGPoint(x: 400, y: 720))
    v.addLine(to: CGPoint(x: 512, y: 452))
    v.addLine(to: CGPoint(x: 624, y: 720))
    v.addLine(to: CGPoint(x: 756, y: 720))
    v.addLine(to: CGPoint(x: 512, y: 250))
    v.closeSubpath()
    ctx.addPath(v)
    ctx.setFillColor(amber)
    ctx.fillPath()

    // Hairline rule under the mark, as in the UI's section headers.
    ctx.setFillColor(amber.copy(alpha: 0.55)!)
    ctx.fill(CGRect(x: 352, y: 196, width: 320, height: 6))
    ctx.restoreGState()

    // Hairline frame.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(6)
    ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(outDir.path)")
