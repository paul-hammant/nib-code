"""Capture mock-only TUI text: python capture_design.py BINARY OUTPUT (requires pyte)."""
import shutil, fcntl, http.server, json, os, pathlib, pty, select, signal, socket, struct, subprocess, sys, termios, threading, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = pathlib.Path(sys.argv[1]).resolve()
OUT = pathlib.Path(sys.argv[2]).resolve()
CASES = ROOT/'.zig-cache/design-pass'/OUT.name
sys.path[:0] = [str(ROOT/'tests')]
if CASES.exists(): shutil.rmtree(CASES)
import pyte

OUT.mkdir(parents=True, exist_ok=True)
base = {k:v for k,v in os.environ.items() if not k.startswith(('NIB_', 'DEEPSEEK_', 'OPENAI_', 'CODEX_'))}
base.update(TERM='xterm-256color', HOME=str(CASES/'user'), CODEX_HOME=str(CASES/'codex'))
counter = 0
class Terminal:
    def __init__(self, name, port, cols=120, rows=32, extra=None):
        self.name, self.cols, self.rows = name, cols, rows
        self.cwd = CASES/name
        self.cwd.mkdir(parents=True, exist_ok=True)
        (self.cwd/'.git').touch()
        self.home = self.cwd/'home'
        self.home.mkdir(exist_ok=True)
        self.env = dict(base, NIB_PROVIDER='chat_completions', NIB_API_KEY='mock', NIB_MODEL='mock-model', NIB_CONTEXT_WINDOW='128000', NIB_BASE_URL=f'http://127.0.0.1:{port}', NIB_HOME=str(self.home))
        if extra: self.env.update(extra)
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        def tty():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        self.p = subprocess.Popen([str(BINARY)], cwd=self.cwd, env=self.env, stdin=slave, stdout=slave, stderr=slave, preexec_fn=tty)
        os.close(slave)
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.drain(1.4)
    def drain(self, duration=.2):
        until=time.monotonic()+duration
        while time.monotonic()<until:
            if select.select([self.master], [], [], min(.03,max(0,until-time.monotonic())))[0]:
                try: data=os.read(self.master, 65536)
                except OSError: break
                self.stream.feed(data)
    def wait(self, text, timeout=15):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            self.drain(.05)
            if text in '\n'.join(self.screen.display): return
        self.snap('WAIT-FAILED')
        raise RuntimeError((self.name,text,'\n'.join(self.screen.display)))
    def send(self, text):
        os.write(self.master,text.encode())
        self.drain(.15)
    def snap(self, label):
        assert self.p.poll() is None, (self.name, self.p.returncode)
        global counter
        self.drain(.1)
        counter+=1
        stem=f'{counter:02}-{self.name}-{label}'
        (OUT/(stem+'.txt')).write_text('\n'.join(x.rstrip() for x in self.screen.display)+'\n')
        print(stem,flush=True)
    def resize(self, cols, rows=32):
        self.cols,self.rows=cols,rows
        self.screen.resize(rows,cols)
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH',rows,cols,0,0))
        os.kill(self.p.pid,signal.SIGWINCH)
        self.drain(.4)
    def close(self):
        if self.p.poll() is None:
            self.send('\x03')
            try: self.p.wait(3)
            except subprocess.TimeoutExpired: self.p.kill();self.p.wait()
        self.drain(.1)
        
        os.close(self.master)
    def __enter__(self): return self
    def __exit__(self,*args): self.close()

def port():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]
def serve(script, p):
    log=(OUT/(script+'.server.txt')).open('w')
    proc=subprocess.Popen(['/usr/bin/python3',str(ROOT/'tests'/script),str(p),str(OUT/(script+'.requests.jsonl'))],env=dict(base,MOCK_PROMPT_TOKENS='3300'),stdout=log,stderr=log)
    for _ in range(100):
        try:
            with socket.create_connection(('127.0.0.1',p),timeout=.05): return proc
        except OSError: time.sleep(.02)
    raise RuntimeError('mock startup')

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['content-length'])))
        msgs=body['messages']
        user=next(m['content'] for m in reversed(msgs) if m['role']=='user' and not m.get('content','').startswith('[background'))
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
        def ev(d):
            self.wfile.write(('data: '+json.dumps({'choices':[{'delta':d}]})+'\n\n').encode());self.wfile.flush()
        def run(code):
            args=json.dumps({'code':code})
            ev({'tool_calls':[{'index':0,'id':'design-run','type':'function','function':{'name':'run','arguments':''}}]})
            for i in range(0,len(args),32):
                ev({'tool_calls':[{'index':0,'function':{'arguments':args[i:i+32]}}]});time.sleep(.08)
        try:
            if any(m['role']=='tool' for m in msgs):
                ev({'content':'Work recorded.'})
            elif user=='stages':
                ev({'reasoning_content':'Inspecting the entry point.'});time.sleep(1)
                ev({'content':'I will read and edit the sample.'});time.sleep(1)
                run('await Promise.all([tools.read({path:"sample.txt"}),tools.read({path:"sample.txt"}),tools.grep({pattern:"old",path:"."})]); await tools.edit({path:"sample.txt",old_text:"old",new_text:"new"}); await tools.bash({command:"sleep 3; exit 1"})')
            elif user=='background':
                run('await tools.bash({command:"sleep 4; echo ready",background:true})')
            elif user=='auto': run('await tools.bash({command:"sleep 4; echo ready"})')
            elif user=='supersede':
                run('await tools.bash({command:"sleep 4; echo ready",background:true}); await tools.write({path:"change.txt",content:"new"}); await tools.bash({command:"sleep 4; echo ready",background:true})')
            elif user=='long':
                run('await tools.write({path:"large.txt",content:Array.from({length:240},(_,i)=>"line "+i).join("\\n")}); for(let i=1;i<=30;i++) console.log("output line "+i); "finished"')
            else: ev({'content':'Received.'})
            self.wfile.write(b'data: {"choices":[],"usage":{"prompt_tokens":3300,"completion_tokens":30,"prompt_cache_hit_tokens":1200}}\n\ndata: [DONE]\n\n');self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): pass

