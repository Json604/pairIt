package dev.bluetoothswitch.relay;
/** Only an interrupted external-output session may auto-resume. */
final class ExternalOutputRecovery {
    private volatile boolean waiting;
    void lost(boolean external,boolean enabled){waiting=external&&enabled;}
    boolean waiting(){return waiting;}
    boolean ready(boolean externalReady,boolean permitted){return waiting&&externalReady&&permitted;}
    void cancel(){waiting=false;}
}
