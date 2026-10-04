"""Render guard: a tiny pass-through proxy between Open WebUI and Ollama.

Problem it solves: a 30B chat model needs ~20 GiB of the RTX 3090. If you chat while ComfyUI is
rendering, Ollama grabs whatever VRAM is left (or the driver spills into system RAM) and the
render slows to a crawl or runs out of memory.

What it does:
  * Chat/generate request while ComfyUI has a job running or queued (or answered too slowly to
    tell, or was busy less than HOLD_SEC ago) -> add options.num_gpu = 0, so Ollama answers on
    the CPU and leaves the GPU to the render. Qwen3 30B-A3B is a mixture-of-experts model (~3B
    active parameters per token), so this is slower but usable on a fast desktop CPU.
  * Chat/generate request while ComfyUI is idle but still caches models in VRAM -> ask ComfyUI
    to free them (POST /free) and wait briefly, so the chat model loads fully onto the GPU.
  * A render starts while a chat model sits idle in VRAM -> unload it (background watcher).
  * ComfyUI not running -> everything passes through untouched.
Model list, pulls, embeddings and unload calls always pass through unchanged. Unlike an Open
WebUI filter function, this also covers Open WebUI's background calls (titles, tags, web-search
queries), which go straight to Ollama.

Standard library only. Configuration via environment variables (see CONFIG below).
Status page: GET /render-guard/status
"""
import errno
import http.client
import json
import os
import select
import signal
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _env_bool(name, default):
    return os.environ.get(name, default).strip().lower() not in ('0', 'false', 'no', 'off', '')


CONFIG = {
    'upstream': os.environ.get('UPSTREAM', 'http://host.docker.internal:11434').rstrip('/'),
    'comfyui_urls': [u.strip().rstrip('/') for u in os.environ.get(
        'COMFYUI_URLS', 'http://host.docker.internal:8188,http://host.docker.internal:8000').split(',') if u.strip()],
    'mode': os.environ.get('RENDER_GUARD_MODE', 'cpu').strip().lower(),   # cpu | off
    'free_idle': _env_bool('FREE_COMFYUI_WHEN_IDLE', '1'),
    'unload_on_render': _env_bool('UNLOAD_ON_RENDER', '1'),
    'free_min_mib': int(os.environ.get('FREE_COMFYUI_MIN_MIB', '1024')),
    'listen_port': int(os.environ.get('LISTEN_PORT', '11434')),
    'probe_timeout': float(os.environ.get('PROBE_TIMEOUT', '1.0')),
    'cache_sec': float(os.environ.get('CACHE_SEC', '2')),
    'hold_sec': float(os.environ.get('HOLD_SEC', '60')),
    'free_backoff_sec': float(os.environ.get('FREE_BACKOFF_SEC', '300')),
    'watch_sec': float(os.environ.get('WATCH_SEC', '5')),
}
GUARDED_PATHS = ('/api/chat', '/api/generate')
HOP_BY_HOP = {'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te',
              'trailer', 'trailers', 'transfer-encoding', 'upgrade', 'content-length', 'host'}

_lock = threading.Lock()
_cache = {'at': 0.0, 'value': None}
_last_busy = {'at': 0.0}
_free_attempts = {}          # ComfyUI url -> (time, held_mib) of the last /free that did not help
_inflight = {'n': 0}
_cpu_models = {}             # model name -> time it was last sent to the CPU by the guard
_stats = {'started': time.strftime('%Y-%m-%dT%H:%M:%S'), 'requests': 0, 'cpu_routed': 0,
          'comfy_freed': 0, 'ollama_unloaded': 0, 'last_action': None}


def log(msg):
    sys.stdout.write('%s %s\n' % (time.strftime('%Y-%m-%dT%H:%M:%S'), msg))
    sys.stdout.flush()


def _bump(key, n=1):
    with _lock:
        _stats[key] += n


def _action(what):
    with _lock:
        _stats['last_action'] = {'at': time.strftime('%Y-%m-%dT%H:%M:%S'), 'what': what}
    log(what)


def _http_json(url, timeout, data=None):
    req = urllib.request.Request(url, data=data, method='POST' if data is not None else 'GET')
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read()
    return json.loads(body.decode('utf-8')) if body else {}


