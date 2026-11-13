package dev.bluetoothswitch.relay;
import java.util.concurrent.*;
public class InvitationInteropCheck {
 public static void main(String[] args)throws Exception{
  CountDownLatch done=new CountDownLatch(1);final boolean receive=args[0].equals("receive");final String code="audiorelay://pair/"+java.util.Base64.getUrlEncoder().encodeToString(("{\"host\":\"127.0.0.1\",\"pin\":\""+"a".repeat(64)+"\",\"token\":\""+"b".repeat(64)+"\",\"name\":\"Test computer\"}").getBytes());
  ListeningInvitations invitations=new ListeningInvitations(new ListeningInvitations.UI(){
   public void confirm(String title,String comparison,java.util.function.Consumer<Boolean> answer){System.out.println("SAS "+comparison);answer.accept(true);}
   public void received(String value){if(!value.startsWith("audiorelay://pair/"))throw new AssertionError();System.out.println("RECEIVED");}
   public void finished(String text){System.out.println(text);done.countDown();}
  },Runnable::run);
  if(receive)System.out.println("PORT "+invitations.start());else invitations.invite("127.0.0.1",Integer.parseInt(args[1]),code,"Test computer");
  if(!done.await(10,TimeUnit.SECONDS))throw new AssertionError("timeout");invitations.stop();
 }
}
