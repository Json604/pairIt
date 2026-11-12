#!/usr/bin/env python3
"""Actual Mac TLS gateway with temporary identity + synthetic source/sink only."""
from pathlib import Path
import os, hashlib, json, secrets, socket, ssl, struct, subprocess, tempfile, time

ROOT=Path(__file__).resolve().parent.parent
OUT=ROOT/os.environ.get('PAIRIT_VERIFY_OUTPUT','artifacts/feature-preview/verification');OUT.mkdir(parents=True,exist_ok=True)
binary=OUT/'feature-gateway-harness'
sources=['mac/RelayServer.swift','mac/WiFiServer.swift','mac/LocalIdentity.swift','mac/MicrophoneOutput.swift','mac/SyncOutput.swift','scripts/FeatureServerHarness.swift','scripts/FeatureGatewayHarness.swift']
subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-D','GATEWAY','-framework','CoreAudio','-framework','AVFAudio','-framework','AudioToolbox','-framework','Network','-framework','Security',*[str(ROOT/s) for s in sources],'-o',str(binary)],check=True)
checks=[]
def require(value,name):
    if not value:raise AssertionError(name)
    checks.append(name)
def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def read(s,n):
    out=b''
    while len(out)<n:
        data=s.recv(n-len(out))
        if not data:raise EOFError()
        out+=data
    return out
def line(s):
    out=b''
    while len(out)<128:
        out+=read(s,1)
        if out.endswith(b'\n'):return out
    raise AssertionError('Oversized response')
def closed(s):
    try:return s.recv(1)==b''
    except (ConnectionResetError,ssl.SSLError):return True
def wait_for(predicate,timeout=3):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if predicate():return True
        time.sleep(.01)
    return False
