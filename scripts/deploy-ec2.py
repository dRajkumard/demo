"""Deploy the CI revision to one SSM-managed EC2 instance (AWS CLI required)."""
import base64
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time


def aws(*args):
    return json.loads(subprocess.check_output(['aws', *args, '--output', 'json'], text=True))


def main():
    region = os.environ['AWS_REGION']
    registry = os.environ['ECR_REGISTRY']
    revision = os.environ['GITHUB_SHA']
    instance = os.environ['EC2_INSTANCE_ID']
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Expected a full Git commit SHA')
    compose = json.loads(subprocess.check_output(
        ['docker', 'compose', 'config', '--format', 'json'], text=True))
    for name, service in compose['services'].items():
        service.pop('build', None)
        service['image'] = f'{registry}/vanika-demo/{name}:{revision}'
    encoded = base64.b64encode(json.dumps(compose).encode()).decode()
    smoke = base64.b64encode(Path('scripts/smoke-demo.py').read_bytes()).decode()
    quote = shlex.quote
    script = f'''#!/bin/bash
set -euo pipefail
mkdir -p /opt/vanika-demo
exec 9>/opt/vanika-demo/deploy.lock
flock -w 600 9
cd /opt/vanika-demo
mkdir -p releases/{revision}
echo {quote(encoded)} | base64 --decode > releases/{revision}/compose.json
echo {quote(smoke)} | base64 --decode > releases/{revision}/smoke.py
aws ecr get-login-password --region {quote(region)} | docker login --username AWS --password-stdin {quote(registry)}
compose_file=/opt/vanika-demo/releases/{revision}/compose.json
docker compose -p vanikaai-demo -f "$compose_file" pull
if ! docker compose -p vanikaai-demo -f "$compose_file" up -d --no-build --wait --wait-timeout 180; then
  docker compose -p vanikaai-demo -f "$compose_file" logs --tail 100
  exit 1
fi
python3 releases/{revision}/smoke.py
ln -sfn "$compose_file" current.json
'''
    # Explicit bash is needed: AWS-RunShellScript otherwise invokes /bin/sh.
    command = 'bash -c ' + quote(script)
    response = aws('ssm', 'send-command', '--instance-ids', instance,
                   '--document-name', 'AWS-RunShellScript', '--timeout-seconds', '60',
                   '--parameters', json.dumps({'commands': [command], 'executionTimeout': ['1200']}))
    command_id = response['Command']['CommandId']
    print(f'SSM deployment command: {command_id}', flush=True)
    for _ in range(150):
        time.sleep(10)
        try:
            result = aws('ssm', 'get-command-invocation', '--command-id', command_id,
                         '--instance-id', instance)
        except subprocess.CalledProcessError:
            # Run Command results are eventually consistent.
            continue
        if result['Status'] in ('Pending', 'InProgress', 'Delayed', 'Cancelling'):
            continue
        print(result.get('StandardOutputContent', ''))
        print(result.get('StandardErrorContent', ''))
        if result['Status'] != 'Success':
            raise SystemExit(f"Deployment failed: {result['Status']}")
        return
    raise SystemExit('Timed out waiting for SSM; inspect the command in AWS Systems Manager.')


if __name__ == '__main__':
    main()
