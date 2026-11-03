"""OpenAI-compatible streaming mock. Usage: mock_llm.py PORT LOGFILE

A user message triggers one `run` tool call (bash: echo + wc); the following
request (last message is a tool result) gets a text answer quoting it.
A user message containing "bad" makes the script use TypeScript syntax;
"fail2" makes the second request of the Turn return HTTP 500.
Summary requests return a short fixed summary without tool calls.
Set MOCK_PROMPT_TOKENS to override usage before compaction; summarized requests
report a byte-based token estimate. Thinking is on unless the request sends
thinking.type "disabled": replies then stream reasoning_content, and like
DeepSeek, a request with tools whose assistant messages lack reasoning_content
gets HTTP 400. "reject1"/"reject2" return HTTP 400 before
the first/second Step; "truncated" closes the stream without [DONE].
"delegate" runs two children; "delegate_many" runs six; "delegate_failure"
catches a failed child's error. "delegate_cancel PATH" runs a child whose bash
writes its pid to PATH and sleeps. "child probe" answers without a Run. "interrupt me" streams
partial text, then stalls for a second; "interrupt stalled" stalls for 30 seconds. "edit_test" writes and
edits files. "fetch_test" fetches GET /redirect (to /page) and
/slow (3 s) with a short timeout; GET serves those pages.
Child Runs report the exposed tools, allowing depth-limit checks.
Each request is logged to LOGFILE as one JSON line, with a monotonic received time."""
import http.server, json, os, shlex, sys, threading, time
LOG=open(sys.argv[2],'a')
LOG_LOCK = threading.Lock()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        if self.path == '/redirect':
            self.send_response(302); self.send_header('location','/page'); self.send_header('content-length','0'); self.end_headers(); return
        if self.path == '/large':
            body = b'x' * (1024 * 1024 + 10)
            self.send_response(200); self.send_header('content-type','text/plain'); self.send_header('content-length',str(len(body))); self.end_headers()
            try: self.wfile.write(body)
            except OSError: pass
            return
        if self.path == '/slow':
            time.sleep(3)
        body = '<html><head><title>t</title></head><body><nav>menu</nav><main><h1>Mock page</h1><p>Accept: ' + self.headers.get('accept','') + '</p></main></body></html>'
        self.send_response(200); self.send_header('content-type','text/html; charset=utf-8'); self.send_header('content-length',str(len(body.encode()))); self.end_headers()
        try: self.wfile.write(body.encode())
        except OSError: pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['content-length'])))
        msgs=body['messages']
        with LOG_LOCK:
            LOG.write(json.dumps({"received":time.monotonic(),"n":len(msgs),"roles":[m['role'] for m in msgs],"has_tools":(body.get('tools') or [{}])[0].get('function',{}).get('name'),
                              "messages":msgs,"thinking":body.get('thinking'),"system_has_tools_api":'const tools = {' in msgs[0].get('content','')})+"\n"); LOG.flush()
        summary = 'max_tokens' in body and not body.get('tools')
        lastuser=[m for m in msgs if m['role']=='user'][-1]['content']
        if ('reject1' in lastuser or (msgs[-1]['role']=='tool' and 'reject2' in lastuser)) and not summary:
            self.send_response(400); self.send_header('content-type','application/json'); self.end_headers(); self.wfile.write(b'{"error":"rejected"}'); return
        thinking = (body.get('thinking') or {}).get('type') != 'disabled'
        if thinking and body.get('tools') and any(m['role']=='assistant' and not m.get('reasoning_content') for m in msgs):
            self.send_response(400); self.send_header('content-type','application/json'); self.end_headers()
            self.wfile.write(b'{"error":{"message":"The reasoning_content in the thinking mode must be passed back to the API."}}'); return
        if msgs[-1]['role']=='tool' and lastuser == 'child stall2':
            time.sleep(3)
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
        elif last['role']=='user' and lastuser == 'child probe':
            if thinking: ev({"choices":[{"delta":{"reasoning_content":"Probe."}}]})
            ev({"choices":[{"delta":{"content":"probe complete"}}], "usage":{"prompt_tokens":prompt_tokens(100),"completion_tokens":10}})
        elif last['role']=='user' and lastuser in ('interrupt me', 'interrupt stalled'):
            if thinking: ev({"choices":[{"delta":{"reasoning_content":"想一想。"}}]})
            ev({"choices":[{"delta":{"content":"partial answer"}}]})
            time.sleep(30 if lastuser == 'interrupt stalled' else 1)
            try: ev({"choices":[{"delta":{"content":" never seen"}}]}); self.wfile.write(b'0\r\n\r\n')
            except OSError: pass
            return
        elif last['role']=='user':
            code = 'const r = await tools.bash({command: "echo hello from bash; printf \'a\\\\nb\\\\nc\\\\n\' | wc -l"});\nconsole.log("exit", r.exit_code);\nr.output.trim().split("\\n")'
            if lastuser.startswith('delegate_cancel '):
                code = 'await tools.agent({prompt: ' + json.dumps('child cancel ' + lastuser.split(' ', 1)[1]) + '})'
            elif lastuser.startswith('delegate_timeout '):
                code = ('await tools.agent({prompt: ' + json.dumps('child timeout ' + lastuser.split(' ', 1)[1]) +
                        ', timeout_ms: 1600}).catch(e => e.message)')
            elif lastuser == 'delegate_timeout_stall':
                code = 'await tools.agent({prompt: "child stall2", timeout_ms: 1600}).catch(e => e.message)'
            elif lastuser == 'delegate_stall':
                code = 'await tools.agent({prompt: "child stall2"})'
            elif lastuser == 'delegate_failure':
                code = 'try { await tools.agent({prompt: "child reject2"}); } catch (e) { e.message }'
            elif lastuser == 'delegate_many':
                code = 'await Promise.all(Array.from({length: 6}, (_, i) => tools.agent({prompt: "child " + i})))'
            elif lastuser == 'delegate_probe':
                code = 'await tools.agent({prompt: "child probe"})'
            elif lastuser == 'edit_test':
                code = ('await tools.write({path: "notes.txt", content: "a\\nb\\n"});\n'
                        'await tools.edit({path: "notes.txt", old_text: "b", new_text: "B"});\n'
                        'await tools.write({path: "same.txt", content: "x\\n"}); "done"')
            elif lastuser == 'output_limit_test':
                code = ('const r = await tools.bash({command: "head -c 32768 /dev/zero | tr \'\\\\0\' x"});'
                        'if (r.output.length !== 32768) throw new Error("tool data was truncated"); r.output')
            elif lastuser == 'fetch_test':
                base = 'http://127.0.0.1:' + sys.argv[1]
                code = ('const page = await tools.fetch({url: "' + base + '/redirect"});\n'
                        'const slow = await tools.fetch({url: "' + base + '/slow", timeout_ms: 300}).catch(e => e.message);\n'
                        'const large = await tools.fetch({url: "' + base + '/large", raw: true});\n'
                        '({url: page.url, status: page.status, text: page.text, truncated: page.truncated, '
                        'large: {length: large.text.length, truncated: large.truncated, clean: /^x+$/.test(large.text)}, slow})')
            elif lastuser == 'delegate':
                code = 'await Promise.all([tools.agent({prompt: "child alpha"}), tools.agent({prompt: "child beta"})])'
            elif lastuser.startswith('child '):
                command = 'sleep 0.3'
                if lastuser.startswith('child timeout '):
                    path = lastuser.split(' ', 2)[2]
                    command = 'printf partial > ' + shlex.quote(path) + '; echo $$ > ' + shlex.quote(path + '.pid') + '; exec sleep 30'
                if lastuser.startswith('child cancel '):
                    command = 'echo $$ > ' + shlex.quote(lastuser.split(' ', 2)[2]) + '; exec sleep 30'
                code = 'await tools.bash({command: ' + json.dumps(command) + '}); ({prompt: ' + json.dumps(lastuser) + ', agent: typeof tools.agent, keys: Object.keys(tools)})'
            if 'bad' in last['content']: code='const x: number = 1; x'
            args=json.dumps({"code":code})
            if thinking: ev({"choices":[{"delta":{"reasoning_content":"先用 bash 看看。"}}]})
            ev({"choices":[{"delta":{"content":"我先跑一下。"}}]})
            # stream the arguments in fragments, as real providers do
            ev({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"run","arguments":""}}]}}]})
            for i in range(0,len(args),7):
                ev({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":args[i:i+7]}}]}}]})
            ev({"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":prompt_tokens(100),"completion_tokens":20,"prompt_cache_hit_tokens":64}})
        else:
            if thinking: ev({"choices":[{"delta":{"reasoning_content":"结果出来了。"}}]})
            ev({"choices":[{"delta":{"content":"工具返回：" + last['content'].replace('\n',' | ')}}]})
            ev({"choices":[],"usage":{"prompt_tokens":prompt_tokens(150),"completion_tokens":10,"prompt_cache_hit_tokens":128}})
        if 'truncated' in lastuser:
            self.wfile.write(b'0\r\n\r\n'); return
        d=b'data: [DONE]\n\n'; self.wfile.write(b'%x\r\n'%len(d)+d+b'\r\n0\r\n\r\n')
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
