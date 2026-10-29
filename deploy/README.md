# Deploying Vanika

One command on a laptop, and a documented path to a server or a cloud. Every
target below runs the same images from the same compose file, so what you test
locally is what you deploy.

| Target | Command | Notes |
|---|---|---|
| Windows | `powershell -ExecutionPolicy Bypass -File .\install.ps1` | Also tunes WSL2 memory |
| macOS | `./install.sh` | Installs Docker Desktop via Homebrew if missing |
| Linux, Ubuntu, Debian, Fedora, Arch | `./install.sh` | Installs Docker Engine if missing |
| Server, unattended | `./install.sh --yes --no-browser` | No prompts, no browser |
| CI | `./install.sh --yes --no-browser --no-build` | Uses prebuilt images |
| Kubernetes | `kubectl apply -f deploy/k8s/` | See `deploy/k8s/README.md` |
| AWS, Azure, GCP | below | Managed database strongly recommended |

The installers are safe to re-run and are also how you update: nothing already
correct is reinstalled, and `.env.docker` is never overwritten.

---

## What the installer actually does

1. **Checks the machine.** Architecture, memory, free disk. It warns rather than
   refuses when a machine is small, because it will still run, just slowly.
2. **Installs only what is missing.** Git, curl, Docker. It probes for each
   before touching a package manager.
3. **Tunes WSL2 on Windows.** See the memory note below; this is the single
   biggest difference in how the machine feels.
4. **Generates secrets.** Three 32-byte values: the internal service key, the
   key that encrypts organisations' AI provider keys, and the database password
   for the unprivileged tenant role. It never overwrites an existing
   `.env.docker`.
5. **Starts the stack, waits, opens the browser.** It waits for the gateway's
   health endpoint and the web app to actually answer rather than assuming.

`--repair` diagnoses an existing install: it reclaims build cache and restarts
anything that is not `Up`.

---

## Why WSL2 shows so much memory on Windows, and what to do

Task Manager can show `VmmemWSL` holding many gigabytes while the containers
themselves use under one. That difference is **Linux page cache inside the WSL2
virtual machine**, not the application. WSL2 grows the VM to hold it and, by
default, never gives it back to Windows.

On a machine measured while running this stack: WSL reported 15.5 GB total with
**12.6 GB in page cache** and 2.3 GB genuinely used, against roughly 900 MB of
actual container memory. Docker's build cache had grown to 28 GB across a day of
rebuilds, and every byte of that I/O passed through the cache.

Three fixes, in order of effect:

```powershell
# 1. Reclaim the build cache. This is usually the biggest single win.
docker builder prune -af

# 2. Let WSL hand memory back. The installer writes this for you.
#    %USERPROFILE%\.wslconfig
[wsl2]
memory=8GB               # a ceiling, not a reservation
processors=8             # not all 24; builds will use every core they are given
autoMemoryReclaim=gradual # the setting that actually fixes the growth
sparseVhd=true           # let the virtual disk shrink when images are pruned

# 3. Apply it.
wsl --shutdown           # then start Docker Desktop again
```

After a `wsl --shutdown`, Docker Desktop can leave **stale port forwarding**:
containers come back `Up`, the services answer inside the Docker network, and
Docker still lists the ports as published, but nothing reaches them from the
host. A single `docker compose up -d --force-recreate` re-establishes it; both
installers detect this case and do it for you.

Note also that a container without a restart policy will not come back. Check
before you restart WSL:

```bash
docker ps -a --format '{{.Names}}	{{.State}}'   | while read -r n _; do printf '%s %s
' "$n"       "$(docker inspect "$n" --format '{{.HostConfig.RestartPolicy.Name}}')"; done
```

`autoMemoryReclaim` needs WSL 2.0 or newer; check with `wsl --version`.

Every compose service also carries a memory and CPU ceiling, sized several times
its measured steady state. Those exist so one runaway service cannot take the
machine, which is exactly what Redpanda did before it was capped.

---

## Only one stack, ever

Three things stop a second copy from running beside the first.

**The project name is pinned** (`name: vanikaai` in the compose file). Without
it Compose derives the name from the directory, so a second clone -- or the same
repo checked out at another path -- becomes a separate project whose containers
fight this one for the same published ports and the same database. Pinned, any
invocation from anywhere addresses the same containers: `up` reuses or replaces
them, and `down` from a copy stops the right thing.

