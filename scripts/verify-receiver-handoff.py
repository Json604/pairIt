#!/usr/bin/env python3
"""Pinned TLS + actual iPhone transport, synthetic bytes; no audio/camera capture."""
from pathlib import Path
import hashlib, json, os, secrets, select, socket, ssl, struct, subprocess, tempfile, threading, time

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'artifacts/simple-listening/verification'
OUT.mkdir(parents=True, exist_ok=True)
binary = OUT / 'receiver-handoff-harness'
subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-framework', 'AVFAudio', '-framework', 'Network', '-framework', 'Security',
    *[str(ROOT / p) for p in ('ios/AudioRelay/RelayTransport.swift', 'ios/AudioRelay/RelaySecurity.swift', 'ios/AudioRelay/PairingStore.swift', 'ios/AudioRelay/PairingConfirmation.swift', 'scripts/ReceiverHandoffHarness.swift')], '-o', str(binary)], check=True)
reports = []
with tempfile.TemporaryDirectory(prefix='pairit-receiver-check-') as folder:
    folder = Path(folder)
    key, cert = folder / 'key.pem', folder / 'cert.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=PairIt Synthetic Receiver', '-keyout', str(key), '-out', str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    for mode in ('modern', 'legacy', 'withheld-release-ack', 'modern-output', 'legacy-output'):
        modern = not mode.startswith('legacy')
        output_case = mode.endswith('-output')
        token = secrets.token_hex(32)
        listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(1); listener.settimeout(8)
        port = listener.getsockname()[1]
        commands, errors = [], []
        def serve():
            try:
                raw, _ = listener.accept(); raw.settimeout(7)
                with context.wrap_socket(raw, server_side=True) as peer:
                    buffered = b''
                    while not buffered.endswith(b'\n'): buffered += peer.recv(1)
                    assert buffered == (token + '\n').encode()
                    buffered = b''; status = (129 if output_case else 1) if modern else 0; sequence = 0
                    while True:
                        readable, _, _ = select.select([peer], [], [], .01)
                        if readable or peer.pending():
                            chunk = peer.recv(65536)
                            if not chunk: break
                            buffered += chunk
                            while b'\n' in buffered:
                                line, buffered = buffered.split(b'\n', 1)
                                words = line.decode().split(' ')
                                if words[0] == 'PING':
                                    peer.sendall(struct.pack('<IIQQ', 0x31435342, status, int(words[1]), time.monotonic_ns()))
                                elif words[0] in ('PARK', 'RESUME', 'RELEASE'):
                                    assert modern, 'Unknown extension sent to legacy peer'
                                    intent = int(words[1]); commands.append([words[0], intent, words[2:]])
                                    status = (status & 192) | 1 | (intent << 8) | (4 if words[0] == 'PARK' else 32 if words[0] == 'RELEASE' and mode != 'withheld-release-ack' else 0)
                                elif words[0] == 'OUTPUT':
                                    assert modern and output_case, 'Unsupported output command sent'
                                    assert words[1] in ('COMPUTER', 'PHONE')
                                    commands.append(['OUTPUT', words[1]])
                                    status = (status | 64) if words[1] == 'COMPUTER' else (status & ~64)
                                elif words[0] == 'ACTIVE': commands.append(['ACTIVE', int(words[1])])
                        # Deliberately continue framed PCM after PARK, to verify
                        # receiver-side stale/backlog suppression independently.
                        peer.sendall(struct.pack('<IIIIQ', 0x31415342, sequence, 48000, 256, time.monotonic_ns()) + bytes(1024))
                        sequence += 1
            except (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError): pass
            except BaseException as error: errors.append(type(error).__name__ + ': ' + str(error))
            finally: listener.close()
        thread = threading.Thread(target=serve); thread.start()
        config = folder / 'configuration.json'
        config.write_text(json.dumps({'computer': {'host': '127.0.0.1', 'pin': pin, 'token': token, 'platform': 'mac'}, 'port': port, 'modern': modern, 'outputCase': output_case})); os.chmod(config, 0o600)
        run = subprocess.run([str(binary), str(config)], text=True, capture_output=True, timeout=9)
        thread.join(9)
        assert not thread.is_alive() and not errors, errors
        assert run.returncode == 0, run.stdout + run.stderr
        result = json.loads(run.stdout.strip().splitlines()[-1])
        if modern:
            handoffs=[c for c in commands if c[0] != 'OUTPUT']
            assert [c[0] for c in handoffs] == ['RESUME', 'PARK', 'RESUME', 'PARK', 'RELEASE'], commands
            assert [c[1] for c in handoffs] == [1, 2, 3, 4, 5], commands
            if output_case: assert [c for c in commands if c[0]=='OUTPUT'] == [['OUTPUT','COMPUTER'],['OUTPUT','PHONE'],['OUTPUT','COMPUTER'],['OUTPUT','PHONE']], commands
        else: assert all(c[0] == 'ACTIVE' for c in commands), commands
        reports.append({'mode': mode, **result, 'commands': commands, 'passed': True})
        print('PASS:', mode)
    for mode in ('resume-output','lost-output-ack','phone-reconnect','desktop-controls'):
        lost_ack=mode=='lost-output-ack'
        phone_reconnect=mode=='phone-reconnect'
        desktop_controls=mode=='desktop-controls'
        token=secrets.token_hex(32)
        listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(2);listener.settimeout(6)
        port=listener.getsockname()[1];commands=[];errors=[]
        def resume_output():
            computer_output=not lost_ack and not phone_reconnect and not desktop_controls
            try:
                for attempt in range(1 if desktop_controls else 2):
                    raw,_=listener.accept();raw.settimeout(6)
                    with context.wrap_socket(raw,server_side=True) as peer:
                        auth=b''
                        while not auth.endswith(b'\n'):auth+=peer.recv(1)
                        assert auth==(token+'\n').encode()
                        buffered=b'';status=129 | (64 if computer_output else 0);sequence=0
                        while True:
                            readable,_,_=select.select([peer],[],[],.01)
                            if readable or peer.pending():
                                chunk=peer.recv(65536)
                                if not chunk:break
                                buffered+=chunk
                                while b'\n' in buffered:
                                    line,buffered=buffered.split(b'\n',1);words=line.decode().split(' ')
                                    if words[0]=='PING':
                                        peer.sendall(struct.pack('<IIQQ',0x31435342,status,int(words[1]),time.monotonic_ns()))
                                        if desktop_controls and status>>8 in (1,2):
                                            request=(status&0xffffff00)|2|(16 if status>>8==2 else 0)
                                            peer.sendall(struct.pack('<IIQQ',0x32435342,request,0,0))
                                    elif words[0]=='OUTPUT':
                                        commands.append(words)
                                        if lost_ack and attempt==0:
                                            peer.shutdown(socket.SHUT_RDWR)
                                            break
                                        computer_output=words[1]=='COMPUTER'
                                        status=(status | 64) if computer_output else (status & ~64)
                                    elif words[0] in ('PARK','RESUME','RELEASE'):
                                        if phone_reconnect:
                                            commands.append([attempt,*words])
                                            if words[0]=='PARK' and attempt==0:
                                                peer.shutdown(socket.SHUT_RDWR);break
                                        status=(status & 192)|1|(int(words[1])<<8)|(4 if words[0]=='PARK' else 32 if words[0]=='RELEASE' else 0)
                                        if phone_reconnect and attempt==1 and words[0]=='PARK':status|=16
                            try:peer.sendall(struct.pack('<IIIIQ',0x31415342,sequence,48000,256,time.monotonic_ns())+bytes(1024))
                            except (BrokenPipeError,ConnectionResetError,ssl.SSLEOFError):break
                            sequence+=1
            except BaseException as error:errors.append(type(error).__name__+': '+str(error))
            finally:listener.close()
        thread=threading.Thread(target=resume_output);thread.start()
        config=folder/'resume.json'
        config.write_text(json.dumps({'computer':{'host':'127.0.0.1','pin':pin,'token':token},'port':port,'modern':True,'resumeCase':not lost_ack,'lostAckCase':lost_ack,'phoneReconnect':phone_reconnect,'desktopControls':desktop_controls}));os.chmod(config,0o600)
        run=subprocess.run([str(binary),str(config)],text=True,capture_output=True,timeout=7);thread.join(6)
        assert run.returncode==0 and not thread.is_alive() and not errors,(run.stdout,run.stderr,errors)
        if desktop_controls: assert not commands,commands
        elif phone_reconnect:
            assert [c[1] for c in commands if c[0]==1]==['PARK','RESUME'],commands
            assert [c for c in commands if c[0]==1][0][3:]==['PHONE'],commands
        else: assert commands==([['OUTPUT','COMPUTER'],['OUTPUT','COMPUTER']] if lost_ack else [['OUTPUT','PHONE']]),commands
        reports.append({'mode':mode,**json.loads(run.stdout),'passed':True});print('PASS:',mode)
    for mode in ('pair-confirmed', 'pair-legacy-rejected', 'pair-timeout', 'pair-wrong-pin'):
        token=secrets.token_hex(32)
        listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(1); listener.settimeout(6)
        port=listener.getsockname()[1]; received=[]; errors=[]
        def confirm_pairing():
            try:
                raw,_=listener.accept(); raw.settimeout(5)
                with context.wrap_socket(raw,server_side=True) as peer:
                    request=b''
                    while not request.endswith(b'\n'):
                        chunk=peer.recv(1)
                        if not chunk:break
                        request+=chunk
                    received.append(request)
                    if mode=='pair-wrong-pin': assert not request
                    else: assert request==(token+' PAIR1\n').encode()
                    if mode=='pair-confirmed':
                        peer.sendall(b'OK PA'); time.sleep(.02); peer.sendall(b'IR1\n')
                    elif mode=='pair-timeout':
                        assert peer.recv(1)==b''
            except ssl.SSLError:
                if mode!='pair-wrong-pin': errors.append('Unexpected TLS failure')
            except BaseException as error:errors.append(type(error).__name__+': '+str(error))
            finally:listener.close()
        thread=threading.Thread(target=confirm_pairing); thread.start()
        config=folder/'pairing.json'
        config.write_text(json.dumps({'computer':{'host':'127.0.0.1','pin':'0'*64 if mode=='pair-wrong-pin' else pin,'token':token},'port':port,'pairingProbe':True}));os.chmod(config,0o600)
        started=time.monotonic()
        run=subprocess.run([str(binary),str(config)],text=True,capture_output=True,timeout=7)
        elapsed=time.monotonic()-started;thread.join(6)
        assert run.returncode==0 and not thread.is_alive() and not errors, (run.stdout,run.stderr,errors)
        result=json.loads(run.stdout)
        assert result['confirmed']==(mode=='pair-confirmed'),result
        assert elapsed<5.5,'Pairing confirmation exceeded its bound'
        reports.append({'mode':mode,**result,'passed':True});print('PASS:',mode)
(OUT / 'ios-receiver-handoff.json').write_text(json.dumps({'kind': 'Actual iOS receiver transport and pin verification over loopback TLS', 'synthetic_pcm_only': True, 'audio_engine_used': False, 'private_test_credentials_removed': True, 'cases': reports}, indent=2) + '\n')