def _is_timeout(e):
    if isinstance(e, (socket.timeout, TimeoutError)):
        return True
    reason = getattr(e, 'reason', None)
    return isinstance(reason, (socket.timeout, TimeoutError))


def _probe_one(base):
    """One ComfyUI URL -> None (nothing listening) or a dict describing it."""
    try:
        q = _http_json(base + '/queue', CONFIG['probe_timeout'])
    except Exception as e:
        if _is_timeout(e):
            # Port open but no answer in time: ComfyUI is running and too busy to reply
            # (e.g. loading a checkpoint). Safer to treat that as a render in progress.
            return {'url': base, 'busy': True, 'running': -1, 'pending': -1, 'held_mib': None, 'slow': True}
        return None
    running = len(q.get('queue_running') or [])
    pending = len(q.get('queue_pending') or [])
    held = None
    try:
        s = _http_json(base + '/system_stats', CONFIG['probe_timeout'])
        dev = (s.get('devices') or [{}])[0]
        held = int(dev.get('torch_vram_total', 0)) // (1024 * 1024)   # PyTorch reserved VRAM
    except Exception:
        pass
    return {'url': base, 'busy': (running + pending) > 0, 'running': running, 'pending': pending,
            'held_mib': held, 'slow': False}


def comfy_state(fresh=False):
    """Combined view of every configured ComfyUI. Probes run outside the lock."""
    now = time.time()
    with _lock:
        if not fresh and now - _cache['at'] <= CONFIG['cache_sec']:
            return _cache['value']
    found = [p for p in (_probe_one(u) for u in CONFIG['comfyui_urls']) if p]
    value = None
    if found:
        busy = any(p['busy'] for p in found)
        value = {'busy': busy, 'instances': found,
                 'running': sum(max(p['running'], 0) for p in found),
                 'pending': sum(max(p['pending'], 0) for p in found)}
    with _lock:
        _cache['value'] = value
        _cache['at'] = time.time()
        if value and value['busy']:
            _last_busy['at'] = _cache['at']
    return value


def recently_busy():
    with _lock:
        return _last_busy['at'] > 0 and (time.time() - _last_busy['at']) < CONFIG['hold_sec']


def free_comfy(inst):
    """Ask an idle ComfyUI to drop its cached models; wait up to 12 s for the VRAM to come back
    (ComfyUI empties the CUDA cache a few seconds after unloading). Backs off if it did not help."""
    base, held = inst['url'], inst['held_mib']
    with _lock:
        last = _free_attempts.get(base)
        if last and time.time() - last[0] < CONFIG['free_backoff_sec'] and held >= last[1] * 0.9:
            return None
    try:
        _http_json(base + '/free', 3, data=json.dumps({'unload_models': True, 'free_memory': True}).encode())
    except Exception as e:
        log('could not ask ComfyUI at %s to free VRAM: %s' % (base, e))
        return None
    now_held = held
    deadline = time.time() + 12
    while time.time() < deadline:
        time.sleep(0.5)
        p = _probe_one(base)
        if not p or p['busy']:
            break
        if p['held_mib'] is not None:
            now_held = p['held_mib']
            if now_held < CONFIG['free_min_mib']:
                break
    with _lock:
        _cache['at'] = 0.0
        if now_held is not None and now_held < CONFIG['free_min_mib']:
            _free_attempts.pop(base, None)
        else:
            _free_attempts[base] = (time.time(), held)
    if now_held is not None and now_held < held:
        _bump('comfy_freed')
        return 'ComfyUI was idle with %d MiB of VRAM cached; freed it (%d MiB left)' % (held, now_held)
    return None


