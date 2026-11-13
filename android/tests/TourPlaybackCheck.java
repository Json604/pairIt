package dev.bluetoothswitch.relay;
public final class TourPlaybackCheck {
    private static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
    public static void main(String[] args){
        TourPlayback tour=new TourPlayback();
        for(int i=0;i<100;i++)tour.tick(100,false);
        require(tour.step==0&&tour.elapsed==0,"Background does not advance");
        tour.playing=false;for(int i=0;i<100;i++)tour.tick(100,true);
        require(tour.elapsed==0,"Pause preserves progress");
        tour.playing=true;for(int i=0;i<90;i++)tour.tick(100,true);
        require(tour.step==1&&tour.elapsed==0,"Autoplay advances after nine seconds");
        tour.select(3);for(int i=0;i<100;i++)tour.tick(100,true);
        require(tour.step==3&&!tour.playing&&tour.progress()==1,"Last step stops without closing");
        tour.select(-1);require(tour.step==0&&tour.elapsed==0,"Swiping before first remains bounded");
        tour.select(99);require(tour.step==3,"Swiping beyond last remains bounded");
        System.out.println("PASS: autoplay, pause, background, final-step hold and bounded navigation");
    }
}
