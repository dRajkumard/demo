"""Dummy sandbox endpoint. Does not execute commands."""
from demo.runtime import run


if __name__ == '__main__':
    run('ubuntu-sandbox', 7447)
