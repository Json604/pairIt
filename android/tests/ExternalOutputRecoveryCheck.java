package dev.bluetoothswitch.relay;
public final class ExternalOutputRecoveryCheck {
    public static void main(String[] args) {
        ExternalOutputRecovery r=new ExternalOutputRecovery();
        if(r.ready(true,true))throw new AssertionError("Unrelated attachment must not start playback");
        r.lost(true,true);
        if(!r.waiting()||r.ready(false,true)||r.ready(true,false))throw new AssertionError("Wait for external output and permission");
        if(!r.ready(true,true))throw new AssertionError("First or replacement headset can resume immediately");
        ExternalOutputRecovery restored=new ExternalOutputRecovery();
        restored.restore("saved-pin","saved-pin",true);
        if(!restored.ready(true,true))throw new AssertionError("Recovery survives service recreation");
        restored.restore("old-pin","new-pin",true);
        if(restored.waiting())throw new AssertionError("Never resume a different computer");
        restored.restore("saved-pin","saved-pin",false);
        if(restored.waiting())throw new AssertionError("Disabled recovery stays disabled after restart");
        restored.restore("","",true);
        if(restored.waiting())throw new AssertionError("No saved intent must stay idle");
        r.cancel();if(r.ready(true,true))throw new AssertionError("Manual choice cancels recovery");
        r.lost(false,true);if(r.waiting())throw new AssertionError("Phone speaker is not an external loss");
        r.lost(true,false);if(r.waiting())throw new AssertionError("Disabled auto reconnect must be respected");
        r.lost(true,true);r.cancel();r.lost(false,true);if(r.waiting())throw new AssertionError("No stale recovery");
        System.out.println("PASS: external output loss, first/replacement attachment, speaker exclusion and manual cancellation");
    }
}
