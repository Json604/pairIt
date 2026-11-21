import Foundation

/// Each IMA1 stereo packet stands alone. Its first stereo sample is lossless.
enum ImaAudio {
    private static let steps = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
        598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
        1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635,
        13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
    private static let increments = [-1, -1, -1, -1, 2, 4, 6, 8]

    private struct Channel {
        var predictor: Int
        var index: Int

        init(first: Int, next: Int) {
            predictor = first
            // Match the initial slope so each short capture packet starts at a usable step.
            let slope = abs(next - first)
            var lower = 0, upper = steps.count - 1
            while lower < upper {
                let middle = (lower + upper) / 2
                if steps[middle] < slope { lower = middle + 1 } else { upper = middle }
            }
            index = lower
        }

        mutating func encode(_ sample: Int) -> UInt8 {
            let step = steps[index]
            let difference = sample - predictor
            var remainder = abs(difference)
            var magnitude = 0
            var delta = step >> 3
            for bit in 0..<3 {
                let threshold = step >> bit
                if remainder >= threshold {
                    magnitude |= 4 >> bit
                    remainder -= threshold
                    delta += threshold
                }
            }
            predictor = min(32767, max(-32768, predictor + (difference < 0 ? -delta : delta)))
            index = min(88, max(0, index + increments[magnitude]))
            return UInt8(magnitude | (difference < 0 ? 8 : 0))
        }
    }

    static func encode(_ pcm: Data) -> Data {
        pcm.withUnsafeBytes { source in
            guard source.count >= 28,
                  UInt32(littleEndian: source.loadUnaligned(as: UInt32.self)) == 0x31415342 else { return pcm }
            let frames = Int(UInt32(littleEndian: source.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
            guard frames > 0, source.count == 24 + 4 * frames else { return pcm }
            func sample(_ offset: Int) -> Int {
                Int(Int16(littleEndian: source.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
            }
            var result = Data(count: 30 + frames - 1)
            result.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                target.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[..<28]))
                target.storeBytes(of: UInt32(0x314D4441).littleEndian, as: UInt32.self)
                var left = Channel(first: sample(24), next: sample(frames > 1 ? 28 : 24))
                var right = Channel(first: sample(26), next: sample(frames > 1 ? 30 : 26))
                target[28] = UInt8(left.index)
                target[29] = UInt8(right.index)
                for frame in 1..<frames {
                    let offset = 24 + frame * 4
                    target[29 + frame] = left.encode(sample(offset)) | (right.encode(sample(offset + 2)) << 4)
                }
            }
            return result
        }
    }
}

/// Cache each negotiated representation once per capture packet and gain.
struct ListenerAudio {
    let source: Data
    let volume: ComputerVolume?
    private var pcm: Data?
    private var ima: Data?

    init(_ source: Data, volume: ComputerVolume?) {
        self.source = source
        self.volume = volume
    }

    mutating func packet(compressed: Bool) -> Data {
        guard source.count > 24 else { return source }
        if pcm == nil {
            var gained = source
            volume?.apply(to: &gained)
            pcm = gained
        }
        if !compressed { return pcm! }
        if ima == nil { ima = ImaAudio.encode(pcm!) }
        return ima!
    }
}
