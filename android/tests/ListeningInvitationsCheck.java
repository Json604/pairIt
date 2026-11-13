package dev.bluetoothswitch.relay;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
public class ListeningInvitationsCheck {
 static final class UI implements ListeningInvitations.UI {
  final boolean accept; final CountDownLatch done=new CountDownLatch(1); volatile String received,comparison;
  UI(boolean accept){this.accept=accept;}
  public void confirm(String title,String code,java.util.function.Consumer<Boolean> answer){comparison=code;answer.accept(accept);}
  public void received(String code){received=code;}
  public void finished(String message){done.countDown();}
 }
 public static void main(String[] args) throws Exception {
  for(boolean accept:new boolean[]{true,false}){
   UI senderUI=new UI(true),receiverUI=new UI(accept);
   ListeningInvitations sender=new ListeningInvitations(senderUI,Runnable::run),receiver=new ListeningInvitations(receiverUI,Runnable::run);
   int port=receiver.start();if(port==0)throw new AssertionError("listener");
   sender.invite("127.0.0.1",port,"audiorelay://pair/private-test-code","Test computer");
   if(!senderUI.done.await(5,TimeUnit.SECONDS)||!receiverUI.done.await(5,TimeUnit.SECONDS))throw new AssertionError("timeout");
   if(accept&&!"audiorelay://pair/private-test-code".equals(receiverUI.received))throw new AssertionError("credentials not received");
   if(!accept&&receiverUI.received!=null)throw new AssertionError("credentials despite decline");
   if(!senderUI.comparison.equals(receiverUI.comparison))throw new AssertionError("comparison");
   sender.stop();receiver.stop();
  }
  System.out.println("Invitation accept/decline socket checks passed");
 }
}
