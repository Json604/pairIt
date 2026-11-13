package dev.bluetoothswitch.relay;
import java.util.Arrays;
public class InvitationCryptoCheck {
 public static void main(String[] args) throws Exception {
  InvitationCrypto sender=new InvitationCrypto(), receiver=new InvitationCrypto();
  sender.agree(receiver.publicKey(),true); receiver.agree(sender.publicKey(),false);
  if(!sender.comparison().equals(receiver.comparison()))throw new AssertionError("comparison mismatch");
  byte[] message="private pairing credentials".getBytes(java.nio.charset.StandardCharsets.UTF_8);
  byte[] sealed=sender.seal(message);
  if(!Arrays.equals(message,receiver.open(sealed)))throw new AssertionError("decrypt");
  sealed[sealed.length-1]^=1;
  try { receiver.open(sealed); throw new AssertionError("accepted tampering"); } catch(java.security.GeneralSecurityException expected){}
  try { new InvitationCrypto().agree(new byte[65],true); throw new AssertionError("invalid point"); } catch(java.security.GeneralSecurityException expected){}
  System.out.println("Invitation crypto checks passed");
 }
}
