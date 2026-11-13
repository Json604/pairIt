package dev.bluetoothswitch.relay;
public final class ExternalOutputRecoveryCheck {
    public static void main(String[] args) {
        ExternalOutputRecovery r=new ExternalOutputRecovery();
        if(r.ready(true,true))throw new AssertionError("Unrelated attachment must not start playback");
        r.lost(true,true);
        if(!r.waiting()||r.ready(false,true)||r.ready(true,false))throw new AssertionError("Wait for external output and permission");
        if(!r.ready(true,true))throw new AssertionError("First or replacement headset can resume immediately");
        r.cancel();if(r.ready(true,true))throw new AssertionError("Manual choice cancels recovery");
        r.lost(false,true);if(r.waiting())throw new AssertionError("Phone speaker is not an external loss");
        r.lost(true,false);if(r.waiting())throw new AssertionError("Disabled auto reconnect must be respected");
        r.lost(true,true);r.cancel();r.lost(false,true);if(r.waiting())throw new AssertionError("No stale recovery");
        System.out.println("PASS: external output loss, first/replacement attachment, speaker exclusion and manual cancellation");
    }
}
