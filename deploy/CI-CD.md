# Demo CI and image delivery

All five former submodule folders now contain dummy Python code stored as
ordinary repository files. The sixth image is the dummy sandbox in the gateway
folder. CI needs no source repository token and no application credentials.

## Checks

The workflow runs on pull requests, manual dispatch and pushes to main, master,
development and V2. It performs:

1. Compose syntax and Dockerfile existence checks.
2. Real HTTP tests for all six service identities, entrypoint tests, and coverage
   collection with an 80 percent minimum.
3. Secret scanning using the existing configuration and historical baseline.
4. Separate Docker builds for all six images.
5. Full stack startup with Docker health checks, followed by HTTP smoke tests.

Runtime code uses only the Python standard library. Coverage 7.6.1 is the only
extra test tool installed by CI. Earlier npm, Prisma, pytest, model evaluation
and Playwright commands were removed because they belonged to the absent real
application sources. The current checks exercise only the dummy implementation.

## AWS image delivery and deployment

After all required checks pass on a push to main, six images are published to
`<account>.dkr.ecr.<region>.amazonaws.com/vanika-demo/<service>:<full-commit-sha>`.
The deploy job waits for all six uploads, then uses Systems Manager Run Command
to update one EC2 Docker Compose stack and verify every demo HTTP endpoint.
Other branches and pull requests run checks without deploying.

Configure the EC2 host, ECR repositories and GitHub OIDC role using
[AWS EC2 setup](AWS-EC2.md). No SonarQube settings or self-hosted runner are
required. Deployment uses GitHub-hosted Ubuntu runners.

Publication rebuilds the same source revision and Compose settings. Base image
tags are not digest pinned, so rebuilds are not guaranteed byte identical.
Workflow runs are queued rather than cancelling an in-flight deployment.

## Local verification

```sh
python3 -m unittest discover -s tests -v
python3 scripts/check-build-contexts.py
docker compose up -d --build --wait
python3 scripts/smoke-demo.py
docker compose down
```

The original full application Compose file is preserved as
`docker-compose.production-reference.yml`. It is a reference for future
restoration of real sources, not the configuration used by this demo.
