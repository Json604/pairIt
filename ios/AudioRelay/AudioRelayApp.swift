import SwiftUI

@main
struct AudioRelayApp: App {
    @StateObject private var receiver = RelayReceiver()
    @StateObject private var ads = BannerAds()
    var body: some Scene {
        WindowGroup { ReceiverView(receiver: receiver, pairing: receiver.pairing).environmentObject(ads).preferredColorScheme(.light) }
    }
}
