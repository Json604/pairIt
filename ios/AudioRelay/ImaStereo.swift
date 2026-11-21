import Foundation

enum ImaStereo {
    private static let indexChange = [-1, -1, -1, -1, 2, 4, 6, 8]
    private static let steps = [
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,
        88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,
        598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,
        2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,
        11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767
    ]

    static func decode(_ encoded: Data, frames: Int) -> Data? {
        guard frames > 0, encoded.count == frames + 5, Int(encoded[4]) < steps.count, Int(encoded[5]) < steps.count else { return nil }
        var pcm = Data(repeating: 0, count: frames * 4)
        pcm[0] = encoded[0]; pcm[1] = encoded[1]; pcm[2] = encoded[2]; pcm[3] = encoded[3]
        for channel in 0..<2 {
            var predictor = Int(Int16(bitPattern: UInt16(encoded[channel * 2]) | UInt16(encoded[channel * 2 + 1]) << 8))
            var index = Int(encoded[4 + channel])
            for frame in 1..<frames {
                let code = Int((encoded[5 + frame] >> (channel * 4)) & 15), step = steps[index]
                var delta = step >> 3
                if code & 1 != 0 { delta += step >> 2 }
                if code & 2 != 0 { delta += step >> 1 }
                if code & 4 != 0 { delta += step }
                predictor = max(-32768, min(32767, predictor + (code & 8 == 0 ? delta : -delta)))
                index = max(0, min(steps.count - 1, index + indexChange[code & 7]))
                let offset = frame * 4 + channel * 2, sample = UInt16(bitPattern: Int16(predictor))
                pcm[offset] = UInt8(truncatingIfNeeded: sample); pcm[offset + 1] = UInt8(truncatingIfNeeded: sample >> 8)
            }
        }
        return pcm
    }
}
