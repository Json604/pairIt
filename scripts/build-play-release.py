#!/usr/bin/env python3
"""Build a signed, reproducible internal candidate; private keys never enter this repo."""
import argparse, hashlib, importlib.util, json, os, secrets, shutil, subprocess, tempfile, urllib.request, zipfile
from pathlib import Path
from release_tools import verified_download
ROOT=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--internal',action='store_true',help='Allow documented configuration/acceptance blockers; does not submit or force test ads');parser.add_argument('--output-dir',type=Path,help='Isolated candidate directory');args=parser.parse_args()
p=json.loads((ROOT/'release/google-play/release.json').read_text())
spec=importlib.util.spec_from_file_location('content',ROOT/'scripts/prepare-play-content.py');content=importlib.util.module_from_spec(spec);spec.loader.exec_module(content);content.main()
errors=content.validate(p)
if p.get('admob',{}).get('mode')!='live':errors.append('Live AdMob App ID / banner ID and published UMP messages')
elif not p['admob'].get('consent_messages_confirmed'):errors.append('Publisher must configure and verify AdMob privacy messages')
if p.get('release_stage')=='feature-preview':errors.append('Feature preview: physical audio and platform acceptance remains pending')
if errors and not args.internal:raise SystemExit('Production configuration incomplete: '+', '.join(errors))
keydir=Path.home()/'.android/keystores/pairit';keydir.mkdir(parents=True,exist_ok=True);keydir.chmod(0o700)
credentials=keydir/'upload-credentials.json';key=keydir/'upload.p12'
if credentials.exists()!=key.exists():raise SystemExit('Incomplete signing state. Restore the existing key and credentials; do not replace them.')
java_home=subprocess.check_output(['/usr/libexec/java_home','-v','21'],text=True).strip();env=os.environ.copy();env['JAVA_HOME']=java_home
keytool=str(Path(java_home)/'bin/keytool');java=str(Path(java_home)/'bin/java')
def run(command,**kwargs):subprocess.run(command,check=True,env=env,**kwargs)
if not key.exists():raise SystemExit('Existing upload key is missing. Restore its private backup; this build never creates a replacement identity.')
c=json.loads(credentials.read_text());env.update(RELAY_KEYSTORE=str(key),RELAY_STORE_PASSWORD=c['password'],RELAY_KEY_ALIAS=c['alias'],RELAY_KEY_PASSWORD=c['password'],PAIR_UPLOAD_PASSWORD=c['password'])
name='PairIt-'+p['version_name']
out=args.output_dir or ROOT/'artifacts'/(name+'-Google-Play');out=out.resolve();out.mkdir(parents=True,exist_ok=True)
with (ROOT/'artifacts/pairit-release-build.log').open('w') as log:run([str(ROOT/'android/gradlew'),'bundleRelease','assembleRelease','lintRelease','--console=plain'],cwd=ROOT/'android',stdout=log,stderr=subprocess.STDOUT)
aab=out/(name+'.aab');shutil.copy2(ROOT/'android/build/outputs/bundle/release/AudioRelay-release.aab',aab)
run([keytool,'-exportcert','-rfc','-keystore',str(key),'-storepass:env','PAIR_UPLOAD_PASSWORD','-alias',c['alias'],'-file',str(out/'upload-certificate.pem')])
with (out/'bundle-signature.txt').open('w') as log:run([str(Path(java_home)/'bin/jarsigner'),'-verify','-verbose','-certs',str(aab)],stdout=log,stderr=subprocess.STDOUT)
cache=ROOT/'artifacts/tools';cache.mkdir(exist_ok=True);bundletool=cache/'bundletool-all-1.18.3.jar'
verified_download('https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar', bundletool,
                  'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29')
with (out/'bundle-validation.txt').open('w') as log:run([java,'-jar',str(bundletool),'validate','--bundle='+str(aab)],stdout=log,stderr=subprocess.STDOUT)
# A temporary password file avoids secrets in argv/process listings. Removed immediately.
fd,secretfile=tempfile.mkstemp(prefix='pairit-signing-',dir=keydir)
try:
    with os.fdopen(fd,'w') as f:f.write(c['password'])
    apks=out/'universal.apks'
    run([java,'-jar',str(bundletool),'build-apks','--bundle='+str(aab),'--output='+str(apks),'--mode=universal','--overwrite','--ks='+str(key),'--ks-key-alias='+c['alias'],'--ks-pass=file:'+secretfile,'--key-pass=file:'+secretfile])
    with zipfile.ZipFile(apks) as z:(out/(name+'-testing.apk')).write_bytes(z.read('universal.apk'))
    apks.unlink()
finally:os.unlink(secretfile)
sdk=Path(env.get('ANDROID_HOME',Path.home()/'Library/Android/sdk'))
with (out/'apk-signature.txt').open('w') as log:run([str(sdk/'build-tools/36.0.0/apksigner'),'verify','--verbose',str(out/(name+'-testing.apk'))],stdout=log,stderr=subprocess.STDOUT)
with zipfile.ZipFile(aab) as z:native=[x for x in z.namelist() if x.endswith('.so')]
report={'name':p['app_name'],'version':p['version_name'],'version_code':p['version_code'],'application_id':p['application_id'],'target_sdk':36,'signed':True,'bundletool_validation':'passed','ad_mode':p['admob']['mode'],'production_configuration_blockers':errors,'native_libraries':native,'signing_key_location':str(keydir),'physical_audio_regression':'not evaluated by this build; see README.md','privacy_url_live':'not evaluated by this build; see release/google-play/website-verification.json','hashes':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in out.iterdir() if f.suffix in ['.aab','.apk','.pem']}}
(out/'build-report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='hashes'},indent=2))
