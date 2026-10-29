"""Check every published demo endpoint after Compose starts the stack."""
import json
import os
from urllib.request import urlopen


ENDPOINTS = {
    'frontend': int(os.environ.get('FRONTEND_PORT', '18080')),
    'gateway-service': int(os.environ.get('GATEWAY_PORT', '13001')),
    'srm-service': int(os.environ.get('SRM_PORT', '13002')),
    'ai-proxy': int(os.environ.get('AI_PROXY_PORT', '13004')),
    'sim-worker': int(os.environ.get('SIM_WORKER_PORT', '18003')),
    'ubuntu-sandbox': int(os.environ.get('SANDBOX_PORT', '17447')),
}


def main():
    for service, port in ENDPOINTS.items():
        for path in ('/health', '/api/demo'):
            with urlopen(f'http://127.0.0.1:{port}{path}', timeout=5) as response:
                payload = json.load(response)
                if payload.get('service') != service or payload.get('mode') != 'demo':
                    raise RuntimeError(f'Unexpected response from {service}: {payload}')
        print(f'{service}: healthy, demo endpoint passed')


if __name__ == '__main__':
    main()
