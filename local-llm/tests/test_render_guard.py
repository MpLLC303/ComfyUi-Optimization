"""Behaviour tests for stack/render-guard/render_guard.py (stdlib only, no GPU, no ComfyUI).

A fake ComfyUI (switchable queue, VRAM held, records /free) and a fake Ollama upstream (records
request bodies, streams NDJSON) run in this process; the guard runs as a subprocess, exactly as in
its container. Exit code = number of failed checks.

    python3 tests/test_render_guard.py
"""
import base64
import http.client
import http.server
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(os.path.dirname(HERE), 'stack', 'render-guard', 'render_guard.py')
failures = 0


def check(cond, msg):
    global failures
    print(('  ASSERT OK   ' if cond else '  ASSERT FAIL ') + msg, flush=True)
    if not cond:
        failures += 1


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


# ---- fake ComfyUI ------------------------------------------------------------------------------
# queue_code / api_queue_code: HTTP status of /queue and /api/queue (ComfyUI serves both routes).
COMFY = {'running': 0, 'pending': 0, 'held_mib': 0, 'frees': 0, 'free_releases': True,
         'queue_code': 200, 'api_queue_code': 200}


class ComfyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        d = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(d)))
        self.end_headers()
        self.wfile.write(d)

    def do_GET(self):
        if self.path in ('/queue', '/api/queue'):
            code = COMFY['queue_code' if self.path == '/queue' else 'api_queue_code']
            if code != 200:
                self._json({'error': 'forbidden'}, code)
                return
            self._json({'queue_running': [[1]] * COMFY['running'], 'queue_pending': [[2]] * COMFY['pending']})
        elif self.path == '/system_stats':
            self._json({'devices': [{'torch_vram_total': COMFY['held_mib'] * 1024 * 1024}]})
        else:
            self._json({})

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        self.rfile.read(n)
        if self.path == '/free':
            COMFY['frees'] += 1
            if COMFY['free_releases']:
                COMFY['held_mib'] = 100
        self._json({})


class SlowComfyHandler(http.server.BaseHTTPRequestHandler):
    """A ComfyUI busy loading a model: /queue answers just inside the probe timeout, /system_stats
    not at all (the guard gives up on it)."""
    def log_message(self, *a):
        pass

    def do_GET(self):
        time.sleep(0.8 if self.path == '/queue' else 3)
        try:
            d = json.dumps({'queue_running': [], 'queue_pending': []} if self.path == '/queue' else {}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(d)))
            self.end_headers()
            self.wfile.write(d)
        except OSError:
            pass   # the guard stopped waiting


# ---- fake Ollama upstream ----------------------------------------------------------------------
# Runner bookkeeping with Ollama 0.35.1's rules (server/sched.go): one model loaded at a time
# (OLLAMA_MAX_LOADED_MODELS=1), and a loaded runner is REUSED when the request's num_gpu is unset
# (-1) or equal to the one it was loaded with (needsReload); only a different num_gpu >= 0 reloads.
# keep_alive 0 without messages/prompt unloads. /api/ps lists names with their tag ('m:latest')
# and size_vram > 0 even for CPU loads (it is not reliable for CPU loads on every Ollama build).
# 'slow*' models stream slowly; a pull of 'grow*' takes 1.5 s and then gives the model vision.
BODIES = []      # chat/generate request bodies (unload calls excluded)
RAW = []         # the same, as the bytes received
UNLOADS = []     # model names of unload calls, in order
EVENTS = []      # ('chat', name, num_gpu) and ('unload', name), in order
RESIDENT = {}    # loaded model -> num_gpu it was loaded with (-1 = Ollama's automatic GPU placement)
SHOW = {'hits': 0}
VISION = set()   # models (with tag) that /api/show reports with 'vision', besides 'vl*'
FAIL = {'ps': 0, 'unload': 0}    # answer the next N /api/ps or unload calls with HTTP 500
OLLAMA_LOCK = threading.Lock()


def model_key(name):
    name = str(name or '')
    return name if ':' in name.rsplit('/', 1)[-1] else name + ':latest'


def reset_ollama():
    with OLLAMA_LOCK:
        del BODIES[:], RAW[:], UNLOADS[:], EVENTS[:]
        RESIDENT.clear()
        VISION.clear()
        SHOW['hits'] = 0
        FAIL.update(ps=0, unload=0)


class OllamaHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        d = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(d)))
        self.end_headers()
        self.wfile.write(d)

    def do_GET(self):
        if self.path == '/api/ps':
            with OLLAMA_LOCK:
                fail = FAIL['ps'] > 0
                FAIL['ps'] -= int(fail)
            if fail:
                self._json({'error': 'injected'}, 500)
                return
            with OLLAMA_LOCK:
                models = [{'name': k, 'model': k, 'size_vram': 1} for k in RESIDENT]
            self._json({'models': models})
        else:
            self._json({'version': 'fake'})

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n)
        body = json.loads(raw or b'{}')
        if self.path == '/api/show':
            # 'vl*' models can see images, 'broken*' makes /api/show fail, the rest are text-only.
            SHOW['hits'] += 1
            name = str(body.get('model'))
            if name.startswith('broken'):
                self._json({'error': 'boom'}, 500)
            else:
                vision = name.startswith('vl') or model_key(name) in VISION
                self._json({'capabilities': ['completion', 'vision'] if vision else ['completion']})
            return
        if self.path == '/api/pull' and str(body.get('model')).startswith('grow'):
            time.sleep(1.5)
            VISION.add(model_key(body.get('model')))
        if self.path not in ('/api/chat', '/api/generate'):
            self._json({})
            return
        key = model_key(body.get('model'))
        if body.get('keep_alive') == 0 and not body.get('messages') and not body.get('prompt'):
            with OLLAMA_LOCK:
                fail = FAIL['unload'] > 0
                FAIL['unload'] -= int(fail)
            if fail:
                self._json({'error': 'injected'}, 500)
                return
            with OLLAMA_LOCK:
                RESIDENT.pop(key, None)
                UNLOADS.append(key)
                EVENTS.append(('unload', key))
            self._json({'model': key, 'done': True, 'done_reason': 'unload'})
            return
        ng = (body.get('options') or {}).get('num_gpu', -1)
        with OLLAMA_LOCK:
            BODIES.append(body)
            RAW.append(raw)
            EVENTS.append(('chat', key, ng))
            if not (key in RESIDENT and (ng < 0 or RESIDENT[key] == ng)):
                RESIDENT.clear()
                RESIDENT[key] = ng
        # Stream a few NDJSON lines with chunked encoding, like Ollama does.
        self.send_response(200)
        self.send_header('Content-Type', 'application/x-ndjson')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        lines = [{'message': {'content': 'tok%d' % i}, 'done': False} for i in range(5)] + [{'done': True}]
        for obj in lines:
            data = (json.dumps(obj) + '\n').encode()
            self.wfile.write(b'%x\r\n%s\r\n' % (len(data), data))
            self.wfile.flush()
            time.sleep(0.4 if key.startswith('slow') else 0.02)
        self.wfile.write(b'0\r\n\r\n')


