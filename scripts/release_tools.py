"""Integrity checks for executable release tooling, including cached downloads."""
import hashlib
import os
from pathlib import Path
import tempfile
import urllib.request


def verified_download(url, destination, expected_sha256):
    destination = Path(destination)
    if destination.exists():
        if hashlib.sha256(destination.read_bytes()).hexdigest() != expected_sha256:
            raise ValueError(f'Checksum mismatch: {destination.name}; remove the untrusted cache file before retrying')
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=destination.parent, prefix='.download-')
    try:
        digest = hashlib.sha256()
        size = 0
        with os.fdopen(descriptor, 'wb') as output, urllib.request.urlopen(url, timeout=60) as response:
            while block := response.read(1024 * 1024):
                size += len(block)
                if size > 128 * 1024 * 1024:
                    raise ValueError('Tool download exceeds 128 MiB')
                output.write(block)
                digest.update(block)
        if digest.hexdigest() != expected_sha256:
            raise ValueError('Tool download checksum mismatch')
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)
