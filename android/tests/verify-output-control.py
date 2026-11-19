#!/usr/bin/env python3
"""Exercise pairing and shared output on a disposable PairItAudit emulator.

Requires an already booted audit AVD and a Preview APK. Uses only generated TLS
credentials and silent synthetic PCM; never touches a physical device or audio.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', required=True)
parser.add_argument('--apk', type=Path, required=True)
args = parser.parse_args()
adb = shutil.which('adb') or str(Path(os.environ['ANDROID_HOME']) / 'platform-tools/adb')
package = 'dev.bluetoothswitch.relay.preview'

def run(*command, input=None):
    return subprocess.run([adb, '-s', args.serial, *command], input=input, text=True,
                          capture_output=True, check=True, timeout=45).stdout

if not args.serial.startswith('emulator-') or not run('emu', 'avd', 'name').splitlines()[0].startswith('PairItAudit'):
    parser.error('Use only a disposable emulator with an AVD name starting PairItAudit')

def wait_for(test, message, seconds=15):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if test(): return
        time.sleep(.2)
    raise AssertionError(message)

def window():
    for _ in range(4):
        result = run('shell', 'uiautomator', 'dump', '--compressed', '/sdcard/pairit-output-check.xml')
        if 'dumped to' in result:
            return ET.fromstring(run('shell', 'cat', '/sdcard/pairit-output-check.xml'))
        time.sleep(.5)
    raise AssertionError('Android accessibility hierarchy did not become idle')

def tap(label):
    nodes = [node for node in window().iter('node') if node.get('text', '').casefold() == label.casefold() and node.get('clickable') == 'true']
    if not nodes: raise AssertionError('Missing control: ' + label)
    left, top, right, bottom = map(int, re.findall(r'\d+', nodes[0].get('bounds')))
    run('shell', 'input', 'tap', str((left + right) // 2), str((top + bottom) // 2))

def visible(text):
    return any(text in node.get('text', '') for node in window().iter('node'))

run('wait-for-device')
wait_for(lambda: run('shell', 'getprop', 'sys.boot_completed').strip() == '1', 'Emulator not booted', 60)
run('install', '-r', str(args.apk.resolve()))
run('shell', 'am', 'force-stop', package)
run('shell', 'run-as', package, 'mkdir', '-p', 'shared_prefs')
run('shell', f"run-as {package} sh -c 'cat > shared_prefs/relay.xml'", input='''<map>
<string name="output">SPEAKER</string><boolean name="asked_controls_notifications" value="true"/>
</map>''')
run('shell', f"run-as {package} sh -c 'cat > shared_prefs/advertising.xml'",
    input=f'<map><long name="lastFullscreenAd" value="{int(time.time()*1000)}"/></map>')
run('logcat', '-c')

with tempfile.TemporaryDirectory(prefix='pairit-output-tls-') as directory:
    folder = Path(directory)
    key, cert = folder/'key.pem', folder/'cert.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=PairIt Synthetic Output Test', '-keyout', str(key), '-out', str(cert)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
    token = 'b' * 64  # Disposable synthetic credential, never a user's identity.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(); listener.settimeout(.2)
    port = listener.getsockname()[1]
    run('reverse', 'tcp:5002', 'tcp:' + str(port))
    stopped = threading.Event()
    state = {'computer': False, 'pairings': 0, 'acknowledge_pairing': True,
             'drop_next_output': False, 'media': 0, 'closed': 0, 'commands': [], 'errors': []}

    def peer(raw):
        media = False
        try:
            raw.settimeout(4)
            with context.wrap_socket(raw, server_side=True) as stream:
                first = b''
                while not first.endswith(b'\n') and len(first) < 128:
                    chunk = stream.recv(1)
                    if not chunk: return
                    first += chunk
                if first == (token + ' PAIR1\n').encode():
                    state['pairings'] += 1
                    stream.sendall(b'OK PAIR1\n' if state['acknowledge_pairing'] else b'ERR ROLE\n')
                    assert not stream.recv(1), 'Pair confirmation must not send audio controls'
                    return
                assert first == (token + '\n').encode(), 'Unexpected authentication role'
                media = True; state['media'] += 1
                stream.settimeout(.01)
                buffered = b''; intent = 0; held = False; released = False; sequence = 0; next_pcm = 0
                while not stopped.is_set():
                    try:
                        chunk = stream.recv(4096)
                        if not chunk: break
                        buffered += chunk
                    except socket.timeout: pass
                    while b'\n' in buffered:
                        line, buffered = buffered.split(b'\n', 1)
                        words = line.decode().split(' ')
                        if words[0] != 'STATS': state['commands'].append(words)
                        if words[0] == 'OUTPUT':
                            if words[1] == 'COMPUTER' and state['drop_next_output']:
                                state['drop_next_output'] = False
                                return  # Drop before applying or acknowledging the requested destination.
                            state['computer'] = words[1] == 'COMPUTER'
                        if words[0] in ('RESUME', 'PARK', 'RELEASE'):
                            intent = int(words[1]); held = words[0] == 'PARK'; released = words[0] == 'RELEASE'
                        if words[0] == 'PING':
                            flags = 1 | 128 | (64 if state['computer'] else 0) | (4 if held else 0) | (32 if released else 0)
                            stream.sendall(struct.pack('<IIQQ', 0x31435342, flags | intent << 8, int(words[1]), time.monotonic_ns()))
                    if time.monotonic() >= next_pcm:
                        if not state['computer'] and not held and not released:
                            stream.sendall(struct.pack('<IIIIQ', 0x31415342, sequence, 48000, 480, time.monotonic_ns()) + bytes(1920))
                            sequence += 1
                        else: stream.sendall(struct.pack('<IIIIQ', 0x31415342, 0, 48000, 0, 0))
                        next_pcm = time.monotonic() + .01
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError): pass
        except Exception as error: state['errors'].append(str(error))
        finally:
            if media: state['closed'] += 1
            raw.close()

    def serve():
        while not stopped.is_set():
            try: raw, _ = listener.accept()
            except socket.timeout: continue
            except OSError: break
            threading.Thread(target=peer, args=(raw,), daemon=True).start()

    server = threading.Thread(target=serve, daemon=True); server.start()
    try:
        payload = dict(host='127.0.0.1', pin=pin, token=token, name='Synthetic output computer', platform='windows')
        code = 'audiorelay://pair/' + base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip('=')
        run('shell', 'am', 'start', '-W', '-n', package+'/dev.bluetoothswitch.relay.MainActivity', '-a', 'android.intent.action.VIEW', '-d', code)
        time.sleep(2)
        tap('Pair computer')
        wait_for(lambda: state['pairings'] == 1, 'PAIR1 acknowledgment was not sent')
        wait_for(lambda: visible('computer confirmed the connection'), 'Confirmed pairing feedback missing')
        assert state['media'] == 0, 'Saving a pairing started media capture'
        print('PASS: PAIR1 confirms on the computer without opening a media session', flush=True)
        tap('Start audio')
        wait_for(lambda: state['media'] == 1 and any(c[0] == 'RESUME' for c in state['commands']), 'Listening connection not established')
        wait_for(lambda: visible('Play on computer'), 'Output capability control missing')
        tap('Play on computer'); tap('Play on computer')
        wait_for(lambda: state['computer'], 'OUTPUT COMPUTER was not sent')
        wait_for(lambda: visible('Playing on computer'), 'Computer-output feedback missing')
        time.sleep(5)
        assert state['media'] == 1 and state['closed'] == 0, 'Computer output disconnected the control channel'
        tap('Listen here')
        wait_for(lambda: not state['computer'], 'OUTPUT PHONE was not sent')
        wait_for(lambda: visible('Pause audio'), 'Phone playback did not return')
        assert state['media'] == 1, 'Returning to the phone opened another connection'
        print('PASS: computer/phone output changes keep the same authenticated socket', flush=True)
        state['drop_next_output'] = True
        tap('Play on computer'); tap('Play on computer')
        wait_for(lambda: state['computer'] and state['media'] == 2, 'Reconnect lost the pending Computer-output selection')
        wait_for(lambda: visible('Playing on computer'), 'Reconnected output acknowledgment missing')
        tap('Listen here')
        wait_for(lambda: not state['computer'], 'Could not return after recovered output request')
        wait_for(lambda: visible('Pause audio'), 'Phone playback did not return after reconnect')
        print('PASS: connection loss before OUTPUT acknowledgment preserves and retries the user choice', flush=True)
        tap('Pause audio')
        wait_for(lambda: any(c[:1] == ['PARK'] for c in state['commands']), 'Pause was not sent')
        resume_count = sum(c[0] == 'RESUME' for c in state['commands'])
        state['computer'] = True; time.sleep(2); state['computer'] = False; time.sleep(2)
        assert visible('Listening paused'), 'Computer output change cleared paused intent'
        assert sum(c[0] == 'RESUME' for c in state['commands']) == resume_count, 'Output switch resumed a paused receiver'
        media_session = run('shell', 'dumpsys', 'media_session').split('package=' + package, 1)[1].split('flags=', 1)[0]
        assert 'active=true' in media_session, 'Paused headphone controls were not restored after returning from computer output'
        tap('Phone'); time.sleep(1)
        state['computer'] = True; time.sleep(2); state['computer'] = False; time.sleep(2)
        assert visible('Phone audio'), 'Computer output change cleared Phone intent'
        assert sum(c[0] == 'RESUME' for c in state['commands']) == resume_count, 'Output switch resumed Phone selection'
        assert not state['errors'], state['errors']
        logs = run('logcat', '-d', '-s', 'AndroidRuntime:E', '*:S')
        assert 'FATAL EXCEPTION' not in logs, 'Android process crashed'
        print('PASS: paused and Phone selections survive desktop output changes', flush=True)
        run('shell', 'am', 'force-stop', package)
        state['acknowledge_pairing'] = False
        run('shell', 'am', 'start', '-W', '-n', package+'/dev.bluetoothswitch.relay.MainActivity', '-a', 'android.intent.action.VIEW', '-d', code)
        time.sleep(2); tap('Pair computer')
        wait_for(lambda: visible('could not confirm'), 'Legacy/offline confirmation must be reported honestly')
        preferences = run('shell', 'run-as', package, 'cat', 'shared_prefs/relay.xml')
        assert pin in preferences and token in preferences, 'Unconfirmed pairing must remain saved'
        assert state['pairings'] == 2 and state['media'] == 2, 'Unconfirmed pairing started audio'
        print('PASS: unsupported pairing confirmation preserves saved credentials without starting audio', flush=True)
    finally:
        run('shell', 'am', 'force-stop', package)
        run('reverse', '--remove', 'tcp:5002')
        stopped.set(); listener.close(); server.join(2)
