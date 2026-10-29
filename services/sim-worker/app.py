"""Dummy sim-worker for pipeline testing, with no external dependencies."""
from demo.runtime import run


if __name__ == '__main__':
    run('sim-worker', 8003)
