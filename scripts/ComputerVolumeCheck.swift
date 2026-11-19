import Foundation
@main struct Check {
 static func main() {
  func require(_ test:Bool,_ message:String){if !test{fatalError(message)}}
  let quiet=ComputerVolume(level:0.25,muted:false)
  require(quiet.wireValue==250,"volume is portable fixed point")
  require(ComputerVolume(wireValue:250)?.level==0.25,"volume decodes")
  require(ComputerVolume(wireValue:1001)==nil,"out-of-range volume rejected")
  require(ComputerVolume(wireValue:0x40000)==nil,"unknown flags rejected")
  require(ComputerVolume(wireValue:0x20000|500)?.phoneOwned==true,"VOLUME2 phones learn the computer no longer attenuates them")
  require(ComputerVolume(wireValue:500)?.phoneOwned==false,"older value is not phone-owned")
  require(ComputerVolume(level:1,muted:true).wireValue==0x10000+1000,"mute is separate from saved level")
  var packet=Data(count:28)
  packet.withUnsafeMutableBytes{raw in raw.storeBytes(of:Int16(12000).littleEndian,toByteOffset:24,as:Int16.self);raw.storeBytes(of:Int16(-12000).littleEndian,toByteOffset:26,as:Int16.self)}
  quiet.apply(to:&packet)
  require(packet.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:24,as:Int16.self)}==3000,"volume actually reduces PCM")
  require(packet.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:26,as:Int16.self)} == -3000,"negative samples scale")
  ComputerVolume(level:1,muted:true).apply(to:&packet)
  require(packet.suffix(4)==Data(count:4),"mute silences PCM")
  require(packet.prefix(24)==Data(count:24),"packet header preserved")
  print("PASS: computer volume scales audio, mute preserves level, wire validation rejects malformed values")
 }
}
