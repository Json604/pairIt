#!/usr/bin/env python3
"""Live capture probe, not a unit test. Examines PCM in memory; saves no audio."""
import argparse
import math
import socket
import struct
import time

parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=float, default=15)
args = parser.parse_args()

def read_exact(connection, count):
    result = bytearray()
    while len(result) < count:
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise EOFError('Sender closed connection')
        result.extend(chunk)
    return result

with socket.create_connection(('127.0.0.1', 5001), timeout=30) as connection:
    connection.settimeout(30)
    start = time.monotonic()
    frames_total = gaps = packets = nonzero = 0
    previous = None
    peak = 0
    while time.monotonic() - start < args.seconds:
        magic, sequence, rate, frames, capture_ns = struct.unpack('<IIIIQ', read_exact(connection, 24))
        if magic != 0x31415342 or rate not in (44100, 48000) or not 0 < frames <= 8192:
            raise ValueError('Invalid live stream header')
        pcm = read_exact(connection, frames * 4)
        samples = struct.unpack('<' + 'h' * (frames * 2), pcm)
        block_peak = max(map(abs, samples))
        peak = max(peak, block_peak)
        nonzero += block_peak > 0
        if previous is not None:
            gaps += max(0, sequence - previous - 1)
        previous = sequence
        frames_total += frames
        packets += 1
    print(f'LIVE CAPTURE: packets={packets} frames={frames_total} rate={rate} gaps={gaps} nonzero_packets={nonzero} peak_dBFS={20 * math.log10(max(peak, 1) / 32768):.1f}', flush=True)
    if nonzero == 0:
        raise SystemExit('No audible signal captured. Play a source and verify System Audio Recording permission.')
