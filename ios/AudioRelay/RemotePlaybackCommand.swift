/// Lock-screen intent does not depend on the last asynchronously displayed phase.
enum RemotePlaybackCommand {
    case play, pause, toggle
    enum Action { case connect, pause, none, unavailable }
    func action(paired: Bool, listening: Bool) -> Action {
        guard paired else { return .unavailable }
        switch self {
        case .play: return listening ? .none : .connect
        case .pause: return listening ? .pause : .none
        case .toggle: return listening ? .pause : .connect
        }
    }
}