def guard(path, body):
    """Mutates body in place when needed. Returns a short description of what was done."""
    if CONFIG['mode'] == 'off':
        return None
    # Only requests that generate text. Open WebUI's load/unload calls carry no messages/prompt.
    if path == '/api/chat':
        has_input = bool(body.get('messages'))
    else:
        has_input = bool(body.get('prompt')) or bool(body.get('images'))
    if not has_input:
        return None
    state = comfy_state()
    if (state and state['busy']) or recently_busy():
        opts = body.get('options')
        if not isinstance(opts, dict):
            opts = {}
            body['options'] = opts
        if 'num_gpu' in opts:
            return None
        opts['num_gpu'] = 0
        _bump('cpu_routed')
        with _lock:
            _cpu_models[str(body.get('model'))] = time.time()
        if state and state['busy'] and any(i['slow'] for i in state['instances']) and state['running'] == 0:
            why = 'ComfyUI too busy to answer'
        elif state and state['busy']:
            why = 'ComfyUI busy (%d running, %d queued)' % (state['running'], state['pending'])
        else:
            why = 'ComfyUI was busy < %ds ago' % CONFIG['hold_sec']
        return '%s: %s runs on the CPU' % (why, body.get('model'))
    # This request loads the model onto the GPU again (if it was on the CPU).
    with _lock:
        _cpu_models.pop(str(body.get('model')), None)
    if state and CONFIG['free_idle']:
        done = []
        for inst in state['instances']:
            if inst['held_mib'] is not None and inst['held_mib'] >= CONFIG['free_min_mib']:
                r = free_comfy(inst)
                if r:
                    done.append(r)
        return '; '.join(done) or None
    return None


