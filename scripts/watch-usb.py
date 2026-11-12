#!/usr/bin/env python3
"""Restore the development-only audio tunnel after USB reconnects. Exits after 15 min."""
import subprocess
import time

deadline = time.monotonic() + 900
previous = None
while time.monotonic() < deadline:
    try:
        result = subprocess.run(['adb', 'reverse', '--list'], capture_output=True, text=True, timeout=5)
        state = 'connected' if result.returncode == 0 else 'disconnected'
        if state != previous:
            print(f'USB {state}', flush=True)
        if result.returncode == 0 and 'tcp:5001 tcp:5001' not in result.stdout:
            restored = subprocess.run(['adb', 'reverse', 'tcp:5001', 'tcp:5001'], capture_output=True, text=True, timeout=5)
            print('Restored audio tunnel' if restored.returncode == 0 else 'Tunnel restoration failed', flush=True)
        previous = state
    except subprocess.TimeoutExpired:
        pass
    time.sleep(2)
