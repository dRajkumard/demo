# Architecture

How Vanika is put together, and why each piece is where it is. This describes
what the code does today, not an intended future state; where something is
incomplete it says so.

---

## The shape

```
                          browser (React, Three.js)
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────┐
│  gateway-service  (NestJS on Fastify)                             │
│    the only door for people. Authenticates, authorises, meters,   │
│    enforces plan limits and capability switches, then forwards.   │
└───────┬──────────────────────┬──────────────────────┬─────────────┘
        │                      │                      │
        ▼                      ▼                      ▼
  srm-service            ai-proxy               ubuntu-sandbox
  (NestJS)               (FastAPI)              (ROS 2, colcon)
  the robot model,       model routing,         builds packages
  simulation, fleet      generation, repair     over a socket proxy
        │                      │
        ▼                      │
    Kafka ──► sim-worker ──────┘
              (PyBullet)
                    │
                    ▼
              Postgres  ◄── redis (rate limits)

  robots in the field ──► /v1/device/fleet/*  (fleet token only)
```

Everything shares one Postgres database. Tenants are separated inside it by
row-level security, not by separate schemas.

---

## The services

### gateway-service

The only service a browser talks to. It owns:

- **Authentication.** A Supabase JWT is verified against JWKS. The guard then
  reads the caller's organisation role from `memberships` on every request, so a
  role change takes effect immediately rather than at next sign-in.
- **Authorisation.** Twelve permissions across four cumulative roles, in
  `permissions.ts`. Routes declare what they need; the guard refuses with a
  message naming the role and the permission.
- **Metering and limits.** Every AI call's tokens, cost and latency are recorded.
  Plan limits gate projects, seats, AI tokens and simulation runs.
- **Capability switches.** Ten feature flags, each with a real refusal behind it.
- **The admin surface.** Users, projects, access, features, organisations,
  providers, routing, evaluation, plans, audit, system metrics.

It holds three Prisma clients on purpose: one for the auth guard, one for
project data, and one for the platform admin. The first two connect as the
unprivileged tenant role; the admin keeps the owner role because it reads across
organisations by design.

### srm-service

Owns the **Standard Robot Model**: the URDF, its versions, staged changes, mesh
inventory, simulation runs and the fleet. Reachable from the browser only
through the gateway's proxy, and directly by robots on the five device paths.

### ai-proxy

All model traffic. It holds the route table (conversation, coding, debugging),
the failover chains, intent classification, prompt expansion, URDF and CAD
generation, the prompt cache, and the usage ledger. It never touches the
database; everything it needs arrives in the request.

### sim-worker

Consumes simulation jobs from Kafka, runs them in PyBullet, and publishes
results. Each run is independent, so replicas are simulations in parallel.

### ubuntu-sandbox

A ROS 2 container where `colcon` builds a project's workspace. The gateway
drives it through an haproxy **socket proxy** that allows a short list of
read-only Docker calls plus exec into this one container by name. Creating
containers, mounting the host and reaching other containers are all denied.

---

## How a request flows

### A conversation

1. Browser posts to `/v1/ai/converse`.
2. The gateway authenticates, checks `ai.use`, checks the org is not suspended,
   checks the plan's token allowance and the per-org rate limit.
3. It attaches, server-side: the project's intake answers, the platform's
   routing, the organisation's own provider routing, the sealed provider keys
   opened for this request only, and the capability switches.
4. The AI proxy classifies the message, extracts intent, and dispatches to the
   handle the routing named — building an ephemeral client when the credential
   is the organisation's own.
5. Usage rides back inline (`usage` on JSON, an `event: usage` before `done` on
   a stream). The gateway prices it and writes `ai_usage_events`.

The key property: **the browser never sees a provider key, and never chooses a
model.** Both are decided server-side from configuration the admin controls.

### A simulation

1. `POST /v1/srm/:projectId/sim/run` reaches the SRM through the gateway proxy,
   which checks the caller's role carries `sim.run`.
2. The SRM checks the capability switch for that test, then the plan's monthly
   allowance, then creates the run and publishes to Kafka.
3. The worker pulls the URDF and any meshes, runs the physics, and publishes the
   result; the SRM consumer writes it back. The recording carries the base pose
   **and every movable joint's angle** at 60 Hz, each column named `j:<joint>`,
   so the replay animates the robot's own joints rather than sliding a rigid
   body. Columns are read by name, so a recording made before joints were
   captured still replays.
4. A failed run can be handed to `/v1/ai/repair`, which is described below.

Three things run on top of that one path, and none of them adds physics:

- **The world matrix** queues the robot against every shipped world at once. One
  run says it settles somewhere; the matrix says whether it survives everywhere.
- **A saved environment** is a shipped world plus a team's own changes, stored in
  the shape a run already accepts and validated by the schema the worker already
  enforces. Saving one therefore cannot express anything a run would refuse.
- **A sweep** runs the same robot at a series of values for one parameter --
  payload mass, push impulse, drive speed, ground friction. The design question
  is rarely "does it survive 5 kg" but "how much before it does not", and each
  run records which series and value it belongs to so the results read as a
  curve. The summary is careful: a sweep tests points, so a boundary is reported
  as the interval between the largest value that coped and the smallest that did
  not, a series where everything passed is reported as a limit above what was
  tried, and a series where a larger value passed after a smaller one failed is
  reported as having no single limit rather than being smoothed into one. That
  last case is not hypothetical -- a quadruped shoved at 4 and 8 Ns fell over,
  and at 20 Ns landed back on its feet.

### Generated code

A request for a node, a launch file or a script is a different job from a
request for a robot, and the two used to be confused at every stage.

1. The classifier picks the `generate_code` tool. Its schema deliberately asks
   the extractor for a *placeholder* in the code field, because the real file is
   written afterwards by the coding route.
