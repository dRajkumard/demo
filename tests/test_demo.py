"""Exercise HTTP responses for every demo identity through real sockets."""
import json
import os
from pathlib import Path
import runpy
from threading import Thread
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import urlopen

from demo.runtime import create_server, run


SERVICES = (
    'frontend', 'gateway-service', 'srm-service',
    'ai-proxy', 'sim-worker', 'ubuntu-sandbox',
)


class DemoHTTPTests(unittest.TestCase):
    def test_entrypoints_select_correct_service_and_port(self):
        root = Path(__file__).resolve().parents[1]
        entrypoints = (
            ('apps/VanikaAi-Frontend/app.py', 'frontend', 8080),
            ('services/Gateway-Service/app.py', 'gateway-service', 3000),
            ('services/srm-service/app.py', 'srm-service', 3001),
            ('services/ai-proxy/app.py', 'ai-proxy', 3002),
            ('services/sim-worker/app.py', 'sim-worker', 8003),
            ('services/Gateway-Service/sandbox.py', 'ubuntu-sandbox', 7447),
        )
        for path, service, port in entrypoints:
            with self.subTest(service=service), patch('demo.runtime.run') as start:
                runpy.run_path(str(root / path), run_name='__main__')
                start.assert_called_once_with(service, port)

    def test_runtime_uses_environment_overrides(self):
        with patch.dict(os.environ, {'HOST': '127.0.0.1', 'PORT': '9000'}):
            with patch('demo.runtime.create_server') as create, patch('builtins.print'):
                run('example', 8000)
                create.assert_called_once_with('example', '127.0.0.1', 9000)
                create.return_value.__enter__.return_value.serve_forever.assert_called_once()

    def test_runtime_uses_default_port(self):
        with patch.dict(os.environ, {}, clear=True):
            with patch('demo.runtime.create_server') as create, patch('builtins.print'):
                run('example', 8000)
                create.assert_called_once_with('example', '0.0.0.0', 8000)

    def test_service_routes(self):
        for service in SERVICES:
            with self.subTest(service=service):
                with create_server(service, '127.0.0.1', 0) as server:
                    thread = Thread(target=server.serve_forever, daemon=True)
                    thread.start()
                    try:
                        base = f'http://127.0.0.1:{server.server_port}'
                        for path in ('/health', '/v1/health?check=ready'):
                            with urlopen(base + path, timeout=3) as response:
                                self.assertEqual(response.status, 200)
                                self.assertEqual(json.load(response), {
                                    'status': 'ok', 'service': service, 'mode': 'demo',
                                })
                        with urlopen(base + '/api/demo', timeout=3) as response:
                            data = json.load(response)
                            self.assertEqual(data['service'], service)
                            self.assertEqual(data['mode'], 'demo')
                            self.assertIn('Dummy response', data['message'])
                        with urlopen(base + '/', timeout=3) as response:
                            if service == 'frontend':
                                self.assertIn('text/html', response.headers['Content-Type'])
                                self.assertIn(b'Vanika CI Demo', response.read())
                            else:
                                self.assertEqual(json.load(response)['service'], service)
                        with self.assertRaises(HTTPError) as error:
                            urlopen(base + '/does-not-exist', timeout=3)
                        self.assertEqual(error.exception.code, 404)
                        self.assertEqual(json.load(error.exception)['error'], 'not found')
                        error.exception.close()
                    finally:
                        server.shutdown()
                        thread.join(timeout=3)


if __name__ == '__main__':
    unittest.main()
