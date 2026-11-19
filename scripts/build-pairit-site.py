#!/usr/bin/env python3
from pathlib import Path
import argparse,json,re,shutil
parser=argparse.ArgumentParser()
parser.add_argument('--page', choices=['privacy','support'], help='Update only this policy/help page')
parser.add_argument('--site-dir', type=Path, help='Website folder (default: site/)')
args=parser.parse_args()
ROOT=Path(__file__).resolve().parent.parent
site=(args.site_dir or ROOT/'site').resolve()
home=(site/'index.html').read_text()
head=home.split('<main id="main">')[0]+'<main id="main">'
header=re.search(r'<header>.*?</header>',home,re.S).group()
footer=re.search(r'<hr><footer>.*?</footer>',home,re.S).group()+'</main></body></html>'
for name,title in [('privacy','privacy policy'),('support','setup guide')]:
 if args.page and name!=args.page:continue
 source=(ROOT/('release/google-play/site/'+name+'.html')).read_text()
 body=source.split('</nav>',1)[1].split('<footer>',1)[0]
 body=re.sub(r'<h1>.*?</h1>','<h1>'+title+'</h1>',body,count=1)
 (site/(name+'.html')).write_text(re.sub(r'<title>.*?</title>','<title>'+title+' — PairIt</title>',head)+header+body+footer)
if not args.page:shutil.copy2(ROOT/'release/google-play/graphics/feature-1024x500.png',site/'feature.png')
profile=json.loads((ROOT/'release/google-play/release.json').read_text())
publisher=profile.get('admob',{}).get('publisher_id','')
if publisher and not args.page:
 if not re.fullmatch(r'pub-\d{16}',publisher):raise SystemExit('Invalid AdMob publisher ID')
 (site/'app-ads.txt').write_text(f'google.com, {publisher}, DIRECT, f08c47fec0942fa0\n')
