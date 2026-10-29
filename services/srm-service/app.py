"""Dummy srm-service for pipeline testing, with no external dependencies."""
from demo.runtime import run


if __name__ == '__main__':
    run('srm-service', 3001)
