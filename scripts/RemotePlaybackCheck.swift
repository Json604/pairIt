@main struct RemotePlaybackCheck {
    static func main() {
        // Saved pairing is sufficient to retry; a previous playing/paused phase is not required.
        precondition(RemotePlaybackCommand.play.action(paired: true, listening: false) == .connect)
        precondition(RemotePlaybackCommand.toggle.action(paired: true, listening: false) == .connect)
        precondition(RemotePlaybackCommand.toggle.action(paired: true, listening: true) == .pause)
        precondition(RemotePlaybackCommand.play.action(paired: true, listening: true) == .none)
        precondition(RemotePlaybackCommand.pause.action(paired: true, listening: true) == .pause)
        precondition(RemotePlaybackCommand.play.action(paired: false, listening: false) == .unavailable)
        print("PASS: remote play retries saved pairing; toggle follows listening intent; unpaired play is rejected")
    }
}
