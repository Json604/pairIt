"""Account-free, bounded reporting to one public repository. No client credentials."""
import hashlib, hmac, json, os, re, sqlite3, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib import request, error

REPOSITORY = 'Json604/pairIt-download'
ISSUE_PREFIX = 'https://github.com/' + REPOSITORY + '/issues/'
PLATFORMS = {'Android', 'iOS', 'macOS', 'Windows', 'Linux'}
class Uncertain(Exception): pass
class Rejected(Exception): pass
class NoRedirect(request.HTTPRedirectHandler):
 def redirect_request(self,*args,**kwargs):raise Rejected()
def issue_url(value):
 if not isinstance(value,str) or not re.fullmatch(re.escape(ISSUE_PREFIX)+r'[1-9][0-9]*',value):raise Uncertain()
 return value
class GitHub:
 def __init__(self,token):self.token=token;self.opener=request.build_opener(NoRedirect)
 def call(self,path,data=None):
  req=request.Request('https://api.github.com/repos/'+REPOSITORY+path,data=None if data is None else json.dumps(data).encode(),headers={'Authorization':'Bearer '+self.token,'Accept':'application/vnd.github+json','Content-Type':'application/json','User-Agent':'PairIt-Reports','X-GitHub-Api-Version':'2026-03-10'})
  try:
   with self.opener.open(req,timeout=15) as result:
    raw=result.read(2_000_001)
    if len(raw)>2_000_000:raise Uncertain()
    return json.loads(raw)
  except error.HTTPError as exc:
   print("GitHub request rejected with HTTP",exc.code,flush=True)
   if exc.code in (400,401,403,404,422,429):raise Rejected() from None
   raise Uncertain() from None
  except (OSError,ValueError):raise Uncertain() from None
 def create(self,title,body):return issue_url(self.call('/issues',{'title':title,'body':body})['html_url'])
 def find(self,report_id):
  marker='<!-- pairit-report:'+report_id+' -->'
  # An uncertain request is reconciled, never blindly recreated. Include closed
  # issues so owner moderation does not turn a retry into a duplicate.
  for page in range(1,4):
   issues=self.call('/issues?state=all&sort=created&direction=desc&per_page=100&page='+str(page))
   if not isinstance(issues,list):raise Uncertain()
   for item in issues:
    if marker in (item.get('body') or ''):return issue_url(item.get('html_url'))
   if len(issues)<100:break
  return None

def validate(data):
 if not isinstance(data,dict) or set(data)!={'id','title','description','platform','context'}:raise ValueError()
 report_id=str(uuid.UUID(data['id']))
 if report_id!=data['id'] or uuid.UUID(report_id).version!=4:raise ValueError()
 for key,minimum,maximum in [('title',3,100),('description',10,4000)]:
  value=data[key]
  if not isinstance(value,str) or not minimum<=len(value.strip())<=maximum or any(ord(c)<32 and c not in '\n\t' for c in value):raise ValueError()
 if data['platform'] not in PLATFORMS:raise ValueError()
 context=data['context']
 if not isinstance(context,dict) or not set(context)<= {'version','os','state','output'}:raise ValueError()
 for value in context.values():
  if not isinstance(value,str) or len(value)>100 or any(ord(c)<32 for c in value):raise ValueError()
 return report_id

def format_issue(data):
 body='## What happened\n\n'+data['description'].strip()+'\n\n## App details\n\nPlatform: '+data['platform']+'\n'
 for key,label in [('version','App version'),('os','OS version'),('state','Playback state'),('output','Output type')]:
  if key in data['context']:
   value=data['context'][key].replace('`','').replace('<','').replace('>','')
   body+='\n'+label+': `'+value+'`\n'
 body+='\nSubmitted from PairIt. The reporter chose to publish this report. Automatic details exclude names, network addresses, pairing credentials, audio and raw logs.\n\n<!-- pairit-report:'+data['id']+' -->'
 return '['+data['platform']+'] '+data['title'].strip().replace('\n',' '),body

