#!/usr/bin/env python3
"""Sign installer metadata with the release-only P-256 key, never bundled in apps.

Input: JSON array with platform, architecture, kind, build, version, url, file.
File is a local package path; it is replaced by SHA256 and byte size in output.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import re
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('entries',type=Path);p.add_argument('output',type=Path)
p.add_argument('--key',type=Path,default=Path.home()/'.config/pairit/desktop-update-signing.pem')
a=p.parse_args()
entries=json.loads(a.entries.read_text());seen=set()
for entry in entries:
    identity=(entry['platform'],entry['architecture'],entry['kind'])
    if identity in seen:raise ValueError('Duplicate installer target')
    seen.add(identity)
    if entry['platform'] not in ('windows','linux') or entry['architecture'] not in ('x64','arm64') or entry['kind'] not in ('zip','deb'):raise ValueError('Unknown target')
    if not isinstance(entry['build'],int) or entry['build']<=0:raise ValueError('Invalid build')
    if not re.fullmatch(r'https://github\.com/Json604/pairIt-download/releases/download/v[0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*',entry['url']) or '..' in entry['url']:raise ValueError('Invalid official asset URL')
    file=Path(entry.pop('file'));entry['size']=file.stat().st_size
    if not 0<entry['size']<=512*1024*1024:raise ValueError('Installer size outside bounds')
    with file.open('rb') as stream:entry['sha256']=hashlib.file_digest(stream,'sha256').hexdigest()
payload=json.dumps({'schema':1,'releases':entries},sort_keys=True,separators=(',',':')).encode()
signature=subprocess.run(['openssl','dgst','-sha256','-sign',str(a.key)],input=payload,stdout=subprocess.PIPE,check=True).stdout
a.output.write_text(json.dumps({'payload':base64.b64encode(payload).decode(),'signature':base64.b64encode(signature).decode()},indent=2)+'\n')
print(f'Signed {len(entries)} installers: {a.output}')
