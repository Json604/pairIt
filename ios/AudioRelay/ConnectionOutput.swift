// Only a fresh user playback request may adopt a different system output.
// Automatic recovery retains the previous route to avoid loudspeaker surprises.
enum ConnectionOutput {
    static func resolve<Output>(saved: Output, current: Output?, explicit: Bool) -> Output {
        explicit ? (current ?? saved) : saved
    }
}
