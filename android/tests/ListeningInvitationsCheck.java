package dev.bluetoothswitch.relay;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
public class ListeningInvitationsCheck {
 static final class UI implements ListeningInvitations.UI {
  volatile boolean hostReady=true;
  public boolean canHost(){return hostReady;}
  final boolean accept; final CountDownLatch done=new CountDownLatch(1); volatile String received,comparison,title;
  UI(boolean accept){this.accept=accept;}
  public void confirm(String title,String code,java.util.function.Consumer<Boolean> answer){this.title=title;comparison=code;answer.accept(accept);}
  public void received(String code){received=code;}
  public void finished(String message){done.countDown();}
 }
 public static void main(String[] args) throws Exception {
  if(ListeningInvitations.hostProblem(false,true,true).isEmpty())throw new AssertionError("Disconnected host allowed");
  if(!ListeningInvitations.hostProblem(true,true,true).isEmpty())throw new AssertionError("Ready speaker host rejected");
  if(ListeningInvitations.hostProblem(true,false,true).isEmpty())throw new AssertionError("Computer-output host allowed");
  for(boolean accept:new boolean[]{true,false}){
   UI senderUI=new UI(true),receiverUI=new UI(accept);
   ListeningInvitations sender=new ListeningInvitations(senderUI,Runnable::run),receiver=new ListeningInvitations(receiverUI,Runnable::run);
   int port=receiver.start();if(port==0)throw new AssertionError("listener");
   sender.invite("127.0.0.1",port,"audiorelay://pair/private-test-code","Test computer");
   if(!senderUI.done.await(5,TimeUnit.SECONDS)||!receiverUI.done.await(5,TimeUnit.SECONDS))throw new AssertionError("timeout");
   if(accept&&!"audiorelay://pair/private-test-code".equals(receiverUI.received))throw new AssertionError("credentials not received");
   if(!accept&&receiverUI.received!=null)throw new AssertionError("credentials despite decline");
   if(!senderUI.comparison.equals(receiverUI.comparison))throw new AssertionError("comparison");
   if(!senderUI.title.startsWith("Host")||!receiverUI.title.startsWith("Join"))throw new AssertionError("Missing role prompts");
   sender.stop();receiver.stop();
  }
  UI senderUI=new UI(true),receiverUI=new UI(true);senderUI.hostReady=false;
  ListeningInvitations sender=new ListeningInvitations(senderUI,Runnable::run),receiver=new ListeningInvitations(receiverUI,Runnable::run);
  sender.invite("127.0.0.1",receiver.start(),"audiorelay://pair/private-test-code","Test computer");
  if(!senderUI.done.await(5,TimeUnit.SECONDS)||!receiverUI.done.await(5,TimeUnit.SECONDS))throw new AssertionError("Disconnected host timeout");
  if(receiverUI.received!=null)throw new AssertionError("Disconnected host shared credentials");
  sender.stop();receiver.stop();
  System.out.println("Invitation accept/decline socket checks passed");
 }
}
