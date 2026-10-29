# Vanika CI/CD demo

This repository currently contains **dummy services for pipeline testing**. All
service code is stored here directly. No Git submodules, Supabase credentials,
AI provider keys, Postgres, Redis or Kafka are required to run the demo.

## Run

With Docker Desktop running:

```sh
docker compose up -d --build --wait
python3 scripts/smoke-demo.py
```

Open http://localhost:18080 for the demo page. Every service exposes `/health`,
`/v1/health` and `/api/demo` with a JSON response identifying the service and
`"mode": "demo"`.

| Service | Host port | Source |
| --- | --- | --- |
| Frontend | 18080 | `apps/VanikaAi-Frontend/app.py` |
| Gateway | 13001 | `services/Gateway-Service/app.py` |
| SRM | 13002 | `services/srm-service/app.py` |
| AI proxy | 13004 | `services/ai-proxy/app.py` |
| Simulation worker | 18003 | `services/sim-worker/app.py` |
| Sandbox | 17447 | `services/Gateway-Service/sandbox.py` |

The demo uses a separate set of local ports to avoid existing applications.
You can override them with `FRONTEND_PORT`, `GATEWAY_PORT`, `SRM_PORT`,
`AI_PROXY_PORT`, `SIM_WORKER_PORT` and `SANDBOX_PORT`. Use the same variables
when running Compose and the smoke script.

These are small Python HTTP endpoints using the shared `demo/runtime.py` module.
They return canned data. They do not authenticate users, call AI models, process
simulation jobs or execute shell commands. Containers run as an unprivileged user.

```sh
docker compose logs -f
docker compose down
python3 -m unittest discover -s tests -v
```

## GitHub Actions and SonarQube

The workflow validates sources, runs HTTP tests with coverage, builds all six
images, starts the entire demo stack, runs smoke checks and scans with SonarQube.
After all checks pass on main, it publishes commit tagged images to GHCR.

For SonarQube, configure the Actions secret `SONAR_TOKEN` and repository variables
`SONAR_HOST_URL` and `SONAR_PROJECT_KEY`. See [CI/CD setup](deploy/CI-CD.md).
Missing settings fail the SonarQube job. No deployment to a server is configured.

The original application documentation and Compose configuration are preserved
in `README.production-reference.md` and `docker-compose.production-reference.yml`
for reference. The original application sources were absent. The old installers
and deployment manifests describe that original application, and are not needed
for this demo. Use the commands above to run the dummy stack.
