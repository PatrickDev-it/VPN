# Contributing to VPS Proxy Stack

Thank you for taking the time to contribute. This document explains how to set up your
development environment, follow project conventions, and submit high-quality pull requests.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Development Setup](#2-development-setup)
3. [Code Style](#3-code-style)
4. [Branch Naming](#4-branch-naming)
5. [Commit Format](#5-commit-format)
6. [Pull Request Checklist](#6-pull-request-checklist)
7. [Adding a Policy Rule (Tutorial)](#7-adding-a-policy-rule-tutorial)
8. [Adding a Test](#8-adding-a-test)
9. [Language Policy](#9-language-policy)
10. [Security Disclosures](#10-security-disclosures)

---

## 1. Prerequisites

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| Python | 3.12 | Running tests and lint locally |
| Docker | 24.0 | Running the full stack |
| Docker Compose | v2.20 | Service orchestration |
| Git | 2.40 | Version control |

---

## 2. Development Setup

```bash
# Clone the repository
git clone https://github.com/your-org/vps-proxy-stack.git
cd vps-proxy-stack

# Install development dependencies (includes pytest, ruff, pre-commit)
pip install -r requirements-dev.txt

# Install git hooks (runs ruff + yaml checks before every commit)
pre-commit install

# Copy example config files
cp .env.example .env
cp app/users.yaml.example app/users.yaml

# Run the stack locally
make up

# Run the test suite
make test

# Run linter
make lint
```

---

## 3. Code Style

This project uses [ruff](https://docs.astral.sh/ruff/) for linting and formatting.
Configuration is in `ruff.toml`.

- **Line length:** 100 characters
- **Target:** Python 3.12
- **Import order:** stdlib → third-party → first-party (`gatekeeper`)

Pre-commit hooks run ruff automatically on every commit. To run manually:

```bash
ruff check app/ tests/ --fix   # lint + auto-fix
ruff format app/ tests/        # format
```

**Comment policy:** Write comments only when the *why* is non-obvious (hidden constraint,
workaround, subtle invariant). Do not describe *what* the code does — well-named identifiers
already do that.

---

## 4. Branch Naming

```
<type>/<short-description>
```

| Type | Use when |
|------|----------|
| `feat/` | Adding a new feature |
| `fix/` | Fixing a bug |
| `hardening/` | Security or robustness improvement |
| `refactor/` | Code restructuring without behavior change |
| `docs/` | Documentation only |
| `ci/` | CI/CD pipeline changes |
| `chore/` | Dependency bumps, tooling, cleanup |

Examples: `feat/exit-country-ui`, `fix/rate-limit-race`, `docs/contributing`

---

## 5. Commit Format

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short summary in imperative mood>

[optional body — explain the motivation, not the diff]

[optional footer — breaking changes, closes #issue]
```

Examples:

```
feat(gatekeeper): add per-user policy profile resolution
fix(rate-limit): use RLock snapshot to prevent race condition
docs(contributing): add branch naming and commit format sections
ci(security): add weekly pip-audit job to security.yml
```

---

## 6. Pull Request Checklist

Before opening a PR, confirm:

- [ ] `make lint` passes (ruff clean)
- [ ] `make test` passes (all tests green)
- [ ] `make verify` passes (compose config valid + smoke test)
- [ ] All text in code, comments, docs, and commit messages is in **English**
- [ ] No secrets, credentials, or personal data committed
- [ ] `session.md` updated locally with a `[PATCH-NNN]` entry (git-ignored — not pushed)
- [ ] New behavior is covered by at least one new test in `tests/test_gatekeeper.py`
- [ ] `docs/` updated if the change affects architecture, operations, or security

---

## 7. Adding a Policy Rule (Tutorial)

Policy rules live in `app/policy.yaml` and are hot-reloaded every 30 seconds (no restart needed).

**To block a new domain:**

```yaml
# app/policy.yaml
blacklist_domains:
  - 'newspam\.example\.com'   # block this domain
```

**To block a URL keyword:**

```yaml
blacklist_keywords:
  - 'spamtracker'
```

**To add a per-user profile:**

```yaml
profiles:
  readonly:
    whitelist_domains:
      - 'internal\.corp\.example\.com$'
    blacklist_domains:
      - '.*'
    whitelist_keywords: []
    blacklist_keywords: []
```

Then assign it to a user in `app/users.yaml`:

```yaml
users:
  charlie:
    password_sha256: "..."
    policy_profile: "readonly"
```

All patterns are Python regular expressions, matched case-insensitively against the request
host (domain rules) or the full URL (keyword rules).

---

## 8. Adding a Test

Tests live in `tests/test_gatekeeper.py`. They use `MagicMock` to stub mitmproxy types —
no live stack or Docker required.

**Minimal test template:**

```python
def test_my_new_behavior(self, gk):
    """One-line docstring stating what should happen."""
    with patch("gatekeeper.Gatekeeper.is_dns_blocked", return_value=False):
        flow = _make_flow(host="example.com", url="http://example.com/my-path")
        gk.request(flow)
    assert flow.response is not None
    assert flow.response.status_code == 403   # or whatever is expected
```

Run the suite:

```bash
make test
# or directly:
python -m pytest tests/ -v
```

All 9 existing tests must remain green. Add at least one test per new behavioral change.

---

## 9. Language Policy

**All text in this project must be in English.**

This applies without exception to:

- Source code (identifiers, strings, comments, docstrings)
- Configuration files (`.yaml`, `.toml`, `.env.example`, shell scripts)
- Documentation (`docs/`, `AGENTS.md`, `README.md`, this file)
- Commit messages and PR descriptions
- Issue and PR template content

This is a non-negotiable rule for an internationally readable open-source project.
PRs containing non-English text will be asked to revise before merge.

---

## 10. Security Disclosures

**Do not open a public GitHub issue for security vulnerabilities.**

Email the maintainers directly at the address listed in the repository's `SECURITY.md`
(if present) or the contact in the README. Include:

- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested fix (optional)

We aim to acknowledge reports within 48 hours and release a patch within 14 days for
confirmed critical issues.
