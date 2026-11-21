#!/usr/bin/env python3
"""Run Android's platform-independent security checks using the installed JDK."""
from pathlib import Path
import subprocess
import tempfile

android = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="pairit-android-check-") as temporary:
    # Stub the Android clock and track. The timing estimator and network parser run unchanged.
    process_stub = Path(temporary) / "Process.java"
    process_stub.write_text("package android.os; public final class Process { public static final int THREAD_PRIORITY_AUDIO=-16; public static void setThreadPriority(int priority) {} }")
    timing_stubs = {
        "SystemClock.java": "package android.os; public class SystemClock { public static long now; public static long elapsedRealtime() { return now; } }",
        "AudioTimestamp.java": "package android.media; public class AudioTimestamp { public long framePosition, nanoTime; }",
        "AudioTrack.java": "package android.media; public class AudioTrack { public long frame; public boolean getTimestamp(AudioTimestamp t) { t.framePosition = ++frame; t.nanoTime = System.nanoTime(); return true; } public int getPlaybackRate() { return 48000; } }",
    }
    for name, source in timing_stubs.items():
        (Path(temporary) / name).write_text(source)
    subprocess.run(["javac", "-d", temporary, str(process_stub),
                    *[str(Path(temporary) / name) for name in timing_stubs],
                    str(android / "src/dev/bluetoothswitch/relay/VideoTiming.java"),
                    str(android / "tests/VideoTimingCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/ReleaseDownloadLink.java"),
                    str(android / "src/dev/bluetoothswitch/relay/RadialMotion.java"),
                    str(android / "tests/RadialMotionCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/ConnectionTone.java"),
                    str(android / "src/dev/bluetoothswitch/relay/AdTiming.java"),
                    str(android / "src/dev/bluetoothswitch/relay/ConnectionHealth.java"),
                    str(android / "tests/ConnectionHealthCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/ListeningFeedback.java"),
                    str(android / "tests/ListeningFeedbackCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/ImaStereo.java"),
                    str(android / "src/dev/bluetoothswitch/relay/PcmInbox.java"),
                    str(android / "src/dev/bluetoothswitch/relay/PlayoutTiming.java"),
                    str(android / "src/dev/bluetoothswitch/relay/PresentationTiming.java"),
                    str(android / "src/dev/bluetoothswitch/relay/BluetoothRelayBridge.java"),
                    str(android / "tests/BluetoothRelayBridgeCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/PcmGap.java"),
                    str(android / "tests/PcmGapCheck.java"),
                    str(android / "tests/ImaPacketCheck.java"),
                    str(android / "tests/HeartbeatCheck.java"),
                    str(android / "tests/PresentationWireCheck.java"),
                    str(android / "tests/ConnectionToneCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/RelayHandoff.java"),
                    str(android / "src/dev/bluetoothswitch/relay/DiscoveryRecord.java"),
                    str(android / "tests/DiscoveryRecordCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/ExplicitConnectionIntent.java"),
                    str(android / "tests/ExplicitConnectionIntentCheck.java"),
                    str(android / "tests/ReleaseDownloadLinkCheck.java"),
                    str(android / "tests/RelayHandoffCheck.java"),
                    ], check=True)
    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.VideoTimingCheck"], check=True)
    subprocess.run(["java", "-cp", temporary,
                    "dev.bluetoothswitch.relay.ReleaseDownloadLinkCheck"], check=True)
    subprocess.run(["java", "-cp", temporary,
                    "dev.bluetoothswitch.relay.RelayHandoffCheck"], check=True)

    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.DiscoveryRecordCheck"], check=True)

    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.ExplicitConnectionIntentCheck"], check=True)

    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.RadialMotionCheck"], check=True)

    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.ConnectionToneCheck"], check=True)

    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.ConnectionHealthCheck"], check=True)

    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.ListeningFeedbackCheck"], check=True)

    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.BluetoothRelayBridgeCheck"], check=True)
    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.PcmGapCheck"], check=True)
    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.ImaPacketCheck"], check=True)
    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.HeartbeatCheck"], check=True)
    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.PresentationWireCheck"], check=True)


# Standalone recovery policy also runs without Android runtime.
with tempfile.TemporaryDirectory() as out:
    subprocess.run(["javac","-d",out,str(android/"src/dev/bluetoothswitch/relay/ExternalOutputRecovery.java"),str(android/"tests/ExternalOutputRecoveryCheck.java")],check=True)
    subprocess.run(["java","-cp",out,"dev.bluetoothswitch.relay.ExternalOutputRecoveryCheck"],check=True)

with tempfile.TemporaryDirectory() as out:
    subprocess.run(["javac","-d",out,str(android/"src/dev/bluetoothswitch/relay/RelayState.java"),str(android/"src/dev/bluetoothswitch/relay/NotificationPlayback.java"),str(android/"tests/NotificationPlaybackCheck.java")],check=True)
    subprocess.run(["java","-cp",out,"dev.bluetoothswitch.relay.NotificationPlaybackCheck"],check=True)

# Route discovery is stubbed; selection and actual-route checks run unchanged.
with tempfile.TemporaryDirectory() as out:
    stub_sources = {'Build.java': 'package android.os; public class Build {public static class VERSION {public static final int SDK_INT=36;}}', 'AudioRouting.java': 'package android.media; import java.util.List; public interface AudioRouting {AudioDeviceInfo getRoutedDevice();List<AudioDeviceInfo> getRoutedDevices();}', 'AudioDeviceInfo.java': 'package android.media; public class AudioDeviceInfo {\npublic static final int TYPE_BUILTIN_SPEAKER=2,TYPE_WIRED_HEADPHONES=3,TYPE_WIRED_HEADSET=4,TYPE_USB_HEADSET=22,TYPE_USB_DEVICE=11,TYPE_BLUETOOTH_A2DP=8,TYPE_BLE_HEADSET=26,TYPE_BLE_SPEAKER=27;\nprivate final int id,type; public AudioDeviceInfo(int id,int type){this.id=id;this.type=type;} public CharSequence getProductName(){return "Test output";} public int getId(){return id;} public int getType(){return type;}}\n', 'AudioManager.java': 'package android.media; public class AudioManager {public static final int GET_DEVICES_OUTPUTS=2;public AudioDeviceInfo[] getDevices(int flags){return new AudioDeviceInfo[0];}}'}
    paths=[]
    for name, source in stub_sources.items():
        p=Path(out)/name; p.write_text(source); paths.append(str(p))
    subprocess.run(["javac","-d",out,*paths,str(android/"src/dev/bluetoothswitch/relay/OutputRoute.java"),str(android/"tests/OutputRouteCheck.java")],check=True)
    subprocess.run(["java","-cp",out,"dev.bluetoothswitch.relay.OutputRouteCheck"],check=True)

with tempfile.TemporaryDirectory() as out:
    subprocess.run(["javac","-d",out,str(android/"src/dev/bluetoothswitch/relay/PresentationTiming.java"),str(android/"tests/PresentationTimingCheck.java")],check=True)
    subprocess.run(["java","-cp",out,"dev.bluetoothswitch.relay.PresentationTimingCheck"],check=True)

with tempfile.TemporaryDirectory() as out:
    subprocess.run(["javac","-d",out,str(android/"src/dev/bluetoothswitch/relay/PhoneVolume.java"),str(android/"tests/PhoneVolumeCheck.java")],check=True)
    subprocess.run(["java","-cp",out,"dev.bluetoothswitch.relay.PhoneVolumeCheck"],check=True)
