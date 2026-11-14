@main enum ConnectionOutputCheck {
 static func main() {
  precondition(ConnectionOutput.resolve(saved: "bluetooth", current: "speaker", explicit: true) == "speaker")
  precondition(ConnectionOutput.resolve(saved: "speaker", current: "wired", explicit: true) == "wired")
  precondition(ConnectionOutput.resolve(saved: "wired", current: "bluetooth", explicit: true) == "bluetooth")
  precondition(ConnectionOutput.resolve(saved: "bluetooth", current: "speaker", explicit: false) == "bluetooth")
  precondition(ConnectionOutput.resolve(saved: "wired", current: nil, explicit: true) == "wired")
  print("PASS: current system output on explicit Connect; background output unchanged")
 }
}
