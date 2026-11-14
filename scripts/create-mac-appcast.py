#!/usr/bin/env python3
"""Create Sparkle's HTTPS appcast for a signed/notarized release ZIP."""
import argparse
from datetime import datetime,timezone
from email.utils import format_datetime
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('archive',type=Path);p.add_argument('--build',type=int,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();root=Path(__file__).resolve().parent.parent
ns='http://www.andymatuschak.org/xml-namespaces/sparkle';ET.register_namespace('sparkle',ns)
signature=subprocess.run([str(root/'artifacts/tools/sparkle-2.10.1/bin/sign_update'),'--account','dev.pairit.updates','-p',str(a.archive)],check=True,capture_output=True,text=True).stdout.strip()
if len(signature)!=88:raise ValueError('Unexpected Sparkle signature')
rss=ET.Element('rss',{'version':'2.0'});channel=ET.SubElement(rss,'channel');ET.SubElement(channel,'title').text='PairIt updates'
item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text=f'PairIt 1.1.0 (build {a.build})';ET.SubElement(item,'pubDate').text=format_datetime(datetime.now(timezone.utc))
ET.SubElement(item,'{'+ns+'}version').text=str(a.build);ET.SubElement(item,'{'+ns+'}shortVersionString').text='1.1.0';ET.SubElement(item,'{'+ns+'}minimumSystemVersion').text='14.2'
ET.SubElement(item,'enclosure',{'url':f'https://github.com/Json604/pairIt-download/releases/download/v1.1.0-preview.{a.build}/{a.archive.name}','length':str(a.archive.stat().st_size),'type':'application/octet-stream','{'+ns+'}edSignature':signature})
ET.indent(rss);ET.ElementTree(rss).write(a.output,encoding='utf-8',xml_declaration=True)
print(a.output)
