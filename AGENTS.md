# AGENTS.md — AI Agent Guide

> **Entry point for any AI agent working on this project.**
> Read this file before opening any other file. It maps the codebase, lists hard constraints,
> links to detailed documentation in `docs/`, and defines the mandatory workflow for keeping
> `session.md` up to date.

---

## Cardinal Rule — Language Policy

**All documentation, comments, commit messages, PR descriptions, YAML keys, log messages,
and any human-readable text in this repository must be written in professional English.**
No Italian or any other language is permitted in any tracked file.
This ensures the project is universally readable, maintainable, and suitable for public
open-source distribution at scale.

---

## Project Overview

**Name:** VPS Proxy Stack
**Type:** Authenticated HTTP/HTTPS proxy chain with Tor-based anonymization, containerized via Docker Compose.
**Repository:** https://github.com/PatrickDev-it/VPN
**Primary branch:** `main`
**CI/CD:** GitHub Actions (`.github/workflows/`)

### One-line data flow

```
Client → mitmproxy:8080 (auth + policy + scrub) → Privoxy:8118 (HTTP→SOCKS5) → Tor:9050 → Internet
```

DNS handled locally by **Unbound** (DNSSEC, DNS-over-TLS, ad/tracker sinkhole).

---

## Documentation Map

Read the relevant doc before modifying code. Do not rely solely on this file.

| Document | When to Read |
|----------|-------------|
| [docs/architecture.md](docs/architecture.md) | Before any structural change — understand the full data flow and design rationale |
| [docs/services.md](docs/services.md) | Before modifying Tor, Unbound, Privoxy configs or their Dockerfiles |
| [docs/gatekeeper.md](docs/gatekeeper.md) | Before modifying `app/gatekeeper.py` — auth, policy, scrubbing logic |
| [docs/security.md](docs/security.md) | Before any change that touches networking, capabilities, or TLS |
| [docs/operations.md](docs/operations.md) | For deploy, user management, policy updates, blacklist, troubleshooting |
| [docs/ci-cd.md](docs/ci-cd.md) | For CI/CD pipeline changes, secrets setup, deploy workflow |
| [session.md](session.md) | **Update after every patch** — see mandatory guidelines below |

---

## Repository Layout

```
VPN/
├── AGENTS.md                        ← you are here
├── session.md                       ← patch history (local only, git-ignored)
│
├── .github/
│   └── workflows/
│       ├── ci.yml                   ← lint → test → build → smoke
│       ├── cd.yml                   ← verify → publish digest → deploy via SSH
│       └── security.yml             ← Trivy image/fs scan + pip-audit (weekly)
│
├── docs/                            ← technical reference (committed to git)
│   ├── README.md                    ← docs index and reading order
│   ├── architecture.md              ← data flow, design decisions, limitations
│   ├── services.md                  ← per-service configuration reference
│   ├── gatekeeper.md                ← addon Python hook-by-hook documentation
│   ├── security.md                  ← 5-layer security model
│   ├── operations.md                ← deploy, users, policy, troubleshooting
│   └── ci-cd.md                     ← CI/CD pipeline reference and secrets
│
├── vpn/                             ← application and Compose root
│   ├── app/
│   │   ├── gatekeeper.py            ← core mitmproxy addon
│   │   ├── policy.yaml              ← whitelist and blacklist rules
│   │   ├── users.yaml               ← credentials (git-ignored)
│   │   └── users.yaml.example       ← credential schema template
│   ├── services/                    ← Unbound, Privoxy, and Tor images
│   ├── unbound/                     ← DNS resolver configuration
│   ├── privoxy/                     ← HTTP-to-SOCKS bridge configuration
│   ├── tor/                         ← Tor configuration
│   ├── init/                        ← host and runtime bootstrap scripts
│   ├── cron/                        ← blacklist refresh automation
│   ├── Dockerfile                   ← mitmproxy image
│   ├── docker-compose.yml           ← four-service runtime model
│   ├── requirements.txt             ← production dependencies
│   └── requirements-dev.txt         ← test and lint dependencies
│
├── deploy/                          ← deployment adapters
├── infra/                           ← provider-specific infrastructure code
├── .env.example                     ← environment variable template (52 lines)
└── Makefile                         ← repository-level operational targets
```

