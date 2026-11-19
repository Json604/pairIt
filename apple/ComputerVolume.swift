import Foundation

/// Computer stream gain is separate from each listener's hardware volume.
struct ComputerVolume: Equatable {
    let level: Double
    let muted: Bool
    /// Sent only to phones that advertise STATS VOLUME2: the computer does not attenuate
    /// their audio; its volume keys move the phone's own volume instead.
    let phoneOwned: Bool
    init(level: Double, muted: Bool, phoneOwned: Bool = false) {
        self.level = level.isFinite ? min(1, max(0, level)) : 1; self.muted = muted; self.phoneOwned = phoneOwned
    }
    init?(wireValue: UInt32) {
        guard wireValue & ~UInt32(0x303FF) == 0, wireValue & 0x3FF <= 1000 else { return nil }
        self.init(level: Double(wireValue & 0x3FF) / 1000, muted: wireValue & 0x10000 != 0, phoneOwned: wireValue & 0x20000 != 0)
    }
    var wireValue: UInt32 { UInt32((level * 1000).rounded()) | (muted ? 0x10000 : 0) }
    var description: String { muted ? "Computer muted" : phoneOwned ? "Computer volume keys linked" : "Computer volume · \(Int((level * 100).rounded()))%" }
    func apply(to packet: inout Data) {
        let gain = muted ? 0 : level
        guard gain < 1, packet.count >= 24, (packet.count - 24) % 2 == 0 else { return }
        packet.withUnsafeMutableBytes { raw in
            for offset in stride(from: 24, to: raw.count, by: 2) {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                raw.storeBytes(of: Int16(Double(sample) * gain).littleEndian, toByteOffset: offset, as: Int16.self)
            }
        }
    }
}
