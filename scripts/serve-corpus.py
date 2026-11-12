#!/usr/bin/env python3
"""Loopback-only media server with byte ranges and local observation logging."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import re
import threading

ROOT=Path(__file__).resolve().parent.parent
PUBLIC=ROOT/'artifacts/corpus/public'
REPORTS=ROOT/'artifacts/corpus/reports.jsonl'
LOCK=threading.Lock()
PORT=8765

class Handler(SimpleHTTPRequestHandler):
    def __init__(self,*args,**kw):
        self.byte_range=None
        super().__init__(*args,directory=str(PUBLIC),**kw)
    def log_message(self,format,*args):
        if len(args)>1 and str(args[1]).startswith(('4','5')): super().log_message(format,*args)
    def send_head(self):
        path=Path(self.translate_path(self.path))
        requested=self.headers.get('Range')
        if not requested or not path.is_file(): return super().send_head()
        match=re.fullmatch(r'bytes=(\d*)-(\d*)',requested.strip())
        size=path.stat().st_size
        if not match or not size:
            self.send_error(416);return None
        a,b=match.groups()
        if not a and not b: self.send_error(416);return None
        if a: start=int(a);end=min(int(b) if b else size-1,size-1)
        else: start=max(0,size-int(b));end=size-1
        if start>=size or start>end:
            self.send_response(416);self.send_header('Content-Range',f'bytes */{size}');self.end_headers();return None
        file=path.open('rb');file.seek(start);self.byte_range=(start,end)
        self.send_response(206);self.send_header('Content-Type',self.guess_type(str(path)))
        self.send_header('Content-Range',f'bytes {start}-{end}/{size}')
        self.send_header('Content-Length',str(end-start+1));self.send_header('Accept-Ranges','bytes');self.end_headers()
        return file
    def copyfile(self,source,outputfile):
        try:
            if self.byte_range is None: return super().copyfile(source,outputfile)
            remaining=self.byte_range[1]-self.byte_range[0]+1
            while remaining:
                data=source.read(min(256*1024,remaining))
                if not data: break
                outputfile.write(data);remaining-=len(data)
        except (BrokenPipeError,ConnectionResetError): pass
    def do_POST(self):
        if self.path!='/api/reports': self.send_error(404);return
        if self.headers.get('Origin')!=f'http://127.0.0.1:{PORT}': self.send_error(403);return
        try:
            length=int(self.headers.get('Content-Length','0'))
            if not 0<length<=16384: raise ValueError('Invalid length')
            row=json.loads(self.rfile.read(length))
            if not isinstance(row,dict) or not isinstance(row.get('id'),str) or not isinstance(row.get('kind'),str): raise ValueError('Invalid report')
            with LOCK, REPORTS.open('a') as file: file.write(json.dumps(row,ensure_ascii=False)+'\n')
        except (ValueError,TypeError): self.send_error(400);return
        self.send_response(204);self.end_headers()

if __name__=='__main__':
    if not PUBLIC.joinpath('manifest.js').exists(): raise SystemExit('Build the corpus first.')
    server=ThreadingHTTPServer(('127.0.0.1',PORT),Handler)
    print(f'Listening corpus: http://127.0.0.1:{PORT}',flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()
