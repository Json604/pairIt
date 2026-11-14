import SwiftUI
struct MicrophoneView: View {
    @ObservedObject var receiver: RelayReceiver
    @StateObject private var microphone = PhoneMicrophone()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                RelayBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Your phone.\nYour microphone.").font(RelayTypography.display(30, strong: true))
                        Text("In your computer’s Settings, enable Phone microphone and select an installed virtual audio cable. Choose that cable as the microphone in your calling or recording app.").foregroundStyle(RelayPalette.secondary)
                        VStack(alignment: .leading, spacing: 18) {
                            Label(microphone.message, systemImage: microphone.running ? "mic.fill" : "mic.slash")
                            Button(microphone.running ? "Stop microphone" : "Start microphone") {
                                if microphone.running { microphone.stop() }
                                else { receiver.disconnect(); microphone.start(computer: receiver.pairing.mac, host: receiver.pairing.hostOverride) }
                            }.buttonStyle(RelayPrimaryButtonStyle())
                        }.padding(22).frost(26)
                        Text("Keep this screen open. Leaving it stops transmission. Nothing is recorded or uploaded. Starting microphone mode stops computer audio on this phone.").font(.caption).foregroundStyle(RelayPalette.secondary)
                    }.padding(22)
                }
            }.foregroundStyle(RelayPalette.ink).navigationTitle("Phone microphone").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.light)
            .onDisappear { microphone.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { microphone.stop() } }
    }
}
