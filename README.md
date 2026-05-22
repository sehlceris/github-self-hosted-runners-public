# GitHub Actions Self-Hosted Runner

Self-hosted GitHub Actions runner providing free CI/CD for GitHub repositories
with full Docker support (test containers, Docker builds, container-based actions).

## ⚠️ Run only inside a dedicated VM

This runner mounts the host's Docker socket (`/var/run/docker.sock`) so that
workflows can run `docker build`, testcontainers, etc. **Anything with access
to the Docker socket is effectively root on the host** — a workflow can launch
a privileged container that mounts `/` and reads or writes any file as root.

Treat the runner's host as a single-purpose disposable machine:

- Run **only inside a VM** (or a dedicated physical host you can wipe). Never
  on your laptop or a shared server.
- Never accept PRs from untrusted contributors on a repo this runner serves —
  PR code runs with the same privilege as the runner.
- Keep the VM isolated on the network if it has access to anything sensitive.

## Getting started

On a dedicated VM with Docker installed:

```sh
# 1. Clone the repo (anywhere — /opt is a common choice for shared VMs)
git clone <this-repo-url> /opt/github-runner
cd /opt/github-runner

# 2. Configure the runner
cp .env.example .env
$EDITOR .env   # set GITHUB_PAT, GITHUB_ORG (or GITHUB_REPO_URL), RUNNER_NAME, RUNNER_LABELS

# 3. Make the runtime dirs writable by the container (UID 1000)
#    One-time only. The runner-*/ and cache/*/ dirs are container-managed
#    scratch space — humans don't need to own them.
sudo chown -R 1000:1000 runner-1 runner-2 cache

# 4. Bring up the runners
docker compose up -d

# 5. Verify they registered
docker compose logs -f
```

The runners should appear as **Idle** at
`github.com/organizations/{org}/settings/actions/runners` (or the repo's
runner settings page) within ~30 seconds.

