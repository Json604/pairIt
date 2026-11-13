import SwiftUI

private struct TourAnchor: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { let next = nextValue(); if next != .zero { value = next } }
}

/// Native app components, sample state only. No receiver or system audio session.
struct QuickTour: View {
    let finish: () -> Void
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var step = 0
    @State private var playing = true
    @State private var elapsed = 0.0
    @State private var lastTick = ProcessInfo.processInfo.systemUptime
    @State private var automatic = false
    @State private var connected = false
    @State private var computer = false
    @State private var paused = false
    @State private var explanation: String?
    @State private var center = UnitPoint(x: 0.5, y: 0.62)
    private let duration = 9.0
    private let titles = ["Connect your computer", "Choose where to listen", "Control without opening PairIt", "One computer. Listen together."]
    private let notes = ["Tap a nearby computer. If it isn’t listed, use Scan QR.", "Switch output without disconnecting. Audio has volume and Refresh audio.", "Use Now Playing to pause or resume. Open PairIt to change output or disconnect.", "Share movies, music and more from one computer with up to four phones. Everyone uses their own headphones."]
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PhoneBackdrop()
                if (step == 0 && !connected) || step == 3 { DiscoveryVisual(center: center, reduceMotion: reduced) }
                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        PairItMark(tint: .white).frame(width: 27, height: 27)
                        Text("PairIt").font(.system(size: 21, weight: .semibold))
                        Spacer()
                        Text("DEMO").font(.system(size: 10)).tracking(1).padding(.horizontal, 8).padding(.vertical, 5).background(.white.opacity(0.08), in: Capsule())
                    }.padding(.horizontal, 20).padding(.top, 17).padding(.bottom, 17)
                    HStack {
                        Text("\(step + 1) of 4").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Button("Skip tour", action: finish).font(.system(size: 12)).frame(minWidth: 64, minHeight: 44)
                    }.padding(.horizontal, 16)
                    TabView(selection: $step) {
                        ForEach(0..<4) { page in
                            GeometryReader { size in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 17) {
                                        Text(titles[page]).font(.system(size: 29, weight: .semibold)).tracking(-0.8)
                                        Text(notes[page]).font(.system(size: 14)).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                        sample(page).frame(maxWidth: .infinity)
                                        Spacer(minLength: 0)
                                    }.padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: size.size.height)
                                }.scrollBounceBehavior(.basedOnSize)
                            }.tag(page)
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .never))
                        .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in playing = false })
                    progress.padding(.horizontal, 16).padding(.top, 12)
                    if step == 3 {
                        Button("Start using PairIt", action: finish).buttonStyle(RelayPrimaryButtonStyle()).padding(.horizontal, 16).padding(.top, 10)
                    } else {
                        Text("Swipe to explore · Tap a dot to jump").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).padding(.top, 10)
                    }
                }.padding(.bottom, 12)
            }.foregroundStyle(.white).tint(.white).coordinateSpace(name: "tour")
                .onPreferenceChange(TourAnchor.self) { point in
                    guard geometry.size.height > 0 else { return }
                    center = UnitPoint(x: point.x / geometry.size.width, y: point.y / geometry.size.height)
                }
        }
        .onAppear { if reduced || UIAccessibility.isVoiceOverRunning { playing = false }; lastTick = ProcessInfo.processInfo.systemUptime }
        .onChange(of: step) { _, _ in
            if !automatic { playing = false }; automatic = false; elapsed = 0; connected = false; computer = false; paused = false
        }
        .onChange(of: scene) { _, _ in lastTick = ProcessInfo.processInfo.systemUptime }
        .onReceive(Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let delta = min(0.1, max(0, now - lastTick)); lastTick = now
            guard scene == .active, playing, explanation == nil else { return }
            elapsed = min(duration, elapsed + delta)
            if elapsed >= duration {
                if step < 3 { automatic = true; withAnimation(reduced ? nil : .easeOut(duration: 0.25)) { step += 1 } }
                else { playing = false }
            }
        }
        .alert("Try it first", isPresented: Binding(get: { explanation != nil }, set: { if !$0 { explanation = nil } })) {
            Button("Done") { explanation = nil }
        } message: { Text(explanation ?? "") }
    }
    private var progress: some View {
        HStack(spacing: 0) {
            ForEach(0..<4) { index in
                Button { playing = false; withAnimation(reduced ? nil : .easeOut(duration: 0.2)) { step = index }; elapsed = 0 } label: {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.4))
                        if index == step { Rectangle().fill(.white).frame(width: 32 * min(1, elapsed / duration)) }
                    }.frame(width: index == step ? 32 : 7, height: 7).clipShape(Capsule()).frame(width: 44, height: 44)
                }.accessibilityLabel("Step \(index + 1): \(titles[index])").accessibilityAddTraits(index == step ? .isSelected : [])
            }
            Spacer()
            Button { playing.toggle(); if elapsed >= duration { elapsed = 0 }; lastTick = ProcessInfo.processInfo.systemUptime } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 15)).frame(width: 44, height: 44).background(.white.opacity(0.14), in: Circle())
            }.accessibilityLabel(playing ? "Pause tutorial" : "Play tutorial")
        }.buttonStyle(.plain)
    }
    private func act(_ action: () -> Void) { playing = false; action() }
    private func explain(_ text: String) { playing = false; explanation = text }
    @ViewBuilder private func sample(_ page: Int) -> some View {
        if page == 0 && connected { output }
        else if page == 0 || page == 3 { discovery(page) }
        else if page == 1 { output }
        else { notification }
    }
    private func discovery(_ page: Int) -> some View {
        VStack(spacing: 18) {
            if page == 3 {
                RelayPhoneOrbit {
                    tourPhone("Alex’s phone", platform: "iPhone")
                    tourPhone("Sam’s phone", platform: "Android")
                    tourPhone("Maya’s phone", platform: "iPhone")
                }
            } else {
                RelayNearbyDevice(name: "MacBook Pro", detail: connected ? "Connected" : "Paired") {
                    act { connected = true }
                }
            }
            VStack(spacing: 5) {
                Image(systemName: "iphone").font(.title2).frame(width: 46, height: 46)
                    .background(.white.opacity(0.08), in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.3)))
                    .background(GeometryReader { proxy in
                        if step == page { Color.clear.preference(key: TourAnchor.self, value: CGPoint(x: proxy.frame(in: .named("tour")).midX, y: proxy.frame(in: .named("tour")).midY)) }
                    })
                Text("You").font(.caption)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(page == 3 ? "Invite to listen together" : connected ? "Connected" : "Ready to connect").font(.headline)
                Button { act { if page == 3 { explain("Share PairIt, then scan the same computer’s code. Up to four phones.") } else { connected.toggle() } } } label: {
                    Label(page == 3 ? "Share app" : connected ? "Pause audio" : "Connect", systemImage: page == 3 ? "square.and.arrow.up" : "headphones")
                }.buttonStyle(RelayPrimaryButtonStyle())
                if page == 0 {
                    HStack(alignment: .top, spacing: 6) {
                        RelayShortcut(title: "Output", icon: "headphones") { explain("Choose headphones or your phone’s speaker.") }
                        RelayShortcut(title: "Scan QR", icon: "qrcode.viewfinder") { explain("Scan the pairing code shown on your computer.") }
                        RelayShortcut(title: "Get PC app", icon: "laptopcomputer") { explain("Downloads for Mac, Windows and Linux.") }
                    }
                }
            }.padding(18).foregroundStyle(RelayPalette.ink).frost(26)
        }
    }
    private func tourPhone(_ name: String, platform: String) -> some View {
        RelayNearbyDevice(name: name, detail: platform, phone: true) {
            explain("Share the app, then scan the same computer’s code. This demo sends nothing.")
        }.frame(maxWidth: .infinity)
    }
    private var output: some View {
        VStack(spacing: 18) {
            ListeningVisual(playing: !computer && !paused, computer: computer, reduceMotion: reduced)
            Text(computer ? "Playing on computer" : paused ? "Paused" : "Listening through your phone").font(.subheadline)
            VStack(spacing: 12) {
                HStack(spacing: 4) {
                    RelayOutputChoice(title: "This phone", icon: "iphone", selected: !computer) { act { computer = false } }
                    RelayOutputChoice(title: "Computer", icon: "laptopcomputer", selected: computer) { act { computer = true } }
                }.padding(5).background(Color(white: 0.92), in: RoundedRectangle(cornerRadius: 17))
                Button(paused ? "Start audio" : "Pause audio") { act { paused.toggle() } }.buttonStyle(RelayPrimaryButtonStyle())
                    .opacity(computer ? 0 : 1).allowsHitTesting(!computer).accessibilityHidden(computer)
                Text("Headphones").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 6) {
                    RelayShortcut(title: "Output", icon: "headphones") { explain("Choose headphones, a wired device or your iPhone’s speaker.") }
                    RelayShortcut(title: "Audio", icon: "slider.horizontal.3") { explain("Change volume or refresh the audio buffer.") }
                    RelayShortcut(title: "More", icon: "ellipsis") { explain("Pair another computer or disconnect.") }
                }
            }.padding(18).foregroundStyle(RelayPalette.ink).frost(26)
        }
    }
    private var notification: some View {
        // iOS owns the actual Now Playing view. Only its supported commands appear here.
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: "headphones").font(.largeTitle).frame(width: 60, height: 60).background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) { Text("Computer audio").font(.headline); Text("PairIt").font(.subheadline).foregroundStyle(.secondary) }; Spacer()
            }
            Button { act { paused.toggle() } } label: { Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 30)).frame(width: 64, height: 56) }.accessibilityLabel(paused ? "Resume" : "Pause")
        }.padding(22).foregroundStyle(.black).tint(.black).background(.white, in: RoundedRectangle(cornerRadius: 26))
    }
}