with tempfile.TemporaryDirectory(prefix='pairit-synthetic-identity-') as directory:
    folder=Path(directory);token=secrets.token_hex(32)
    def openssl(*args,input=None):
        subprocess.run(['/usr/bin/openssl',*args],input=input,capture_output=True,check=True)
    openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=PairIt synthetic integration','-keyout',str(folder/'key.pem'),'-out',str(folder/'cert.pem'))
    openssl('x509','-in',str(folder/'cert.pem'),'-outform','DER','-out',str(folder/'cert.der'))
    pin=hashlib.sha256((folder/'cert.der').read_bytes()).hexdigest()
    openssl('pkcs12','-export','-inkey',str(folder/'key.pem'),'-in',str(folder/'cert.pem'),'-out',str(folder/'identity.p12'),'-passout','stdin','-keypbe','PBE-SHA1-3DES','-certpbe','PBE-SHA1-3DES','-macalg','sha1',input=(token+'\n').encode())
    (folder/'identity.json').write_text(json.dumps({'token':token,'pin':pin}))
    tlsport,rawport=port(),port()
    process=subprocess.Popen([str(binary),str(tlsport),str(rawport),directory],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
    assert process.stdout.readline().strip()=='READY'
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
    # Local test identity is authenticated by exact leaf pin before sending any token.
    def connect(auth=None):
        for attempt in range(30):
            try:
                s=context.wrap_socket(socket.create_connection(('127.0.0.1',tlsport),timeout=3),server_hostname='localhost');break
            except ConnectionRefusedError:time.sleep(.1)
        require_pin=hashlib.sha256(s.getpeercert(binary_form=True)).hexdigest()==pin
        if not require_pin:s.close();raise AssertionError('Pin mismatch')
        if auth is not None:s.sendall((auth+'\n').encode())
        return s
    def command(text):
        process.stdin.write(text+'\n');process.stdin.flush();return process.stdout.readline().strip()
    def stats():return json.loads(command('stats'))
    try:
        with socket.create_connection(('127.0.0.1',rawport),timeout=2) as raw:
            raw.sendall(b'HELLO '+b'a'*32+b'\nACTIVE 1\n')
            require(closed(raw),'Loopback callers cannot bypass TLS pairing to receive audio')
        with socket.create_connection(('127.0.0.1',rawport),timeout=2) as raw:
            raw.sendall(('AUTH '+token+'\n').encode())
            require(closed(raw),'A phone pairing token is not a loopback gateway capability')
        require(stats()['sourceStarts']==0,'Unauthenticated loopback callers never start capture')
        with connect('0'*64) as s:require(closed(s),'Wrong credentials rejected before source/sink start')
        with connect(token+' MIC2') as s:require(closed(s),'Unsupported role rejected without starting source')
        require(stats()['sourceStarts']==0,'Rejected authentication never starts capture')
        with connect('0'*64+' PAIR1') as s:require(closed(s),'Pairing confirmation requires the correct token')
        require(stats()['pairings']==0,'Invalid pairing confirmation cannot produce desktop success')
        with connect(token+' PAIR1') as s:
            require(line(s)==b'OK PAIR1\n','Pairing confirmation reaches the computer before audio starts')
            require(closed(s),'Pairing confirmation ends without opening an audio session')
        require(stats()['pairings']==1 and stats()['sourceStarts']==0,'Confirmed pairing produces feedback without starting capture')
        with connect(token+' MIC1') as s:require(line(s)==b'ERR DISABLED\n','Mic requires desktop opt-in')
        command('enable');time.sleep(.05)
        with connect(token+' MIC1') as s:
            require(line(s)==b'OK MIC1 48000\n','Mic receives bounded acceptance before PCM')
            with connect(token+' MIC1') as second:require(line(second)==b'ERR BUSY\n','Second microphone cannot evict first')
            with connect(token) as receiver:require(closed(receiver),'Desktop receiver rejected during mic lease')
            payload=struct.pack('<IIII',0x314d5342,0,48000,960)+bytes(1920)
            for byte in [payload[:3],payload[3:17],payload[17:]]:s.sendall(byte)
            time.sleep(.1)
            require(stats()['micFrames']==960,'Fragmented mic frame reassembles exactly')
            s.sendall(struct.pack('<IIII',0x314d5342,1,48000,0))
            require(line(s)==b'STOPPED\n','Stop flushes sink and acknowledges')
        time.sleep(.1);require(stats()['micStops']==1,'Stop releases sink once')
        with connect(token+' MIC1') as s:
            require(line(s)==b'OK MIC1 48000\n','Explicit new session allowed after Stop')
            s.sendall(struct.pack('<IIII',0x314d5342,0,44100,960))
            require(closed(s),'Unsupported mic rate closes session')
        with connect(token+' MIC1') as s:
            require(line(s)==b'OK MIC1 48000\n','Lease recovers after malformed frame')
            command('disable');require(closed(s),'Desktop revoke closes active mic and flushes sink')
        command('bad-output');time.sleep(.05)
        with connect(token+' MIC1') as s:require(line(s)==b'ERR OUTPUT\n','Unavailable endpoint never starts mic session')
        command('enable');time.sleep(.05)
        with connect(token) as receiver:
            receiver.sendall(b'ACTIVE 1\nPING 1234567\n')
            seen_pcm=seen_clock=False
            for _ in range(20):
                h=read(receiver,24);magic,sequence,rate,frames,stamp=struct.unpack('<IIIIQ',h)
                if magic==0x31435342:seen_clock=True
                elif magic==0x31415342:read(receiver,frames*4);seen_pcm|=frames>0
                else:raise AssertionError('Framing mismatch')
                if seen_pcm and seen_clock:break
            require(seen_pcm and seen_clock,'Legacy receiver auth and PCM/clock stream work over TLS')
            with connect(token+' MIC1') as s:require(line(s)==b'ERR BUSY\n','Mic cannot disrupt active desktop receiver')
        time.sleep(.3)
        with connect(token+' MIC1') as s:
            require(line(s)==b'OK MIC1 48000\n','Mic admitted after last receiver cleanup')
            s.settimeout(4);require(closed(s),'Idle mic input expires and releases sink')
        require(wait_for(lambda:stats()['micStarts']==stats()['micStops']),'Idle mic cleanup completes before next scenario')

        command('slow-open')
        with connect(token+' MIC1') as pending:
            require(wait_for(lambda:stats()['micOpening']==1),'Synthetic endpoint enters slow setup')
            began=time.monotonic()
            with connect('0'*64) as other:responsive=closed(other)
            require(responsive and time.monotonic()-began<.35,'Slow endpoint setup does not block unrelated authentication')
            command('disable')
            require(closed(pending),'Revoked pending setup closes without an OK acknowledgement')
            command('enable')
            with connect(token+' MIC1') as other:require(line(other)==b'ERR BUSY\n','Canceled setup retains its lease until actual sink cleanup')
            with connect(token) as receiver:require(closed(receiver),'Canceled setup cannot overlap desktop capture')
        require(wait_for(lambda:stats()['micStarts']==stats()['micStops']),'Revoked setup stops its eventual endpoint')

        command('slow-open')
        pending=connect(token+' MIC1')
        require(wait_for(lambda:stats()['micOpening']==1),'Second slow setup begins')
        pending.close()
        require(wait_for(lambda:stats()['micStarts']==stats()['micStops']),'Remote EOF cancels pending setup and releases the eventual sink')

        command('slow-stop')
        with connect(token+' MIC1') as s:
            require(line(s)==b'OK MIC1 48000\n','Slow-teardown session is admitted')
            s.sendall(struct.pack('<IIII',0x314d5342,0,48000,0))
            require(wait_for(lambda:stats()['micClosing']==1),'Stop waits for synthetic sink teardown')
            began=time.monotonic()
            with connect('0'*64) as other:responsive=closed(other)
            require(responsive and time.monotonic()-began<.3,'Slow endpoint teardown does not block authentication')
            with connect(token+' MIC1') as other:require(line(other)==b'ERR BUSY\n','Mic lease remains exclusive throughout sink teardown')
            with connect(token) as receiver:require(closed(receiver),'Desktop capture remains excluded throughout sink teardown')
            require(line(s)==b'STOPPED\n','STOPPED is sent only after the sink has stopped')
            require(stats()['micClosing']==0,'Stop acknowledgement follows actual endpoint teardown')
        command('enable')
        with connect(token+' MIC1') as s:
            require(line(s)==b'OK MIC1 48000\n','A fresh mic session is admitted after slow teardown')
            time.sleep(.15)
            with connect(token+' MIC1') as other:require(line(other)==b'ERR BUSY\n','Old cleanup cannot release a newer session lease')
            s.sendall(struct.pack('<IIII',0x314d5342,0,48000,0));line(s)

        command('slow-accept')
        before=stats()['micFrames']
        with connect(token+' MIC1') as s:
            require(line(s)==b'OK MIC1 48000\n','Slow sink accepts a fresh session')
            s.sendall(struct.pack('<IIII',0x314d5342,0,48000,960)+bytes(1920))
            require(wait_for(lambda:stats()['micAccepting']==1),'Synthetic sink blocks one in-flight frame')
            began=time.monotonic()
            with connect('0'*64) as other:responsive=closed(other)
            require(responsive and time.monotonic()-began<.35,'Blocked sink scheduling leaves the TLS control queue responsive')
            s.sendall(b''.join(struct.pack('<IIII',0x314d5342,i,48000,960)+bytes(1920) for i in range(1,10)))
            command('disable');require(closed(s),'Revoke cancels a blocked sink without waiting for its audio operation')
        require(wait_for(lambda:stats()['micStarts']==stats()['micStops']),'Blocked sink finishes cleanup without admitting another stream')
        require(stats()['micFrames']-before==960 and stats()['maxMicAccepting']==1,'At most one sink operation is in flight and queued frames are discarded on revoke')

        command('timeout-open')
        with connect(token+' MIC1') as s:
            s.settimeout(5);began=time.monotonic()
            require(closed(s) and time.monotonic()-began<4.7,'A stalled setup times out without sending OK')
        require(wait_for(lambda:stats()['micStarts']==stats()['micStops']),'Timed-out setup eventually cleans up while keeping the lease')
        result=stats();require(result['micStarts']==result['micStops'],'Every admitted mic sink was stopped')
        require(result['sourceStarts']==result['sourceStops'],'Every synthetic desktop capture was stopped')
        require(command('stop')=='STOPPED','TLS gateway and source shut down cleanly');process.wait(timeout=5)
        report={'result':'passed','checks':checks,'counters':result,'not_tested':['Physical input/output','OS mic permissions','Acoustic timing','Real virtual cable']}
        (OUT/'mac-gateway.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
    finally:
        if process.poll() is None:process.terminate();process.wait(timeout=5)
