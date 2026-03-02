# VPS - Authenticated Privacy Proxy Stack

This repository provides a production-oriented proxy chain with policy enforcement, authentication, and privacy-focused egress routing.

Core flow:

`Client -> Mitmproxy (auth + policy + rate limit) -> Privoxy -> Tor -> Exit Node -> Target`

## Components

- `mitmproxy`: authenticated ingress proxy with user policy enforcement and request/response controls.
- `privoxy`: HTTP forward proxy that forwards to Tor SOCKS.
- `tor`: privacy egress layer with strict node selection, stream isolation, and connection padding.
- `unbound`: local DNS resolver with DNSSEC and optional DNS-over-TLS (DoT).

## Repository Structure

```
project-root/
├── app/
│   ├── gatekeeper.py
│   ├── policy.yaml
│   ├── users.yaml.example
│   └── __init__.py
├── unbound/
│   ├── unbound.conf
│   └── blacklist.conf
├── privoxy/
│   └── config
├── tor/
│   └── torrc
├── services/
│   ├── unbound/Dockerfile
│   ├── privoxy/Dockerfile
│   └── tor/Dockerfile
├── init/
│   ├── bootstrap.sh
│   ├── setup-vps.sh
│   ├── setup-domain.sh
│   ├── generate-certs.sh
│   └── vps-proxy-stack.service
├── cron/
│   └── update_blacklist.sh
├── ssl-certificates/      # generated at runtime
├── logs/
├── Dockerfile
├── docker-compose.yml
├── Makefile
├── requirements.txt
├── requirements-dev.txt
├── .env.example
└── README.md
```

## Quick Start (Existing Docker Host)

1. Prepare environment:

   - `cp .env.example .env`
   - `cp app/users.yaml.example app/users.yaml`

2. Generate password hash:

   - `python3 -c "import hashlib; print(hashlib.sha256(b'STRONG_PASSWORD').hexdigest())"`

3. Set credentials and token in `app/users.yaml`.
4. Build and validate:

   - `make build`
   - `make verify`

5. Start stack:

   - `make up`

6. Update DNS blocklist:

   - `make update-blacklist`

## Full VPS Bootstrap (Debian 12)

Run a full host bootstrap (system update, Docker install, optional CloudPanel setup, firewall, kernel tuning, Fail2Ban, TLS generation, stack start):

- `sudo make setup-vps`

The script `init/setup-vps.sh` performs all required host-level steps and then calls `init/bootstrap.sh`.

## Domain + HTTPS Guided Setup

To switch from IP-only access to domain-based access:

- `make setup-domain`

The wizard:

1. Prompts for domain and email.
2. Shows recommended DNS records.
3. Checks DNS propagation.
4. Lets you choose TLS mode:
   - `cloudpanel`
   - `letsencrypt`
   - `selfsigned`
5. Generates/links certificates and restarts the stack.

## TLS Certificate Modes

Certificate logic is managed by `init/generate-certs.sh`.

- `selfsigned`: generates `server.key` and `server.crt` in `ssl-certificates/`.
- `letsencrypt`: obtains certs with certbot standalone, then copies to `ssl-certificates/`.
- `cloudpanel`: copies certs from `/etc/nginx/ssl-certificates/<domain>.{key,crt}`.

Run manually:

- `make generate-certs`

## Port Model and Defaults

Ports are intentionally separated between exposed and internal services.

- `MITMPROXY_BIND_PORT` (default `8080/tcp`): authenticated ingress proxy.
- `UNBOUND_DNS_PORT` (default `5353/tcp+udp`): local DNS resolver.
- `UNBOUND_DOT_PORT` (default `853/tcp`): DNS-over-TLS.
- `PRIVOXY_BIND_PORT` (default `8118/tcp`): intermediate forward proxy (recommended loopback-only).
- `TOR_SOCKS_PORT` (default `9050/tcp`): internal SOCKS endpoint for Privoxy.

Recommended firewall posture:

- Expose only required ports (`8080`, and optionally `53/udp+tcp`, `853/tcp`).
- Keep `8118` and `9050` internal.

## Tor Privacy Profile

`tor/torrc` is configured for privacy-focused operation:

- fixed entry-guard behavior (`UseEntryGuards`, `NumEntryGuards`),
- strict geo-constrained exit policy (`ExitNodes`, `ExcludeNodes`, `StrictNodes`),
- anti-profiling circuit timing,
- traffic-analysis resistance (`ConnectionPadding`),
- stream isolation (`IsolateDestAddr`, `IsolateDestPort`, `IsolateSOCKSAuth`),
- persistent operational logging (`/var/log/tor/notices.log`, `/var/log/tor/info.log`).

Tor logs can be tailed with:

- `make logs-tor`

## Authentication and Policy

Auth and policy are implemented in `app/gatekeeper.py`.

- auth mode: `basic` or `token` via `AUTH_MODE`,
- users file: `USERS_FILE` (default `/app/app/users.yaml`),
- policy file: `POLICY_FILE` (default `/app/app/policy.yaml`),
- rate limit: `RATE_LIMIT_RPM` and `RATE_LIMIT_WINDOW_SEC`.

If authentication fails, the proxy returns `407 Proxy Authentication Required`.
If limits are exceeded, the proxy returns `429`.

## Logging

- Auth log: `logs/auth.log`
- Traffic log: `logs/traffic.log`
- Tor logs: `/var/log/tor/notices.log` and `/var/log/tor/info.log` (inside `tor` container)

## Make Targets

### Setup / Bootstrap

- `make init`: run `bootstrap.sh` (compose up + generated config + optional systemd/cron)
- `make setup-vps`: full Debian host bootstrap
- `make setup-domain`: guided domain and HTTPS setup
- `make generate-certs`: generate/sync TLS certificates

### Operations

- `make build`: build all images
- `make up`: start stack
- `make down`: stop stack
- `make logs`: stream logs for all core services
- `make logs-auth`: stream auth log
- `make logs-traffic`: stream traffic log
- `make logs-tor`: stream Tor notice log
- `make update-blacklist`: regenerate `unbound/blacklist.conf`

### Quality Checks

- `make lint`: run Ruff checks
- `make test`: run tests
- `make smoke`: verify mitmdump runtime
- `make verify`: lint + smoke + `docker compose config -q`

## Security Notes

- Run on hardened hosts with deny-by-default ingress policy.
- Keep user secrets (`app/users.yaml`, `.env`) out of source control.
- Rotate tokens and credentials regularly.
- Review legal/compliance requirements before TLS interception in your jurisdiction.