def start(handler):
    port = free_port()
    srv = Server(('127.0.0.1', port), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, port


def silent_listener():
    """Accepts TCP connections (kernel backlog) but never answers: a ComfyUI too busy to reply."""
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    s.listen(16)
    return s, s.getsockname()[1]


def run_guard(comfy_urls, upstream_port, extra=None):
    port = free_port()
    env = dict(os.environ, UPSTREAM='http://127.0.0.1:%d' % upstream_port, COMFYUI_URLS=comfy_urls,
               LISTEN_PORT=str(port), PROBE_TIMEOUT='0.5', CACHE_SEC='0', HOLD_SEC='4',
               FREE_BACKOFF_SEC='30', WATCH_SEC='0.5', FREE_COMFYUI_MIN_MIB='1024')
    env.update(extra or {})
    p = subprocess.Popen([sys.executable, '-u', GUARD], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            socket.create_connection(('127.0.0.1', port), timeout=0.2).close()
            return p, port
        except OSError:
            time.sleep(0.1)
    raise RuntimeError('render guard did not start')


def chat(port, model='m', body=None, messages=None):
    c = http.client.HTTPConnection('127.0.0.1', port, timeout=60)
    messages = messages or [{'role': 'user', 'content': 'hi'}]
    c.request('POST', '/api/chat', body=body or json.dumps({'model': model, 'messages': messages}),
              headers={'Content-Type': 'application/json'})
    r = c.getresponse()
    lines = [json.loads(l) for l in r.read().decode().splitlines() if l.strip()]
    c.close()
    return lines


def status(port):
    c = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
    c.request('GET', '/render-guard/status')
    s = json.loads(c.getresponse().read())
    c.close()
    return s


def post(port, path, obj):
    c = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
    c.request('POST', path, body=json.dumps(obj), headers={'Content-Type': 'application/json'})
    data = c.getresponse().read()
    c.close()
    return data


def last_num_gpu():
    return (BODIES[-1].get('options') or {}).get('num_gpu')


def image_chat(model):
    return json.dumps({'model': model, 'stream': True, 'messages': [
        {'role': 'user', 'content': 'what is this error?', 'images': ['aGVsbG8=']},
        {'role': 'assistant', 'content': 'A missing DLL.'},
        {'role': 'user', 'content': 'fix it'}]})


def wait_for(cond, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if cond():
            return True
        time.sleep(0.1)
    return cond()


def main():
    _, up_port = start(OllamaHandler)
    _, comfy_port = start(ComfyHandler)
    comfy = 'http://127.0.0.1:%d' % comfy_port

    print('\n=== idle ComfyUI: chats stay on the GPU, streaming is relayed ===', flush=True)
    guard, gport = run_guard(comfy, up_port)
    try:
        lines = chat(gport)
        check(len(lines) == 6 and lines[-1].get('done') is True, 'streamed answer relayed completely (%d lines)' % len(lines))
        check(last_num_gpu() is None, 'idle ComfyUI: no num_gpu added')

        print('\n=== busy ComfyUI: chats go to the CPU, then back after the hold ===', flush=True)
        COMFY['running'] = 1
        check(wait_for(lambda: 'm:latest' not in RESIDENT, 3), 'render started: the idle chat model is unloaded from VRAM')
        chat(gport)
        check(last_num_gpu() == 0, 'running job: num_gpu 0 added')
        check(RESIDENT.get('m:latest') == 0, 'running job: the model was reloaded on the CPU')
        unloads_before = len(UNLOADS)
        time.sleep(1.5)
        check(RESIDENT.get('m:latest') == 0 and len(UNLOADS) == unloads_before,
              "during the render the watcher keeps the guard's own CPU copy ('m' = 'm:latest' in /api/ps)")
        COMFY['running'] = 0
        chat(gport)
        check(last_num_gpu() == 0, 'within HOLD_SEC after the job: still on the CPU')
        last_cpu = len(EVENTS)
        check(wait_for(lambda: 'm:latest' not in RESIDENT, 7),
              'after HOLD_SEC the watcher unloads the CPU copy, with no chat needed (unloads: %s)' % UNLOADS)
        chat(gport)
        check(last_num_gpu() is None, 'after HOLD_SEC: no num_gpu added')
        check(('unload', 'm:latest') in EVENTS[last_cpu:] and RESIDENT.get('m:latest') == -1,
              'after HOLD_SEC: the chat gets a fresh GPU load, not the reused CPU runner (resident: %s)' % RESIDENT)

        print('\n=== idle ComfyUI holding VRAM is asked to free it, with back-off ===', flush=True)
        COMFY['held_mib'] = 8000
        COMFY['frees'] = 0
        chat(gport)
        check(COMFY['frees'] == 1, '/free called once for an idle ComfyUI holding 8000 MiB')
        COMFY['held_mib'] = 8000
        COMFY['free_releases'] = False
        chat(gport)
        frees_after_failed = COMFY['frees']
        chat(gport)
        check(COMFY['frees'] == frees_after_failed, 'a /free that did not help is not repeated at once (back-off)')
        COMFY['held_mib'] = 0
        COMFY['free_releases'] = True

        print('\n=== an attached image reaches Ollama unchanged, on the GPU and on the CPU ===', flush=True)
        # About 2 MB of base64, like a phone photo Open WebUI has turned into Ollama's 'images' field.
        img = base64.b64encode(os.urandom(1536 * 1024)).decode()
        VISION.add(model_key('localai-vision'))   # a vision model: the guard must not drop its images
        for busy in (0, 1):
            COMFY['running'] = busy
            t0 = time.time()
            done = chat(gport, 'localai-vision', messages=[{'role': 'user', 'content': 'What colour?', 'images': [img]}])[-1].get('done')
            sent = BODIES[-1]['messages'][0].get('images')
            check(done is True and sent == [img] and (last_num_gpu() == 0) == bool(busy) and time.time() - t0 < 5,
                  'image passed through byte-identical with ComfyUI %s (num_gpu %s, %.1f s)' % ('busy' if busy else 'idle', last_num_gpu(), time.time() - t0))
        COMFY['running'] = 0

        print('\n=== 20 concurrent streamed chats ===', flush=True)
        results = []

        def one():
            try:
                results.append(chat(gport)[-1].get('done') is True)
            except Exception:
                results.append(False)
        ts = [threading.Thread(target=one) for _ in range(20)]
        for t in ts:
            t.start()
        for t in ts:
            t.join(60)
        check(len(results) == 20 and all(results), 'all 20 concurrent streams finished (%d ok)' % sum(results))
        time.sleep(0.3)
        check(status(gport)['inflight'] == 0, 'in-flight counter back to 0')
    finally:
        guard.terminate()
        guard.wait(10)

    print('\n=== no watcher: the first chats after the hold unload the CPU copy exactly once ===', flush=True)
    reset_ollama()
    guard, gport = run_guard(comfy, up_port, {'WATCH_SEC': '1000'})
    try:
        COMFY['running'] = 1
        chat(gport, 'm2')
        check(RESIDENT.get('m2:latest') == 0, 'render: m2 loaded on the CPU')
        COMFY['running'] = 0
        time.sleep(4.5)
        first = len(EVENTS)
        results = []
        ts = [threading.Thread(target=lambda: results.append(chat(gport, 'm2')[-1].get('done') is True)) for _ in range(2)]
        for t in ts:
            t.start()
        for t in ts:
            t.join(60)
        after = EVENTS[first:]
        chats = [e for e in after if e[0] == 'chat']
        check(len(results) == 2 and all(results), 'both post-hold chats answered')
        check(after.count(('unload', 'm2:latest')) == 1, 'two concurrent post-hold chats: exactly one unload (%s)' % after)
        check(bool(after) and after[0] == ('unload', 'm2:latest') and all(e[2] == -1 for e in chats),
              'the unload reaches Ollama before either chat, and neither carries num_gpu')
        check(RESIDENT.get('m2:latest') == -1, 'm2 is loaded fresh with automatic GPU placement (%s)' % RESIDENT)
        check(status(gport)['on_cpu'] == [], 'status: no model left marked as on the CPU')

        print('\n=== CPU copy evicted, then a chat while another request streams ===', flush=True)
        COMFY['running'] = 1
        chat(gport, 'm3')
        check(RESIDENT.get('m3:latest') == 0, 'render: m3 loaded on the CPU')
        COMFY['running'] = 0
        time.sleep(4.5)
        slow = threading.Thread(target=lambda: chat(gport, 'slow'))
        slow.start()
        check(wait_for(lambda: 'slow:latest' in RESIDENT, 5), 'another model loads and evicts the CPU copy of m3')
        chat(gport, 'm3')
        check(RESIDENT.get('m3:latest') == -1 and status(gport)['on_cpu'] == [],
              'm3 chatted while that model streams: loaded on the GPU and no longer marked as on the CPU (%s)' % RESIDENT)
        slow.join(30)
        first = len(EVENTS)
        chat(gport, 'm3')
        check(('unload', 'm3:latest') not in EVENTS[first:] and RESIDENT.get('m3:latest') == -1,
              "the next chat keeps m3's GPU copy: no unload, no reload (%s)" % EVENTS[first:])
    finally:
        guard.terminate()
        guard.wait(10)

    print('\n=== Ollama errors while unloading the CPU copy ===', flush=True)
    reset_ollama()
    guard, gport = run_guard(comfy, up_port)
    try:
        COMFY['running'] = 1
        chat(gport)
        check(RESIDENT.get('m:latest') == 0, 'render: m loaded on the CPU')
        COMFY['running'] = 0
        time.sleep(1)       # inside HOLD_SEC: the watcher leaves Ollama alone until it ends
        FAIL.update(ps=1, unload=1)
        check(wait_for(lambda: 'm:latest' not in RESIDENT, 12),
              'a 500 from /api/ps, then from the unload call: the watcher retries and unloads the CPU copy')
        check(FAIL == {'ps': 0, 'unload': 0}, 'both injected errors reached the guard (%s)' % FAIL)
        chat(gport)
        check(RESIDENT.get('m:latest') == -1, 'the next chat loads m fresh with GPU placement (%s)' % RESIDENT)
        COMFY['running'] = 1
        chat(gport)
        COMFY['running'] = 0
        time.sleep(1)
        FAIL['unload'] = 100
        check(wait_for(lambda: status(gport)['on_cpu'] == [], 15),
              'the unload call keeps failing: the guard stops trying after a while')
        check(100 - FAIL['unload'] == 5, 'it gave up after 5 tries, not after the first error (%d tries)' % (100 - FAIL['unload']))
    finally:
        FAIL.update(ps=0, unload=0)
        COMFY['running'] = 0
        guard.terminate()
        guard.wait(10)

    print('\n=== images in a chat sent to a model without vision ===', flush=True)
    reset_ollama()
    # RENDER_GUARD_MODE=off: the image fix does not depend on the GPU routing mode.
    guard, gport = run_guard(comfy, up_port, {'RENDER_GUARD_MODE': 'off'})
    try:
        sent = image_chat('text')
        lines = chat(gport, body=sent)
        fwd = BODIES[-1]['messages']
        check(lines and lines[-1].get('done') is True, 'text-only model: the chat is answered')
        check(not any('images' in m for m in fwd), 'text-only model: no images forwarded')
        check('image omitted' in fwd[0]['content'] and fwd[0]['content'].startswith('what is this error?'),
              'text-only model: the message says the image was left out')
        check(fwd[1:] == json.loads(sent)['messages'][1:], 'text-only model: the other messages are unchanged')
        sent = image_chat('vl')
        chat(gport, body=sent)
        check(RAW[-1] == sent.encode(), 'vision model: the request is forwarded byte for byte')
        sent = image_chat('broken')
        lines = chat(gport, body=sent)
        check(RAW[-1] == sent.encode() and lines and lines[-1].get('done') is True,
              '/api/show fails: the request passes through unchanged (fail open)')
        hits = SHOW['hits']
        chat(gport, body=image_chat('text:latest'))
        check(SHOW['hits'] == hits and 'images' not in BODIES[-1]['messages'][0],
              "capabilities are cached ('text' = 'text:latest')")
        post(gport, '/api/pull', {'model': 'text', 'stream': False})
        chat(gport, body=image_chat('text'))
        check(SHOW['hits'] == hits + 1, 'a pull through the guard clears the capability cache')
        hits = SHOW['hits']
        chat(gport, 'text')
        check(SHOW['hits'] == hits, 'chats without images never ask /api/show')
        # A pull that changes the model: an image chat sent while it runs caches the old list.
        pull = threading.Thread(target=lambda: post(gport, '/api/pull', {'model': 'grow', 'stream': False}))
        pull.start()
        time.sleep(0.5)
        chat(gport, body=image_chat('grow'))
        check('images' not in BODIES[-1]['messages'][0], 'during the pull: grow has no vision yet, images dropped')
        pull.join(30)
        sent = image_chat('grow')
        chat(gport, body=sent)
        check(RAW[-1] == sent.encode(), 'after the pull through the guard: capabilities read again, the images reach the model')
    finally:
        guard.terminate()
        guard.wait(10)

    print('\n=== a model given vision on Ollama directly (not through the guard) ===', flush=True)
    reset_ollama()
    guard, gport = run_guard(comfy, up_port, {'RENDER_GUARD_MODE': 'off', 'CAPS_NO_VISION_TTL_SEC': '1'})
    try:
        chat(gport, body=image_chat('direct'))
        check('images' not in BODIES[-1]['messages'][0], 'text-only at first: images dropped')
        VISION.add('direct:latest')     # e.g. Update-Models.ps1 re-created it with 'ollama create'
        time.sleep(1.3)
        sent = image_chat('direct')
        chat(gport, body=sent)
        check(RAW[-1] == sent.encode(), 'a list without vision expires after CAPS_NO_VISION_TTL_SEC: the images now reach the model')
    finally:
        guard.terminate()
        guard.wait(10)

    print('\n=== ComfyUI that refuses /queue ===', flush=True)
    reset_ollama()
    guard, gport = run_guard(comfy, up_port)
    try:
        COMFY.update(running=1, queue_code=403)
        chat(gport)
        check(last_num_gpu() == 0, '403 on /queue, a job on /api/queue: the chat runs on the CPU')
        COMFY.update(running=0, api_queue_code=403)
        time.sleep(4.5)
        chat(gport)
        check(last_num_gpu() is None, 'neither route readable: chats stay on the GPU (not stuck on the CPU)')
        inst = ((status(gport)['comfyui'] or {}).get('instances') or [{}])[0]
        check(bool(inst.get('unreadable')) and inst.get('busy') is False,
              'status shows that instance as unreadable, not busy (%s)' % inst)
    finally:
        COMFY.update(running=0, queue_code=200, api_queue_code=200)
        guard.terminate()
        guard.wait(10)

    print('\n=== ComfyUI that accepts connections but does not answer = busy ===', flush=True)
    sil, sil_port = silent_listener()
    guard, gport = run_guard('http://127.0.0.1:%d' % sil_port, up_port)
    try:
        chat(gport)
        check(last_num_gpu() == 0, 'connected but silent (loading a checkpoint): treated as busy')
    finally:
        guard.terminate()
        guard.wait(10)
        sil.close()

    print('\n=== unreachable ComfyUI host is NOT busy ===', flush=True)
    # 10.255.255.1 never answers (blackhole or no route); a closed local port refuses.
    closed = free_port()
    guard, gport = run_guard('http://10.255.255.1:8188,http://127.0.0.1:%d' % closed, up_port)
    try:
        t0 = time.time()
        chat(gport)
        took = time.time() - t0
        check(last_num_gpu() is None, 'blackholed / closed ComfyUI URLs: chats stay on the GPU')
        s = status(gport)
        check(not (s['comfyui'] or {}).get('busy'), 'status reports ComfyUI not busy')
        check(took < 5, 'the probe gives up quickly (%.1f s)' % took)
    finally:
        guard.terminate()
        guard.wait(10)

    print('\n=== status page with slow ComfyUIs: within the time the nightly backup waits for it ===', flush=True)
    # Backup-OpenWebUI.ps1 (and the nightly model re-check) ask /render-guard/status, through
    # Get-LaiChatsInFlight, how many chats are being answered before they stop Open WebUI or unload
    # the models. The page probes every ComfyUI first; if they give up sooner they do not wait,
    # which happens exactly while ComfyUI is busy and chats run slowly on the CPU.
    root = os.path.dirname(HERE)
    with open(os.path.join(root, 'lib', 'LocalAI.psm1'), encoding='utf-8') as f:
        lib = f.read()
    m = re.search(r"render-guard/status',timeout=(\d+)", lib)
    backup_limit = int(m.group(1)) if m else 0
    m = re.search(r'function Get-LaiDockerTimeout \{.*?\$s = (\d+)', lib, re.S)
    docker_limit = int(m.group(1)) if m else 0
    _, slow1 = start(SlowComfyHandler)
    _, slow2 = start(SlowComfyHandler)
    # Two URLs (the default list has two) and the default PROBE_TIMEOUT of 1 s.
    guard, gport = run_guard('http://127.0.0.1:%d,http://127.0.0.1:%d' % (slow1, slow2), up_port, {'PROBE_TIMEOUT': '1.0'})
    try:
        t0 = time.time()
        s = status(gport)
        took = time.time() - t0
        check(s.get('inflight') == 0, 'status answered with the in-flight count')
        check(backup_limit > 0 and took * 2 <= backup_limit,
              'status took %.1f s; the backup waits %d s for it (needs 2x headroom for docker exec on a busy PC)' % (took, backup_limit))
        check(backup_limit > 0 and docker_limit > 0 and backup_limit + 5 <= docker_limit,
              "the backup's status wait (%d s) ends well inside its docker exec limit (%d s)" % (backup_limit, docker_limit))
    finally:
        guard.terminate()
        guard.wait(10)

    print('\n=== docker stop: SIGTERM ends the guard at once ===', flush=True)
    guard, gport = run_guard(comfy, up_port)
    t0 = time.time()
    guard.terminate()
    code = guard.wait(10)
    check(code == 0 and time.time() - t0 < 3, 'SIGTERM: clean exit 0 in %.1f s' % (time.time() - t0))

    print('\nRENDER GUARD TEST %s' % ('PASSED' if failures == 0 else 'FAILED (%d)' % failures), flush=True)
    return failures


if __name__ == '__main__':
    sys.exit(main())