def _render_watcher():
    """When a render starts while a chat model idles in VRAM, unload it so ComfyUI gets the GPU."""
    url = CONFIG['upstream']
    while True:
        time.sleep(CONFIG['watch_sec'])
        try:
            if CONFIG['mode'] == 'off' or not CONFIG['unload_on_render']:
                continue
            state = comfy_state()
            if not state or not state['busy']:
                continue
            with _lock:
                if _inflight['n'] > 0:
                    continue
            ps = _http_json(url + '/api/ps', 3)
            with _lock:
                on_cpu = set(_cpu_models)
            for m in ps.get('models') or []:
                name = m.get('name') or m.get('model')
                # Models the guard itself sent to the CPU stay (size_vram is not reliable for
                # CPU loads on every Ollama build).
                if name in on_cpu:
                    continue
                if int(m.get('size_vram') or 0) > 0:
                    _http_json(url + '/api/generate', 30, data=json.dumps({'model': name, 'keep_alive': 0}).encode())
                    _bump('ollama_unloaded')
                    _action('ComfyUI started a job; unloaded %s from VRAM' % name)
        except Exception as e:
            log('render watcher: %s' % e)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'render-guard'
    timeout = 300   # client-socket reads (request line/body); never applies to Ollama's answer

    def log_message(self, fmt, *args):  # quiet default access log
        pass

    def _read_body(self):
        if 'chunked' in (self.headers.get('Transfer-Encoding') or '').lower():
            data = b''
            while True:
                line = self.rfile.readline().strip()
                size = int(line.split(b';')[0], 16) if line else 0
                if size == 0:
                    while self.rfile.readline() not in (b'\r\n', b'\n', b''):
                        pass
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n) if n > 0 else b''

    def _send_json(self, code, obj):
        data = json.dumps(obj).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def _watch_client(self, upstream_conn, done):
        """If the client hangs up (Stop button) while Ollama is still thinking, close the
        upstream socket so Ollama cancels the request instead of finishing it for nobody."""
        sock = self.connection
        while not done.is_set():
            try:
                r, _, _ = select.select([sock], [], [], 1.0)
                if not r:
                    continue
                if sock.recv(1, socket.MSG_PEEK) == b'':
                    break
                # Unexpected extra bytes (pipelining); stop watching rather than guess.
                return
            except (OSError, ValueError):
                break
        if not done.is_set():
            try:
                if upstream_conn.sock is not None:
                    upstream_conn.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def _proxy(self):
        # One request per connection: a broken or truncated upstream answer can then never leave
        # the client waiting on a half-finished keep-alive response.
        self.close_connection = True
        _bump('requests')
        path_only = urllib.parse.urlsplit(self.path).path
        if path_only == '/render-guard/status':
            with _lock:
                stats = dict(_stats)
            with _lock:
                inflight = _inflight['n']
            self._send_json(200, {'config': CONFIG, 'stats': stats, 'comfyui': comfy_state(fresh=True),
                                  'holding_cpu': recently_busy(), 'inflight': inflight})
            return
        body = self._read_body()
        guarded = self.command == 'POST' and path_only in GUARDED_PATHS
        if guarded and body:
            try:
                obj = json.loads(body.decode('utf-8'))
            except ValueError:
                obj = None
            if isinstance(obj, dict):
                try:
                    action = guard(path_only, obj)
                except Exception as e:  # never let the guard break a chat
                    action = None
                    log('guard error (request passed through): %s' % e)
                if action:
                    body = json.dumps(obj).encode('utf-8')
                    _action(action)

        up = urllib.parse.urlsplit(CONFIG['upstream'])
        # Short connect timeout (Ollama down = fast error), long read timeout (CPU answers are slow).
        conn = http.client.HTTPConnection(up.hostname, up.port or 80, timeout=10)
        done = threading.Event()
        if guarded:
            with _lock:
                _inflight['n'] += 1
        try:
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
            headers['Host'] = up.netloc
            headers['Connection'] = 'close'
            if body or self.command in ('POST', 'PUT', 'DELETE'):
                headers['Content-Length'] = str(len(body))
            try:
                conn.connect()
                conn.sock.settimeout(900)
                conn.request(self.command, self.path, body=body if body else None, headers=headers)
            except Exception as e:
                self._send_json(502, {'error': 'render-guard: Ollama at %s is not reachable: %s' % (CONFIG['upstream'], e)})
                return
            threading.Thread(target=self._watch_client, args=(conn, done), daemon=True).start()
            try:
                resp = conn.getresponse()
            except Exception as e:
                if not done.is_set():
                    try:
                        self._send_json(502, {'error': 'render-guard: no answer from Ollama: %s' % e})
                    except OSError:
                        pass
                return
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in HOP_BY_HOP:
                    self.send_header(k, v)
            self.send_header('Connection', 'close')
            length = resp.getheader('Content-Length')
            if self.command == 'HEAD' or resp.status in (204, 304):
                self.send_header('Content-Length', length or '0')
                self.end_headers()
                return
            if length is not None:
                self.send_header('Content-Length', length)
                self.end_headers()
                remaining = int(length)
                while remaining > 0:
                    chunk = resp.read(min(65536, remaining))
                    if not chunk:
                        break   # truncated upstream; the closed connection tells the client
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            else:
                # Streaming (NDJSON): forward each piece as soon as Ollama sends it.
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                while True:
                    chunk = resp.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(b'%x\r\n%s\r\n' % (len(chunk), chunk))
                    self.wfile.flush()
                if not resp.isclosed() and resp.length not in (None, 0):
                    return  # upstream cut off mid-stream: no terminating chunk, connection closes
                self.wfile.write(b'0\r\n\r\n')
            self.wfile.flush()
        except (OSError, http.client.HTTPException) as e:
            # Client went away (Stop) or Ollama reset the stream. Either way this connection is
            # closed (close_connection) and the upstream socket is closed below.
            if getattr(e, 'errno', None) not in (None, errno.EPIPE, errno.ECONNRESET):
                log('proxy error on %s %s: %s' % (self.command, path_only, e))
        finally:
            done.set()
            if guarded:
                with _lock:
                    _inflight['n'] -= 1
            conn.close()

    do_GET = do_POST = do_DELETE = do_HEAD = do_PUT = _proxy


def main():
    ThreadingHTTPServer.daemon_threads = True
    srv = ThreadingHTTPServer(('0.0.0.0', CONFIG['listen_port']), Handler)
    threading.Thread(target=_render_watcher, daemon=True).start()
    log('render-guard listening on :%d -> %s, mode=%s, ComfyUI at %s' % (
        CONFIG['listen_port'], CONFIG['upstream'], CONFIG['mode'], ', '.join(CONFIG['comfyui_urls'])))
    # As PID 1 in its container, Python gets no default SIGTERM handling: without this, every
    # 'docker stop' waits its full 10 s grace period and then kills the process.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        log('render-guard stopping')


if __name__ == '__main__':
    main()
