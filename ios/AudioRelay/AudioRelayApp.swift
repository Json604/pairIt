import SwiftUI

@main
struct AudioRelayApp: App {
    init() { LegacyPurchaseCleanup.run() }
    @ObservedObject private var receiver = RelayReceiver.shared
    @StateObject private var ads = BannerAds()
    var body: some Scene {
        WindowGroup { ReceiverView(receiver: receiver, pairing: receiver.pairing).environmentObject(ads).preferredColorScheme(.dark) }
    }
}
