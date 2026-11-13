#!/usr/bin/env python3
"""Run Android's platform-independent security checks using the installed JDK."""
from pathlib import Path
import subprocess
import tempfile

android = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="pairit-android-check-") as temporary:
    # Only the platform scheduling hook is stubbed; the network parser runs unchanged.
    process_stub = Path(temporary) / "Process.java"
    process_stub.write_text("package android.os; public final class Process { public static final int THREAD_PRIORITY_AUDIO=-16; public static void setThreadPriority(int priority) {} }")
    subprocess.run(["javac", "-d", temporary, str(process_stub),
                    str(android / "src/dev/bluetoothswitch/relay/ReleaseDownloadLink.java"),
                    str(android / "src/dev/bluetoothswitch/relay/RadialMotion.java"),
                    str(android / "tests/RadialMotionCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/ConnectionTone.java"),
                    str(android / "src/dev/bluetoothswitch/relay/AdTiming.java"),
                    str(android / "src/dev/bluetoothswitch/relay/ConnectionHealth.java"),
                    str(android / "tests/ConnectionHealthCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/ListeningFeedback.java"),
                    str(android / "tests/ListeningFeedbackCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/PcmInbox.java"),
                    str(android / "tests/HeartbeatCheck.java"),
                    str(android / "tests/ConnectionToneCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/RelayHandoff.java"),
                    str(android / "src/dev/bluetoothswitch/relay/DiscoveryRecord.java"),
                    str(android / "tests/DiscoveryRecordCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/ExplicitConnectionIntent.java"),
                    str(android / "tests/ExplicitConnectionIntentCheck.java"),
                    str(android / "tests/ReleaseDownloadLinkCheck.java"),
                    str(android / "tests/RelayHandoffCheck.java"),
                    str(android / "src/dev/bluetoothswitch/relay/TourPlayback.java"),
                    str(android / "tests/TourPlaybackCheck.java")], check=True)
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

    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.HeartbeatCheck"], check=True)

    subprocess.run(["java", "-cp", temporary, "dev.bluetoothswitch.relay.TourPlaybackCheck"], check=True)

# Standalone recovery policy also runs without Android runtime.
with tempfile.TemporaryDirectory() as out:
    subprocess.run(["javac","-d",out,str(android/"src/dev/bluetoothswitch/relay/ExternalOutputRecovery.java"),str(android/"tests/ExternalOutputRecoveryCheck.java")],check=True)
    subprocess.run(["java","-cp",out,"dev.bluetoothswitch.relay.ExternalOutputRecoveryCheck"],check=True)
