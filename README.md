# livemask-ci-cd
LiveMask CI/CD pipelines, GitHub Actions workflows, deployment automation, infrastructure as code, and multi-repo coordination scripts

## Local Dev Runtime

Use `infra/docker-compose.local.yml` for the long-lived local development
runtime. It runs the shared `livemask-local` compose project and mounts sibling
repo source trees into the containers.

The local dev ports are fixed by the compose file so every AI editor and
terminal window uses the same entrypoints:

| Service | URL / port |
| --- | --- |
| Backend | `http://127.0.0.1:18080` |
| Admin | `http://127.0.0.1:3001` |
| Website | `http://127.0.0.1:3002` |
| App Web | `http://127.0.0.1:3003` |
| NodeAgent | `http://127.0.0.1:19090` |
| Postgres | `127.0.0.1:15432` |
| Redis | `127.0.0.1:16379` |

Recommended entry (hot reload **on by default**):

```bash
bash scripts/local-dev.sh start
bash scripts/local-dev.sh status
bash scripts/local-dev.sh logs --services backend
```

`local-dev.sh` / `runtime.sh` always merge `infra/docker-compose.hot.yml` in
local mode unless you pass `--no-hot-reload` or set
`LIVEMASK_LOCAL_HOT_RELOAD=false`.

Hot reload behavior:

- **Admin / Website**: native dev servers with polling watchers (`HMR`)
- **Backend / Job Service / NodeAgent**: checksum watcher on mounted Go sources,
  rebuild temp binary, restart only that process
- Does **not** run `docker compose down`, delete volumes, pull branches, or
  mutate task state

Admin and Website local containers default to the shared dev API
`https://api.livemask-vpn.com`, so `http://127.0.0.1:3001` and
`http://127.0.0.1:3002` show real dev data during frontend validation.
Override `BACKEND_INTERNAL_URL`, `VITE_API_BASE_URL`, or `VITE_PROXY_TARGET`
only when intentionally testing against the source-mounted local Backend.

Website can still be pointed at a chosen API with `VITE_API_BASE_URL` and
`VITE_PROXY_TARGET` when you intentionally want frontend-only hot reload or a
specific Backend target.

Manual compose (equivalent to default hot reload):

```bash
docker compose \
  --profile admin \
  --profile website \
  --profile nodeagent \
  --profile job-service \
  -f infra/docker-compose.local.yml \
  -f infra/docker-compose.hot.yml \
  up -d
```

Disable hot reload explicitly:

```bash
bash scripts/local-dev.sh start --no-hot-reload
# or
LIVEMASK_LOCAL_HOT_RELOAD=false bash scripts/local-dev.sh start
```

`livemask-app` is not managed by Docker. Use the local Flutter SDK for app
build/run refresh.

## Development Flow

The old task-branch, ledger, lease, Cursor continuation, completion-evidence,
and issue-close guard automation has been removed. New work follows the current
MVP plan and AI editor rules in `livemask-docs`.

Recommended flow:

1. Start from `dev` and create a local `task/*` branch for the work.
2. Make the code/doc change locally on that task branch.
3. Run focused repo tests or smoke checks.
4. Merge the task branch into local `dev` with `scripts/dev-merge-guard.sh`.
5. Push `dev` through `scripts/dev-merge-guard.sh --push`.

Local branches do not need to be pushed to GitHub before merge. A push to
`dev` is enough for the dev runtime automation to rebuild and redeploy the
affected service.

Completed task work must not stop at local validation. The task branch must be
merged into `dev` and `origin/dev` must be pushed through
`scripts/dev-merge-guard.sh --push`.

## Branch Protection

Use `scripts/apply-branch-protection.sh` to apply the baseline GitHub branch
protection for LiveMask `dev` and `main` branches:

```bash
DRY_RUN=true bash scripts/apply-branch-protection.sh
bash scripts/apply-branch-protection.sh
```

The baseline protection disallows force pushes and branch deletion. It does not
yet require named status checks because some repos still use different check
names; tighten required checks once each repo has stable green CI on `dev`.

The local runtime is persistent by default. Do not run `stop`, `down`,
`restart`, `docker compose down`, or process-kill cleanup unless the user
explicitly asks for that action.

## Dev Runtime Validation

