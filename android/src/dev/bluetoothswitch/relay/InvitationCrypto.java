package dev.bluetoothswitch.relay;

import java.security.*;
import java.security.interfaces.ECPublicKey;
import java.security.spec.*;
import java.math.BigInteger;
import java.util.Arrays;
import javax.crypto.*;
import javax.crypto.spec.*;
import java.nio.charset.StandardCharsets;

/** Ephemeral P-256 ECDH + AES-GCM. A human compares the transcript before credentials are sent. */
final class InvitationCrypto {
    private static final byte[] CONTEXT="PairIt invitation v1".getBytes(StandardCharsets.US_ASCII);
    private final KeyPair pair;
    private byte[] key;
    InvitationCrypto() throws GeneralSecurityException {
        KeyPairGenerator generator=KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1"));pair=generator.generateKeyPair();
    }
    byte[] publicKey(){
        ECPublicKey pub=(ECPublicKey)pair.getPublic();byte[] result=new byte[65];result[0]=4;
        coordinate(pub.getW().getAffineX(),result,1);coordinate(pub.getW().getAffineY(),result,33);return result;
    }
    private static void coordinate(BigInteger value,byte[] result,int offset){byte[] raw=value.toByteArray();int length=Math.min(raw.length,32);System.arraycopy(raw,raw.length-length,result,offset+32-length,length);}
    void agree(byte[] remote,boolean sender) throws GeneralSecurityException {
        if(remote.length!=65||remote[0]!=4)throw new GeneralSecurityException("Invalid public key");
        ECParameterSpec params=((ECPublicKey)pair.getPublic()).getParams();
        ECPoint point=new ECPoint(new BigInteger(1,Arrays.copyOfRange(remote,1,33)),new BigInteger(1,Arrays.copyOfRange(remote,33,65)));
        PublicKey pub=KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(point,params));
        KeyAgreement agreement=KeyAgreement.getInstance("ECDH");agreement.init(pair.getPrivate());agreement.doPhase(pub,true);
        MessageDigest digest=MessageDigest.getInstance("SHA-256");digest.update(agreement.generateSecret());
        digest.update(sender?publicKey():remote);digest.update(sender?remote:publicKey());key=digest.digest(CONTEXT);
    }
    String comparison() throws GeneralSecurityException {
        MessageDigest digest=MessageDigest.getInstance("SHA-256");digest.update(key);
        return hex(digest.digest("compare".getBytes(StandardCharsets.US_ASCII))).substring(0,16).toUpperCase(java.util.Locale.ROOT).replaceAll("(.{4})(?!$)","$1 ");
    }
    byte[] seal(byte[] plain) throws GeneralSecurityException {
        byte[] nonce=new byte[12];new SecureRandom().nextBytes(nonce);
        Cipher cipher=cipher(Cipher.ENCRYPT_MODE,nonce);byte[] encrypted=cipher.doFinal(plain);
        byte[] result=Arrays.copyOf(nonce,12+encrypted.length);System.arraycopy(encrypted,0,result,12,encrypted.length);return result;
    }
    byte[] open(byte[] sealed) throws GeneralSecurityException {
        if(sealed.length<28||sealed.length>8192)throw new GeneralSecurityException("Invalid ciphertext");
        return cipher(Cipher.DECRYPT_MODE,Arrays.copyOf(sealed,12)).doFinal(sealed,12,sealed.length-12);
    }
    private Cipher cipher(int mode,byte[] nonce) throws GeneralSecurityException {
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(mode,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,nonce));cipher.updateAAD(CONTEXT);return cipher;
    }
    static String hex(byte[] bytes){StringBuilder result=new StringBuilder();for(byte b:bytes)result.append(String.format(java.util.Locale.ROOT,"%02x",b&255));return result.toString();}
    static byte[] unhex(String value) throws GeneralSecurityException {
        if(value.length()>16384||value.length()%2!=0||!value.matches("[a-f0-9]+"))throw new GeneralSecurityException("Invalid encoding");
        byte[] bytes=new byte[value.length()/2];for(int i=0;i<bytes.length;i++)bytes[i]=(byte)Integer.parseInt(value.substring(i*2,i*2+2),16);return bytes;
    }
}
