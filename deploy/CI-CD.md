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
6. SonarQube static analysis and Python coverage import, waiting for its gate.

Runtime code uses only the Python standard library. Coverage 7.6.1 is the only
extra test tool installed by CI. Earlier npm, Prisma, pytest, model evaluation
and Playwright commands were removed because they belonged to the absent real
application sources. The current checks exercise only the dummy implementation.

## SonarQube setup

Create a project on your SonarQube server, reachable from GitHub hosted runners.
Under repository Settings, Secrets and variables, Actions, configure:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `SONAR_TOKEN` | Project analysis token |
| Variable | `SONAR_HOST_URL` | HTTPS URL of the server |
| Variable | `SONAR_PROJECT_KEY` | Existing project key |

The scanner imports `coverage.xml` from the test job and waits up to 600 seconds
for the server quality gate. Missing settings fail the job. Branch and pull
request analysis require a server edition supporting them. Fork pull requests
skip SonarQube because secrets are unavailable. Configure branch protection to
require the desired checks before merging.

The action and gate configuration follow the [official SonarQube action](https://github.com/SonarSource/sonarqube-scan-action).

## Image delivery

After all required checks pass on a push to main, six images are published to
`ghcr.io/<owner>/<repository>/<service>:<full-commit-sha>`. The path is lowercased.
Grant Actions access to create packages or write to existing packages. The
publication job uses its GitHub token with packages write permission.

Publication rebuilds the same source revision and Compose settings. Base image
tags are not digest pinned, so rebuilds are not guaranteed byte identical.
No running server is updated. Deployment needs a target environment and a
separate deployment job.

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
