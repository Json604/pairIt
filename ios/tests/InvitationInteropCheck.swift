import Foundation
import Combine
enum RelayPlaybackMode { case reliable, interactive }
@main struct Interop {
 static func main() throws {
  precondition(!ListeningInvitations.hostProblem(connected: false, phoneOutput: true, available: true).isEmpty)
  precondition(ListeningInvitations.hostProblem(connected: true, phoneOutput: true, available: true).isEmpty)
  precondition(!ListeningInvitations.hostProblem(connected: true, phoneOutput: false, available: true).isEmpty)
  let invitations=ListeningInvitations();var finished=false;var sawBusy=false
  let prompt=invitations.$prompt.sink { value in
   guard let value else { return };print("SAS " + value.comparison);fflush(stdout)
   DispatchQueue.main.async { invitations.answer(true) }
  }
  let busy=invitations.$busy.sink { value in if value { sawBusy=true } else if sawBusy { finished=true } }
  invitations.received={code in print("RECEIVED");fflush(stdout)}
  if CommandLine.arguments[1]=="receive" { invitations.start { port in print("PORT \(port)");fflush(stdout) } }
  else {
   let value=PairedMac(host:"127.0.0.1",pin:String(repeating:"a",count:64),token:String(repeating:"b",count:64),name:"Test computer")
   let code="audiorelay://pair/"+(try JSONEncoder().encode(value)).base64EncodedString()
   var phone=NearbyDevices.Device(id:"test",name:"Test phone",platform:"android",pin:nil,host:"127.0.0.1")
   phone.invitationPort=Int(CommandLine.arguments[2])!
   invitations.invite(phone,code:code,computer:"Test computer")
  }
  let deadline=Date().addingTimeInterval(12)
  while !finished && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
  print(invitations.notice);invitations.stop();withExtendedLifetime((prompt,busy)){}
  precondition(finished,"timeout")
 }
}
