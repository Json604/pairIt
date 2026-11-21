#!/usr/bin/env python3
"""Exercise the real Mac fanout with synthetic PCM; no hardware audio or unit tests."""
from pathlib import Path
import base64, json, os, socket, struct, subprocess, threading, time

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / os.environ.get('PAIRIT_VERIFY_OUTPUT', 'artifacts/feature-preview/verification')
OUT.mkdir(parents=True, exist_ok=True)
binary = OUT / 'feature-server-harness'
subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-framework','CoreAudio',
                str(ROOT/'apple/ComputerVolume.swift'),str(ROOT/'mac/RelayServer.swift'),str(ROOT/'scripts/FeatureServerHarness.swift'),'-o',str(binary)],check=True)
with socket.socket() as reserve:
    reserve.bind(('127.0.0.1',0)); port=reserve.getsockname()[1]
process=subprocess.Popen([str(binary),str(port)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
ready=process.stdout.readline().strip().split(' ',1)
assert len(ready)==2 and ready[0]=='READY'
gateway_token=ready[1]
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
    def __init__(self,number,read=True,extra=''):
        self.socket=socket.create_connection(('127.0.0.1',port),timeout=2)
        self.socket.settimeout(3);self.packets={};self.clocks=0;self.status=0;self.desktop=0;self.volume=None;self.error=None;self.running=True;self.presentation=None
        self.volume_requests=[];self.last_sample=None;self.player=None
        self.send('AUTH '+gateway_token+'\nHELLO '+format(number,'032x')+'\nSTATS CONTROLS1\nSTATS VOLUME1\n'+extra+'ACTIVE 1\n')
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
                if magic==0x34435342:self.presentation=(seq,rate,frames);continue
                if magic==0x33435342:self.volume=seq;continue
                if magic==0x32435342:self.desktop=seq;continue
                if magic==0x35435342:self.volume_requests.append(seq);continue
                if magic==0x36435342:self.player=seq;continue
                if magic==0x31435342:self.clocks+=1;self.status=seq;continue
                assert magic==0x31415342 and rate in(44100,48000) and frames<=8192
                if frames:
                    pcm=self.read(frames*4);self.packets[seq]=(stamp,len(pcm));self.last_sample=struct.unpack('<h',pcm[:2])[0]
        except (OSError,EOFError) as e:self.error=type(e).__name__
        except Exception as e:self.error=str(e)
    def close(self):
        self.running=False
        try:self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:pass
        self.socket.close()
clients=[]
try:
    pending=socket.create_connection(('127.0.0.1',port),timeout=2)
    pending.settimeout(.15)
    try:
        pending.recv(1)
        raise AssertionError('Pending authentication received data or closed early')
    except socket.timeout:pass
    require(json.loads(command('stats'))['starts']==0,'Pending loopback authentication cannot start capture or receive a heartbeat')
    clients=[Client(i) for i in range(1,5)]
    pending.close()
    time.sleep(.5)
    clients[0].send('SYNC 610\n');time.sleep(.25)
    clients[1].send('SYNC 730\n');clients[2].send('SYNC 450\n')
    time.sleep(.5)
    shared=set.intersection(*(set(c.packets) for c in clients))
    require(len(shared)>50,'Four receivers share >50 source packets')
    require(all(len({c.packets[s] for c in clients})==1 for s in shared),'Identical timestamps and PCM sizes across receivers')
    require(all(c.clocks>=3 and c.error is None for c in clients),'PCM and clock responses stay framed on every connection')
    stats=json.loads(command('stats'))
    require(all(c.volume==250 for c in clients),'Computer volume metadata reaches all negotiated receivers')
    require(stats['starts']==1,'One shared capture for four receivers')
    require(stats['adjustments']==[610],'Secondary SYNC cannot change primary timing')
    clients[0].send('STATS ALIGN1 320 20\n')
    require(wait_for(lambda:clients[0].presentation==(0,4,1)),'Mixed legacy listeners do not enable presentation alignment')
    for client,delay in zip(clients[1:],[25,100,180]):client.send(f'STATS ALIGN1 320 {delay}\n')
    require(wait_for(lambda:all(c.presentation==(500,4,4) for c in clients)),'Four outputs negotiate one bounded presentation deadline')
    require(json.loads(command('stats'))['starts']==1,'Presentation negotiation does not restart shared capture')

    require(wait_for(lambda:all(c.status & 128 for c in clients)),'Computer output controls are advertised')
    for turn in range(2):
        command('computer-output')
        require(wait_for(lambda:all(c.status & 64 for c in clients)),'Computer speaker selection reaches every phone')
        require(wait_for(lambda:(lambda s:s['starts']==s['stops'])(json.loads(command('stats')))),'Computer speaker selection releases capture and restores output')
        time.sleep(.3);before=[len(c.packets) for c in clients];clocks=[c.clocks for c in clients]
        time.sleep(.4)
        require(all(len(c.packets)==n and c.error is None and c.clocks>clock for c,n,clock in zip(clients,before,clocks)),'Speaker selection retains control connections without sending audio')
        clients[0].send('OUTPUT PHONE\n')
        require(wait_for(lambda:all(not(c.status & 64) and len(c.packets)>n for c,n in zip(clients,before))),'Phone output resumes on the same four sockets')
    require(command('reserve')=='BUSY','Microphone rejected during desktop capture')
    with socket.create_connection(('127.0.0.1',port),timeout=2) as fifth:
        fifth.sendall(('AUTH '+gateway_token+'\n').encode())
        reply=b''
        while len(reply)<24:
            chunk=fifth.recv(24-len(reply))
            if not chunk:break
            reply+=chunk
        rejected=len(reply)==24 and struct.unpack('<II',reply[:8])==(0x31455342,1)
    require(rejected,'Fifth receiver receives explicit group-full status')
    before=[len(c.packets) for c in clients];time.sleep(.3)
    require(all(len(c.packets)>n for c,n in zip(clients,before)),'Fifth receiver does not evict healthy listeners')
    other_before=[len(c.packets) for c in clients[1:]]
    clients[0].send('ACTIVE 0\n');time.sleep(.4)
    require(all(len(c.packets)>n and c.error is None for c,n in zip(clients[1:],other_before)),'Pausing one phone leaves the other three playing')
    require(json.loads(command('stats'))['adjustments'][-1]==730,'Paused primary hands timing to cached successor')
    clients[0].close();clients.pop(0)
    slow=Client(9,read=False);clients.append(slow)
    before=len(clients[0].packets)
    # Keep the packet-count assertion, but wait for the event instead of assuming
    # a shared CI runner schedules synthetic capture at a fixed wall-clock rate.
    progressed=wait_for(lambda: len(clients[0].packets)>before+300 or clients[0].error is not None, timeout=6)
    require(progressed and len(clients[0].packets)>before+300 and clients[0].error is None,
            f'Stalled receiver cannot block healthy capture (packets={len(clients[0].packets)-before}, error={clients[0].error})')
    slow.close();clients.remove(slow)
    with socket.create_connection(('127.0.0.1',port),timeout=2) as bad:
        bad.sendall(('AUTH '+gateway_token+'\n').encode()+b'x'*4097)
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
    time.sleep(1)
    require(not other.status&16, 'Silence does not reclaim phone audio')
    command('audio-on')
    require(wait_for(lambda:other.status&16), 'Fresh computer audio offers resume to a phone interruption')
    require(not parked.status&16, 'Fresh computer audio does not override an explicit pause')
    other.send('RESUME 2\n')
    require(wait_for(lambda:other.status>>8==2 and not other.status&20), 'Resume clears the offer and releases the hold')
    other.send('PARK 3 PHONE\n')
    require(wait_for(lambda:other.status>>8==3 and other.status&4), 'New phone interruption is acknowledged')
    time.sleep(.5)
    require(not other.status&16, 'Already playing computer audio does not immediately steal focus back')
    command('audio-off');time.sleep(1)
    other.send('PARK 4 OUTPUT\n')
    require(wait_for(lambda:other.status>>8==4), 'Output interruption is acknowledged')
    command('audio-on');time.sleep(.5)
    require(not other.status&16, 'Output changes and call holds do not auto-resume')
    command('audio-off')
    command('phone-resume')
    require(wait_for(lambda:other.desktop&18==18 and parked.desktop&18==18), 'Desktop resume explicitly requests paused phones')
    other.send('RESUME 5\n')
    require(wait_for(lambda:other.status>>8==5 and not other.status&16), 'Receiver acknowledgment clears desktop request')
    command('phone-pause')
    require(wait_for(lambda:other.desktop&18==2), 'Desktop pause requests stop without implying resume')
    other.send('PARK 6 PAUSE\n')
    require(wait_for(lambda:other.status>>8==6 and other.status&4 and not other.status&16), 'Desktop pause completes only after receiver acknowledgment')
    parked.close();other.close();clients=[];time.sleep(.5)
    require(wait_for(lambda:(lambda s:s['starts']==s['stops'])(json.loads(command('stats')))), 'Loss of all parked phones restores the original computer output')
    resumed=Client(80);clients.append(resumed);resumed.send('RESUME 1\n')
    require(wait_for(lambda:resumed.status>>8==1 and not resumed.status&4 and len(resumed.packets)>10),'A returning installation receives fresh audio')
    resumed.close();clients=[]
    require(wait_for(lambda:(lambda s:s['starts']==s['stops'])(json.loads(command('stats')))), 'Unexpected loss of the active phone restores the original output')
    replaced=Client(84);clients.append(replaced);replaced.send('PARK 1 PAUSE\n')
    require(wait_for(lambda:replaced.status>>8==1 and replaced.status&4),'Park ACK waits for slow capture startup to finish')
    replacement=Client(84);clients.append(replacement);replacement.send('RESUME 1\n')
    require(wait_for(lambda:replacement.status>>8==1 and not replacement.status&4),'Same-installation replacement can resume')
    replacement.send('RELEASE 2\n')
    require(wait_for(lambda:replacement.status>>8==2 and replacement.status&32),'Replacement releases its hold')
    replaced.close();replacement.close();clients=[]
    require(wait_for(lambda:(lambda s:s['starts']==s['stops'])(json.loads(command('stats')))),'Late replaced-peer removal cannot resurrect phantom hold')
    paused=Client(90);active=Client(91);clients=[paused,active]
    require(wait_for(lambda:paused.status&128 and len(active.packets)>5),'New output-switch check starts with two listeners')
    paused.send('PARK 1 PAUSE\n')
    require(wait_for(lambda:paused.status&4),'Listener explicitly parks before output change')
    active.send('OUTPUT COMPUTER\n')
    require(wait_for(lambda:paused.status&64 and active.status&64 and paused.status&4),'A parked phone stays parked in speaker mode')
    time.sleep(.3);paused_count=len(paused.packets);active_count=len(active.packets)
    command('phone-output')
    require(wait_for(lambda:not(active.status&64) and len(active.packets)>active_count),'Desktop output selection restores an active listener')
    time.sleep(.3)
    require(paused.error is None and len(paused.packets)==paused_count and paused.status&4,'Output change never resumes a paused listener')
    command('computer-output')
    require(wait_for(lambda:active.status&64 and (lambda s:s['starts']==s['stops'])(json.loads(command('stats')))),'Speaker selection finishes before failed-return check')
    before_starts=json.loads(command('stats'))['starts']
    command('fail-next-start');command('phone-output')
    require(wait_for(lambda:(lambda s:s['starts']>before_starts and s['starts']==s['stops'])(json.loads(command('stats')))),'Failed return cleans up its capture attempt')
    before_clocks=active.clocks
    require(wait_for(lambda:active.status&64 and active.clocks>before_clocks and paused.status&4),'Failed return falls back to speakers with live control and paused intent')
    require(active.error is None and paused.error is None,'Capture failure keeps both phone connections')
    active_count=len(active.packets);command('phone-output')
    require(wait_for(lambda:not(active.status&64) and len(active.packets)>active_count),'Explicit retry resumes audio on the same connection')
    paused.send('RELEASE 2\n');active.send('RELEASE 1\n')
    require(wait_for(lambda:paused.status&32 and active.status&32),'Output-switch check releases both listeners')
    for c in clients:c.close()
    clients=[]
    # Phone-owned volume, computer-side disconnect and media handoff (STATS VOLUME2/CONTROLS2).
    def name(text):return 'NAME1 '+base64.b64encode(text.encode()).decode()+'\n'
    def stats():return json.loads(command('stats'))
    command('volume 0.25');command('audio-on')
    owner=Client(101,extra=name('Owner phone')+'STATS VOLUME2\nSTATS CONTROLS2\nSTATS PVOL1 500\n');clients=[owner]
    require(wait_for(lambda:stats()['volumeWrites']==[0.5]),'A single volume-controlled phone sets the Mac volume to its own level')
    time.sleep(.3)
    require(owner.volume_requests==[],'Following the phone volume is not echoed back to the phone')
    legacy=Client(100);clients.append(legacy)
    require(wait_for(lambda:owner.volume is not None and owner.volume&0x20000 and legacy.volume is not None and not legacy.volume&0x20000),'Only VOLUME2 phones learn the computer stopped attenuating them')
    require(wait_for(lambda:owner.last_sample==1000 and legacy.last_sample==500),'VOLUME2 phones get full-scale PCM; older phones keep the Mac volume applied')
    require(wait_for(lambda:any(r['name']=='Owner phone' and r['level']==500 and r['disconnect'] for r in json.loads(command('phones')))),'Mac controls list the phone, its volume and disconnect support')
    command('volume 0.5625')
    require(wait_for(lambda:owner.volume_requests==[563]),'A Mac volume-key step moves the phone volume by the same step')
    require(legacy.volume_requests==[],'Older phones never receive volume requests')
    owner.send('STATS PVOL1 533\n');time.sleep(.4)
    require(stats()['volumeWrites']==[0.5],'With an older phone connected the Mac volume does not follow another phone')
    legacy.close();clients.remove(legacy);time.sleep(.4)
    owner.send('STATS PVOL1 600\n')
    require(wait_for(lambda:stats()['volumeWrites']==[0.5,0.6]),'The Mac follows the volume a sole phone actually applied')
    time.sleep(.3)
    require(owner.volume_requests==[563],'Following the applied phone step is not echoed back')
    require(command('disconnect Owner phone')=='OK' and wait_for(lambda:owner.desktop&64),'Computer disconnect request reaches an updated phone')
    owner.send('RELEASE 1\n')
    require(wait_for(lambda:owner.status&32),'The phone acknowledges a computer disconnect with RELEASE')
    for c in clients:c.close()
    clients=[];time.sleep(.5)
    media=Client(102);clients=[media];media.send('RESUME 1\n')
    require(wait_for(lambda:media.status>>8==1 and media.status&2 and len(media.packets)>5),'Media control availability is advertised to phones')
    base=stats()['presses']
    media.send('PARK 2 PAUSE\n')
    require(wait_for(lambda:stats()['presses']==base+1),'Pausing the last listening phone presses Play/Pause on the Mac')
    require(wait_for(lambda:stats()['presses']==base+2,timeout=4),'A press that does not silence the Mac is undone')
    media.send('RESUME 3\n');time.sleep(.3)
    require(stats()['presses']==base+2,'Resume does not press Play after an undone pause')
    media.send('PARK 4 PAUSE\n')
    require(wait_for(lambda:stats()['presses']==base+3),'A later pause presses Play/Pause again')
    command('audio-off')
    require(wait_for(lambda:media.status>>8==4 and media.status&8),'The phone is told the Mac player is paused')
    time.sleep(1.6)
    require(stats()['presses']==base+3,'A pause that silenced the Mac is kept')
    media.send('RESUME 5\n')
    require(wait_for(lambda:stats()['presses']==base+4),'Phone resume presses Play only after its own pause silenced the Mac')
    media.send('STATS MEDIA1 NEXT\nSTATS MEDIA1 PREVIOUS\n')
    require(wait_for(lambda:stats()['skips']==[True,False]),'Earphone next/previous track reach the Mac media keys')
    time.sleep(3.2);media.send('PARK 7 PAUSE\n');time.sleep(.3)
    require(stats()['presses']==base+4,'Pausing a silent Mac never presses Play/Pause')
    time.sleep(2.2);media.send('RESUME 8\n')
    require(wait_for(lambda:stats()['presses']==base+5),'Earphone play after a pause starts the Mac player even if PairIt did not pause it')
    media.send('PARK 9 PAUSE\nSTATS MEDIA1 NEXT\nRESUME 10\n');time.sleep(.5)
    require(stats()['presses']==base+5,'Resume right after a skip does not press Play (the skip already started playback)')
    smart=Client(105,extra='STATS PLAYER1\n');clients.append(smart);smart.send('RESUME 1\n')
    command('audio-on')
    require(wait_for(lambda:smart.player==1),'Phones learn the Mac is playing')
    command('audio-off')
    require(wait_for(lambda:smart.player==0,timeout=4),'Phones learn the Mac paused (silence) so earphone play starts it')
    presses=stats()['presses'];smart.send('STATS MEDIA1 PLAY\n')
    require(wait_for(lambda:stats()['presses']==presses+1),'Earphone play while the Mac is paused presses Play on the Mac')
    smart.send('PARK 2 PAUSE\n');time.sleep(2.3);command('audio-on')
    require(wait_for(lambda:smart.status>>8==2 and smart.status&16,timeout=4),'Mac play/next while the phone is paused offers that phone a resume')
    command('audio-off');smart.send('RESUME 3\n');time.sleep(.3)
    gap=Client(106,extra='STATS PLAYER1\n');clients.append(gap);gap.send('RESUME 1\n');command('audio-on');time.sleep(.5)
    gap.send('PARK 2 PAUSE\n');time.sleep(.3);command('audio-off');time.sleep(1);command('audio-on');time.sleep(1.2)
    require(not gap.status&16,'A short gap between songs does not resume a paused phone')
    command('audio-off');smart.close();gap.close();clients.remove(smart);clients.remove(gap);time.sleep(.3)
    presses=stats()['presses']
    reconnect=Client(104);clients.append(reconnect);reconnect.send('RESUME 1\n');time.sleep(.5)
    require(stats()['presses']==presses,'A first connection never starts the Mac player')
    reconnect.close();clients.remove(reconnect)
    command('audio-on');other=Client(103);clients.append(other);time.sleep(.5)
    media.send('PARK 11 PAUSE\n');time.sleep(.4)
    require(media.status>>8==11 and stats()['presses']==presses,'Pausing one of several listeners leaves the Mac player alone')
    command('audio-off')
    for c in clients:c.close()
    clients=[]
    require(command('stop')=='STOPPED','Server shutdown completes')
    process.wait(timeout=5)
    require(process.returncode==0,'Harness exits cleanly')
    report={'result':'passed','checks':checks,'source':'Synthetic PCM through actual Mac RelayServer','not_tested':['TLS gateway (separate checks)','Real capture/output devices','Acoustic sync','Microphone hardware']}
    (OUT/'mac-fanout.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
finally:
    for c in clients:c.close()
    if process.poll() is None:process.terminate();process.wait(timeout=5)
