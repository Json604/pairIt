package dev.bluetoothswitch.relay;
public final class ListeningFeedbackCheck {
    public static void main(String[] args) {
        ListeningFeedback feedback=new ListeningFeedback();
        if(feedback.disconnected())throw new AssertionError("No disconnect cue for failed start");
        feedback.audioStarted();feedback.audioStarted();
        if(!feedback.established()||!feedback.disconnected()||feedback.disconnected())throw new AssertionError("One disconnect per established session");
        feedback.audioStarted();if(!feedback.disconnected())throw new AssertionError("Reconnect starts a new session");
        double difference=0;
        for(int i=0;i<48000;i++){
            double t=i/48000.0,v=ConnectionTone.disconnectSample(t);
            if(!Double.isFinite(v)||Math.abs(v)>.08)throw new AssertionError("Disconnect cue level");
            difference+=Math.abs(v-ConnectionTone.sample(t));
        }
        if(difference<1||ConnectionTone.disconnectSample(0)!=0||ConnectionTone.disconnectSample(.9)!=0)throw new AssertionError("Distinct bounded cue");
        if(ConnectionHealth.expired(20000,19500,true,false))throw new AssertionError("Silent but heartbeating computer is connected");
        System.out.println("Listening-only feedback, distinct cues and silent heartbeat checks passed");
    }
}
