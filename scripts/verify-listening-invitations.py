#!/usr/bin/env python3
"""Exercise production invitation crypto/transport, including Java/Swift interoperability."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
out = root / 'artifacts/invitation-tests'
out.mkdir(parents=True, exist_ok=True)
def run(*args):
    subprocess.run(list(map(str,args)), cwd=root, check=True)
java_sources = ['InvitationCrypto', 'ListeningInvitations']
checks = ['InvitationCryptoCheck', 'ListeningInvitationsCheck', 'InvitationInteropCheck']
run('javac', '-d', out, *[root/f'android/src/dev/bluetoothswitch/relay/{name}.java' for name in java_sources], *[root/f'android/tests/{name}.java' for name in checks])
java = ['java', '-cp', str(out)]
for check in checks[:2]:
    run(*java, 'dev.bluetoothswitch.relay.'+check)
if sys.platform != 'darwin':
    print('Java checks passed; cross-platform checks require macOS CryptoKit.')
    raise SystemExit(0)
run('swiftc', 'ios/AudioRelay/InvitationCrypto.swift', 'ios/tests/InvitationCryptoCheck.swift', '-o', out/'swift-crypto')
run(out/'swift-crypto')
run('swiftc', *[f'ios/AudioRelay/{name}.swift' for name in ['InvitationCrypto','ListeningInvitations','NearbyDevices','PairingStore']], 'ios/tests/InvitationInteropCheck.swift', '-o', out/'swift-interop')
java += ['dev.bluetoothswitch.relay.InvitationInteropCheck']
swift = [str(out/'swift-interop')]
for sender,receiver in [(java,swift),(swift,java)]:
    server=subprocess.Popen(receiver+['receive'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,cwd=root)
    try:
        line=server.stdout.readline().strip()
        assert line.startswith('PORT '),line
        client=subprocess.run(sender+['send',line.split()[1]],capture_output=True,text=True,timeout=15,cwd=root)
        output,error=server.communicate(timeout=15)
        assert client.returncode==0 and server.returncode==0,(client.stderr,error)
        assert 'RECEIVED' in output and 'Invitation accepted.' in client.stdout,(output,client.stdout)
        sas=lambda text:next(x for x in text.splitlines() if x.startswith('SAS '))
        assert sas(output)==sas(client.stdout),'Comparison codes do not match'
    finally:
        if server.poll() is None: server.kill();server.wait()
print('Invitations passed: encryption, tamper rejection, invalid keys, accept/decline, Android/iOS both directions.')
