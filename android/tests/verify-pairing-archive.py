#!/usr/bin/env python3
"""Run the production archive against an in-memory private-preferences adapter."""
from pathlib import Path
import tempfile, subprocess
root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as folder:
 p=Path(folder)
 (p/'SharedPreferences.java').write_text('''package android.content;
 import java.util.*;
 public interface SharedPreferences {
 String getString(String key,String fallback); Set<String> getStringSet(String key,Set<String> fallback);
 interface Editor { Editor putString(String key,String value); Editor putStringSet(String key,Set<String> value); Editor remove(String key); }
 }''')
 (p/'PairingCode.java').write_text('''package dev.bluetoothswitch.relay;
 final class PairingCode { final String host,pin,token,name,platform;
 PairingCode(String h,String p,String t,String n,String f){host=h;pin=p;token=t;name=n;platform=f;}
 static PairingCode stored(String h,String p,String t,String n,String f){return new PairingCode(h,p,t,n,f);}}
 ''')
 (p/'ArchiveCheck.java').write_text('''package dev.bluetoothswitch.relay;
 import java.util.*;import android.content.SharedPreferences;
 public class ArchiveCheck {
 static class Prefs implements SharedPreferences {
 Map<String,Object> data=new HashMap<>();
 public String getString(String k,String d){return (String)data.getOrDefault(k,d);}
 @SuppressWarnings("unchecked") public Set<String> getStringSet(String k,Set<String> d){return (Set<String>)data.getOrDefault(k,d);}
 Edit edit(){return new Edit();}
 class Edit implements SharedPreferences.Editor {
 Map<String,Object> pending=new HashMap<>();Set<String> removed=new HashSet<>();
 public Edit putString(String k,String v){pending.put(k,v);return this;}
 public Edit putStringSet(String k,Set<String> v){pending.put(k,new HashSet<>(v));return this;}
 public Edit remove(String k){removed.add(k);return this;}
 void apply(){removed.forEach(data::remove);data.putAll(pending);}
 }}
 public static void main(String[] args){
 Prefs prefs=new Prefs();PairingArchive a=new PairingArchive(prefs);
 PairingCode mac=PairingCode.stored("192.0.2.1","mac","secret1","Mac","macos");
 PairingCode linux=PairingCode.stored("192.0.2.2","linux","secret2","Linux","linux");
 Prefs.Edit edit=prefs.edit();a.save(mac,edit);if(!a.all().isEmpty())throw new AssertionError("non-atomic write");edit.apply();
 edit=prefs.edit();a.save(linux,edit);edit.apply();edit=prefs.edit();a.save(mac,edit);edit.apply();
 a=new PairingArchive(prefs);if(a.all().size()!=2||!a.get("linux").token.equals("secret2"))throw new AssertionError("lost pairing");
 edit=prefs.edit();a.remove("mac",edit);edit.apply();
 if(a.get("mac")!=null||a.all().size()!=1||!a.get("linux").host.equals("192.0.2.2"))throw new AssertionError("forget removed other computer");
 System.out.println("PASS: atomic archive writes, two computers, deduplication, reload and isolated forgetting");
 }}''')
 subprocess.run(['javac','-d',folder,*map(str,p.glob('*.java')),str(root/'android/src/dev/bluetoothswitch/relay/PairingArchive.java')],check=True)
 subprocess.run(['java','-cp',folder,'dev.bluetoothswitch.relay.ArchiveCheck'],check=True)
