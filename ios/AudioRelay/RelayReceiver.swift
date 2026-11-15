import CallKit
import AVFAudio
import Combine
import MediaPlayer
import UIKit

enum ReceiverPhase {
    case idle, connecting, buffering, playing, computerOutput, paused, phone, reconnecting, headphones, error
    var macSelected: Bool { [.connecting, .buffering, .playing, .computerOutput, .paused, .reconnecting].contains(self) }
}

final class RelayReceiver: ObservableObject {
    @Published private(set) var computerVolumeText = "";
    @Published private(set) var phase = ReceiverPhase.idle
    @Published private(set) var title = "Ready to listen"
    @Published private(set) var detail = "Choose an output, then listen to your computer."
    @Published private(set) var headphones = "Bluetooth headphones"
    @Published private(set) var estimatedMs: Int?
    @Published private(set) var correction = 0
    var canAdjustTiming: Bool { !routeUID.isEmpty && profile != nil }
    @Published private(set) var groupTimingStatus = ""
    @Published private(set) var diagnostics = "No active session."
    @Published private(set) var output: RelayOutput = .bluetooth
    @Published private(set) var playbackMode: RelayPlaybackMode = .reliable
    @Published private(set) var activeMode: RelayPlaybackMode = .reliable
    @Published private(set) var modeNote = ""
    @Published private(set) var supportsOutputControl = false
    @Published private(set) var computerOutput = false
    let pairing = PairingStore()
    var supportsVideoCompensation: Bool { pairing.mac?.platform != "windows" && pairing.mac?.platform != "linux" }
    private let queue = DispatchQueue(label: "relay.iphone.playback", qos: .userInitiated)
    private var transport: RelayTransport?
    private var playback = RelayPlayback()
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var hasRemoteSession = false
    private var desired = false // Playback queue.
    private var localPlaybackReady = false // Playback queue.
    private var playIntent = false // Main thread; independent of asynchronously published phase.
    private var waitingForComputerOutput = false // Main thread; stops local playback before the remote acknowledgement.
    var audioIdleForAdvertisement: Bool { !playIntent }
    private var intentGeneration = 0
    private var connectionGeneration = 0 // Main thread; invalidates delayed UI callbacks after disconnect or suspension.
    private var routeUID = ""
    private var choosingOutput = false
    private var resumeAfterOutputChoice = false
    private let calls = CXCallObserver()
    private var interruptedByPhoneAudio = false
    private var outputRecovery = ExternalOutputRecovery()
    private var outputRecoveryWork: DispatchWorkItem?
    private func cancelOutputRecovery() {
        UserDefaults.standard.removeObject(forKey: "outputRecoveryPin")
        outputRecovery.cancel(); outputRecoveryWork?.cancel(); outputRecoveryWork = nil
    }
    func autoReconnectChanged(_ enabled: Bool) { if !enabled { cancelOutputRecovery() } }
    private func scheduleExternalOutput() {
        guard outputRecovery.waiting else { return }
        outputRecoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resumeExternalOutput() }
        outputRecoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }
    private func resumeExternalOutput() {
        guard outputRecovery.waiting else { return }
        guard UserDefaults.standard.object(forKey: "trustedAutoReconnect") as? Bool != false,
              pairing.mac != nil else { cancelOutputRecovery(); return }
        let selected = [RelayOutput.bluetooth, .wired].first { $0.currentRoute() != nil }
        let permitted = !AudioPresentationGate.isPresenting && !calls.calls.contains(where: { !$0.hasEnded })
        guard outputRecovery.ready(externalReady: selected != nil, permitted: permitted), let selected else {
            if selected != nil { scheduleExternalOutput() }; return
        }
        output = selected; UserDefaults.standard.set(selected.rawValue, forKey: "receiverOutput")
        cancelOutputRecovery(); connect(requestPhoneOutput: true, useCurrentOutput: false)
    }
    private func waitForExternalOutput() {
        outputRecovery.lost(external: output != .speaker,
                            enabled: UserDefaults.standard.object(forKey: "trustedAutoReconnect") as? Bool != false)
        if outputRecovery.waiting { UserDefaults.standard.set(pairing.mac?.pin, forKey: "outputRecoveryPin") }
        else { UserDefaults.standard.removeObject(forKey: "outputRecoveryPin") }
        guard outputRecovery.waiting else { parkListening("OUTPUT", phase: .headphones, title: "Output disconnected"); return }
        interruptedByPhoneAudio = false
        stopPlayback()
        publish(.headphones, "Waiting for headphones", "Reconnect Bluetooth, wired or USB audio to resume automatically.")
        scheduleExternalOutput()
    }
    var currentOutputName: String {
        if computerOutput { return "Playing on " + (pairing.mac?.displayName ?? "computer") }
        let route = output.currentRoute() ?? (!playIntent ? AVAudioSession.sharedInstance().currentRoute.outputs.first : nil)
        return route.map { $0.portType == .builtInSpeaker ? "iPhone speaker" : $0.portName } ?? "Audio output unavailable"
    }
    func beginOutputChoice() { cancelOutputRecovery(); choosingOutput = true; resumeAfterOutputChoice = playIntent && !computerOutput }
    func endOutputChoice() { choosingOutput = false; resumeAfterOutputChoice = false }
    private var generation = 0
    private var reportTimer: DispatchSourceTimer?
    private var holdBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var profile: RouteTiming? {
        pairing.mac.map { RouteTiming(pin: $0.pin, route: routeUID, mode: activeMode, hostOverride: pairing.hostOverride) }
    }

    init() {
        output = RelayOutput(rawValue: UserDefaults.standard.string(forKey: "receiverOutput") ?? "") ?? .bluetooth
        playbackMode = .reliable
        outputRecovery.restore(savedPin: UserDefaults.standard.string(forKey: "outputRecoveryPin") ?? "",
                               currentPin: pairing.mac?.pin ?? "",
                               enabled: UserDefaults.standard.object(forKey: "trustedAutoReconnect") as? Bool != false && output != .speaker)
        if outputRecovery.waiting {
            phase = .headphones; title = "Waiting for headphones"
            detail = "Reconnect your headphones to resume listening."
            scheduleExternalOutput()
        } else { UserDefaults.standard.removeObject(forKey: "outputRecoveryPin") }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            if self.outputRecovery.waiting { self.scheduleExternalOutput(); return }
            if self.choosingOutput, reason == .override || reason == .routeConfigurationChange || reason == .newDeviceAvailable {
                let routes = AVAudioSession.sharedInstance().currentRoute.outputs
                if let selected = RelayOutput.allCases.first(where: { !routes.isEmpty && routes.allSatisfy($0.matches) }),
                   let route = routes.first, route.uid != self.routeUID {
                    let resume = self.resumeAfterOutputChoice
                    self.endOutputChoice()
                    self.output = selected; self.headphones = route.portName
                    UserDefaults.standard.set(selected.rawValue, forKey: "receiverOutput")
                    self.resetDisplayedTiming()
                    if resume { self.connect(requestPhoneOutput: false) }
                    return
                }
            }
            guard self.playIntent || self.interruptedByPhoneAudio, !self.computerOutput, !self.waitingForComputerOutput else { return }
            guard let route = self.output.currentRoute(), route.uid == self.routeUID else {
                self.waitForExternalOutput()
                return
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleExternalOutput()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                guard self.playIntent, !self.computerOutput, !self.waitingForComputerOutput else { return }
                self.parkListening(self.calls.calls.contains(where: { !$0.hasEnded }) ? "OUTPUT" : "PHONE", phase: .phone, title: "Phone audio has priority")
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
        for (command, intent) in [(commands.playCommand, RemotePlaybackCommand.play),
                                  (commands.pauseCommand, .pause),
                                  (commands.togglePlayPauseCommand, .toggle),
                                  (commands.stopCommand, .pause)] {
            let target = command.addTarget { [weak self] _ in
                let perform = { self?.performRemoteCommand(intent) ?? .commandFailed }
                return Thread.isMainThread ? perform() : DispatchQueue.main.sync(execute: perform)
            }
            remoteTargets.append((command, target))
        }
        // A live relay has no track queue. Do not reinterpret next/previous as source switches.
        commands.nextTrackCommand.isEnabled = false; commands.previousTrackCommand.isEnabled = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-connected") {
            phase = .playing; title = "Listening to computer"; detail = "Your headphones · Local network"; headphones = "Bluetooth headphones"
            diagnostics = "Interface preview only. No audio connection."
        }
        #endif
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
    }
    private func performRemoteCommand(_ command: RemotePlaybackCommand) -> MPRemoteCommandHandlerStatus {
        if command == .pause && outputRecovery.waiting {
            pauseComputer()
            return .success
        }
        let listening = playIntent && !computerOutput && !waitingForComputerOutput
        switch command.action(paired: pairing.mac != nil, listening: listening) {
        case .unavailable: return .noSuchContent
        case .none: return .success
        case .pause:
            pauseComputer()
            return .success
        case .connect:
            // Direct service action: no pairing interstitial or app-open ad is requested.
            guard !AudioPresentationGate.isPresenting, !calls.calls.contains(where: { !$0.hasEnded }) else { return .commandFailed }
            connect(requestPhoneOutput: true)
            return playIntent || outputRecovery.waiting ? .success : .commandFailed
        }
    }
    func selectOutput(_ value: RelayOutput) {
        cancelOutputRecovery(); interruptedByPhoneAudio = false
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
    private func resetDisplayedTiming() { groupTimingStatus = ""; estimatedMs = nil; correction = 0; routeUID = ""; activeMode = playbackMode; modeNote = "" }
    func connect(requestPhoneOutput: Bool = true, useCurrentOutput: Bool = true) {
        cancelOutputRecovery()
        DispatchQueue.main.async { ConnectionAcknowledgment.shared.stopSound() }
        guard !AudioPresentationGate.isPresenting else {
            publish(.idle, "Ready to listen", "Close the advertisement, then choose Computer to start audio."); return
        }
        guard let computer = pairing.mac else { publish(.idle, "Connect your computer", "Open PairIt on your computer and scan its pairing code."); return }
        hasRemoteSession = true
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
        let currentOutput = RelayOutput.allCases.first { $0.currentRoute() != nil }
        output = ConnectionOutput.resolve(saved: output, current: currentOutput,
                                          explicit: requestPhoneOutput && useCurrentOutput)
        UserDefaults.standard.set(output.rawValue, forKey: "receiverOutput")
        guard let route = output.currentRoute() else {
            if output != .speaker && UserDefaults.standard.object(forKey: "trustedAutoReconnect") as? Bool != false { waitForExternalOutput(); return }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            publish(.headphones, "Choose \(output.title)", "Use the output picker or Control Center. PairIt won’t silently switch to another output."); return
        }
        playIntent = true; headphones = route.portName; routeUID = route.uid
        let requestedMode: RelayPlaybackMode = PresentationTiming.adaptive(platform: computer.platform ?? "", bluetooth: output == .bluetooth) ? .interactive : .reliable
        activeMode = requestedMode; modeNote = requestedMode == .interactive ? "Learning arrival timing…" : ""
        let override = pairing.hostOverride
        let timing = RouteTiming(pin: computer.pin, route: route.uid, mode: requestedMode, hostOverride: override)
        estimatedMs = timing.estimate; correction = timing.correction
        publish(.connecting, "Connecting to \(computer.displayName)", "Output: \(currentOutputName). Keep PairIt open on your computer.")
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
            transport.onComputerVolume = { [weak self, weak transport] volume in
                DispatchQueue.main.async {
                    guard let self, let transport, self.transport === transport else { return }
                    self.computerVolumeText = volume.description
                }
            }
            transport.onDesktopPlayback = { [weak self] playing in
                guard let self else { return }
                    DispatchQueue.main.async {
                        guard self.connectionGeneration == connectionTicket else { return }
                        if !playing { self.pauseComputer(); return }
                        guard !self.calls.calls.contains(where: { !$0.hasEnded }), !AudioPresentationGate.isPresenting else {
                            self.parkListening("OUTPUT", phase: .phone, title: "Finish the current phone session, then resume"); return
                        }
                        self.connect(requestPhoneOutput: true)
                    }
            }
            let configuredConnection = transport.connections
            transport.onHandoff = { [weak self, weak transport] status in
                guard let self, let transport, self.transport === transport else { return }
                if status & 4 != 0 { DispatchQueue.main.async { if self.connectionGeneration==connectionTicket { self.pausing=false } } }
                let offered = transport.claimResumeOffer(status)
                if offered || (transport.connections > max(1, configuredConnection) && status & 4 != 0) {
                    DispatchQueue.main.async {
                        guard self.connectionGeneration == connectionTicket, self.interruptedByPhoneAudio,
                              self.phase == .phone, !self.playIntent, !self.computerOutput,
                              offered || !AVAudioSession.sharedInstance().isOtherAudioPlaying,
                              !self.calls.calls.contains(where: { !$0.hasEnded }), !AudioPresentationGate.isPresenting else { return }
                        self.interruptedByPhoneAudio = false
                        self.connect(requestPhoneOutput: false)
                    }
                }
                // onHandoff only delivers the current acknowledged intent token.
                // A silent but accepted listening session is already connected.
                if self.desired, self.localPlaybackReady, status & 1 != 0, status & 4 == 0, status & 64 == 0 {
                    DispatchQueue.main.async {
                        guard self.connectionGeneration == connectionTicket, self.playIntent, !self.computerOutput else { return }
                        if [.connecting, .buffering, .reconnecting].contains(self.phase), !self.waitingForComputerOutput {
                            self.publish(.buffering, "Connected · play audio on your computer", "")
                        }
                        ConnectionAcknowledgment.shared.connected(computer.pin, output: self.output)
                    }
                }
                guard !self.desired, status & 4 != 0 else { return }
                DispatchQueue.main.async {
                    guard !self.playIntent, [.paused, .phone, .headphones].contains(self.phase) else { return }
                    if self.computerOutput {
                        self.detail = "Computer output selected. Listening on this iPhone stays stopped; choose Listen here to return."
                        return
                    }
                    self.detail = status & 8 != 0 ? "Computer player paused. Choose Computer to return."
                        : (computer.platform == "windows" || computer.platform == "linux") ? "Relay held. Pause unsupported players on your computer; return here to listen again."
                        : "Mac output is held. Media may still be playing silently. Return here and choose Computer to listen again."
                }
            }
            self.playback.onPlaying = { [weak self, weak transport] in
                guard let self, let transport, self.desired, self.localPlaybackReady, self.generation == generation else { return }
                if transport.claimConnectionFeedback() {
                    DispatchQueue.main.async {
                        guard self.connectionGeneration == connectionTicket, self.playIntent,
                              ConnectionAcknowledgment.shared.claim(computer.pin) else { return }
                        self.queue.async {
                            guard self.desired, self.localPlaybackReady, self.generation == generation else { return }
                            self.playback.requestConnectionFeedback()
                        }
                    }
                }
                self.publish(.playing, "Listening to \(computer.displayName)", "\(route.portName) · Local network")
                DispatchQueue.main.async { self.setNowPlaying() }
            }
            self.playback.onOutputTiming = { [weak transport] minimum, output in
                transport?.setOutputTiming(minimum: minimum, output: output)
            }
            transport.onPresentationTarget = { [weak self, weak transport] target, listeners, capable in
                guard let self, self.transport === transport, self.desired, self.generation == generation else { return }
                self.playback.setPresentationTarget(target)
                let message = listeners < 2 ? "" : capable < listeners ? "Update other phones for shared timing" : target == 0 ? "Learning shared timing…" : "Shared timing adjusted"
                DispatchQueue.main.async { if self.connectionGeneration == connectionTicket { self.groupTimingStatus = self.playIntent && !self.computerOutput && !self.waitingForComputerOutput ? message : "" } }
            }
            transport.setOutputTiming(minimum: 320, output: nil)
            self.playback.onEstimate = { [weak self, weak transport] value in
                guard let self, self.desired, self.generation == generation else { return }
                let profile = RouteTiming(pin: computer.pin, route: route.uid, mode: self.playback.mode, hostOverride: override)
                profile.saveEstimate(value); transport?.setCompensation(profile.effective)
                self.playback.setLocalCorrection(["linux", "windows"].contains(computer.platform) ? profile.correction : 0)
                DispatchQueue.main.async { self.estimatedMs = value; self.correction = profile.correction }
            }
            self.playback.onModeChange = { [weak self, weak transport] mode, message in
                guard let self, self.desired, self.generation == generation else { return }
                let profile = RouteTiming(pin: computer.pin, route: route.uid, mode: mode, hostOverride: override)
                transport?.setCompensation(profile.effective)
                self.playback.setLocalCorrection(["linux", "windows"].contains(computer.platform) ? profile.correction : 0)
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
                DispatchQueue.main.async { if self.connectionGeneration == connectionTicket { ConnectionAcknowledgment.shared.disconnected(output: self.output) } }
            }
            transport.onGroupFull = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.connectionGeneration == connectionTicket else { return }
                    self.stopPlayback()
                    self.publish(.error, "Listening group is full", "Four phones are already connected. Disconnect one phone, then tap Connect again.")
                }
            }
            transport.onUnavailable = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.connectionGeneration == connectionTicket else { return }
                    ConnectionAcknowledgment.shared.disconnected(output: self.output)
                    self.stopPlayback()
                    self.publish(.error, "Computer unavailable", "Connection lost or network changed. Keep both devices on the same Wi-Fi and open PairIt on your computer, then try again.")
                }
            }
            transport.onState = { [weak self] text in
                guard let self, self.desired, self.generation == generation else { return }
                self.publish(text.hasPrefix("Getting") ? .buffering : text.hasPrefix("Connecting") ? .connecting : .reconnecting,
                              text, "Keep both devices on the same local network.")
            }
            transport.diagnostics = { [weak self] in self?.playback.diagnostics ?? "" }
            self.playback.setLocalCorrection(["linux", "windows"].contains(computer.platform) ? timing.correction : 0)
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
        groupTimingStatus = "";
        cancelOutputRecovery(); interruptedByPhoneAudio = false
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
    @Published var pausing = false
    private var pauseTicket=0
    func pauseComputer() {
        if outputRecovery.waiting { cancelOutputRecovery(); stopPlayback(); publish(.paused,"Listening paused","Tap Resume when ready."); return }
        guard phase.macSelected, phase != .paused else { return }
        pauseTicket += 1;let ticket=pauseTicket;pausing=true
        parkListening("PAUSE", phase: .paused, title: "Listening paused")
        DispatchQueue.main.asyncAfter(deadline:.now()+8){[weak self] in
            guard let self,self.pauseTicket==ticket,self.pausing else{return}
            self.pausing=false;self.detail="Computer did not confirm pause. Try again."
        }
        setNowPlaying(paused: true)
    }
    func usePhone() {
        parkListening("PAUSE", phase: .phone, title: "Phone audio")
    }
    func disconnect(completion: (() -> Void)? = nil) {
        UserDefaults.standard.removeObject(forKey: "groupGuestPin")
        groupTimingStatus = "";
        hasRemoteSession = false
        computerVolumeText = ""
        cancelOutputRecovery(); interruptedByPhoneAudio = false
        DispatchQueue.main.async { ConnectionAcknowledgment.shared.disconnected(output: self.output) }
        stopPlayback(completion: completion)
        publish(.idle, "Ready when you are", "Choose an output, then listen to your computer.")
    }
    private func parkListening(_ reason: String, phase: ReceiverPhase, title: String) {
        groupTimingStatus = "";
        cancelOutputRecovery()
        endHoldBackgroundTask()
        interruptedByPhoneAudio = reason == "PHONE"
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
    private func stopPlayback(keepTransport: Bool = false, completion: (() -> Void)? = nil) {
        groupTimingStatus = "";
        playIntent = false; intentGeneration += 1
        if !keepTransport { connectionGeneration += 1 }
        endHoldBackgroundTask()
        // Stop the engine before releasing the session to avoid a speaker fallback.
        queue.sync {
            desired = false; localPlaybackReady = false; generation += 1
            if keepTransport { transport?.park("OUTPUT") }
            else {
                let finished = { if let completion { DispatchQueue.main.async(execute: completion) } }
                if let transport { transport.stop(completion: finished) } else { finished() }
                transport = nil
            }
            reportTimer?.cancel(); reportTimer = nil; playback.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if !keepTransport { supportsOutputControl = false; computerOutput = false; waitingForComputerOutput = false }
    }
    func adjustCorrection(_ delta: Int) {
        guard !routeUID.isEmpty, let profile else { return }
        profile.setCorrection(profile.correction + delta); correction = profile.correction
        let local = !supportsVideoCompensation
        queue.async { self.transport?.setCompensation(profile.effective); self.playback.setLocalCorrection(local ? profile.correction : 0) }
    }
    func resetCorrection() {
        guard let profile else { return }; profile.setCorrection(0); correction = 0
        let local = !supportsVideoCompensation
        queue.async { self.transport?.setCompensation(profile.effective); self.playback.setLocalCorrection(local ? profile.correction : 0) }
    }
    func refreshAudio() {
        guard playIntent, phase.macSelected, !computerOutput else { return }
        queue.async {
            guard self.desired, self.localPlaybackReady else { return }
            self.playback.reset()
            self.publish(.buffering, "Refreshing audio", "Keeping your computer and selected output connected.")
        }
    }
    private func publish(_ phase: ReceiverPhase, _ title: String, _ detail: String) {
        let update = {
            if [.playing, .computerOutput, .buffering, .connecting, .reconnecting].contains(phase) && !self.playIntent { return }
            if phase == .playing && (self.computerOutput || self.waitingForComputerOutput) { return }
            self.phase = phase; self.title = title; self.detail = detail
            if self.hasRemoteSession && [.connecting, .buffering, .playing, .reconnecting, .paused, .headphones, .error].contains(phase) {
                self.setNowPlaying(paused: !self.playIntent)
            }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
    private func setNowPlaying(paused: Bool = false) {
        guard hasRemoteSession, !computerOutput, !waitingForComputerOutput, paused || playIntent else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: pairing.mac?.displayName ?? "PairIt", MPNowPlayingInfoPropertyIsLiveStream: true, MPNowPlayingInfoPropertyPlaybackRate: paused ? 0 : 1]
    }
}
