# docs/ — Documentation Index

This folder contains the full technical reference for the VPS Proxy Stack project.
All documents are interlinked and designed to be read in combination.
Every file in this folder is written in professional English and tracked in git.

---

## Documents

| File | Contents |
|------|----------|
| [architecture.md](architecture.md) | End-to-end data flow, component overview, design rationale, known limitations |
| [services.md](services.md) | Per-service Docker configuration: mitmproxy, Privoxy, Tor, Unbound |
| [gatekeeper.md](gatekeeper.md) | Complete documentation of `app/gatekeeper.py` — hook-by-hook |
| [security.md](security.md) | 5-layer security model, hardening details, operational recommendations |
| [operations.md](operations.md) | Initial setup, daily commands, user/policy/blacklist management, troubleshooting |
| [ci-cd.md](ci-cd.md) | CI/CD pipeline reference: workflows, required secrets, deploy and rollback |

---

## Recommended Reading Order

**First-time setup:**
1. [architecture.md](architecture.md) — understand the full data flow
2. [operations.md](operations.md) — provision and configure the stack
3. [security.md](security.md) — review all security constraints before going live
4. [ci-cd.md](ci-cd.md) — configure GitHub Actions for automated deploy

**Code modification:**
1. [gatekeeper.md](gatekeeper.md) — core proxy logic
2. [services.md](services.md) — service-specific configuration

**Debugging:**
1. [operations.md — Troubleshooting](operations.md#troubleshooting) — step-by-step diagnosis
2. [services.md](services.md) — parameters for the failing service

---

## Related Files in the Repository Root

| File | Role |
|------|------|
| [../AGENTS.md](../AGENTS.md) | AI agent guide — mandatory entry point, contains `session.md` update rules |
| [../session.md](../session.md) | Local patch history (git-ignored) — update after every change |
| [../README.md](../README.md) | End-user README — quick setup and client usage |
| [../app/gatekeeper.py](../app/gatekeeper.py) | mitmproxy addon source |
| [../app/policy.yaml](../app/policy.yaml) | Whitelist / blacklist rules |
| [../docker-compose.yml](../docker-compose.yml) | Service orchestration |
| [../.github/workflows/](../.github/workflows/) | CI/CD GitHub Actions workflows |
