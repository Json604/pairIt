#!/usr/bin/env python3
"""Exercise the real Mac fanout with synthetic PCM; no hardware audio or unit tests."""
from pathlib import Path
import json, os, socket, struct, subprocess, threading, time

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / os.environ.get('PAIRIT_VERIFY_OUTPUT', 'artifacts/feature-preview/verification')
OUT.mkdir(parents=True, exist_ok=True)
binary = OUT / 'feature-server-harness'
subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-framework','CoreAudio',
                str(ROOT/'mac/RelayServer.swift'),str(ROOT/'scripts/FeatureServerHarness.swift'),'-o',str(binary)],check=True)
with socket.socket() as reserve:
    reserve.bind(('127.0.0.1',0)); port=reserve.getsockname()[1]
process=subprocess.Popen([str(binary),str(port)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
assert process.stdout.readline().strip()=='READY'
checks=[]
def command(text):
    process.stdin.write(text+'\n');process.stdin.flush();return process.stdout.readline().strip()
def require(value,name):
    if not value: raise AssertionError(name)
    checks.append(name)
def wait_for(predicate,timeout=3):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if predicate():return True
        time.sleep(.01)
    return False
class Client:
    def __init__(self,number,read=True):
        self.socket=socket.create_connection(('127.0.0.1',port),timeout=2)
        self.socket.settimeout(3);self.packets={};self.clocks=0;self.status=0;self.error=None;self.running=True
        self.send('HELLO '+format(number,'032x')+'\nACTIVE 1\n')
        if read:
            self.reader=threading.Thread(target=self.run,daemon=True);self.reader.start()
        self.pinger=threading.Thread(target=self.ping,daemon=True);self.pinger.start()
    def send(self,text): self.socket.sendall(text.encode())
    def ping(self):
        while self.running:
            try:self.send(f'PING {time.monotonic_ns()}\n')
            except OSError:return
            time.sleep(.2)
    def read(self,n):
        data=b''
        while len(data)<n:
            part=self.socket.recv(n-len(data))
            if not part:raise EOFError()
            data+=part
        return data
    def run(self):
        try:
            while self.running:
                header=self.read(24);magic,seq,rate,frames,stamp=struct.unpack('<IIIIQ',header)
                if magic==0x31435342:self.clocks+=1;self.status=seq;continue
                assert magic==0x31415342 and rate in(44100,48000) and frames<=8192
                if frames:
                    pcm=self.read(frames*4);self.packets[seq]=(stamp,len(pcm))
        except (OSError,EOFError) as e:self.error=type(e).__name__
        except Exception as e:self.error=str(e)
    def close(self):
        self.running=False
        try:self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:pass
        self.socket.close()
clients=[]
try:
    clients=[Client(i) for i in range(1,5)]
    time.sleep(.5)
    clients[0].send('SYNC 610\n');time.sleep(.25)
    clients[1].send('SYNC 730\n');clients[2].send('SYNC 450\n')
    time.sleep(.5)
    shared=set.intersection(*(set(c.packets) for c in clients))
    require(len(shared)>50,'Four receivers share >50 source packets')
    require(all(len({c.packets[s] for c in clients})==1 for s in shared),'Identical timestamps and PCM sizes across receivers')
    require(all(c.clocks>=3 and c.error is None for c in clients),'PCM and clock responses stay framed on every connection')
    stats=json.loads(command('stats'))
    require(stats['starts']==1,'One shared capture for four receivers')
    require(stats['adjustments']==[610],'Secondary SYNC cannot change primary timing')
    require(command('reserve')=='BUSY','Microphone rejected during desktop capture')
    with socket.create_connection(('127.0.0.1',port),timeout=2) as fifth:
        try:rejected=fifth.recv(1)==b''
        except ConnectionResetError:rejected=True
    require(rejected,'Fifth receiver is rejected')
    before=[len(c.packets) for c in clients];time.sleep(.3)
    require(all(len(c.packets)>n for c,n in zip(clients,before)),'Fifth receiver does not evict healthy listeners')
    clients[0].send('ACTIVE 0\n');time.sleep(.4)
    require(json.loads(command('stats'))['adjustments'][-1]==730,'Paused primary hands timing to cached successor')
    clients[0].close();clients.pop(0)
    slow=Client(9,read=False);clients.append(slow)
    before=len(clients[0].packets);time.sleep(3)
    require(len(clients[0].packets)>before+300 and clients[0].error is None,'Stalled receiver cannot block healthy capture')
    slow.close();clients.remove(slow)
    with socket.create_connection(('127.0.0.1',port),timeout=2) as bad:
        bad.sendall(b'x'*4097)
        # Some PCM may have started before this loopback-only malformed command.
        bad.settimeout(2)
        try:
            while bad.recv(8192):pass
            malformed=True
        except ConnectionResetError:malformed=True
    require(malformed,'Oversized control line disconnects only malformed peer')
    for c in clients:c.close()
    clients=[]
    time.sleep(.025)
    require(command('reserve')=='BUSY','Mic admission waits for capture teardown to finish')
    time.sleep(.5)
    stats=json.loads(command('stats'))
    require(stats['stops']==stats['starts'],'Last receiver stops shared capture exactly once')
    require(command('reserve')=='RESERVED','Microphone lease admitted after capture cleanup')
    with socket.create_connection(('127.0.0.1',port),timeout=2) as blocked:
        try:refused=blocked.recv(1)==b''
        except ConnectionResetError:refused=True
    require(refused,'Receiver cannot start while microphone lease held')
    require(command('reserve')=='BUSY','Second microphone lease rejected')
    require(command('release')=='RELEASED','Microphone lease releases')
    command('slow-start')
    cancelled=Client(12);clients.append(cancelled)
    require(wait_for(lambda: json.loads(command('stats'))['starting']==1),'Synthetic capture enters slow startup')
    cancelled.close();clients.remove(cancelled)
    require(wait_for(lambda: json.loads(command('stats'))['stopping']==1),'Canceled startup enters teardown')
    require(command('reserve')=='BUSY','Mic cannot overlap cancellation of a newly started capture')
    require(wait_for(lambda: (lambda s:s['starts']==s['stops'])(json.loads(command('stats')))),'Canceled startup fully stops capture')
    require(command('reserve')=='RESERVED','Mic admission recovers after startup cancellation teardown')
    command('release')
    parked=Client(80);clients.append(parked)
    require(wait_for(lambda:parked.status & 1),'Park capability is advertised in the reserved clock word')
    parked.send('PARK 1 PAUSE\n')
    require(wait_for(lambda:parked.status>>8==1 and parked.status&4),'PARK has a correlated clock acknowledgment')
    time.sleep(.2);before=len(parked.packets);held_stops=json.loads(command('stats'))['stops']
    time.sleep(.4)
    require(len(parked.packets)==before and parked.error is None,'Park drains capture without sending PCM or losing control')
    require(json.loads(command('stats'))['stops']==held_stops,'Last parked phone retains the capture/output owner')
    parked.send('ACTIVE 1\nRESUME 0\nRESUME 1\n')
    time.sleep(.3)
    require(len(parked.packets)==before and parked.status&4,'Legacy and stale resume cannot undo negotiated park')
    other=Client(81);clients.append(other)
    require(wait_for(lambda:len(other.packets)>10),'Another listener continues while one phone is parked')
    other.send('PARK 1 PHONE\n')
    require(wait_for(lambda:other.status>>8==1 and other.status&4),'Second phone parks independently')
    parked.close();other.close();clients=[];time.sleep(.5)
    require(json.loads(command('stats'))['stops']==held_stops,'Unexpected loss of all parked phones preserves bounded orphan hold')
    legacy=Client(82);clients.append(legacy);time.sleep(.3);legacy.close();clients=[];time.sleep(.3)
    require(json.loads(command('stats'))['stops']==held_stops,'A legacy reconnect cannot accidentally release an orphan hold')
    unrelated=Client(83);clients.append(unrelated);unrelated.send('RESUME 1\n')
    require(wait_for(lambda:unrelated.status>>8==1 and len(unrelated.packets)>10),'Unrelated listener may resume while missing phones retain holds')
    unrelated.send('RELEASE 2\n');require(wait_for(lambda:unrelated.status>>8==2 and unrelated.status&32),'Unrelated explicit release acknowledged')
    unrelated.close();clients=[];time.sleep(.3)
    require(json.loads(command('stats'))['stops']==held_stops,'One phone cannot clear another missing listener’s hold')
    second=Client(81);clients.append(second);second.send('RELEASE 1\n')
    require(wait_for(lambda:second.status>>8==1 and second.status&32),'A reconnected installation may explicitly release its own orphan hold')
    second.close();clients=[]
    resumed=Client(80);clients.append(resumed);resumed.send('RESUME 1\n')
    require(wait_for(lambda:resumed.status>>8==1 and not resumed.status&4 and len(resumed.packets)>10),'Explicit same-installation resume clears its orphan hold and returns fresh PCM')
    resumed.send('RELEASE 2\n')
    require(wait_for(lambda:resumed.status>>8==2 and resumed.status&32),'Explicit release is acknowledged before disconnect')
    resumed.close();clients=[]
    require(wait_for(lambda:json.loads(command('stats'))['stops']>held_stops),'Explicit final release stops capture normally')
    replaced=Client(84);clients.append(replaced);replaced.send('PARK 1 PAUSE\n')
    require(wait_for(lambda:replaced.status>>8==1 and replaced.status&4),'Park ACK waits for slow capture startup to finish')
    replacement=Client(84);clients.append(replacement);replacement.send('RESUME 1\n')
    require(wait_for(lambda:replacement.status>>8==1 and not replacement.status&4),'Same-installation replacement can resume')
    replacement.send('RELEASE 2\n')
    require(wait_for(lambda:replacement.status>>8==2 and replacement.status&32),'Replacement releases its hold')
    replaced.close();replacement.close();clients=[]
    require(wait_for(lambda:(lambda s:s['starts']==s['stops'])(json.loads(command('stats')))),'Late replaced-peer removal cannot resurrect phantom hold')
    require(command('stop')=='STOPPED','Server shutdown completes')
    process.wait(timeout=5)
    require(process.returncode==0,'Harness exits cleanly')
    report={'result':'passed','checks':checks,'source':'Synthetic PCM through actual Mac RelayServer','not_tested':['TLS gateway (separate checks)','Real capture/output devices','Acoustic sync','Microphone hardware']}
    (OUT/'mac-fanout.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
finally:
    for c in clients:c.close()
    if process.poll() is None:process.terminate();process.wait(timeout=5)