**A lock file** stops two installers racing each other through a build. It is
held for the life of the install and released when it exits, including on
Ctrl-C, so a cancelled run never leaves a stale lock.

**A port preflight** names whatever already holds one of our ports -- a
container, or a process with its pid -- rather than letting a container restart
forever with "address already in use".

```bash
./scripts/preflight.sh     # run the checks on their own
```

If an older stack is running under a different project name:

```bash
docker ps --filter name=vanika --format '{{.Names}}' | xargs -r docker rm -f
```

---

## Cloud

The shape is the same everywhere: run the containers, point them at a managed
Postgres, and terminate TLS in front of the frontend and gateway.

### Common to all three

- **Use a managed database.** Row-level security, which is how tenants are
  isolated, works identically on RDS, Cloud SQL and Azure Database. Create the
  unprivileged `vanika_app` role there and set `APP_DATABASE_URL` to it; the
  gateway's entrypoint does this automatically when it can.
- **Secrets belong in the platform's secret store**, not in `.env.docker`:
  AWS Secrets Manager, Azure Key Vault, GCP Secret Manager.
- **Do not expose the SRM service or the AI proxy publicly.** Only the frontend
  and the gateway need an ingress. The AI proxy's internal endpoints are guarded
  by `INTERNAL_API_KEY`, but there is no reason to give the internet a route.
- **Set `PUBLIC_APP_URL`** to the real origin, or invitation links point at
  localhost.

### AWS

```bash
# ECS Fargate is the least operational work for this shape.
#   - one task definition per service, from docker-compose.yml
#   - RDS Postgres 16, MSK or a single Redpanda task for Kafka
#   - ElastiCache for Redis
#   - ALB in front of frontend (:80) and gateway (:3000)
#   - EFS for the sandbox workspace if the Code tab's builds are enabled
aws ecs register-task-definition --cli-input-json file://deploy/aws/gateway.json
```

EKS works too; use `deploy/k8s/` unchanged.

### Azure

Container Apps maps cleanly: each compose service becomes a container app in one
environment, with Azure Database for PostgreSQL and Azure Cache for Redis.
Ingress on the frontend and gateway only; everything else stays internal.

```bash
az containerapp env create -n vanika-env -g vanika -l eastus
az containerapp create -n gateway -g vanika --environment vanika-env \
  --image ghcr.io/adityapuppala1/vanika-gateway:latest --ingress external --target-port 3000
```

### GCP

Cloud Run for the stateless services (gateway, SRM, AI proxy, frontend), Cloud
SQL for Postgres, Memorystore for Redis. The sim worker is a Kafka consumer
rather than an HTTP service, so run it on GKE or as a Cloud Run worker pool.

```bash
gcloud run deploy vanika-gateway --image ghcr.io/adityapuppala1/vanika-gateway:latest \
  --add-cloudsql-instances PROJECT:REGION:vanika --set-secrets=INTERNAL_API_KEY=internal-key:latest
```

---

## CI

`.github/workflows/` already builds and tests every service on each push. To
bring a full stack up inside a job:

```yaml
- name: Start Vanika
  run: ./install.sh --yes --no-browser --no-build
- name: Wait and smoke-test
  run: curl -fsS --retry 30 --retry-delay 5 http://localhost:3001/v1/health
```

`--no-build` uses images already pulled or built by an earlier step, which keeps
the job short.

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| A service will not start | `docker compose logs -f <service>` |
| Everything is slow, VmmemWSL is huge | `docker builder prune -af`, then the `.wslconfig` above |
| Disk filling up | `docker system df`, then `docker builder prune -af` |
| A change you made is not taking effect | The build cache can serve a stale layer: `docker compose build --no-cache <service>` |
| Containers are `Up` but nothing answers on localhost | Stale port forwarding, usually after `wsl --shutdown`. `docker compose up -d --force-recreate`. Both installers now detect and fix this automatically. |
| The stack is confused after an upgrade | `./install.sh --repair` |
| Signing in fails | Supabase keys in `.env.docker`; `PUBLIC_APP_URL` must match the browser's origin |
