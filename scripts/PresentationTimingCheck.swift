@main struct PresentationTimingCheck {
 static func main() {
  precondition(PresentationTiming.adaptive(platform:"linux", bluetooth:false))
  precondition(PresentationTiming.adaptive(platform:"windows", bluetooth:false))
  precondition(!PresentationTiming.adaptive(platform:"linux", bluetooth:true))
  precondition(!PresentationTiming.adaptive(platform:"mac", bluetooth:false))
  precondition(!PresentationTiming.adaptive(platform:"", bluetooth:false))
  precondition(PresentationTiming.adaptiveCushion(jitter:3, packet:10, lead:20)==43)
  precondition(PresentationTiming.adaptiveCushion(jitter:600, packet:10, lead:20)==320)
  precondition(PresentationTiming.adaptiveCushion(jitter:0, packet:10, lead:2)==40)
  precondition(PresentationTiming.correctedDelay(20, correction:0)==20)
  precondition(PresentationTiming.correctedDelay(320, correction:-10)==330)
  precondition(PresentationTiming.correctedDelay(320, correction:10)==310)
  precondition(PresentationTiming.correctedDelay(320, correction:500)==40)
  precondition(PresentationTiming.renderDelay(minimum:320,output:nil,target:0)==320)
  precondition(PresentationTiming.renderDelay(minimum:320,output:20,target:0)==320)
  precondition(PresentationTiming.renderDelay(minimum:320,output:20,target:500)+20==500)
  precondition(PresentationTiming.renderDelay(minimum:320,output:180,target:500)+180==500)
  precondition(PresentationTiming.renderDelay(minimum:320,output:nil,target:500)==320)
  precondition(PresentationTiming.renderDelay(minimum:320,output:180,target:400)==320)
  precondition(PresentationTiming.outputDelay(total:500,render:320)==180)
  precondition(PresentationTiming.outputDelay(total:250,render:320)==nil)
  precondition(PresentationTiming.rateCorrection(errorMs:40)==0.001)
  precondition(PresentationTiming.rateCorrection(errorMs:-40) == -0.001)
  precondition(PresentationTiming.rateCorrection(errorMs:0.5)==0)
  // A burst arriving at t=10 contains 100 ms of expired packets followed
  // by packets that can still play at their original 320 ms deadline.
  let burst = [9.580, 9.630, 9.675, 9.685, 9.690]
  precondition(burst.first { PresentationTiming.canAnchor(capture: $0, now: 10, cushion: 0.320) } == 9.685)
  func padding(_ sequence: UInt32, _ elapsed: Int64, after previous: UInt32 = 10) -> Int? {
    PresentationTiming.gapPadding(previous: previous, sequence: sequence, elapsedNs: elapsed,
                                  previousFrames: 480, rate: 48_000)
  }
  precondition(padding(12, 20_000_000) == 480)
  precondition(padding(1, 20_000_000, after: .max) == 480)
  precondition(padding(15, 30_000_000) == 960)
  precondition(padding(16, 30_000_000) == nil)
  precondition(padding(13, 30_020_834) == nil)
  precondition(padding(9, 20_000_000) == nil)
  precondition(padding(10, 20_000_000) == nil)
  precondition(padding(12, 1_000_000) == nil)
  print("PASS: presentation timing, mixed outputs, late join and solo fallback")
 }
}
