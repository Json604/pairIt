import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
func draw(size: Int, mac: Bool) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let info = mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: info)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    if mac { context.addPath(CGPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900), cornerWidth: 202, cornerHeight: 202, transform: nil)); context.clip() }
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(1,0.35,0.12),rgb(1,0.80,0.66),rgb(0.99,0.99,0.98)] as CFArray, locations: [0,0.5,1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 850,y: 0), end: CGPoint(x: 220,y: 1024), options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
    context.setFillColor(rgb(1,1,1,0.10)); context.fillEllipse(in: CGRect(x: -100, y: 420, width: 1060, height: 1060))
    context.setStrokeColor(rgb(1,1,1,0.27)); context.setLineWidth(2)
    context.strokeEllipse(in: CGRect(x: 160,y: 160,width: 704,height: 704))
    let card = CGPath(roundedRect: CGRect(x: 238,y: 236,width: 548,height: 548), cornerWidth: 142, cornerHeight: 142, transform: nil)
    context.saveGState(); context.addPath(card); context.clip()
    let frost = CGGradient(colorsSpace: space, colors: [rgb(1,1,1,0.08),rgb(1,1,1,0.46)] as CFArray, locations: [0,1])!
    context.drawLinearGradient(frost, start: CGPoint(x: 760,y: 220), end: CGPoint(x: 260,y: 820), options: [])
    context.restoreGState(); context.addPath(card); context.setStrokeColor(rgb(1,1,1,0.65)); context.setLineWidth(3); context.strokePath()
    context.setShadow(offset: CGSize(width: 0,height: -5), blur: 12,color: rgb(0.2,0.1,0.05,0.12))
    context.setStrokeColor(rgb(0.098,0.098,0.098)); context.setLineWidth(35); context.setLineCap(.round)
    let arch = CGMutablePath(); arch.move(to: CGPoint(x: 356,y: 445)); arch.addLine(to: CGPoint(x: 356,y: 535))
    arch.addCurve(to: CGPoint(x: 668,y: 535), control1: CGPoint(x: 356,y: 750), control2: CGPoint(x: 668,y: 750)); arch.addLine(to: CGPoint(x: 668,y: 445))
    context.addPath(arch); context.strokePath()
    context.setFillColor(rgb(0.098,0.098,0.098))
    context.addPath(CGPath(roundedRect: CGRect(x: 337,y: 367,width: 82,height: 162), cornerWidth: 38,cornerHeight: 38,transform: nil)); context.fillPath()
    context.addPath(CGPath(roundedRect: CGRect(x: 605,y: 367,width: 82,height: 162), cornerWidth: 38,cornerHeight: 38,transform: nil)); context.fillPath()
    return context.makeImage()!
}
func save(_ image: CGImage, _ path: String) {
    let url = root.appendingPathComponent(path); try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination,image,nil); precondition(CGImageDestinationFinalize(destination))
}
save(draw(size: 1024, mac: false), "ios/AudioRelay/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
save(draw(size: 512, mac: false), "design/PlayStoreIcon.png")
for size in [16,32,128,256,512] {
    save(draw(size: size,mac: true), "design/AudioRelay.iconset/icon_\(size)x\(size).png")
    save(draw(size: size * 2,mac: true), "design/AudioRelay.iconset/icon_\(size)x\(size)@2x.png")
}
// Windows ICO directory entries can contain PNG images (Vista and later).
let iconSizes = [16, 32, 48, 64, 128, 256]
let iconImages: [Data] = iconSizes.map { size in
    let bytes = NSMutableData()
    let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, draw(size: size, mac: true), nil)
    precondition(CGImageDestinationFinalize(destination))
    return bytes as Data
}
var ico = Data()
func appendLE<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { ico.append(contentsOf: $0) }
}
appendLE(UInt16(0)); appendLE(UInt16(1)); appendLE(UInt16(iconSizes.count))
var offset = 6 + 16 * iconSizes.count
for (size, bytes) in zip(iconSizes, iconImages) {
    ico.append(contentsOf: [UInt8(size % 256), UInt8(size % 256), 0, 0])
    appendLE(UInt16(1)); appendLE(UInt16(32)); appendLE(UInt32(bytes.count)); appendLE(UInt32(offset))
    offset += bytes.count
}
iconImages.forEach { ico.append($0) }
try! ico.write(to: root.appendingPathComponent("windows/PairIt.Windows/PairIt.ico"))