---

## Git-Ignored Files (Never Commit)

```
.env                  # secrets — copy from .env.example and fill in
vpn/app/users.yaml    # user credentials — copy from users.yaml.example
ssl-certificates/     # runtime TLS certificates
logs/                 # auth.log and traffic.log (contain IP addresses)
session.md            # local patch history
```

`AGENTS.md` and `docs/` **are tracked in git** and must remain in English.

---

## Code Entry Point

`vpn/app/gatekeeper.py`:
```python
addons = [Gatekeeper()]
```

mitmproxy loads the `Gatekeeper` class automatically and calls the `request(flow)` and
`response(flow)` hooks for every HTTP/HTTPS flow. Everything else in the project is infrastructure.

**Primary hooks:**
- `request(flow)` — authentication, rate limiting, policy enforcement, header stripping (lines 210–280)
- `response(flow)` — traffic logging, JSON/binary ad scrubbing (lines 282–323)

See [docs/gatekeeper.md](docs/gatekeeper.md) for the complete hook-by-hook breakdown.

---

## Key Environment Variables

| Variable | Default | Used In |
|----------|---------|---------|
| `AUTH_MODE` | `basic` | `gatekeeper.py` — `basic` or `token` |
| `RATE_LIMIT_RPM` | `120` | `gatekeeper.py` — max requests per minute per user |
| `RATE_LIMIT_WINDOW_SEC` | `60` | `gatekeeper.py` — sliding window duration |
| `USERS_FILE` | `/app/app/users.yaml` | `gatekeeper.py` — credentials path |
| `POLICY_FILE` | `/app/app/policy.yaml` | `gatekeeper.py` — policy rules path |
| `MITMPROXY_BIND_PORT` | `8080` | `docker-compose.yml` — public proxy port |
| `TLS_MODE` | `selfsigned` | `generate-certs.sh` — `selfsigned`/`letsencrypt`/`cloudpanel` |

Full variable reference: [docs/operations.md](docs/operations.md) and `.env.example`.

---

## Hard Constraints

1. **No secrets in git** — `.env` and `users.yaml` must never be committed.
2. **CONNECT tunnels bypass policy** — HTTPS tunneling via `CONNECT` skips whitelist/blacklist checks (by design, `gatekeeper.py` lines 250–251). Policy applies only to plain HTTP flows.
3. **Policy and users are loaded at startup only** — any YAML change requires `docker compose restart mitmproxy`.
4. **`is_dns_blocked` is fail-closed** — if DNS resolution fails for any reason, the domain is blocked. Do not debug 403 errors without first verifying Unbound is healthy.
5. **Rate limiting is in-memory** — `self.user_requests` resets on every mitmproxy restart. Do not design features that depend on its persistence.
6. **`binary_scrub` replacements must be equal length** — replacing `adPlacements` (12 bytes) with `xxPlacements` (12 bytes) preserves binary offsets. Changing lengths corrupts binary payloads.
7. **`StrictNodes 1` in `torrc` is intentional** — Tor will fail to connect rather than use a non-approved exit country. This is a deliberate privacy-over-availability trade-off. Do not remove without explicit discussion.
8. **All documentation and comments must be in English** — see the Cardinal Rule above.

---

## Common Modification Patterns

### Add a user
1. Generate hash: `echo -n 'password' | sha256sum | cut -d' ' -f1`
2. Generate token: `openssl rand -hex 32`
3. Add the block to `vpn/app/users.yaml`
4. Run `docker compose --env-file ../.env restart mitmproxy` from `vpn/`
5. **Update `session.md`** — mandatory

### Add a policy rule
1. Edit `vpn/app/policy.yaml` (Python regex, case-insensitive)
2. Run `docker compose --env-file ../.env restart mitmproxy` from `vpn/`
3. **Update `session.md`** — mandatory

