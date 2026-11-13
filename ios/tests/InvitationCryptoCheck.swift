import Foundation
@main struct Check {
 static func main() throws {
  var sender=InvitationCrypto(), receiver=InvitationCrypto()
  try sender.agree(receiver.publicKey,sender:true);try receiver.agree(sender.publicKey,sender:false)
  precondition(sender.comparison == receiver.comparison)
  let message=Data("private pairing credentials".utf8)
  var sealed=try sender.seal(message)
  let opened=try receiver.open(sealed);precondition(opened==message)
  sealed[sealed.count-1] ^= 1
  do { _=try receiver.open(sealed);fatalError("accepted tampering") } catch {}
  do { try sender.agree(Data(repeating:0,count:65),sender:true);fatalError("invalid point") } catch {}
  print("Swift invitation crypto checks passed")
 }
}
