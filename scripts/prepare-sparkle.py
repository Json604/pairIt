#!/usr/bin/env python3
"""Fetch a pinned Sparkle binary; preserve framework symlinks and executable modes."""
from pathlib import Path
import tarfile
from release_tools import verified_download
ROOT=Path(__file__).resolve().parent.parent
archive=ROOT/'artifacts/tools/Sparkle-2.10.1.tar.xz'
verified_download('https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz',archive,'1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27')
folder=ROOT/'artifacts/tools/sparkle-2.10.1'
if not (folder/'Sparkle.framework').exists():
 folder.mkdir(parents=True,exist_ok=True)
 with tarfile.open(archive) as source:source.extractall(folder,filter='data')
print(folder)
