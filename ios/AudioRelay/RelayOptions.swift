import AVFAudio
import Foundation

enum RelayOutput: String, CaseIterable, Identifiable {
    case bluetooth, speaker, wired
    var id: String { rawValue }
    var title: String {
        switch self { case .bluetooth: return "Bluetooth"; case .speaker: return "iPhone speaker"; case .wired: return "Wired / USB audio" }
    }
    var icon: String {
        switch self { case .bluetooth: return "headphones"; case .speaker: return "speaker.wave.2"; case .wired: return "cable.connector" }
    }
    func matches(_ port: AVAudioSessionPortDescription) -> Bool {
        switch self {
        case .bluetooth: return port.portType == .bluetoothA2DP || port.portType == .bluetoothLE
        case .speaker: return port.portType == .builtInSpeaker
        case .wired: return port.portType == .headphones || port.portType == .usbAudio || port.portType == .lineOut
        }
    }
    func currentRoute() -> AVAudioSessionPortDescription? {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty, outputs.allSatisfy(matches) else { return nil }
        return outputs.first
    }
}

enum RelayPlaybackMode: String, CaseIterable, Identifiable {
    case reliable, interactive
    var id: String { rawValue }
    var title: String { self == .reliable ? "Reliable" : "Low latency" }
}

enum RelayInstallation {
    static var identifier: String {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "receiverInstallationID"),
           value.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil { return value }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(value, forKey: "receiverInstallationID")
        return value
    }
}