**Multi-user VMs:** anyone in the host's `docker` group can run
`docker compose up` regardless of their own UID — the container writes as
UID 1000 into the pre-owned runtime dirs. The chown step only needs to
happen once after cloning. See [Data layout](#data-layout) for what lives
where.

## Services

| Service | Image | Purpose |
|---|---|---|
| `runner` | `myoung34/github-runner:latest` | GitHub Actions runner daemon |

## Ports

None — the runner connects outbound to GitHub over HTTPS. No inbound ports
or Traefik integration required.

## Data layout

All runtime state lives next to `docker-compose.yml` so the deployment is
self-contained. `${PWD}` in the compose file expands to this directory at
`docker compose up` time, so host and in-container paths match — which
Docker-in-Docker requires (child containers spawned via the mounted socket
inherit host paths).

```
.
├── docker-compose.yml
├── runner-1/        # workspace for runner 1 (job checkouts, build artifacts)
├── runner-2/        # workspace for runner 2
└── cache/
    ├── nx/          # Nx computation cache (shared across runners)
    ├── npm/         # npm package cache
    ├── pnpm/        # pnpm content-addressable store
    └── tool-cache/  # actions/setup-* tool cache (Node, Python, etc.)
```

Each dir holds a `.gitkeep` and its contents are gitignored.

The runner is **stateless** for registration — it re-registers via PAT on
every container start. `EPHEMERAL=true` means the runner deregisters after
each job, so the workdirs are scratch space; only the `cache/` dirs are
meant to persist across restarts.

| Mount | Container path | Purpose |
|---|---|---|
| `./runner-N` | `${PWD}/runner-N` | Per-runner job workspace |
| `./cache/nx` | `${PWD}/runner-N/work/_nx-cache` | Nx computation cache |
| `./cache/npm` | `/home/runner/.npm` | npm package cache |
| `./cache/pnpm` | `/home/runner/.local/share/pnpm/store` | pnpm store |
| `./cache/tool-cache` | `/opt/hostedtoolcache` | `actions/setup-*` tool cache |

Workflows should set `NX_CACHE_DIRECTORY=${RUNNER_WORKDIR}/_nx-cache` (or
configure `cacheDirectory` in `nx.json`) so Nx writes to the persistent
mount. The npm, pnpm, and tool caches are picked up automatically at their
default paths — no workflow configuration needed.

## Prerequisites

### 1. GitHub Organisation (recommended)

GitHub does not support user-level runners. Your options:

- **Create a free GitHub org** at https://github.com/organizations/plan —
  one runner serves all repos in the org. This is the recommended path.
- **Repo-scoped runner** — one runner instance per repo. Set
  `RUNNER_SCOPE=repo` and `GITHUB_REPO_URL`.

### 2. Personal Access Token (PAT)

Create a **classic** PAT at Settings → Developer settings → Personal access
tokens → Tokens (classic):

| Runner scope | Required PAT scopes |
|---|---|
| `org` | `admin:org` (all) |
| `repo` (private) | `repo` (all) |
| `repo` (public) | `public_repo` |

Fine-grained PATs have inconsistent support for runner registration — use
classic PATs.

### 3. Add PAT to Ansible Vault

```sh
cd ansible
ansible-vault edit group_vars/all/vault.yml
```

Add:

```yaml
vault_github_runner_pat: ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### 4. Configure Variables

Edit `ansible/group_vars/all/vars.yml` and set:

```yaml
github_runner_scope: org
github_runner_org: your-org-name
github_runner_name: manifold-runner
github_runner_labels: self-hosted,linux,arm64
```

Or for repo scope:

```yaml
github_runner_scope: repo
github_runner_repo_url: https://github.com/your-username/your-repo
```

### 5. Deploy

```sh
cd ansible && ansible-playbook playbook.yml --tags apps
```

### 6. Verify Registration

- **Org runner:** `github.com/organizations/{org}/settings/actions/runners`
- **Repo runner:** `github.com/{user}/{repo}/settings/actions/runners`

The runner should appear as **Idle** within ~30 seconds of container start.

### 7. Test with a Workflow

Create `.github/workflows/test.yml` in any repo (org-scoped) or the
configured repo (repo-scoped):

```yaml
name: Test self-hosted runner
on: push
jobs:
  test:
    runs-on: [self-hosted, linux, arm64]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Hello from $(hostname)"
      - run: docker version  # verify Docker access
```

## Docker-in-Docker / Test Containers

The runner is configured for full Docker support inside CI jobs:

- **Docker socket** is mounted, so jobs can run `docker build`, `docker run`,
  etc. See the [VM warning](#-run-only-inside-a-dedicated-vm) — this is what
  makes the runner host-root-equivalent.
- **Work directory** uses `${PWD}/runner-N` mounted at the same path inside
  the container. This is critical — child containers spawned by the runner
  inherit host paths, so the path must be identical inside and outside.
- **Testcontainers**, **docker-compose in CI**, and `container:` workflow
  directives all work out of the box.

### ARM64 Considerations

This runner is on an ARM64 (aarch64) host. CI jobs that pull x86-only images
will fail. Use multi-arch images or add `platform: linux/arm64` to your
workflow containers. Most official images (Node, Python, Go, Postgres, Redis,
etc.) support ARM64.

## Ephemeral Mode

`EPHEMERAL=true` is set by default — the runner exits after completing one
job, and Docker restarts it fresh (`restart: always`). This guarantees a
clean environment for every job with no state bleed between runs.

If you need persistent runner state (caches, tool installations), set
`EPHEMERAL=false` in the `.env` and add a data volume for registration state.
See the `myoung34/github-runner` docs for `CONFIGURED_ACTIONS_RUNNER_FILES_DIR`.

## GitHub App Authentication (alternative to PAT)

For better security, especially with org runners, use a GitHub App instead of
a PAT:

1. Create an app at `github.com/organizations/{org}/settings/apps/new`
2. Permissions: Repository → Actions (Read), Administration (Read & Write),
   Metadata (Read); Organization → Self-hosted runners (Read & Write)
3. Install the app to your org
4. Note the App ID and generate a private key (PEM)
5. Set in `.env`:
   ```
   APP_ID=123456
   APP_PRIVATE_KEY=-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----
   APP_LOGIN=your-org-name
   ```
6. Remove `GITHUB_PAT` / `ACCESS_TOKEN` from `.env`

## Scaling

Run multiple concurrent runners:

```sh
# Scale to 3 runners
docker compose up -d --scale runner=3
```

When scaling, set `RUNNER_NAME` to empty and ensure the image uses its default
random suffix naming. Each replica registers as a separate runner in GitHub.

**Note:** When scaling, remove the `container_name` from `compose.yml` (Docker
requires unique container names).

## Updating

```sh
docker compose pull && docker compose up -d
```

The runner deregisters cleanly on stop and re-registers on start.

## Security

- **Run only inside a dedicated VM.** The Docker socket mount makes any
  workflow effectively root on the host — see the warning at the top.
- **Do not use for public repos** that accept PRs from untrusted
  contributors. PR code runs with the runner's privileges.
- Keep the PAT in `.env` (gitignored) or a secret manager, never in
  version control.
- Consider a GitHub App over a PAT for anything beyond personal use.
- `EPHEMERAL=true` prevents state bleed between jobs.