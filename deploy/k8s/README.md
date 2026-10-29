# Running Vanika on Kubernetes

The compose file is the source of truth for how the services fit together. These
manifests mirror it: same images, same environment, same health checks, same
resource ceilings. Nothing here is generated at deploy time, so what you read is
what runs.

## Quick start

```bash
# 1. Secrets. Never commit these; the installer generates the same three.
kubectl create namespace vanika
kubectl -n vanika create secret generic vanika-secrets \
  --from-literal=INTERNAL_API_KEY="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')" \
  --from-literal=PROVIDER_ENCRYPTION_KEY="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')" \
  --from-literal=APP_DB_PASSWORD="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')" \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')" \
  --from-literal=SUPABASE_URL="https://YOUR-PROJECT.supabase.co" \
  --from-literal=SUPABASE_SERVICE_ROLE_KEY="..." \
  --from-literal=MISTRAL_API_KEY="..."

# 2. Everything else.
kubectl -n vanika apply -f .

# 3. Watch it come up.
kubectl -n vanika get pods -w
kubectl -n vanika port-forward svc/frontend 8080:80
```

## What differs from compose, and why

**Postgres is a StatefulSet with a PersistentVolumeClaim.** A Deployment would
lose the database on reschedule. For anything beyond evaluation use a managed
database (RDS, Cloud SQL, Azure Database) and point `DATABASE_URL` at it; the
row-level security this product relies on works the same way there.

**The tenant role still matters.** `APP_DATABASE_URL` must point at the
unprivileged `vanika_app` role, not the owner. Row-level security is only
enforced because the services connect as a role that cannot bypass it. The
gateway's entrypoint creates and passwords that role from `APP_DB_PASSWORD` on
first start.

**The sandbox needs a Docker socket.** `ubuntu-sandbox` builds ROS 2 workspaces,
which the gateway drives through a read-only socket proxy. On Kubernetes that
pattern does not translate directly: either run the sandbox as a privileged
sidecar with its own containerd socket, or disable the Code tab's build feature
from the admin (Features → Build workspace). The manifests here leave it out
rather than shipping a privileged pod you did not ask for.

**Resource requests and limits are set on every pod**, from the same measured
figures as the compose ceilings. Requests are the steady state, limits are
several times that.

## Ingress

`ingress.yaml` assumes an nginx ingress controller and cert-manager. Change the
host and the issuer, or delete it and use your own. The only requirement is that
the browser can reach the frontend and the gateway on the same origin, or that
`CORS_ORIGIN` names where the frontend is served from.

## Scaling

- **gateway-service, srm-service, ai-proxy, frontend** are stateless; raise
  replicas freely.
- **sim-worker** consumes from Kafka; more replicas means more simulations in
  parallel. Each run is independent.
- **postgres, redis, kafka** are single-instance here. Use managed equivalents
  in production.
