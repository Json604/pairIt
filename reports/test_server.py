import importlib.util, tempfile, unittest, uuid
from pathlib import Path
spec=importlib.util.spec_from_file_location('reports_server',Path(__file__).with_name('server.py'))
server=importlib.util.module_from_spec(spec);spec.loader.exec_module(server)
class GitHub:
 def __init__(self):self.created=[];self.uncertain=False
 def create(self,title,body):
  self.created.append((title,body))
  if self.uncertain:raise server.Uncertain()
  return 'https://github.com/Json604/pairIt-download/issues/42'
 def find(self,report_id):return None
class Reports(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.github=GitHub();self.app=server.Reports(Path(self.temp.name)/'reports.db',self.github,b'test-secret')
 def tearDown(self):self.temp.cleanup()
 def payload(self):return {'id':str(uuid.uuid4()),'title':'Audio stops','description':'Play a video and pause one phone. The second phone stops too.','platform':'Android','context':{'version':'1.1.0 (32)','os':'Android 16','state':'PLAYING','output':'speaker'}}
 def test_repeat_returns_same_issue(self):
  p=self.payload();a=self.app.submit(p,'127.0.0.1');b=self.app.submit(p,'127.0.0.1');self.assertEqual(a[1]['url'],b[1]['url']);self.assertEqual(len(self.github.created),1)
 def test_same_id_different_body_rejected(self):
  p=self.payload();self.app.submit(p,'127.0.0.1');p['description']='Something else entirely';self.assertEqual(self.app.submit(p,'127.0.0.1')[0],409)
 def test_only_fixed_context_and_repo(self):
  p=self.payload();p['context']['token']='private';self.assertEqual(self.app.submit(p,'127.0.0.1')[0],400);self.assertEqual(self.github.created,[])
 def test_no_context_allowed(self):
  p=self.payload();p['context']={};self.assertEqual(self.app.submit(p,'127.0.0.1')[0],201)
 def test_rate_limit(self):
  for _ in range(3):self.assertEqual(self.app.submit(self.payload(),'127.0.0.1')[0],201)
  self.assertEqual(self.app.submit(self.payload(),'127.0.0.1')[0],429)
 def test_uncertain_never_blindly_posts_again(self):
  p=self.payload();self.github.uncertain=True
  self.assertEqual(self.app.submit(p,'127.0.0.1')[0],202)
  self.assertEqual(self.app.submit(p,'127.0.0.1')[0],202);self.assertEqual(len(self.github.created),1)
 def test_uncertain_reconciles(self):
  p=self.payload();self.github.uncertain=True;self.app.submit(p,'127.0.0.1')
  with self.app.db() as db:db.execute('UPDATE reports SET checked=0')
  self.github.find=lambda report_id:'https://github.com/Json604/pairIt-download/issues/43'
  self.assertEqual(self.app.submit(p,'127.0.0.1')[1]['url'],'https://github.com/Json604/pairIt-download/issues/43');self.assertEqual(len(self.github.created),1)
 def test_definitive_rejection_can_retry_after_cooldown(self):
  p=self.payload();original=self.github.create
  def reject(*args):raise server.Rejected()
  self.github.create=reject;self.assertEqual(self.app.submit(p,'local')[0],503)
  with self.app.db() as db:db.execute('UPDATE reports SET checked=0')
  self.github.create=original;self.assertEqual(self.app.submit(p,'local')[0],201)
 def test_invalid_issue_destination_is_not_success(self):
  self.github.create=lambda *args:'https://example.com/issues/1'
  self.assertEqual(self.app.submit(self.payload(),'local')[0],202)
 def test_validation(self):
  for key,value in [('id','bad'),('title',''),('description',''),('platform','arbitrary'),('title','x'*101),('description','x'*4001)]:
   p=self.payload();p[key]=value;self.assertEqual(self.app.submit(p,'127.0.0.1')[0],400)

class DeviceQuota(Reports):
 def test_five_per_installation_across_networks(self):
  identity=str(uuid.uuid4())
  for n in range(5):
   p=self.payload();p['installationId']=identity
   code,result=self.app.submit(p,str(n));self.assertEqual(code,201);self.assertEqual(result['remaining'],4-n)
  p=self.payload();p['installationId']=identity
  code,result=self.app.submit(p,'other-network');self.assertEqual(code,429);self.assertEqual(result['error'],'device_limit');self.assertGreater(result['retryAfter'],86390)
  other=self.payload();other['installationId']=str(uuid.uuid4());self.assertEqual(self.app.submit(other,'other-network')[0],201)
  self.assertEqual(self.app.quota({'installationId':identity})[1]['remaining'],0)
  self.assertNotIn(identity,str(self.github.created))
  with self.app.db() as db:self.assertNotIn(identity,str(db.execute('SELECT * FROM reports').fetchall()))
 def test_quota_expiry_and_idempotency(self):
  identity=str(uuid.uuid4());p=self.payload();p['installationId']=identity
  self.app.submit(p,'local');self.app.submit(p,'local')
  self.assertEqual(self.app.quota({'installationId':identity})[1]['remaining'],4)
  with self.app.db() as db:db.execute('UPDATE reports SET created=created-86401')
  self.assertEqual(self.app.quota({'installationId':identity})[1]['remaining'],5)
 def test_next_slot_uses_oldest_report_expiry(self):
  from unittest.mock import patch
  identity=str(uuid.uuid4())
  for n in range(5):
   p=self.payload();p['installationId']=identity
   with patch.object(server.time,'time',return_value=100000+n*60):self.app.submit(p,'local')
  with patch.object(server.time,'time',return_value=100300):
   quota=self.app.quota({'installationId':identity})[1];self.assertEqual(quota['retryAfter'],86100)
  with patch.object(server.time,'time',return_value=186400):self.assertEqual(self.app.quota({'installationId':identity})[1]['remaining'],1)
 def test_rejected_retry_cannot_bypass_full_quota(self):
  identity=str(uuid.uuid4());p=self.payload();p['installationId']=identity;original=self.github.create
  def reject(*args):raise server.Rejected()
  self.github.create=reject;self.app.submit(p,'local');self.github.create=original
  for n in range(5):
   q=self.payload();q['installationId']=identity;self.assertEqual(self.app.submit(q,'local')[0],201)
  with self.app.db() as db:db.execute('UPDATE reports SET checked=0')
  self.assertEqual(self.app.submit(p,'local')[0],429)
 def test_invalid_identity(self):
  p=self.payload();p['installationId']='hardware-serial';self.assertEqual(self.app.submit(p,'local')[0],400)
  self.assertEqual(self.app.quota({'installationId':'bad'})[0],400)

class HTTPReports(unittest.TestCase):
 def setUp(self):
  import threading
  self.temp=tempfile.TemporaryDirectory();self.github=GitHub()
  self.http=server.BoundedServer(('127.0.0.1',0),server.Handler)
  self.http.reports=server.Reports(Path(self.temp.name)/'http.db',self.github,b'test')
  self.thread=threading.Thread(target=self.http.serve_forever,daemon=True);self.thread.start()
 def tearDown(self):self.http.shutdown();self.http.server_close();self.thread.join();self.temp.cleanup()
 def post(self,body,content='application/json'):
  import http.client,json
  connection=http.client.HTTPConnection('127.0.0.1',self.http.server_port,timeout=2)
  connection.request('POST','/v1/reports',body,{'Content-Type':content});response=connection.getresponse();status=response.status;data=response.read();connection.close();return status,json.loads(data)
 def test_http_retry_and_privacy(self):
  import json
  payload={'id':str(uuid.uuid4()),'title':'Test report','description':'A synthetic report for testing.','platform':'iOS','context':{}}
  a=self.post(json.dumps(payload));b=self.post(json.dumps(payload));self.assertEqual(a[0],201);self.assertEqual(b[0],200);self.assertEqual(a[1],b[1]);self.assertEqual(len(self.github.created),1)
  with self.http.reports.db() as db:
   stored=str(db.execute('SELECT * FROM reports').fetchall());self.assertNotIn(payload['description'],stored);self.assertNotIn('127.0.0.1',stored)
 def test_http_rejects_invalid_bodies_without_upstream(self):
  for body,content,expected in [('x','text/plain',415),('no-json','application/json',400),('x'*24001,'application/json',400),('{}','application/json',400)]:
   self.assertEqual(self.post(body,content)[0],expected)
  self.assertEqual(self.github.created,[])

if __name__=='__main__':unittest.main()
