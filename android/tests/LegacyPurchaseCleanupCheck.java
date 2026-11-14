package dev.bluetoothswitch.relay;

import android.content.Context;
import java.security.*;
import java.security.cert.Certificate;
import java.util.*;
import java.io.*;

public final class LegacyPurchaseCleanupCheck {
    public static final class Store extends KeyStoreSpi {
        static final Set<String> aliases = new HashSet<>(Arrays.asList("pairit.purchase", "pairing.identity", "advertising"));
        public void engineLoad(InputStream stream, char[] password) {}
        public boolean engineContainsAlias(String alias) { return aliases.contains(alias); }
        public void engineDeleteEntry(String alias) { aliases.remove(alias); }
        public Key engineGetKey(String alias, char[] password) { return null; }
        public Certificate[] engineGetCertificateChain(String alias) { return null; }
        public Certificate engineGetCertificate(String alias) { return null; }
        public Date engineGetCreationDate(String alias) { return null; }
        public void engineSetKeyEntry(String alias, Key key, char[] password, Certificate[] chain) {}
        public void engineSetKeyEntry(String alias, byte[] key, Certificate[] chain) {}
        public void engineSetCertificateEntry(String alias, Certificate cert) {}
        public Enumeration<String> engineAliases() { return Collections.enumeration(aliases); }
        public int engineSize() { return aliases.size(); }
        public boolean engineIsKeyEntry(String alias) { return aliases.contains(alias); }
        public boolean engineIsCertificateEntry(String alias) { return false; }
        public String engineGetCertificateAlias(Certificate cert) { return null; }
        public void engineStore(OutputStream stream, char[] password) {}
    }
    public static void main(String[] args) {
        Provider fake = new Provider("PairItCleanupTest", "1", "Isolated purchase cleanup test") {};
        fake.put("KeyStore.AndroidKeyStore", Store.class.getName());
        Security.addProvider(fake);
        Context context = new Context();
        LegacyPurchaseCleanup.run(context);
        LegacyPurchaseCleanup.run(context); // Upgrade cleanup is idempotent.
        if (!context.prefs.equals(Set.of("relay", "advertising"))) throw new AssertionError("Deleted unrelated preferences");
        if (!Store.aliases.equals(Set.of("pairing.identity", "advertising"))) throw new AssertionError("Deleted unrelated key");
        Security.removeProvider(fake.getName());
        LegacyPurchaseCleanup.run(context); // Missing/locked keystore must not prevent startup.
        System.out.println("PASS: purchase cleanup preserves pairing and consent; repeat and unavailable keystore are safe");
    }
}
