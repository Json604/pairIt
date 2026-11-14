#!/usr/bin/env python3
"""Validate official release metadata; optionally check reachable destinations."""
import argparse
import json
from pathlib import Path
import re
import urllib.request
from urllib.parse import urlsplit

IDENTITIES = {
    'mac': {'dev.bluetoothswitch.macrelay'},
    'windows': {'dev.bluetoothswitch.windowsrelay'},
    'linux': {'dev.bluetoothswitch.linuxrelay'},
    'ios': {'dev.bluetoothswitch.iosrelay'},
    'android': {'dev.bluetoothswitch.relay', 'dev.bluetoothswitch.relay.preview'},
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_url(value, platform):
    require(isinstance(value, str) and value.isascii() and not any(c.isspace() for c in value), 'Invalid release URL')
    url = urlsplit(value)
    require(url.scheme == 'https' and not url.username and not url.password and not url.port
            and not url.query and not url.fragment, 'Release URL must use plain HTTPS without credentials or parameters')
    if platform == 'ios':
        require(url.netloc == 'apps.apple.com' and re.fullmatch(r'/(?:[a-z]{2}/)?app/(?:[A-Za-z0-9-]+/)?id6833655052', url.path), 'Wrong App Store destination')
        return
    require(url.netloc == 'github.com' and '..' not in url.path and re.fullmatch(
        r'/Json604/pairIt-download/releases/(?:tag/v[0-9][A-Za-z0-9._-]*|download/v[0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*)',
        url.path), 'Expected a versioned official GitHub release')


def validate_feed(raw):
    require(len(raw) <= 65536, 'Feed exceeds 64 KiB')
    data = json.loads(raw)
    require(isinstance(data, dict) and type(data.get('schema')) is int and data['schema'] == 1, 'Unknown feed schema')
    entries = data.get('releases')
    require(isinstance(entries, list) and len(entries) <= 100, 'Invalid release list')
    keys = set()
    for entry in entries:
        require(isinstance(entry, dict), 'Release must be an object')
        # Shipped Apple clients decode all entries before filtering by platform.
        # Non-Apple entries keep an empty compatibility field; their real limits
        # remain minimumSDK or architectures/requirements.
        require(isinstance(entry.get('minimumOS'), str), 'Missing legacy Apple decoder compatibility field')
        platform = entry.get('platform')
        require(isinstance(platform, str) and platform in IDENTITIES, 'Unknown platform')
        require(isinstance(entry.get('bundleID'), str) and entry['bundleID'] in IDENTITIES[platform], 'Wrong bundle identity')
        require(type(entry.get('build')) is int and 0 < entry['build'] <= 2147483647, 'Build must be a positive 32-bit integer')
        require(isinstance(entry.get('version'), str) and re.fullmatch(r'\d+\.\d+\.\d+([.-][A-Za-z0-9.]+)?', entry['version']), 'Invalid version')
        validate_url(entry.get('url'), platform)
        if platform == 'android':
            require(isinstance(entry.get('signerSHA256'), str) and re.fullmatch('[0-9a-f]{64}', entry['signerSHA256']), 'Invalid signer fingerprint')
            require(type(entry.get('minimumSDK')) is int and entry['minimumSDK'] >= 29, 'Invalid minimum SDK')
        elif platform == 'linux':
            require(entry.get('architectures') == ['x64', 'arm64'], 'Invalid Linux architectures')
            require(isinstance(entry.get('requirements'), str) and 1 <= len(entry['requirements']) <= 256, 'Missing Linux requirements')
        else:
            require(isinstance(entry.get('minimumOS'), str) and re.fullmatch(r'\d+\.\d+(\.\d+)?', entry['minimumOS']), 'Invalid minimum OS')
        key = (platform, entry['bundleID'], entry.get('signerSHA256', ''))
        require(key not in keys, 'Duplicate release identity')
        keys.add(key)
    return entries


def validate_destination(original, final, platform):
    # GitHub redirects versioned assets to its signed, expiring asset CDN.
    # This check only probes availability; the original feed URL stays pinned.
    if original.startswith('https://github.com/Json604/pairIt-download/releases/download/'):
        url = urlsplit(final)
        if (url.scheme == 'https' and url.netloc == 'release-assets.githubusercontent.com'
                and not url.username and not url.password and not url.fragment):
            return
    validate_url(final, platform)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true', help='Validate metadata without network requests')
    args = parser.parse_args()
    path = Path(__file__).resolve().parent.parent / 'release/updates.json'
    entries = validate_feed(path.read_bytes())
    if not args.offline:
        for entry in entries:
            request = urllib.request.Request(entry['url'], headers={'User-Agent': 'PairIt-release-validation'}, method='HEAD')
            with urllib.request.urlopen(request, timeout=20) as response:
                require(response.status == 200, 'Release destination is unavailable')
                validate_destination(entry['url'], response.geturl(), entry['platform'])
            print(entry['platform'], entry['build'], 'destination reachable')
    print('Feed valid. Artifact identity and store rollout still require release verification.')


if __name__ == '__main__':
    main()