### Modify Tor exit countries
1. Edit `ExitNodes` / `ExcludeNodes` in `vpn/tor/torrc`
2. Run `docker compose --env-file ../.env restart tor` from `vpn/`
3. **Update `session.md`** — mandatory

### Update DNS blocklist manually
```bash
make update-blacklist && docker compose restart unbound
```

### Trigger a production deploy
Create a tag `vX.Y.Z` or explicitly dispatch the CD workflow. A normal push to `main` never deploys.
See [docs/ci-cd.md](docs/ci-cd.md) for required secrets and rollback procedure.

---

## CI/CD Overview

Four GitHub Actions workflows live in `.github/workflows/`:

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | push/PR to `main` or `develop` | Lint → Test → Build → Smoke |
| `cd.yml` | tag `v*.*.*` or manual dispatch | Verify → publish GHCR digest → SSH deploy |
| `deploy.yml` | manual dispatch | Reuse CI → provider-specific Terraform/Ansible deployment |
| `security.yml` | push/PR + weekly cron | Trivy + pip-audit |

See [docs/ci-cd.md](docs/ci-cd.md) for required GitHub repository secrets and full workflow description.

---

## Mandatory Guidelines for Updating `session.md`

**`session.md` must be updated after every significant patch.**
This is not optional — it is the primary mechanism for maintaining context across agent sessions.

### Entry Format

```markdown
## [PATCH-NNN] Short descriptive title
**Date:** YYYY-MM-DDTHH:MM+HH:MM   ← ISO 8601 with timezone offset (e.g. 2026-06-09T15:30+02:00)
**Type:** feat | fix | hardening | refactor | docs | chore | infra | ci
**Files changed:**
- `path/to/file.ext` — concise description of the change

**What changed:**
Narrative description of the new behavior after this patch.

**Motivation:**
Why this patch was made — bug fixed, feature requested, constraint addressed.

**Notes for agents:**
Non-obvious implications, dependencies, or future constraints introduced by this patch.
Write N/A if none apply.
```

### Mandatory Rules

| Rule | Detail |
|------|--------|
| **Timestamp precision** | Always use ISO 8601 with timezone offset: `2026-06-09T15:30+02:00`. A date-only value is acceptable only when the time is genuinely unknown. |
| **Sequential numbering** | Increment `PATCH-NNN` from the last entry. No gaps. |
| **Correct type** | `feat` = new capability · `fix` = bug fix · `hardening` = security improvement without behavior change · `refactor` = internal rewrite · `docs` = documentation only · `chore` = dependencies/CI/non-functional · `infra` = Dockerfile/compose/init scripts · `ci` = GitHub Actions workflows |
| **List every file changed** | Include configuration files, not just Python source. |
| **"Notes for agents" is mandatory** | Write a note whenever the patch introduces a non-obvious constraint, dependency, workaround, or behavior that would surprise a future reader. Otherwise write `N/A`. |
| **Append-only** | Never delete or rewrite previous entries. Correct a previous entry by appending a new one that references it. |
| **English only** | Every field must be in English. |

### Example Entry

```markdown
## [PATCH-007] Add per-user rate limit override via policy.yaml
**Date:** 2026-06-10T09:15+02:00
**Type:** feat
**Files changed:**
- `app/gatekeeper.py` — `_is_rate_limited()` now reads per-user RPM from `self.config`
- `app/policy.yaml` — added `user_rate_limits` map (username → rpm)

**What changed:**
Individual users can now have a custom RPM limit defined in `policy.yaml` under
`user_rate_limits`. If no per-user value is set, the global `RATE_LIMIT_RPM` env
variable is used as a fallback.

**Motivation:**
CI/CD service accounts need higher throughput than regular users without raising
the global limit.

**Notes for agents:**
The `user_rate_limits` key is optional. If the key is absent from policy.yaml,
behavior is unchanged — the global env var applies to all users. Per-user limits
are still tracked in the in-memory `self.user_requests` dict and reset on restart.
```

---

*Full documentation index: [docs/README.md](docs/README.md)*
