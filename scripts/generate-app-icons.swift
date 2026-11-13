import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
func draw(size: Int, mac: Bool, insetTile: Bool = true) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let info = mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: info)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    if mac { context.addPath(CGPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900), cornerWidth: 202, cornerHeight: 202, transform: nil)); context.clip() }
    // Keep the approved mark identical across platforms; only the outer mask differs.
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(0.04,0.42,0.86),rgb(0.025,0.12,0.26),rgb(0,0,0)] as CFArray, locations: [0,0.55,1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 900,y: 0), end: CGPoint(x: 180,y: 1024), options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
    // Original PairIt headphones, recolored for the approved blue/black palette.
    context.translateBy(x: 512,y: 512)
    context.scaleBy(x: 1.5,y: 1.5)
    context.translateBy(x: -512,y: -512)
    context.setStrokeColor(rgb(0.97,0.97,0.97));context.setLineWidth(35);context.setLineCap(.round)
    let arch = CGMutablePath();arch.move(to:CGPoint(x:356,y:445));arch.addLine(to:CGPoint(x:356,y:535))
    arch.addCurve(to:CGPoint(x:668,y:535),control1:CGPoint(x:356,y:750),control2:CGPoint(x:668,y:750));arch.addLine(to:CGPoint(x:668,y:445))
    context.addPath(arch);context.strokePath()
    context.setFillColor(rgb(0.97,0.97,0.97))
    for x in [337,605] {
        context.addPath(CGPath(roundedRect:CGRect(x:x,y:367,width:82,height:162),cornerWidth:38,cornerHeight:38,transform:nil));context.fillPath()
    }
    return context.makeImage()!
}
func save(_ image: CGImage, _ path: String) {
    let url = root.appendingPathComponent(path); try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination,image,nil); precondition(CGImageDestinationFinalize(destination))
}
if CommandLine.arguments.contains("--play-store-only") {
    save(draw(size: 512, mac: false, insetTile: false), "design/PlayStoreIcon.png")
    exit(0)
}
save(draw(size: 1024, mac: false, insetTile: false), "ios/AudioRelay/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
if CommandLine.arguments.contains("--ios-only") { exit(0) }
save(draw(size: 512, mac: false, insetTile: false), "design/PlayStoreIcon.png")
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
