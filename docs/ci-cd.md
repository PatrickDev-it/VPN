# CI/CD Pipeline Reference

> GitHub Actions workflow documentation.
> For service configuration see [services.md](services.md).
> For operational procedures see [operations.md](operations.md).

---

## Overview

Three GitHub Actions workflows automate quality checks, security scanning, and deployment.

| Workflow | File | Trigger | Purpose |
|----------|------|---------|---------|
| **CI** | `.github/workflows/ci.yml` | Push/PR to `main` or `develop` | Lint → Test → Build → Smoke |
| **CD** | `.github/workflows/cd.yml` | Push to `main` or tag `v*.*.*` | Publish to GHCR → SSH deploy |
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
| `lint` | ubuntu-latest | Runs `ruff check .` on all Python files |
| `test` | ubuntu-latest | Runs `pytest --tb=short -q` (requires `lint` to pass) |
| `compose-validate` | ubuntu-latest | Runs `docker compose config -q` with `.env.example` |
| `build` | ubuntu-latest | Builds all 4 Docker images with layer caching via GitHub Actions Cache |
| `smoke` | ubuntu-latest | Starts the full stack, checks 200 on authenticated request, checks 407 on unauthenticated, tears down |

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
    branches: [main]          # automatic deploy on main merge
  tags:
    - "v*.*.*"                # semantic version tag deploy
  workflow_dispatch:
    inputs:
      force_redeploy: ...     # manual trigger with optional force flag
```

Only one deploy runs at a time (`cancel-in-progress: false` — deploys are never cancelled mid-run).

### Jobs

#### `publish` — Push images to GHCR

1. Logs into `ghcr.io` using the workflow's auto-generated `GITHUB_TOKEN`
2. Extracts image tags via `docker/metadata-action`:
   - `latest` (main branch only)
   - `sha-<short-commit>` (always)
   - `vX.Y.Z` and `vX.Y` (on semver tags)
3. Builds and pushes the mitmproxy image to `ghcr.io/<owner>/<repo>/mitmproxy`
4. Layer cache shared via GitHub Actions Cache

#### `deploy` — SSH deploy to VPS

Requires the `production` environment (configured in GitHub repository settings).

Steps executed on the remote VPS via `appleboy/ssh-action`:

```bash
git fetch origin main && git reset --hard origin/main  # pull latest code
docker login ghcr.io ...                                # authenticate to GHCR
docker compose pull mitmproxy                           # pull updated image
docker compose up -d --remove-orphans                   # rolling update
docker image prune -f                                   # clean dangling layers
docker compose ps mitmproxy | grep -q "Up"             # health check
```

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

## Required GitHub Repository Secrets

Configure these in `Settings → Secrets and variables → Actions`:

| Secret | Required By | Description |
|--------|------------|-------------|
| `VPS_HOST` | `cd.yml` | VPS public IP address or hostname |
| `VPS_USER` | `cd.yml` | SSH username on the VPS (e.g. `ubuntu`, `deploy`) |
| `VPS_SSH_KEY` | `cd.yml` | Private SSH key (RSA or Ed25519) authorized on the VPS |
| `VPS_SSH_PORT` | `cd.yml` | SSH port (optional — defaults to `22`) |
| `VPS_PROJECT_PATH` | `cd.yml` | Absolute path to the cloned repository on the VPS (e.g. `/opt/vpn`) |

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

This triggers both `ci.yml` (full validation) and `cd.yml` (tagged release deploy to GHCR + VPS).

Image will be published as:
```
ghcr.io/<owner>/<repo>/mitmproxy:v1.2.0
ghcr.io/<owner>/<repo>/mitmproxy:v1.2
ghcr.io/<owner>/<repo>/mitmproxy:latest
```

---

## Rollback Procedure

### Automatic (recommended)

The deploy job runs a health check at the end:
```bash
docker compose ps mitmproxy | grep -q "Up"
```
If it fails, the workflow step fails and the deploy is marked failed in GitHub — no automatic rollback occurs. The VPS remains in whatever state the partially-applied deploy left it.

### Manual Rollback via SSH

```bash
ssh <user>@<vps-host>
cd <project-path>

# Roll back to a specific image tag
# Edit docker-compose.yml or use COMPOSE_IMAGE_TAG env var
docker compose pull mitmproxy  # or pin a specific digest

# Alternatively, roll back git commit and redeploy
git log --oneline -10
git reset --hard <previous-safe-commit>
docker compose up -d
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
