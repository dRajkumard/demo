"""Dummy ai-proxy for pipeline testing, with no external dependencies."""
from demo.runtime import run


if __name__ == '__main__':
    run('ai-proxy', 3002)
