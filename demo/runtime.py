"""Dependency free HTTP runtime for the dummy services."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


def create_server(service, host, port):
    """Create a server without starting it, allowing tests to use a free port."""
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path).path
            if path in ('/health', '/v1/health'):
                self.send_json(200, {'status': 'ok', 'service': service, 'mode': 'demo'})
            elif path == '/api/demo':
                self.send_json(200, {
                    'service': service,
                    'mode': 'demo',
                    'message': 'Dummy response for CI/CD testing.',
                })
            elif path == '/' and service == 'frontend':
                page = (
                    '<!doctype html><html lang="en"><meta charset="utf-8">'
                    '<meta name="viewport" content="width=device-width, initial-scale=1">'
                    '<title>Vanika CI Demo</title><main><h1>Vanika CI Demo</h1>'
                    '<p>Dummy services for Docker, GitHub Actions and SonarQube testing.</p>'
                    '<p>No authentication, AI calls or simulations are performed.</p>'
                    '<a href="/api/demo">View demo response</a></main></html>'
                ).encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(page)))
                self.end_headers()
                self.wfile.write(page)
            elif path == '/':
                self.send_json(200, {'service': service, 'mode': 'demo'})
            else:
                self.send_json(404, {'error': 'not found', 'service': service})

        def send_json(self, status, payload):
            body = json.dumps(payload).encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return ThreadingHTTPServer((host, port), Handler)


def run(service, default_port):
    """Start the demo endpoint using optional host and port overrides."""
    host = os.environ.get('HOST', '0.0.0.0')
    port = int(os.environ.get('PORT', str(default_port)))
    with create_server(service, host, port) as server:
        print(f'{service} demo listening on {host}:{server.server_port}', flush=True)
        server.serve_forever()
