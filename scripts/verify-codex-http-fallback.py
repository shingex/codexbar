#!/usr/bin/env python3
"""Offline Codex HTTP fallback/tool-loop probe.

Usage: python3 scripts/verify-codex-http-fallback.py /path/to/codex [...]
Uses a temporary CODEX_HOME, synthetic OAuth tokens and a loopback-only server.
Reads only model metadata from ~/.codex/models_cache.json; never uses real tokens.
"""
import base64, datetime, http.server, json, os, pathlib, subprocess, tempfile, threading, time

def run_probe(binary, force_websocket=False, tool=False):
    with tempfile.TemporaryDirectory(prefix='codexbar-client-probe-') as tmp:
        home = pathlib.Path(tmp)
        requests = []
        input_seen = []
        started = time.monotonic()
        original = json.loads((pathlib.Path.home() / '.codex/models_cache.json').read_text())
        model = original['models'][0].copy()
        model.update(slug='codexbar-probe', display_name='CodexBar probe', prefer_websockets=force_websocket, tool_mode='direct', use_responses_lite=False, visibility='list')
        for k in ['multi_agent_version', 'multi_agent_reasoning_effort', 'guardian']:
            model.pop(k, None)
        (home / 'models.json').write_text(json.dumps({'models': [model]}))
        enc = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip('=')
        claims = {'email': 'probe@example.test', 'exp': int(time.time()) + 3600, 'https://api.openai.com/auth': {'chatgpt_account_id': 'probe-account', 'chatgpt_plan_type': 'plus', 'user_id': 'probe-user'}}
        token = enc({'alg': 'none'}) + '.' + enc(claims) + '.probe'
        auth = {'auth_mode': 'chatgpt', 'tokens': {'access_token': token, 'refresh_token': 'probe-refresh', 'id_token': token, 'account_id': 'probe-account'}, 'last_refresh': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        (home / 'auth.json').write_text(json.dumps(auth))
        (home / 'auth.json').chmod(384)

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *args):
                pass

            def do_GET(self):
                requests.append({'method': 'GET', 'path': self.path, 'upgrade': self.headers.get('Upgrade', ''), 'at_ms': round((time.monotonic() - started) * 1000)})
                body = json.dumps({'error': {'message': 'use HTTP responses'}}).encode()
                self.send_response(426)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                length = int(self.headers.get('Content-Length', '0'))
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw)
                except Exception:
                    body = {}
                requests.append({'method': 'POST', 'path': self.path, 'model': body.get('model'), 'at_ms': round((time.monotonic() - started) * 1000)})
                input_seen.append(body.get('input', []))
                counter = len(input_seen)
                rid = 'resp_probe_' + str(counter)
                call_tool = tool and counter == 1
                if call_tool:
                    names = [t.get('name') for t in body.get('tools', []) if t.get('type') == 'function']
                    if 'exec_command' in names:
                        name = 'exec_command'
                        args = {'cmd': 'printf ROUTING_TOOL_OK', 'max_output_tokens': 50}
                    elif 'shell_command' in names:
                        name = 'shell_command'
                        args = {'command': 'printf ROUTING_TOOL_OK', 'timeout_ms': 1000}
                    else:
                        name = 'shell'
                        args = {'command': ['/bin/sh', '-c', 'printf ROUTING_TOOL_OK']}
                    item = {'type': 'function_call', 'id': 'fc_probe', 'call_id': 'call_probe', 'name': name, 'arguments': json.dumps(args), 'status': 'completed'}
                else:
                    item = {'id': 'msg_probe_' + str(counter), 'type': 'message', 'status': 'completed', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'ROUTING_OK', 'annotations': []}]}
                response = {'id': rid, 'object': 'response', 'created_at': int(time.time()), 'status': 'completed', 'error': None, 'incomplete_details': None, 'model': body.get('model'), 'output': [item], 'usage': {'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15}}
                events = [{'type': 'response.created', 'response': dict(response, status='in_progress', output=[])}]
                if call_tool:
                    events += [{'type': 'response.output_item.added', 'output_index': 0, 'item': dict(item, arguments='', status='in_progress')}, {'type': 'response.function_call_arguments.delta', 'item_id': item['id'], 'output_index': 0, 'delta': item['arguments']}, {'type': 'response.function_call_arguments.done', 'item_id': item['id'], 'output_index': 0, 'arguments': item['arguments']}, {'type': 'response.output_item.done', 'output_index': 0, 'item': item}]
                else:
                    events += [{'type': 'response.output_item.added', 'output_index': 0, 'item': dict(item, status='in_progress', content=[])}, {'type': 'response.content_part.added', 'item_id': item['id'], 'output_index': 0, 'content_index': 0, 'part': {'type': 'output_text', 'text': '', 'annotations': []}}, {'type': 'response.output_text.delta', 'item_id': item['id'], 'output_index': 0, 'content_index': 0, 'delta': 'ROUTING_OK'}, {'type': 'response.output_text.done', 'item_id': item['id'], 'output_index': 0, 'content_index': 0, 'text': 'ROUTING_OK'}, {'type': 'response.output_item.done', 'output_index': 0, 'item': item}]
                events.append({'type': 'response.completed', 'response': response})
                payload = ''.join(('event: ' + e['type'] + '\ndata: ' + json.dumps(e) + '\n\n' for e in events)).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(payload)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(payload)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        (home / 'config.toml').write_text('model_provider = "openai"\nopenai_base_url = "http://127.0.0.1:%d/v1"\nmodel_catalog_json = %s\n[features]\nenable_request_compression = false\n' % (server.server_port, json.dumps(str(home / 'models.json'))))
        env = os.environ.copy()
        env['CODEX_HOME'] = tmp
        env['NO_PROXY'] = 'localhost,127.0.0.1'
        env.pop('OPENAI_API_KEY', None)
        env.pop('OPENAI_BASE_URL', None)
        cmd = [binary, 'exec', '--json', '--skip-git-repo-check', '--ephemeral', '--sandbox', 'read-only', '--color', 'never', '--model', 'codexbar-probe', 'Reply only ROUTING_OK.']
        try:
            result = subprocess.run(cmd, cwd=tmp, env=env, text=True, capture_output=True, timeout=35)
            completed_items = []
            for line in result.stdout.splitlines():
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get('type') == 'item.completed':
                    completed_items.append(event.get('item', {}))
            tool_ok = any((item.get('exit_code') == 0 and 'ROUTING_TOOL_OK' in item.get('aggregated_output', '') for item in completed_items))
            report = {'tool_executed': tool_ok, 'binary': binary, 'force_websocket': force_websocket, 'tool_probe': tool, 'returncode': result.returncode, 'requests': requests, 'received_final': 'ROUTING_OK' in result.stdout, 'received_tool_result': any(('function_call_output' in json.dumps(items) for items in input_seen[1:]))}
            if result.returncode or not report['received_final']:
                report['diagnostic'] = (result.stdout + '\n' + result.stderr)[-1800:]
        except subprocess.TimeoutExpired:
            report = {'binary': binary, 'force_websocket': force_websocket, 'timeout': True, 'requests': requests}
        server.shutdown()
        return report
if __name__ == '__main__':
    import sys
    binaries = sys.argv[1:] or ['/usr/local/bin/codex']
    reports = []
    for binary in binaries:
        for forced in [False, True]:
            report = run_probe(binary, forced, tool=True)
            reports.append(report)
            print(json.dumps(report), flush=True)
    sys.exit(0 if all((r.get('returncode') == 0 and r.get('received_final') and r.get('received_tool_result') and r.get('tool_executed') for r in reports)) else 1)
