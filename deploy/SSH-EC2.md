# SSH deployment to EC2

Pushes to `main` deploy after tests, secret scanning, builds, and smoke checks
pass. Images build on EC2. No AWS credentials are required by this workflow.

Configure repository Actions secrets:

| Secret | Value |
| --- | --- |
| `EC2_HOST` | Public IP or DNS of the EC2 server |
| `EC2_USER` | `ubuntu` |
| `EC2_SSH_KEY` | Complete private key authorized for that user, without a passphrase |
| `EC2_KNOWN_HOSTS` | Verified `host ssh-ed25519 public-key` entry matching `EC2_HOST` |

Read `/etc/ssh/ssh_host_ed25519_key.pub` through your existing trusted server
session to obtain the public host key. Keep the private login key in Secrets.
Allow SSH connectivity from the runner in the server security group.

The server needs Git, Python 3, Bash, flock, Docker, Compose 2.24.4 or later,
and passwordless sudo for the Docker commands. It must already have a clean
checkout of the correct repository at `~/vanika/vanika-demo/vanika` and be able
to fetch `origin main` without interactive authentication.

Create `~/vanika/vanika-demo/compose.server.yml` outside the checkout:

```yaml
services:
  frontend:
    ports: !override
      - "0.0.0.0:${FRONTEND_PORT:-18080}:8080"
```

This exposes the demo frontend on port 18080. Restrict security group ingress to
the clients that should access it. Keep the tracked Compose file clean.

The job checks out the tested commit, builds and starts the services, waits for
container health, and runs `scripts/smoke-demo.py`. Deployment can interrupt
service, and a failed health check does not automatically roll back. Keep enough
server memory and disk space available for builds. The server checkout ends in
detached HEAD state; updates use an explicit `git fetch origin main`.
