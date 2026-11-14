#!/usr/bin/env python3
"""Exercise the retired-purchase migration against isolated fake stores, never user data."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='pairit-cleanup-check-') as directory:
    out = Path(directory)
    context = out / 'Context.java'
    context.write_text('''package android.content;
import java.util.*;
public class Context {
 public final Set<String> prefs = new HashSet<>(Arrays.asList("pairit_pro", "relay", "advertising"));
 public boolean deleteSharedPreferences(String name) { return prefs.remove(name); }
}''')
    subprocess.run(['javac', '-d', directory, str(context),
        str(root/'android/src/dev/bluetoothswitch/relay/LegacyPurchaseCleanup.java'),
        str(root/'android/tests/LegacyPurchaseCleanupCheck.java')], check=True)
    subprocess.run(['java', '-cp', directory, 'dev.bluetoothswitch.relay.LegacyPurchaseCleanupCheck'], check=True)
    fake = out/'FakeSecurity.swift'
    fake.write_text('''@_exported import Foundation
public let kSecClass = "class"
public let kSecClassGenericPassword = "generic-password"
public let kSecAttrService = "service"
public let kSecAttrAccount = "account"
public var queries: [[String: Any]] = []
@discardableResult public func SecItemDelete(_ query: CFDictionary) -> Int32 {
 queries.append(query as NSDictionary as! [String: Any]); return 0
}
''')
    subprocess.run(['swiftc', '-emit-module', '-emit-library', '-module-name', 'FakeSecurity',
                    str(fake), '-o', str(out/'libFakeSecurity.dylib')], check=True)
    # Replace only the Security import: execute the production query construction unchanged.
    migration = out/'LegacyPurchaseCleanup.swift'
    migration.write_text((root/'ios/AudioRelay/LegacyPurchaseCleanup.swift').read_text().replace('import Security', 'import FakeSecurity'))
    check = out/'CleanupCheck.swift'
    check.write_text('''import FakeSecurity
@main struct CleanupCheck {
 static func main() {
  LegacyPurchaseCleanup.run(); LegacyPurchaseCleanup.run()
  precondition(queries.count == 4)
  for (index, query) in queries.enumerated() {
   precondition(query.count == 3)
   precondition(query[kSecClass] as? String == kSecClassGenericPassword)
   precondition(query[kSecAttrService] as? String == "dev.bluetoothswitch.pro")
   precondition(query[kSecAttrAccount] as? String == (index % 2 == 0 ? "purchase" : "checkout"))
  }
  print("PASS: iOS cleanup scopes every deletion to the retired service and two purchase accounts")
 }
}''')
    binary = out/'cleanup-check'
    subprocess.run(['swiftc', '-I', directory, '-L', directory, '-lFakeSecurity',
                    str(migration), str(check), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
