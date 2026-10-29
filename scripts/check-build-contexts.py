#!/usr/bin/env python3
"""Report missing Compose build inputs before dependency installation begins."""
import json
from pathlib import Path
import subprocess
import sys


def missing_build_inputs(config):
    errors = []
    for name, service in config.get('services', {}).items():
        build = service.get('build')
        if not build:
            continue
        if isinstance(build, str):
            build = {'context': build}
        context = Path(build['context'])
        dockerfile = context / build.get('dockerfile', 'Dockerfile')
        if not context.is_dir():
            errors.append(f'{name}: missing build context {context}')
        elif not dockerfile.is_file():
            errors.append(f'{name}: missing {dockerfile}')
    return errors


def main():
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(
        ['docker', 'compose', 'config', '--format', 'json'],
        cwd=root, capture_output=True, text=True,
    )
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        return result.returncode
    errors = missing_build_inputs(json.loads(result.stdout))
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        print(
            '\nRestore the missing Dockerfiles from this repository before building.',
            file=sys.stderr,
        )
        return 1
    print('All Compose build contexts contain their Dockerfiles.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
