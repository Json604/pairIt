#!/usr/bin/env python3
"""Historical TLS lab bridge for a standalone raw test source on port 5001.

This cannot connect to the production Mac backend, which authenticates its own
in-process gateway. Use normal pairing with the companion for product testing.
"""
from pathlib import Path
import hmac
import json
import select
import socket
import ssl
import datetime
import struct
import time

folder = Path(__file__).resolve().parent.parent / 'artifacts' / 'wifi'
config = json.loads((folder / 'config.json').read_text())
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(folder / 'server.pem', folder / 'server.key')

with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((config['host'], 5002))
    listener.listen(4)
    print(f'Wi-Fi TLS ready on {config["host"]}:5002', flush=True)
    while True:
        raw, address = listener.accept()
        raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        raw.settimeout(3)
        try:
            with context.wrap_socket(raw, server_side=True) as client:
                supplied = bytearray()
                while len(supplied) < 65:
                    part = client.recv(1)
                    if not part or part == b'\n': break
                    supplied.extend(part)
                if not hmac.compare_digest(bytes(supplied), config['token'].encode()):
                    print('Rejected unauthenticated client', flush=True)
                    continue
                with socket.create_connection(('127.0.0.1', 5001), timeout=5) as upstream:
                    upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    print('Authenticated phone connected; forwarding local PCM', flush=True)
                    telemetry_buffer = bytearray()
                    packet_buffer = bytearray()
                    previous_packet = None
                    while True:
                        ready, _, _ = select.select([upstream, client], [], [], 5)
                        if client in ready:
                            incoming = client.recv(4096)
                            if not incoming: break
                            telemetry_buffer.extend(incoming)
                            if len(telemetry_buffer) > 8192: raise ValueError('Oversized diagnostic message')
                            while b'\n' in telemetry_buffer:
                                line, _, remainder = telemetry_buffer.partition(b'\n')
                                telemetry_buffer = bytearray(remainder)
                                if not line.startswith(b'STATS '): raise ValueError('Unknown diagnostic message')
                                with (folder / 'telemetry.log').open('a') as log:
                                    log.write(datetime.datetime.now().isoformat() + ' ' + line.decode('utf-8', errors='replace') + '\n')
                        if upstream in ready:
                            data = upstream.recv(4096)
                            if not data: break
                            packet_buffer.extend(data)
                            while len(packet_buffer) >= 24:
                                magic, sequence, rate, frames, captured = struct.unpack_from('<IIIIQ', packet_buffer)
                                if magic != 0x31415342 or not 0 < frames <= 8192: raise ValueError('Invalid sender packet')
                                length = 24 + frames * 4
                                if len(packet_buffer) < length: break
                                now = time.monotonic_ns()
                                if previous_packet and now - previous_packet[0] > 100_000_000:
                                    with (folder / 'telemetry.log').open('a') as log:
                                        log.write(f'{datetime.datetime.now().isoformat()} SOURCE_GAP wall_ms={(now-previous_packet[0])/1e6:.1f} capture_ms={(captured-previous_packet[1])/1e6:.1f}\n')
                                previous_packet = now, captured
                                del packet_buffer[:length]
                            client.sendall(data)
                print('Phone stream closed', flush=True)
        except (OSError, ValueError) as error:
            print(f'Connection ended: {type(error).__name__}: {error}', flush=True)
        finally:
            raw.close()
