#!/usr/bin/env python3
"""Sign embedded updater components inside-out before signing the Mac app."""
from pathlib import Path
import argparse,subprocess
p=argparse.ArgumentParser(description=__doc__);p.add_argument('app',type=Path);p.add_argument('--identity',required=True);a=p.parse_args()
framework=a.app/'Contents/Frameworks/Sparkle.framework'
for relative in ['Versions/B/Autoupdate','Versions/B/Updater.app','Versions/B/XPCServices/Downloader.xpc','Versions/B/XPCServices/Installer.xpc','.']:
    args=['codesign','--force','--options','runtime','--timestamp','--sign',a.identity]
    if relative.endswith('Downloader.xpc'):args+=['--preserve-metadata=entitlements']
    subprocess.run(args+[str(framework/relative)],check=True)
subprocess.run(['codesign','--force','--options','runtime','--timestamp','--sign',a.identity,str(a.app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(a.app)],check=True)
