# CI/CD Pipeline Reference

> GitHub Actions workflow documentation.
> For service configuration see [services.md](services.md).
> For operational procedures see [operations.md](operations.md).

---

## Overview

Four GitHub Actions workflows automate quality checks, security scanning, release deployment, and
operator-controlled provider provisioning.

| Workflow | File | Trigger | Purpose |
|----------|------|---------|---------|
| **CI** | `.github/workflows/ci.yml` | Push/PR to `main` or `develop` | Lint → Test → Build → Smoke |
| **CD** | `.github/workflows/cd.yml` | Tag `v*.*.*` or manual dispatch | Verify → publish immutable image → SSH deploy |
| **Deploy** | `.github/workflows/deploy.yml` | Manual dispatch | Reuse CI → Terraform/Ansible provider deployment |
| **Security** | `.github/workflows/security.yml` | Push/PR to `main` + weekly cron | Trivy + pip-audit |

---

## CI Workflow (`ci.yml`)

### Trigger

```yaml
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]
```

Concurrent runs on the same ref are cancelled automatically (`cancel-in-progress: true`).

### Jobs and Dependencies

```
lint ──────┬──► compose-validate ──┐
           │                       ├──► build ──► smoke
           └──► test ──────────────┘
```

| Job | Runner | What It Does |
|-----|--------|-------------|
| `lint` | ubuntu-latest | Runs `ruff check vpn` on the application tree |
| `test` | ubuntu-latest | Runs `pytest vpn/tests --tb=short -q` (requires `lint` to pass) |
| `compose-validate` | ubuntu-latest | Validates `vpn/docker-compose.yml` with the root `.env.example` |
| `build` | ubuntu-latest | Builds all 4 Docker images with layer caching via GitHub Actions Cache |
| `smoke` | ubuntu-latest | Starts the stack; verifies service state, internal reachability, 407 enforcement, and authenticated admission |

### Image Caching

Docker layer cache is shared across runs using:
```yaml
cache-from: type=gha
cache-to: type=gha,mode=max
```

This significantly reduces build time on repeated runs.

---

## CD Workflow (`cd.yml`)

### Trigger

```yaml
on:
  push:
    tags:
      - "v*.*.*"             # semantic version release
  workflow_dispatch:         # explicit operator-controlled release
```

Only one deploy runs at a time (`cancel-in-progress: false` — deploys are never cancelled mid-run).

### Jobs

#### `verify` — Gate the release candidate

1. Installs the pinned production and development dependencies
2. Runs Ruff and the complete pytest suite against `vpn/`
3. Validates the Compose model using the root `.env.example`

#### `publish` — Push images to GHCR

1. Logs into `ghcr.io` using the workflow's auto-generated `GITHUB_TOKEN`
2. Extracts image tags via `docker/metadata-action`:
   - `latest` (manual dispatch from `main` only)
   - `sha-<short-commit>` (always)
   - `vX.Y.Z` and `vX.Y` (on semver tags)
3. Builds `vpn/Dockerfile` and pushes the mitmproxy image to `ghcr.io/<owner>/<repo>/mitmproxy`
4. Layer cache shared via GitHub Actions Cache

#### `deploy` — SSH deploy to VPS

Requires the `production` environment (configured in GitHub repository settings).

Steps executed on the remote VPS via `appleboy/ssh-action`:

```bash
git fetch --prune --tags origin                          # refresh release refs
git checkout --force --detach <release-sha>              # exact released revision
cd vpn                                                   # application root
docker login ghcr.io ...                                 # authenticate to GHCR
docker compose --env-file ../.env pull mitmproxy         # pull digest-pinned image
docker compose --env-file ../.env up -d --no-build       # restart without rebuilding
docker compose ... ps --status running --services        # health check
```

The workflow exports `MITMPROXY_IMAGE` as a lowercase GHCR repository plus the immutable digest
returned by the publish step. Production therefore consumes the exact artifact that was built.

---

## Security Workflow (`security.yml`)

