import SwiftUI

struct OutputControls: View {
    @ObservedObject var receiver: RelayReceiver
    var body: some View {
        Picker("Output", selection: Binding(get: { receiver.output }, set: receiver.selectOutput)) {
            ForEach(RelayOutput.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.menu).font(.subheadline)
    }
}

struct SharedListeningView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                RelayBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("One stream.\nMore company.").font(RelayTypography.display(28))
                        Text("The most compatible setup uses one phone for each listener, with up to four phones per computer.").foregroundStyle(RelayPalette.secondary)
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Connect each listener’s headphones to their own phone.", systemImage: "headphones")
                            Label("Keep all devices on the same Wi-Fi.", systemImage: "wifi")
                            Label("In the desktop app, choose Listen together and pair each phone.", systemImage: "qrcode")
                            Label("Choose Computer on every phone. Volume and pause are independent.", systemImage: "play.fill")
                        }.font(.subheadline).padding(20).frost()
                        Text("Two headphones on this iPhone").font(.headline)
                        Text("With compatible AirPods or Beats and a supported iPhone, use Apple’s Share Audio from Control Center or the output picker. This depends on Apple’s device support.").font(.subheadline).foregroundStyle(RelayPalette.secondary)
                        HStack { Text("Choose audio output"); Spacer(); AudioRoutePicker().frame(width: 44, height: 44) }.padding(.horizontal, 18).frost()
                        Text("Everyone hears the same computer stream. Different headphones may have different delays; perfectly synchronized sound across all outputs is not guaranteed.").font(.footnote).foregroundStyle(RelayPalette.secondary)
                        Text("The computer/phone playback destination is shared by all listeners. Switching back to phones resumes only listeners who were listening; paused or Phone selections stay paused. Each phone still chooses its own headphones or speaker.").font(.footnote).foregroundStyle(RelayPalette.secondary)
                    }.padding(24)
                }
            }.navigationTitle("Listen together").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(RelayPalette.deep).foregroundStyle(RelayPalette.ink)
    }
}

struct ComputerAddressView: View {
    @ObservedObject var receiver: RelayReceiver
    @ObservedObject var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error = ""
    var body: some View {
        NavigationStack {
            ZStack {
                RelayBackdrop()
                VStack(alignment: .leading, spacing: 18) {
                    Text("Use the address shown by PairIt on your computer when discovery is unavailable or you use a USB network.").font(.subheadline).foregroundStyle(RelayPalette.secondary)
                    TextField("Automatic discovery", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).padding(14).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Computer address override")
                    Text("An empty address restores discovery. The paired identity is still checked; changing the address never trusts a different computer.").font(.footnote).foregroundStyle(RelayPalette.secondary)
                    if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red) }
                    Button("Save address") {
                        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard value.isEmpty || PairedMac.validHost(value) else { error = "Enter a local hostname or IP address without a URL or spaces."; return }
                        do { try receiver.setHostOverride(value); dismiss() }
                        catch { self.error = "Couldn’t save the address. Pair a computer first and try again." }
                    }.buttonStyle(RelayPrimaryButtonStyle()).disabled(pairing.mac == nil)
                    Spacer()
                }.padding(24)
            }.navigationTitle("Computer address").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .onAppear { address = pairing.hostOverride ?? "" }
        }.tint(RelayPalette.deep).foregroundStyle(RelayPalette.ink)
    }
}
