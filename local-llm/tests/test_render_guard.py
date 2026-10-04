"""Behaviour tests for stack/render-guard/render_guard.py (stdlib only, no GPU, no ComfyUI).

A fake ComfyUI (switchable queue, VRAM held, records /free) and a fake Ollama upstream (records
request bodies, streams NDJSON) run in this process; the guard runs as a subprocess, exactly as in
its container. Exit code = number of failed checks.

    python3 tests/test_render_guard.py
"""
import http.client
import http.server
import json
import os
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
COMFY = {'running': 0, 'pending': 0, 'held_mib': 0, 'frees': 0, 'free_releases': True}


class ComfyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj):
        d = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(d)))
        self.end_headers()
        self.wfile.write(d)

    def do_GET(self):
        if self.path == '/queue':
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


# ---- fake Ollama upstream ----------------------------------------------------------------------
BODIES = []


class OllamaHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def do_GET(self):
        d = json.dumps({'models': []} if self.path == '/api/ps' else {'version': 'fake'}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(d)))
        self.end_headers()
        self.wfile.write(d)

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        BODIES.append(body)
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
            time.sleep(0.02)
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
               LISTEN_PORT=str(port), PROBE_TIMEOUT='0.5', CACHE_SEC='0', HOLD_SEC='2',
               FREE_BACKOFF_SEC='30', WATCH_SEC='0.5', FREE_COMFYUI_MIN_MIB='1024')
    env.update(extra or {})
    p = subprocess.Popen([sys.executable, '-u', GUARD], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for _ in range(50):
        try:
            socket.create_connection(('127.0.0.1', port), timeout=0.2).close()
            return p, port
        except OSError:
            time.sleep(0.1)
    raise RuntimeError('render guard did not start')


def chat(port, model='m'):
    c = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
    c.request('POST', '/api/chat', body=json.dumps({'model': model, 'messages': [{'role': 'user', 'content': 'hi'}]}),
              headers={'Content-Type': 'application/json'})
    r = c.getresponse()
    lines = [json.loads(l) for l in r.read().decode().splitlines() if l.strip()]
    c.close()
    return lines


def status(port):
    c = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    c.request('GET', '/render-guard/status')
    s = json.loads(c.getresponse().read())
    c.close()
    return s


def last_num_gpu():
    return (BODIES[-1].get('options') or {}).get('num_gpu')


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
        chat(gport)
        check(last_num_gpu() == 0, 'running job: num_gpu 0 added')
        COMFY['running'] = 0
        chat(gport)
        check(last_num_gpu() == 0, 'within HOLD_SEC after the job: still on the CPU')
        time.sleep(2.5)
        chat(gport)
        check(last_num_gpu() is None, 'after HOLD_SEC: back on the GPU')

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
