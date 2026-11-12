import AVFAudio
import Combine
import MediaPlayer
import UIKit

enum ReceiverPhase {
    case idle, connecting, buffering, playing, computerOutput, paused, phone, reconnecting, headphones, error
    var macSelected: Bool { [.connecting, .buffering, .playing, .computerOutput, .paused, .reconnecting].contains(self) }
}

final class RelayReceiver: ObservableObject {
    @Published private(set) var phase = ReceiverPhase.idle
    @Published private(set) var title = "Ready to listen"
    @Published private(set) var detail = "Choose an output, then listen to your computer."
    @Published private(set) var headphones = "Bluetooth headphones"
    @Published private(set) var estimatedMs: Int?
    @Published private(set) var correction = 0
    @Published private(set) var diagnostics = "No active session."
    @Published private(set) var output: RelayOutput = .bluetooth
    @Published private(set) var playbackMode: RelayPlaybackMode = .reliable
    @Published private(set) var activeMode: RelayPlaybackMode = .reliable
    @Published private(set) var modeNote = ""
    @Published private(set) var supportsOutputControl = false
    @Published private(set) var computerOutput = false
    let pairing = PairingStore()
    var supportsVideoCompensation: Bool { pairing.mac?.platform != "windows" }
    private let queue = DispatchQueue(label: "relay.iphone.playback", qos: .userInitiated)
    private var transport: RelayTransport?
    private var playback = RelayPlayback()
    private var observers: [NSObjectProtocol] = []
    private var desired = false // Playback queue.
    private var localPlaybackReady = false // Playback queue.
    private var playIntent = false // Main thread; independent of asynchronously published phase.
    private var waitingForComputerOutput = false // Main thread; stops local playback before the remote acknowledgement.
    var audioIdleForAdvertisement: Bool { !playIntent }
    private var intentGeneration = 0
    private var connectionGeneration = 0 // Main thread; invalidates delayed UI callbacks after disconnect or suspension.
    private var routeUID = ""
    private var generation = 0
    private var reportTimer: DispatchSourceTimer?
    private var holdBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var profile: RouteTiming? {
        pairing.mac.map { RouteTiming(pin: $0.pin, route: routeUID, mode: activeMode, hostOverride: pairing.hostOverride) }
    }

