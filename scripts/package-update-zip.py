#!/usr/bin/env python3
"""Package a self-contained distribution under the updater's fixed PairIt/ root."""
from pathlib import Path
import sys
import zipfile
root=Path(sys.argv[1]).resolve()
with zipfile.ZipFile(sys.argv[2], 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Distribution symlinks are not supported')
        if path.is_file():
            archive.write(path, 'PairIt/'+path.relative_to(root).as_posix())