def capture():
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        for cols in (60,120,160):
            with Terminal('intro-'+str(cols),server.server_port,cols) as t:
                t.snap('empty');t.send('/');t.snap('menu')
                t.send('\x15/help\r');t.snap('help')
                t.send('\x1b[200~'+''.join(f'Line {i}: keep the file structure.\n' for i in range(1,13))+'\x1b[201~');t.snap('paste')
            with Terminal('stages-'+str(cols),server.server_port,cols) as t:
                (t.cwd/'sample.txt').write_text('old\nkeep\n')
                t.send('stages\r');t.drain(.2);t.snap('thinking')
                t.drain(.8);t.snap('writing-response');t.drain(.8);t.snap('writing-run')
                t.drain(.8);t.snap('executing');t.drain(4);t.snap('collapsed-footer')
                t.send('\x0f');t.snap('expanded')
                t.send('/status\r');t.snap('status')
            for case in ('background','auto','supersede'):
                extra=None
                if case=='auto':
                    home=CASES/(case+'-'+str(cols))/'home';home.mkdir(parents=True,exist_ok=True)
                    (home/'config.toml').write_text('[limits]\nrun_background_after_ms = 500\n')
                with Terminal(case+'-'+str(cols),server.server_port,cols,extra=extra) as t:
                    t.send(case+'\r');t.drain(.8);t.snap('waiting')
                    t.send('/tasks\r');t.snap('tasks');t.drain(4.5);t.snap('completed')
            with Terminal('long-'+str(cols),server.server_port,cols) as t:
                t.send('long\r');t.drain(1.5);t.snap('collapsed');t.send('\x0f');t.snap('expanded')
                t.send('\x1b[5~');t.snap('expanded-scrolled')
                for _ in range(8): t.send('\x1b[5~')
                t.snap('expanded-top')
    finally:server.shutdown();server.server_close()
    p=port();mock=serve('mock_llm.py',p)
    try:
        for cols in (60,120,160):
            with Terminal('agents-'+str(cols),p,cols) as t:
                t.send('delegate_progress\r');t.drain(2);t.snap('running');t.drain(8);t.snap('completed')
            with Terminal('timeout-'+str(cols),p,cols) as t:
                t.send('delegate_timeout '+str(t.cwd/'partial.txt')+'\r');t.drain(5);t.snap('completed');t.send('\x0f');t.snap('expanded')
            with Terminal('cancel-'+str(cols),p,cols) as t:
                t.send('interrupt stalled\r');t.wait('partial answer');t.send('Keep my queued message\r');t.snap('queued')
                t.send('\x1b');t.drain(1);t.snap('canceled')
    finally:mock.terminate();mock.wait()
    p=port();mock=serve('mock_codex.py',p)
    try:
        auth=CASES/'fake-codex';auth.mkdir(exist_ok=True)
        (auth/'auth.json').write_text(json.dumps({'tokens':{'access_token':'fake-access','account_id':'fake-account','refresh_token':'fake-refresh','id_token':'fake-id'}}))
        extra={'NIB_PROVIDER':'codex','NIB_CODEX_TRANSPORT':'sse','NIB_MODEL':'gpt-6.1-sol','CODEX_HOME':str(auth)}
        for cols in (60,120,160):
            with Terminal('retry-'+str(cols),p,cols,extra=extra) as t:
                t.send('stream retry cancel\r');t.drain(.4);t.snap('retrying');t.send('\x1b');t.drain(.6)
                t.send('stream rate exhausted\r');t.drain(2);t.snap('failed')
                t.send('\x0f');t.snap('details')
    finally:mock.terminate();mock.wait()
    (OUT/'INDEX.txt').write_text(''.join(x.name+'\n' for x in sorted(OUT.glob('[0-9]*.txt'), key=lambda p:int(p.name.split('-')[0]))))

if __name__=='__main__': capture()
