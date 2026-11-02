"""OpenAI-compatible streaming mock. Usage: mock_llm.py PORT LOGFILE

A user message triggers one `run` tool call (bash: echo + wc); the following
request (last message is a tool result) gets a text answer quoting it.
A user message containing "bad" makes the script use TypeScript syntax;
"fail2" makes the second request of the Turn return HTTP 500.
Summary requests return a short fixed summary without tool calls.
Set MOCK_PROMPT_TOKENS to override usage before compaction; summarized requests
report a byte-based token estimate. "reject1"/"reject2" return HTTP 400 before
the first/second Step; "truncated" closes the stream without [DONE].
Each request is logged to LOGFILE as one JSON line."""
import http.server, json, os, sys, time
LOG=open(sys.argv[2],'a')
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['content-length'])))
        msgs=body['messages']
        LOG.write(json.dumps({"n":len(msgs),"roles":[m['role'] for m in msgs],"has_tools":(body.get('tools') or [{}])[0].get('function',{}).get('name'),
                              "messages":msgs,"system_has_tools_api":'const tools = {' in msgs[0].get('content','')})+"\n"); LOG.flush()
        summary = 'max_tokens' in body and not body.get('tools')
        lastuser=[m for m in msgs if m['role']=='user'][-1]['content']
        if ('reject1' in lastuser or (msgs[-1]['role']=='tool' and 'reject2' in lastuser)) and not summary:
            self.send_response(400); self.send_header('content-type','application/json'); self.end_headers(); self.wfile.write(b'{"error":"rejected"}'); return
        if msgs[-1]['role']=='tool' and 'fail2' in lastuser:
            self.send_response(500); self.send_header('content-type','application/json'); self.end_headers(); self.wfile.write(b'{"error":"boom"}'); return
        self.send_response(200); self.send_header('content-type','text/event-stream'); self.send_header('transfer-encoding','chunked'); self.end_headers()
        def ev(obj):
            d=('data: '+json.dumps(obj)+'\n\n').encode()
            self.wfile.write(b'%x\r\n'%len(d)+d+b'\r\n'); self.wfile.flush(); time.sleep(0.01)
        last=msgs[-1]
        compacted = any(m.get('content','').startswith('Earlier session summary:') for m in msgs)
        def prompt_tokens(default):
            return sum(len(m.get('content') or '') for m in msgs)//3 if compacted else int(os.environ.get('MOCK_PROMPT_TOKENS',default))
        if summary:
            ev({'choices':[{'delta':{'content':'Earlier work: ran bash successfully. Continue the user task.'}}], 'usage':{'prompt_tokens':100,'completion_tokens':15}})
        elif last['role']=='user':
            code = 'const r = await tools.bash({command: "echo hello from bash; printf \'a\\\\nb\\\\nc\\\\n\' | wc -l"});\nconsole.log("exit", r.exit_code);\nr.output.trim().split("\\n")'
            if 'bad' in last['content']: code='const x: number = 1; x'
            args=json.dumps({"code":code})
            ev({"choices":[{"delta":{"content":"我先跑一下。"}}]})
            # stream the arguments in fragments, as real providers do
            ev({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"run","arguments":""}}]}}]})
            for i in range(0,len(args),7):
                ev({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":args[i:i+7]}}]}}]})
            ev({"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":prompt_tokens(100),"completion_tokens":20,"prompt_cache_hit_tokens":64}})
        else:
            ev({"choices":[{"delta":{"content":"工具返回：" + last['content'].replace('\n',' | ')}}]})
            ev({"choices":[],"usage":{"prompt_tokens":prompt_tokens(150),"completion_tokens":10,"prompt_cache_hit_tokens":128}})
        if 'truncated' in lastuser:
            self.wfile.write(b'0\r\n\r\n'); return
        d=b'data: [DONE]\n\n'; self.wfile.write(b'%x\r\n'%len(d)+d+b'\r\n0\r\n\r\n')
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
