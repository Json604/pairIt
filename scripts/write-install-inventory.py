#!/usr/bin/env python3
"""Record distribution-owned files so the updater never replaces unrelated data."""
import json
from pathlib import Path
import sys
root=Path(sys.argv[1]).resolve()
files=[]
for path in root.rglob('*'):
    if path.is_symlink():
        raise ValueError(f'Symlink not allowed in distribution: {path.name}')
    if path.is_file() and path.name != 'pairit-files.json':
        files.append(path.relative_to(root).as_posix())
files.append('pairit-files.json')
(root/'pairit-files.json').write_text(json.dumps(sorted(files),indent=2)+'\n')
