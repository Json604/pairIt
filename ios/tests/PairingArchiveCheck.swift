import Foundation
import Security

enum RelayPlaybackMode { case reliable, interactive }
@main struct PairingArchiveCheck {
 static func main() throws {
  let service = "dev.pairit.tests.archive." + UUID().uuidString
  let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"mac"]
  defer { SecItemDelete(query as CFDictionary) }
  let first = PairedMac(host:"192.0.2.1",pin:String(repeating:"a",count:64),token:String(repeating:"b",count:64),name:"Mac")
  let second = PairedMac(host:"192.0.2.2",pin:String(repeating:"c",count:64),token:String(repeating:"d",count:64),name:"Linux")
  var legacy=query;legacy[kSecValueData as String]=try JSONEncoder().encode(first)
  precondition(SecItemAdd(legacy as CFDictionary,nil)==errSecSuccess)
  let store=PairingStore(service:service)
  precondition(store.computers.count==1 && store.mac?.pin==first.pin)
  try store.save(second);try store.save(first)
  let restored=PairingStore(service:service)
  precondition(restored.computers.count==2 && restored.mac?.pin==first.pin)
  precondition(restored.savedComputer(pin:second.pin)?.token==second.token)
  try restored.forget(pin:first.pin)
  let remaining=PairingStore(service:service)
  precondition(remaining.mac==nil && remaining.computers.count==1 && remaining.computers[0].pin==second.pin)
  try remaining.save(second)
  precondition(PairingStore(service:service).mac?.pin==second.pin)
  print("PASS: legacy migration, two computers, deduplication, selection, persistence and isolated forgetting")
 }
}