### Trigger

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: "0 6 * * 1"   # every Monday at 06:00 UTC
```

### Jobs

| Job | Tool | Scope | Fail Condition |
|-----|------|-------|---------------|
| `trivy-image` | Trivy | mitmproxy Docker image | CRITICAL or HIGH unfixed CVEs |
| `trivy-fs` | Trivy | Repository filesystem + deps | CRITICAL or HIGH |
| `pip-audit` | pip-audit | `requirements.txt` | Any known vulnerability |

Results are uploaded to the **GitHub Security tab** as SARIF reports (visible under
`Security → Code scanning alerts`).

---

## Multi-provider Deployment Workflow (`deploy.yml`)

This operator-controlled workflow first invokes `ci.yml` as a reusable gate, then selects one target:

- `ubuntu`: Ansible against an explicitly supplied host;
- `aws`: Terraform provisioning followed by Ansible configuration;
- `gcp`: Terraform provisioning followed by Ansible configuration;
- `azure`: Terraform provisioning followed by Ansible configuration.

Provider support is a deployment adapter boundary, not a universal portability claim. Each provider must
be validated with its own credentials, plan, ephemeral environment, smoke test, and cleanup evidence before
being presented as a verified target.

---

## Required GitHub Repository Secrets

Configure these in `Settings → Secrets and variables → Actions`:

| Secret | Required By | Description |
|--------|------------|-------------|
| `VPS_HOST` | `cd.yml` | VPS public IP address or hostname |
| `VPS_USER` | `cd.yml` | SSH username on the VPS (e.g. `ubuntu`, `deploy`) |
| `VPS_SSH_KEY` | `cd.yml` | Private SSH key (RSA or Ed25519) authorized on the VPS |
| `VPS_SSH_PORT` | `cd.yml` | SSH port (optional — defaults to `22`) |
| `VPS_PROJECT_PATH` | `cd.yml` | Absolute repository root on the VPS; the workflow enters its `vpn/` child directory |

`GITHUB_TOKEN` is provided automatically by GitHub Actions — no manual configuration required.

### Generating a Dedicated Deploy SSH Key

```bash
# On your local machine
ssh-keygen -t ed25519 -C "github-actions-deploy" -f deploy_key -N ""

# Copy the public key to the VPS
ssh-copy-id -i deploy_key.pub <user>@<vps-host>

# Add the private key content to GitHub:
# Settings → Secrets → VPS_SSH_KEY → paste contents of deploy_key
```

---

## GitHub Environments

The `cd.yml` workflow targets the `production` environment, which enables:
- **Required reviewers** — optionally require a manual approval before deploy
- **Deployment protection rules** — branch/tag restrictions
- **Environment secrets** — secrets scoped to production only

To create the environment:
`Settings → Environments → New environment → "production"`

---

## Tagging a Release

```bash
git tag v1.2.0
git push origin v1.2.0
```

This triggers `cd.yml`, whose `verify` job blocks publication and deployment unless lint, tests,
and Compose validation pass. Standard CI also validates every change merged into `main`.

Image will be published as:
```
ghcr.io/<owner>/<repo>/mitmproxy:v1.2.0
ghcr.io/<owner>/<repo>/mitmproxy:v1.2
```

The running deployment is pinned by digest even when human-readable semantic tags are also published.

---

## Rollback Procedure

### Automatic (recommended)

The deploy job runs a health check at the end:
```bash
docker compose --env-file ../.env ps --status running --services | grep -qx "mitmproxy"
```
If it fails, the workflow step fails and the deploy is marked failed in GitHub. No automatic rollback
occurs; the VPS remains in the state reached by the failed rollout.

### Manual Rollback via SSH

```bash
ssh <user>@<vps-host>
cd <project-path>/vpn

# Roll back to a specific image tag
# Edit docker-compose.yml or use COMPOSE_IMAGE_TAG env var
MITMPROXY_IMAGE=ghcr.io/<owner>/<repo>/mitmproxy@sha256:<digest> \
  docker compose --env-file ../.env pull mitmproxy

# Alternatively, roll back git commit and redeploy
git log --oneline -10
git reset --hard <previous-safe-commit>
docker compose --env-file ../.env up -d --no-build
```

### Pull a Specific Image Version

```bash
# On the VPS
docker pull ghcr.io/<owner>/<repo>/mitmproxy:sha-<commit>
# Then update docker-compose.yml image reference and restart
```

---

## Adding a New Workflow Job

1. Add the job definition to the appropriate `.yml` file in `.github/workflows/`
2. Ensure `needs:` dependency chain is correct
3. Test with a PR — CI runs on pull requests before merging
4. Document the new job in this file
5. Update `session.md` with a `ci` type patch entry

---

*See also: [operations.md](operations.md) · [security.md](security.md) · [architecture.md](architecture.md)*