2. That second step now exists (`code_generation.py`). It runs on the
   `generate_code` task, which an admin can point at its own provider and model,
   and it puts the robot's real joint and link names into the prompt where the
   project has them, so the node names this robot's joints rather than examples.
   A file cut off by the output limit says so in a comment rather than being
   returned as if complete.
3. The browser routes the result by what came back, not by the intent's name.
   `generate_code` accepts urdf as a language, so a urdf payload -- or any
   payload with a `<robot>` root -- stays in the model channel, and everything
   else becomes a named source file.
4. The file is *offered*, not written. The Code tab shows it with its filename
   and saves it under `generated/` only when the user accepts, the same bargain
   the workspace scaffold makes. From there colcon builds it.

Before this, all four stages were wrong in the same direction: the placeholder
string was the answer, it was written over the project's saved URDF, pushed into
the SRM state as the robot's model, and reported as "Robot URDF & meshes ready".

### A robot in the field

A device has no user session, so it authenticates with the enrolment token it was
given. The gateway's device controller allow-lists five paths and forwards; the
SRM resolves the organisation, project and robot from the token's own row, under
a policy keyed on the token hash so a device can only ever see itself. Commands
are created `pending_confirmation` and withheld until a human confirms them.

---

## Data isolation

Every tenant table carries a row-level security policy of the form
`org_id = nullif(current_setting('app.current_org_id', true), '')::uuid`.

Two things make that real:

1. **The services connect as `vanika_app`**, a role with `NOBYPASSRLS`. For
   months the only role was a superuser, which meant every policy was inert and
   tenants were separated by application code alone.
2. **Every query runs inside a transaction that sets the context.** A query that
   forgets returns *no rows* — not an error. That is the trap to know about: a
   new context-less query looks like an empty result, not a failure.

The `nullif` is not cosmetic. `current_setting(..., true)` returns null only
until something sets it; afterwards the placeholder persists on that pooled
connection and reverts to the empty string, and `''::uuid` raises rather than
comparing false. Without `nullif`, any query legitimately running without
context failed intermittently, on connections that had previously carried one.

Three self-access policies let the auth guard work before an organisation
context exists: a user may see their own memberships, their own user row and
their own sessions.

---

## Bringing your own key

An organisation configures its own AI providers in the product rather than in an
env file.

- A catalogue of sixteen templates carries each provider's endpoint, wire
  protocol, model-list path and free-tier terms. Nearly all speak the
  OpenAI-compatible protocol, so one client path serves them; Anthropic has its
  own.
- Keys are sealed with AES-256-GCM and never returned to a client — only a
  masked hint and the last test result.
- A key is tested against the provider *before* it is stored, and the model list
  the dialog offers is the one that provider just returned. The test proves the
  **key**, not merely that the host answered: several providers serve their
  catalogue publicly, so listing models would pass with an invalid key. Where a
  key is required, one single-token completion is made against a model the
  listing offered. A rejected key and an empty balance are reported differently,
  because a valid key with no credit is correctly configured.
- On each request the gateway resolves the organisation's routing, opens the
  sealed keys for that request only, and attaches both to the body. The proxy
  builds an ephemeral client and **does not fall back** to platform keys: a
  refusal is honest about whose credential failed.

---

## Repairing a robot

`POST /v1/ai/repair` turns a failure into a fix, in two clearly separated parts.

**Deterministic analysers run first and always.** A mass written as element
text, a zero mass on a moving link, a missing collision shape or inertial, a
moving joint with no axis, and collision geometry pointing at mesh files that
were never uploaded. Each has one correct answer a validator can compute, so
each returns the repaired URDF itself rather than advice.

Sizes are derived, never invented: from the link's own primitive visual where
there is one, otherwise from the joint origins — the distance between a link and
the links it joins is that segment's real length. Where neither is available the
text says the number is a default, in those words.

**The model is asked only for judgement** — why a robot topples, what a scenario
demands — with the exact error, the robot's real structure and the computed
repairs already in the prompt so it does not repeat them. Its proposals are
labelled by origin and confidence, and a model failure degrades to the rules
alone.

---

## Resource behaviour

The whole stack idles at roughly 900 MB. Every service carries a memory and CPU
ceiling several times its measured steady state, so one runaway process cannot
take the machine — the failure Redpanda produced before it was capped to one
core and 1.4 GB.

On Windows, `VmmemWSL` can appear enormous while containers use very little.
That gap is Linux page cache inside the WSL2 virtual machine, inflated by Docker
build cache. `deploy/README.md` covers the three fixes in order of effect.

---

## What is not finished

Stated plainly, because a document that claims completeness is worth less than
one you can trust.

- **Payments.** Plans, limits and statements exist and are enforced; no payment
  provider is wired, so nothing is charged.
- **The CAD executor** runs model-generated Python in an ordinary subprocess
  behind an AST screen and a network block. Real isolation (gVisor, Firecracker)
  is the right answer before untrusted traffic.
- **Kubernetes leaves the sandbox out** rather than shipping a privileged pod;
  the Code tab's build feature should be switched off there, or the sandbox run
  deliberately as a privileged sidecar.
- **Two provider accounts have no balance** in the reference deployment, so
  cross-vendor failover has nowhere to go until they are topped up.
- **Training a control policy.** There is none, and nothing here claims
  otherwise. What exists is design search: sweeping a parameter across a series
  and reading the boundary. Learning a gait or a controller is a different
  problem needing a different runtime.
- **The URDF is edited as text.** Adding, removing and re-shaping parts, and
  attaching meshes, all patch the XML directly, because the XML is the robot and
  regenerating it from a parsed model would drop everything that model does not
  carry -- materials, transmissions, gazebo tags, plugins, comments.