    init() {
        output = RelayOutput(rawValue: UserDefaults.standard.string(forKey: "receiverOutput") ?? "") ?? .bluetooth
        playbackMode = .reliable
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.playIntent, !self.computerOutput, !self.waitingForComputerOutput else { return }
            guard let route = self.output.currentRoute(), route.uid == self.routeUID else {
                self.parkListening("OUTPUT", phase: .headphones, title: "Audio output changed")
                return
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                guard self.playIntent, !self.computerOutput, !self.waitingForComputerOutput else { return }
                self.parkListening("PHONE", phase: .phone, title: "Phone audio has priority")
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if (self.computerOutput || self.waitingForComputerOutput) && self.playIntent {
                self.parkListening("OUTPUT", phase: .paused, title: "Playing on computer")
                self.detail = "Computer audio continues. Return to PairIt and choose Listen here when you want it on this iPhone."
            } else if !self.playIntent { self.finishHoldInBackground() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] notification in
            guard let self else { return }
            let object = notification.object as AnyObject?
            self.queue.async { if self.desired && self.localPlaybackReady { self.playback.configurationChanged(object) } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.playIntent && !self.computerOutput && !self.waitingForComputerOutput {
                self.connect(requestPhoneOutput: false)
            } else {
                // A local audio-service reset is not a choice to move a shared
                // computer output back to phones or resume a parked listener.
                self.queue.sync { self.localPlaybackReady = false; self.playback.stop() }
            }
        })
        let commands = MPRemoteCommandCenter.shared()
        commands.pauseCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.pauseComputer() }; return .success }
        commands.playCommand.addTarget { [weak self] _ in
            guard !AudioPresentationGate.isPresenting else { return .commandFailed }
            DispatchQueue.main.async { if let self, self.phase.macSelected { self.connect() } }; return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard !AudioPresentationGate.isPresenting else { return .commandFailed }
            DispatchQueue.main.async {
                guard let self, self.phase.macSelected else { return }
                if self.phase == .paused { self.connect() } else { self.pauseComputer() }
            }; return .success
        }
        commands.stopCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.pauseComputer() }; return .success }
        // A live relay has no track queue. Do not reinterpret next/previous as source switches.
        commands.nextTrackCommand.isEnabled = false; commands.previousTrackCommand.isEnabled = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-connected") {
            phase = .playing; title = "Listening to computer"; detail = "Your headphones · Local network"; headphones = "Bluetooth headphones"
            diagnostics = "Interface preview only. No audio connection."
        }
        #endif
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func selectOutput(_ value: RelayOutput) {
        guard value != output else { return }
        if playIntent || phase == .paused { parkListening("OUTPUT", phase: .headphones, title: "Output selected") }
        output = value; UserDefaults.standard.set(value.rawValue, forKey: "receiverOutput")
        if value == .bluetooth { playbackMode = .reliable }
        resetDisplayedTiming()
        publish(.idle, "Output selected", "Choose \(value.title) in the system picker, then tap Computer.")
    }
    func setHostOverride(_ value: String) throws {
        disconnect(); try pairing.setHostOverride(value); resetDisplayedTiming()
        publish(.idle, "Computer address saved", "Tap Computer to reconnect securely. An empty address uses automatic discovery.")
    }
    private func resetDisplayedTiming() { estimatedMs = nil; correction = 0; routeUID = ""; activeMode = playbackMode; modeNote = "" }
    func connect(requestPhoneOutput: Bool = true) {
        guard !AudioPresentationGate.isPresenting else {
            publish(.idle, "Ready to listen", "Close the advertisement, then choose Computer to start audio."); return
        }
        guard let computer = pairing.mac else { publish(.idle, "Connect your computer", "Open PairIt on your computer and scan its pairing code."); return }
        waitingForComputerOutput = false
        stopPlayback(keepTransport: true)
        let intentTicket = intentGeneration
        let connectionTicket = connectionGeneration
        let session = AVAudioSession.sharedInstance()
        do {
            // Receiver never requests microphone/HFP or a playAndRecord speaker override.
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.010)
            try session.setActive(true)
        } catch {
            publish(.error, "Audio is unavailable", "Finish the current call or audio session, then try again."); return
        }
        guard let route = output.currentRoute() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            publish(.headphones, "Choose \(output.title)", "Use the output picker or Control Center. PairIt won’t silently switch to another output."); return
        }
        playIntent = true; headphones = route.portName; routeUID = route.uid
        let requestedMode = output == .bluetooth ? RelayPlaybackMode.reliable : playbackMode
        activeMode = requestedMode; modeNote = requestedMode == .interactive ? "Learning arrival timing…" : ""
        let override = pairing.hostOverride
        let timing = RouteTiming(pin: computer.pin, route: route.uid, mode: requestedMode, hostOverride: override)
        estimatedMs = timing.estimate; correction = timing.correction
        publish(.connecting, "Connecting to \(computer.displayName)", "Keep PairIt open on your computer.")
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1; let generation = self.generation; self.desired = true
            self.localPlaybackReady = true
            self.playback.stop(); self.reportTimer?.cancel()
            self.playback = RelayPlayback(mode: requestedMode)
            let existing = self.transport
            let transport = existing ?? RelayTransport(mac: computer, queue: self.queue, hostOverride: override); self.transport = transport
            transport.onOutput = { [weak self, weak transport] supported, onComputer in
                guard let self, let transport, self.transport === transport else { return }
                let needsPhonePreparation = !self.localPlaybackReady
                let pendingOutput = transport.pendingComputerOutput
                if onComputer || pendingOutput == true { self.localPlaybackReady = false; self.playback.stop() }
                DispatchQueue.main.async {
                    guard self.connectionGeneration == connectionTicket else { return }
                    self.supportsOutputControl = supported; self.computerOutput = onComputer
                    self.waitingForComputerOutput = pendingOutput == true && !onComputer
                    if !self.playIntent {
                        if self.phase == .phone {
                            self.detail = onComputer ? "Computer output selected. Phone apps remain selected on this iPhone."
                                : "Phone apps remain selected. Choose Computer when you want to listen here."
                        } else if self.phase == .paused {
                            self.detail = onComputer ? "Computer output selected. This iPhone stays paused; choose Listen here to return."
                                : "Phones selected. This iPhone stays paused until you choose Resume audio."
                        }
                        return
                    }
                    guard self.intentGeneration == intentTicket else { return }
                    if self.waitingForComputerOutput {
                        if supported { self.publish(.buffering, "Switching to computer", "Waiting for the computer to confirm. Audio stays stopped on this iPhone.") }
                        else {
                            self.parkListening("OUTPUT", phase: .paused, title: "Computer output is unavailable")
                            self.detail = "Update the companion to switch its output. Choose Computer explicitly to listen on this iPhone again."
                        }
                        return
                    }
                    if onComputer {
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                        if pendingOutput == false { self.publish(.buffering, "Returning audio here", "Waiting for the computer to switch back to phones.") }
                        else { self.publish(.computerOutput, "Playing on computer", "Still connected to \(computer.displayName). Choose Listen here to return audio to your iPhone.") }
                    } else if needsPhonePreparation {
                        if UIApplication.shared.applicationState == .active { self.connect(requestPhoneOutput: false) }
                        else { self.parkListening("OUTPUT", phase: .paused, title: "Ready to listen here") }
                    }
                }
            }
            transport.onHandoff = { [weak self, weak transport] status in
                guard let self, let transport, self.transport === transport, !self.desired, status & 4 != 0 else { return }
                DispatchQueue.main.async {
                    guard !self.playIntent, [.paused, .phone, .headphones].contains(self.phase) else { return }
                    if self.computerOutput {
                        self.detail = "Computer output selected. Listening on this iPhone stays stopped; choose Listen here to return."
                        return
                    }
                    self.detail = status & 8 != 0 ? "Computer player paused. Choose Computer to return."
                        : computer.platform == "windows" ? "Relay held. Pause unsupported players on your computer; return here to listen again."
                        : "Mac output is held. Media may still be playing silently. Return here and choose Computer to listen again."
                }
            }
            self.playback.onPlaying = { [weak self] in
                guard let self, self.desired, self.localPlaybackReady, self.generation == generation else { return }
                self.publish(.playing, "Listening to \(computer.displayName)", "\(route.portName) · Local network")
                DispatchQueue.main.async { self.setNowPlaying() }
            }
            self.playback.onEstimate = { [weak self, weak transport] value in
                guard let self, self.desired, self.generation == generation else { return }
                let profile = RouteTiming(pin: computer.pin, route: route.uid, mode: self.playback.mode, hostOverride: override)
                profile.saveEstimate(value); transport?.setCompensation(profile.effective)
                DispatchQueue.main.async { self.estimatedMs = value; self.correction = profile.correction }
            }
            self.playback.onModeChange = { [weak self, weak transport] mode, message in
                guard let self, self.desired, self.generation == generation else { return }
                let profile = RouteTiming(pin: computer.pin, route: route.uid, mode: mode, hostOverride: override)
                transport?.setCompensation(profile.effective)
                DispatchQueue.main.async { self.activeMode = mode; self.modeNote = message; self.estimatedMs = profile.estimate; self.correction = profile.correction }
            }
            self.playback.onRecovery = { [weak self] in
                guard let self, self.desired, self.generation == generation else { return }
                self.publish(.buffering, "Restoring smooth playback", "Refreshing audio on the selected output.")
            }
            self.playback.onError = { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.playIntent, self.intentGeneration == intentTicket else { return }
                    self.parkListening("OUTPUT", phase: .headphones, title: "Couldn’t use the audio output")
                    self.detail = message + " Choose an output, then return to Computer."
                }
            }
            transport.onPacket = { [weak self] packet, offset in
                guard let self, self.desired, self.localPlaybackReady, self.generation == generation else { return }; self.playback.accept(packet, clockOffset: offset)
            }
            transport.onReset = { [weak self] in
                guard let self, self.desired, self.generation == generation else { return }; self.playback.reset()
            }
            transport.onState = { [weak self] text in
                guard let self, self.desired, self.generation == generation else { return }
                self.publish(text.hasPrefix("Getting") ? .buffering : text.hasPrefix("Connecting") ? .connecting : .reconnecting,
                              text, "Keep both devices on the same local network.")
            }
            transport.diagnostics = { [weak self] in self?.playback.diagnostics ?? "" }
            transport.setCompensation(timing.effective)
            if requestPhoneOutput { transport.requestOutput(computer: false) }
            if existing != nil { transport.resume() } else { transport.start() }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self, weak transport] in
                guard let self, let transport else { return }
                let text = "Transport: local network · TLS\nConnections: \(transport.connections)\nClock RTT: \(String(format: "%.1f", transport.roundTripMs)) ms\n" + self.playback.diagnostics + "\n\nSoftware estimates; not an acoustic measurement."
                DispatchQueue.main.async { self.diagnostics = text }
            }
            self.reportTimer = timer; timer.resume()
        }
    }
    func listenOnComputer() {
        guard supportsOutputControl else { return }
        let requested = queue.sync {
            guard transport?.requestOutputIfConnected(computer: true) == true else { return false }
            localPlaybackReady = false; playback.stop()
            return true
        }
        guard requested else {
            supportsOutputControl = false
            detail = "Choose Computer to reconnect before changing the playback destination."
            return
        }
        waitingForComputerOutput = true
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if playIntent { publish(.buffering, "Switching to computer", "Waiting for the computer to confirm. Audio stays stopped on this iPhone.") }
    }
    func pauseComputer() {
        guard phase.macSelected, phase != .paused else { return }
        parkListening("PAUSE", phase: .paused, title: "Listening paused")
        setNowPlaying(paused: true)
    }
    func usePhone() {
        parkListening("PAUSE", phase: .phone, title: "Phone audio")
    }
    func disconnect() {
        stopPlayback()
        publish(.idle, "Ready when you are", "Choose an output, then listen to your computer.")
    }
    private func parkListening(_ reason: String, phase: ReceiverPhase, title: String) {
        endHoldBackgroundTask()
        playIntent = false; intentGeneration += 1
        queue.sync {
            desired = false; localPlaybackReady = false; generation += 1; playback.stop()
            reportTimer?.cancel(); reportTimer = nil
            transport?.park(reason)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        publish(phase, title, "Listening stopped. Choose Computer to return; pause the computer player if needed.")
        if UIApplication.shared.applicationState != .active { finishHoldInBackground() }
    }
    private func finishHoldInBackground() {
        guard !playIntent, holdBackgroundTask == .invalid else { return }
        let ticket = intentGeneration
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Finish audio handoff") { [weak self] in
            self?.finishHeldTransport(ticket: ticket, task: task)
        }
        holdBackgroundTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finishHeldTransport(ticket: ticket, task: task)
        }
    }
    private func finishHeldTransport(ticket: Int, task: UIBackgroundTaskIdentifier) {
        guard !playIntent, intentGeneration == ticket, holdBackgroundTask == task else { return }
        // Once suspended, a later interruption-ended notification must not
        // reconnect in the background. The listener explicitly chooses Computer.
        connectionGeneration += 1
        supportsOutputControl = false
        queue.sync { transport?.suspend() }
        endHoldBackgroundTask()
    }
    private func endHoldBackgroundTask() {
        if holdBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(holdBackgroundTask); holdBackgroundTask = .invalid
        }
    }
    private func stopPlayback(keepTransport: Bool = false) {
        playIntent = false; intentGeneration += 1
        if !keepTransport { connectionGeneration += 1 }
        endHoldBackgroundTask()
        // Stop the engine before releasing the session to avoid a speaker fallback.
        queue.sync {
            desired = false; localPlaybackReady = false; generation += 1
            if keepTransport { transport?.park("OUTPUT") }
            else { transport?.stop(); transport = nil }
            reportTimer?.cancel(); reportTimer = nil; playback.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if !keepTransport { supportsOutputControl = false; computerOutput = false; waitingForComputerOutput = false }
    }
    func adjustCorrection(_ delta: Int) {
        guard supportsVideoCompensation, !routeUID.isEmpty, let profile else { return }
        profile.setCorrection(profile.correction + delta); correction = profile.correction
        queue.async { self.transport?.setCompensation(profile.effective) }
    }
    func resetCorrection() {
        guard supportsVideoCompensation, let profile else { return }; profile.setCorrection(0); correction = 0
        queue.async { self.transport?.setCompensation(profile.effective) }
    }
    func refreshAudio() { if phase.macSelected { connect() } }
    private func publish(_ phase: ReceiverPhase, _ title: String, _ detail: String) {
        let update = {
            if [.playing, .computerOutput, .buffering, .connecting, .reconnecting].contains(phase) && !self.playIntent { return }
            if phase == .playing && (self.computerOutput || self.waitingForComputerOutput) { return }
            self.phase = phase; self.title = title; self.detail = detail
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
    private func setNowPlaying(paused: Bool = false) {
        guard !computerOutput, !waitingForComputerOutput, paused || playIntent else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Computer audio", MPMediaItemPropertyArtist: "PairIt", MPNowPlayingInfoPropertyIsLiveStream: true, MPNowPlayingInfoPropertyPlaybackRate: paused ? 0 : 1]
    }
}
