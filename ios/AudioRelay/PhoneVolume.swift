import AVFAudio
import MediaPlayer
import UIKit

/// This iPhone's system media volume as the 0...1000 wire level used by STATS PVOL1
/// and the computer's volume request frame.
enum PhoneVolume {
    static func level(_ value: Float) -> Int {
        guard value.isFinite else { return 0 }
        return Int((max(0, min(1, value)) * 1000).rounded())
    }
    static var current: Int { level(AVAudioSession.sharedInstance().outputVolume) }

    /// iOS has no public setter for the system volume. MPVolumeView's slider is the
    /// widely used route: the view must be in a window, so a tiny, nearly transparent
    /// instance is placed off-screen while requests arrive, then removed so the system
    /// volume HUD behaves normally for the phone's own buttons. If no slider or window is
    /// available, the request is ignored.
    @MainActor private static var host: MPVolumeView?
    @MainActor private static var removal: DispatchWorkItem?
    @MainActor static func set(level: Int) {
        guard (0...1000).contains(level) else { return }
        let target = Float(level) / 1000
        if let host, host.window != nil { apply(target, to: host) }
        else {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
            let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 160, height: 40))
            view.alpha = 0.01; view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true; view.isAccessibilityElement = false
            window.addSubview(view); host = view
            // A new slider connects to the system volume on the next run-loop turn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if host === view { apply(target, to: view) } }
        }
        removal?.cancel()
        let work = DispatchWorkItem { host?.removeFromSuperview(); host = nil; removal = nil }
        removal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
    @MainActor private static func apply(_ target: Float, to view: MPVolumeView) {
        guard let slider = slider(in: view), abs(slider.value - target) >= 0.001 else { return }
        slider.setValue(target, animated: false)
    }
    private static func slider(in view: UIView) -> UISlider? {
        for child in view.subviews {
            if let found = child as? UISlider { return found }
            if let found = slider(in: child) { return found }
        }
        return nil
    }
}
