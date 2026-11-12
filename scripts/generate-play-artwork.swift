import AppKit
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpaceCreateDeviceRGB()
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ a:CGFloat=1)->CGColor { CGColor(red:r,green:g,blue:b,alpha:a) }
func context(_ w:Int,_ h:Int)->CGContext { CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)! }
func save(_ c:CGContext,_ name:String) { let u=root.appendingPathComponent(name);try! FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true);let d=CGImageDestinationCreateWithURL(u as CFURL,UTType.png.identifier as CFString,1,nil)!;CGImageDestinationAddImage(d,c.makeImage()!,nil);precondition(CGImageDestinationFinalize(d)) }
func headphones(_ c:CGContext,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ ink:CGColor) {
 c.saveGState();c.translateBy(x:x,y:y);c.scaleBy(x:size/100,y:size/100)
 c.setStrokeColor(ink);c.setLineWidth(6);c.setLineCap(.round)
 c.move(to:CGPoint(x:20,y:35));c.addLine(to:CGPoint(x:20,y:52));c.addCurve(to:CGPoint(x:80,y:52),control1:CGPoint(x:20,y:94),control2:CGPoint(x:80,y:94));c.addLine(to:CGPoint(x:80,y:35));c.strokePath()
 c.setFillColor(ink)
 for x:CGFloat in [15,69] { c.addPath(CGPath(roundedRect:CGRect(x:x,y:20,width:16,height:30),cornerWidth:8,cornerHeight:8,transform:nil));c.fillPath() }
 c.restoreGState()
}
func text(_ c:CGContext,_ text:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ weight:NSFont.Weight,_ ink:NSColor) {
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
 (text as NSString).draw(at:CGPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:ink,.kern:-size*0.035]);NSGraphicsContext.restoreGraphicsState()
}
let icon=context(512,512)
let gradient=CGGradient(colorsSpace:space,colors:[color(0.05,0.30,0.78),color(0.18,0.55,0.94),color(0.51,0.79,1)] as CFArray,locations:[0,0.6,1])!
icon.drawLinearGradient(gradient,start:CGPoint(x:480,y:0),end:CGPoint(x:10,y:512),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
headphones(icon,48,35,416,color(1,1,1));save(icon,"release/google-play/graphics/icon-512.png")
let feature=context(1024,500);feature.setFillColor(color(0.97,0.98,1));feature.fill(CGRect(x:0,y:0,width:1024,height:500))
let wash=CGGradient(colorsSpace:space,colors:[color(0.97,0.98,1),color(0.85,0.93,1)] as CFArray,locations:[0,1])!
feature.drawLinearGradient(wash,start:CGPoint(x:500,y:250),end:CGPoint(x:1024,y:250),options:[])
let ink=NSColor(red:0.08,green:0.15,blue:0.23,alpha:1)
text(feature,"PairIt",64,400,24,.semibold,ink)
text(feature,"Mac audio.",64,272,62,.semibold,ink);text(feature,"Same headphones.",64,202,62,.semibold,ink)
text(feature,"Keep them connected to your phone.",67,137,22,.regular,NSColor(red:0.33,green:0.41,blue:0.50,alpha:1))
headphones(feature,704,135,265,color(0.08,0.39,0.83))
text(feature,"MAC + ANDROID",67,53,13,.medium,NSColor(red:0.24,green:0.38,blue:0.52,alpha:1))
save(feature,"release/google-play/graphics/feature-1024x500.png")
