#!/usr/bin/env python3
"""Temporary localhost QA relay. Generates silence; never captures system audio."""
import base64, hashlib, json, os, select, signal, socket, ssl, struct, subprocess, tempfile, time
from pathlib import Path

def end(*_): raise KeyboardInterrupt()
signal.signal(signal.SIGTERM, end)
with tempfile.TemporaryDirectory(prefix='pairit-qa-') as folder:
    folder = Path(folder)
    key, cert = folder/'key.pem', folder/'cert.pem'
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=PairIt Synthetic QA','-keyout',str(key),'-out',str(cert)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
    token = 'b' * 64  # Explicitly disposable test fixture, never a user's credential.
    code = 'audiorelay://pair/' + base64.urlsafe_b64encode(json.dumps({'host':'127.0.0.1','pin':pin,'token':token,'name':'Synthetic QA relay','platform':'mac'},separators=(',',':')).encode()).decode().rstrip('=')
    codepath = Path('/tmp/pairit-synthetic-qa-code.txt')
    codepath.write_text(code); os.chmod(codepath,0o600)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.minimum_version=ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert,key)
    listener=socket.socket();listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listener.bind(('127.0.0.1',15002));listener.listen(2)
    print('READY: localhost synthetic PCM only',flush=True)
    try:
      while True:
        raw,_=listener.accept();raw.settimeout(10)
        try:
          with context.wrap_socket(raw,server_side=True) as peer:
            line=b''
            while not line.endswith(b'\n'):line+=peer.recv(1)
            if line!=(token+'\n').encode():continue
            pending=b''; status=1; sequence=0; active=True; next_pcm=time.monotonic_ns()
            while True:
                readable,_,_=select.select([peer],[],[],.002)
                if readable or peer.pending():
                    data=peer.recv(65536)
                    if not data:break
                    pending+=data
                    while b'\n' in pending:
                        line,pending=pending.split(b'\n',1);words=line.decode().split(' ')
                        if words[0]=='PING':peer.sendall(struct.pack('<IIQQ',0x31435342,status,int(words[1]),time.monotonic_ns()))
                        elif words[0] in ('PARK','RESUME','RELEASE'):
                            number=int(words[1]); active=words[0]=='RESUME'; next_pcm=time.monotonic_ns()
                            status=1|(number<<8)|(4 if words[0]=='PARK' else 32 if words[0]=='RELEASE' else 0)
                            print(words[0]+(' '+words[2] if words[0]=='PARK' else ''),flush=True)
                        elif words[0]=='ACTIVE':active=words[1]=='1'
                now=time.monotonic_ns()
                # Preserve a 48 kHz sample timeline instead of accumulating select's
                # scheduling delay. Catch up at most 100 ms after a host stall.
                next_pcm=max(next_pcm,now-100_000_000)
                while active and now>=next_pcm:
                    peer.sendall(struct.pack('<IIIIQ',0x31415342,sequence,48000,256,next_pcm)+bytes(1024));sequence=(sequence+1)&0xffffffff;next_pcm+=5_333_333
        except (OSError,EOFError,ValueError):print('CONNECTION CLOSED',flush=True)
    except KeyboardInterrupt:pass
    finally:listener.close();codepath.unlink(missing_ok=True)
