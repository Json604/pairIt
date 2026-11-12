#!/usr/bin/env python3
"""Validate publication metadata and reachable official destinations, without secrets."""
import json, re, urllib.request
from pathlib import Path
from urllib.parse import urlparse
p=Path(__file__).resolve().parent.parent/'release/updates.json'
raw=p.read_bytes(); data=json.loads(raw)
assert len(raw)<=65536 and data['schema']==1 and len(data['releases'])<=100
keys=set()
for e in data['releases']:
    platform=e['platform']; assert platform in ('mac','windows','ios','android')
    assert type(e['build']) is int and e['build']>0
    assert re.fullmatch(r'\d+\.\d+\.\d+([.-][A-Za-z0-9.]+)?',e['version'])
    u=urlparse(e['url']); assert u.scheme=='https' and not u.username and not u.password and not u.port
    if platform=='ios': assert u.hostname=='apps.apple.com' and u.path.endswith('/id6833655052')
    else: assert u.hostname=='github.com' and u.path.startswith('/Json604/pairIt/releases/') and '..' not in u.path
    if platform=='android':
        assert e['bundleID'] in ('dev.bluetoothswitch.relay','dev.bluetoothswitch.relay.preview')
        assert re.fullmatch('[0-9a-f]{64}',e['signerSHA256']) and type(e['minimumSDK']) is int and e['minimumSDK']>=29
    else: assert re.fullmatch(r'\d+\.\d+(\.\d+)?',e['minimumOS'])
    key=(platform,e['bundleID'],e.get('signerSHA256','')); assert key not in keys; keys.add(key)
    req=urllib.request.Request(e['url'],headers={'User-Agent':'PairIt-release-validation'},method='HEAD')
    with urllib.request.urlopen(req,timeout=20) as response: assert response.status==200
    print(platform,e['build'],'destination reachable')
print('Feed valid. Artifact identity and store rollout still require release verification.')
