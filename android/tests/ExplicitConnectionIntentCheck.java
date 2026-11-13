package dev.bluetoothswitch.relay;
public final class ExplicitConnectionIntentCheck {
    static void check(boolean value){if(!value)throw new AssertionError("Stale explicit audio intent");}
    public static void main(String[] args){
        ExplicitConnectionIntent intent=new ExplicitConnectionIntent();
        intent.begin(1);intent.paused(false);check(!intent.matches(1));check(!intent.consume(1,true,true));
        intent.begin(2);intent.paused(true);check(intent.matches(2));check(!intent.consume(2,false,false));check(intent.consume(2,true,true));check(!intent.consume(2,true,true));
        intent.begin(3);intent.begin(4);check(!intent.matches(3));intent.cancel();check(!intent.consume(4,true,true));
        System.out.println("Explicit connect background, ad-resume, cancellation and replay checks passed");
    }
}