`Staging Smoke` has been removed. Runtime validation now happens through the
persistent `Dev Runtime Deploy` workflow after changes are merged into `dev`.
Do not start a separate `livemask-staging-*` test stack on the public dev
server. `livemask-dev` and `livemask-stage`/`livemask-staging` are a
one-or-the-other choice on the same host, because they use the same independent
service ports.

Validation is **dev-only**. Do not run acceptance smoke from `task/*`,
`codex/*`, or any other feature branch. A task branch can run local/unit
prechecks, but final CI/CD evidence must come after the task branch is merged
into `dev`, pushed to `origin/dev`, and rebuilt from `dev`.

NodeAgent-protocol smoke rules (mandatory for local runtime):

- `scripts/protocol-endpoint-smoke.sh` and `scripts/protocol-capability-smoke.sh`
  must use an existing real node (default node name: `local-nodeagent`).
- The scripts no longer create virtual smoke nodes for protocol validation.
- Override only when needed with `LIVEMASK_SMOKE_NODE_ID` and optionally
  `LIVEMASK_SMOKE_NODE_NAME`.
- If a new node is required, provision it as a **real NodeAgent container**
  (for example by scaling `nodeagent` service in local compose), let it register,
  run smoke, then remove/scale-down after test. Do not use fake DB-only nodes.
- Each run must include backend + nodeagent container log sanity checks.

The workflow and compose defaults set service refs to `dev`. `scripts/validate-dev-ref.sh`
fails fast if a smoke run tries to use a non-`dev` service ref.

## Public Dev Runtime

`Dev Runtime Deploy` runs `infra/docker-compose.staging.yml` as the public dev
stack. Public domains terminate at nginx on `80/443` and proxy to independent
host ports:

| Service | Public domain | Host port |
| --- | --- | --- |
| Website | `www.livemask-vpn.com` | `64000` |
| Admin | `admin.livemask-vpn.com` | `64001` |
| Job Service | `job.livemask-vpn.com` | `64002` |
| Backend API | `api.livemask-vpn.com` | `64003` |
| NodeAgent control | direct host port | `65000` |
| NodeAgent VPN business pool | direct host ports | `65001-65535/tcp,udp` |

Regenerate nginx with `scripts/setup-public-nginx.sh` after port changes. The
script writes `api`, `www`, `admin`, and `job` vhosts and proxies them to the
ports above.

Each runtime service can be recreated independently. The dev compose file does
not use service-level `depends_on` between Backend, Admin, Website, Job Service,
and NodeAgent. Frontend services default to the shared dev API for real data;
backend-facing services use stable host-port endpoints such as
`http://host.docker.internal:64003` instead of Docker service DNS, so a single
service restart does not require unrelated application containers to be on the
same compose network.

On the public runtime host, enable either `livemask-dev` or
`livemask-stage`/`livemask-staging`, not both. `deploy-service.sh` enforces this
guard before deployment and fails if the other stack is already running.

Recommended targeted deploy entry:

```bash
bash scripts/deploy-service.sh --service backend --compose infra/docker-compose.staging.yml --start-deps
bash scripts/deploy-service.sh --service admin --compose infra/docker-compose.staging.yml
bash scripts/deploy-service.sh --service website --compose infra/docker-compose.staging.yml
bash scripts/deploy-service.sh --service job-service --compose infra/docker-compose.staging.yml
bash scripts/deploy-service.sh --service nodeagent --compose infra/docker-compose.staging.yml
```

`deploy-service.sh` never runs `docker compose down`, never deletes volumes, and
always uses `docker compose up -d --build --no-deps <service>` for app services.
Use `--start-deps` only when PostgreSQL/Redis should be ensured before deploying
Backend or Job Service.

The GitHub `Dev Runtime Deploy` workflow also accepts a `service` input
(`all`, `backend`, `admin`, `website`, `job-service`, `nodeagent`). Repository
dispatch callers can pass the same value as `client_payload.service`.

Backend and Job Service still need reachable PostgreSQL/Redis at runtime.
Admin, Website, and NodeAgent still need their configured Backend/API endpoint
reachable at runtime.

Current default smoke target:

```text
http://127.0.0.1:64003
```

Override when needed:

```bash
LIVEMASK_SMOKE_HTTP_PORT=18081 bash scripts/smoke.sh
LIVEMASK_SMOKE_URL=https://staging.example.com bash scripts/smoke.sh
```

Replace the placeholder nginx service with real LiveMask backend, admin,
website, app support services, Redis, and database services as those deployment
artifacts become available.
