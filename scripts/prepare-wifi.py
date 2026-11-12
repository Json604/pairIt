#!/usr/bin/env python3
"""Create a local test identity and embed its pin in the debug APK. Never prints secrets."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import ssl
import socket
import subprocess

root = Path(__file__).resolve().parent.parent
folder = root / 'artifacts' / 'wifi'
folder.mkdir(parents=True, exist_ok=True)
os.chmod(folder, 0o700)
cert, key = folder / 'server.pem', folder / 'server.key'
if not cert.exists() or not key.exists() or subprocess.run(['openssl', 'x509', '-checkend', '2592000', '-noout', '-in', str(cert)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
                    '-subj', '/CN=Audio Relay Lab', '-keyout', str(key), '-out', str(cert)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(key, 0o600)
config_path = folder / 'config.json'
config = json.loads(config_path.read_text()) if config_path.exists() else {'token': secrets.token_hex(32)}
try:
    config['host'] = subprocess.check_output(['ipconfig', 'getifaddr', 'en0'], text=True).strip()
except subprocess.CalledProcessError:
    config.setdefault('host', socket.gethostname())
config['pin'] = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
config_path.write_text(json.dumps(config))
os.chmod(config_path, 0o600)
generated = root / 'android' / 'build' / 'generated'
generated.mkdir(parents=True, exist_ok=True)
source = 'package dev.bluetoothswitch.relay;\nfinal class LabConfig {\n'
for name in ('host', 'pin', 'token'):
    source += f'    static final String {name.upper()} = {json.dumps(config[name])};\n'
source += '}\n'
(generated / 'LabConfig.java').write_text(source)
print(f'Prepared pinned local Wi-Fi endpoint {config["host"]}:5002 (credentials not logged)')

subprocess.run(['openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(cert), '-out', str(folder / 'identity.p12'), '-passout', 'stdin', '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1'], input=(config['token']+'\n').encode(), check=True)
os.chmod(folder / 'identity.p12', 0o600)
