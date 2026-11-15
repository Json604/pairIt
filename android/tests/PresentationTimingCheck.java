package dev.bluetoothswitch.relay;
public final class PresentationTimingCheck {
 public static void main(String[] args) {
  check(PresentationTiming.correctedDelay(20,0)==20,"reset preserves learned interactive prefill");
  check(PresentationTiming.correctedDelay(320,-10)==330,"early sound delayed ten ms");
  check(PresentationTiming.correctedDelay(320,10)==310,"late sound advanced ten ms");
  check(PresentationTiming.correctedDelay(320,500)==40,"bounded network prefill");
  check(PresentationTiming.renderDelay(320, -1, 0)==320,"solo unchanged before measurement");
  check(PresentationTiming.renderDelay(320, 180, 0)==320,"solo unchanged after measurement");
  check(PresentationTiming.renderDelay(320, 20, 500)+20==500,"speaker group presentation");
  check(PresentationTiming.renderDelay(320, 180, 500)+180==500,"Bluetooth group presentation");
  check(PresentationTiming.renderDelay(320,-1,500)==320,"unmeasured output cannot apply target");
  check(PresentationTiming.renderDelay(320,180,400)==320,"late join waits for adequate group target");
  check(PresentationTiming.outputDelay(500,320)==180,"remove render cushion from OS estimate");
  check(PresentationTiming.outputDelay(250,320)==-1,"reject invalid negative output estimate");
  check(PresentationTiming.renderDelay(320,180,0)==320,"last listener leaving restores solo timing");
  check(PresentationTiming.rateCorrection(40)==0.001,"late receiver catches up at bounded rate");
  check(PresentationTiming.rateCorrection(-40)==-0.001,"early receiver slows at bounded rate");
  check(PresentationTiming.rateCorrection(.5)==0,"sub-millisecond noise does not chase drift");
  System.out.println("PASS: presentation timing, mixed outputs, late join and solo fallback");
 }
 static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
}
