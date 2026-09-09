"""Loopback HTTP transport for Tower's optional browser workspace."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import secrets
import subprocess
import sys
import threading
import webbrowser

from tower_ui import Queue, QueueError, ROOT

ASSETS = {'/': ('index.html', 'text/html'), '/tower.css': ('tower.css', 'text/css'),
          '/tower.js': ('tower.js', 'text/javascript')}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def respond(self, status, body, content_type='application/json'):
        if content_type == 'application/json':
            body = json.dumps(body).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', content_type + '; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(body)

    def valid_host(self):
        return self.headers.get('Host') == '127.0.0.1:' + str(self.server.server_port)

    def authorized(self):
        expected_origin = 'http://127.0.0.1:' + str(self.server.server_port)
        origin = self.headers.get('Origin')
        token = self.headers.get('X-Tower-Token', '')
        return self.valid_host() and origin in (None, expected_origin) and secrets.compare_digest(token, self.server.token)

    def do_GET(self):
        if not self.valid_host():
            self.respond(403, {'error': 'Open the local URL printed by tower-ui.'})
            return
        if self.path in ASSETS:
            filename, content_type = ASSETS[self.path]
            self.respond(200, (ROOT / 'web' / filename).read_bytes(), content_type)
            return
        if self.path != '/api/cards':
            self.respond(404, {'error': 'Not found.'})
            return
        if not self.authorized():
            self.respond(403, {'error': 'Open the full session URL printed by tower-ui.'})
            return
        self.perform(self.server.queue.snapshot)

    def action_data(self, fields):
        if self.headers.get('Content-Type') != 'application/json':
            raise ValueError('Expected a JSON action.')
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 65536:
            raise ValueError('Invalid action size.')
        data = json.loads(self.rfile.read(size))
        if not isinstance(data, dict):
            raise ValueError('Expected an action object.')
        if set(data) != fields:
            raise ValueError('Required fields: ' + ', '.join(sorted(fields)))
        if not all(isinstance(value, str) for value in data.values()):
            raise ValueError('Action fields must be strings.')
        return data

    def do_POST(self):
        if not self.authorized():
            self.respond(403, {'error': 'Open the full session URL printed by tower-ui.'})
            return
        if self.path not in ('/api/action', '/api/comment'):
            self.respond(404, {'error': 'Not found.'})
            return
        try:
            fields = {'id', 'action', 'revision'} if self.path == '/api/action' else {'id', 'revision', 'comment_id', 'text'}
            data = self.action_data(fields)
        except (ValueError, UnicodeError) as error:
            self.respond(400, {'error': str(error)})
            return
        if self.path == '/api/comment':
            self.perform(lambda: self.server.queue.comment(data['id'], data['revision'], data['comment_id'], data['text']))
        else:
            self.perform(lambda: self.server.queue.act(data['id'], data['action'], data['revision']))

    def perform(self, operation):
        try:
            with self.server.operations:
                result = operation()
            self.respond(200, result)
        except QueueError as error:
            self.respond(409, {'error': str(error)})
        except (OSError, ValueError) as error:
            self.respond(409, {'error': 'Could not read or update Tower state: ' + str(error)})


class Server(ThreadingHTTPServer):
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(15)
        return connection, address


def create_server(queue, port):
    server = Server(('127.0.0.1', port), Handler)
    server.queue = queue
    server.token = secrets.token_urlsafe(32)
    server.operations = threading.Lock()
    return server


def main():
    parser = argparse.ArgumentParser(prog='tower-ui', description='Review, approve, and dispatch Tower cards in a local browser.')
    parser.add_argument('--from', dest='directory', help='Project directory (uses tower-locate)')
    parser.add_argument('--port', type=int, default=0, help='Local port; default chooses an available port')
    parser.add_argument('--no-open', action='store_true', help='Print the URL without opening a browser')
    args = parser.parse_args()
    command = [str(ROOT / 'bin/tower-locate')]
    if args.directory:
        command.extend(['--from', args.directory])
    located = subprocess.run(command, capture_output=True, text=True)
    if located.returncode:
        sys.stderr.write(located.stderr)
        return located.returncode
    try:
        queue = Queue(Path(located.stdout.splitlines()[0]))
        server = create_server(queue, args.port)
    except (OSError, ValueError, QueueError) as error:
        print('tower-ui: ' + str(error), file=sys.stderr)
        return 1
    url = 'http://127.0.0.1:' + str(server.server_port) + '/#' + server.token
    print('tower-ui: ' + str(queue.project), flush=True)
    print(url, flush=True)
    print('Keep this command running. Press Ctrl-C to stop.', flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