class Reports:
 def __init__(self,path,github,salt):
  self.path=str(path);self.github=github;self.salt=salt;self.lock=threading.Lock()
  with self.db() as db:db.execute('CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, digest TEXT NOT NULL, ip TEXT NOT NULL, created REAL NOT NULL, status TEXT NOT NULL, url TEXT, checked REAL NOT NULL DEFAULT 0)')
 def db(self):return sqlite3.connect(self.path,timeout=5)
 def submit(self,data,ip):
  try:report_id=validate(data)
  except (ValueError,TypeError,KeyError,AttributeError):return 400,{'error':'invalid','message':'Check the title and description, then try again.'}
  digest=hashlib.sha256(json.dumps(data,sort_keys=True,separators=(',',':')).encode()).hexdigest()
  ip_hash=hmac.new(self.salt,ip.encode(),hashlib.sha256).hexdigest();now=time.time()
  with self.lock:
   with self.db() as db:
    row=db.execute('SELECT digest,status,url,checked FROM reports WHERE id=?',(report_id,)).fetchone()
    if row:
     if not hmac.compare_digest(row[0],digest):return 409,{'error':'changed','message':'This report changed. Start a new report.'}
     if row[1]=='complete':return 200,{'url':row[2]}
     # Serialize reconciliation and limit upstream read calls per uncertain report.
     if row[3]>now-30:return 202,{'pending':True,'message':'Still confirming with GitHub. Try again in 30 seconds; this will not create a duplicate.'}
     db.execute('UPDATE reports SET checked=?,status=? WHERE id=?',(now,'pending',report_id));existing=row[1]!='rejected'
    else:
     hour=db.execute('SELECT COUNT(*) FROM reports WHERE ip=? AND created>?',(ip_hash,now-3600)).fetchone()[0]
     day=db.execute('SELECT COUNT(*) FROM reports WHERE ip=? AND created>?',(ip_hash,now-86400)).fetchone()[0]
     total=db.execute('SELECT COUNT(*) FROM reports WHERE created>?',(now-86400,)).fetchone()[0]
     if hour>=3 or day>=5 or total>=int(os.environ.get('REPORTS_DAILY_LIMIT','50')):return 429,{'error':'rate_limited','message':'The reporting limit has been reached. Please try later; your draft is kept.'}
     db.execute('INSERT INTO reports(id,digest,ip,created,status,checked) VALUES(?,?,?,?,?,?)',(report_id,digest,ip_hash,now,'pending',now));existing=False
  try:
   url=self.github.find(report_id) if existing else self.github.create(*format_issue(data))
   if not url:return 202,{'pending':True,'message':'Still confirming with GitHub. Try again in 30 seconds; this will not create a duplicate.'}
   url=issue_url(url)
   with self.db() as db:db.execute('UPDATE reports SET status=?,url=? WHERE id=?',('complete',url,report_id))
   return (200 if existing else 201),{'url':url}
  except Rejected:
   if not existing:
    with self.db() as db:db.execute('UPDATE reports SET status=? WHERE id=?',('rejected',report_id))
   return 503,{'error':'unavailable','message':'Reporting is temporarily unavailable. Your draft is kept.'}
  except (Uncertain,KeyError,sqlite3.Error):
   return 202,{'pending':True,'message':'Still confirming with GitHub. Try again in 30 seconds; this will not create a duplicate.'}

class BoundedServer(ThreadingHTTPServer):
 daemon_threads=True
 def handle_error(self,request,address):pass # Do not expose raw client addresses in exception logs.
 def __init__(self,*args,**kwargs):
  self.slots=threading.BoundedSemaphore(16)
  super().__init__(*args,**kwargs)
 def process_request(self,request,address):
  if not self.slots.acquire(blocking=False):self.shutdown_request(request);return
  try:super().process_request(request,address)
  except Exception:self.slots.release();raise
 def process_request_thread(self,request,address):
  try:super().process_request_thread(request,address)
  finally:self.slots.release()

class Handler(BaseHTTPRequestHandler):
 server_version='PairIt';sys_version=''
 def log_message(self,*args):pass # Never log submitted bodies, credentials or addresses.
 def setup(self):super().setup();self.connection.settimeout(10)
 def respond(self,status,value):
  data=json.dumps(value).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.send_header('Connection','close');self.end_headers();self.wfile.write(data)
 def do_GET(self):self.respond(200 if self.path=='/health' else 404,{'ok':True} if self.path=='/health' else {'error':'not_found'})
 def do_POST(self):
  if self.path!='/v1/reports':self.respond(404,{'error':'not_found'});return
  if self.headers.get('Content-Type','').split(';')[0]!='application/json':self.respond(415,{'error':'content_type'});return
  try:
   length=int(self.headers.get('Content-Length','0'))
   if not 1<=length<=24000:raise ValueError()
   raw=self.rfile.read(length)
   if len(raw)!=length:raise ValueError()
   data=json.loads(raw)
  except (ValueError,OSError):self.respond(400,{'error':'invalid'});return
  # Caddy overwrites X-Real-IP; port is reachable only on host loopback.
  ip=self.headers.get('X-Real-IP',self.client_address[0])
  try:status,body=self.server.reports.submit(data,ip)
  except Exception:status,body=503,{'error':'unavailable','message':'Reporting is temporarily unavailable. Your draft is kept.'}
  self.respond(status,body)

if __name__=='__main__':
 os.umask(0o077)
 token=os.environ['GITHUB_REPORTS_TOKEN'];salt=os.environ['REPORTS_IP_SALT'].encode()
 path=Path(os.environ.get('REPORTS_DB','/data/reports.db'));path.parent.mkdir(parents=True,exist_ok=True)
 server=BoundedServer(('0.0.0.0',8788),Handler);server.reports=Reports(path,GitHub(token),salt);server.serve_forever()
