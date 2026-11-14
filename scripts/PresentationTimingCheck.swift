@main struct PresentationTimingCheck {
 static func main() {
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
  print("PASS: presentation timing, mixed outputs, late join and solo fallback")
 }
}
