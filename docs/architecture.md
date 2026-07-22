# Architecture

> This document describes the end-to-end data flow and design rationale.
> For per-service configuration see [services.md](services.md).
> For the security model see [security.md](security.md).
> For operational procedures see [operations.md](operations.md).

---

## Overview

The VPS Proxy Stack is a **containerized authenticated HTTP/HTTPS proxy chain** with
Tor-based anonymization. It is not a traditional VPN (no IKEv2, OpenVPN, or WireGuard).
Traffic flows through four distinct layers, each with a well-defined responsibility.

---

## End-to-End Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│  CLIENT  (HTTP proxy on port 8080 — Basic Auth or Bearer Token)     │
└────────────────────────────┬────────────────────────────────────────┘
                             │ HTTP/HTTPS + Proxy-Authorization
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│  MITMPROXY  :8080  (python:3.12-slim)                               │
│  Addon: app/gatekeeper.py                                           │
│  ├─ Authentication     — Basic SHA256 or Bearer Token               │
│  ├─ Rate limiting      — per-user sliding window                    │
│  ├─ Policy enforcement — whitelist / blacklist (regex on host+URL)  │
│  ├─ Header stripping   — X-Forwarded-For, Via, Sec-CH-UA, etc.     │
│  ├─ DNS sinkhole check — socket.gethostbyname → 127/0.0.0.0        │
│  └─ Response scrubbing — recursive JSON + binary ad field removal   │
└────────────────────────────┬────────────────────────────────────────┘
                             │ upstream: http://privoxy:8118
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PRIVOXY  :8118  (debian:12-slim — loopback only)                   │
│  ├─ HTTP forward proxy                                              │
│  └─ forward-socks5t: all traffic → tor:9050                        │
└────────────────────────────┬────────────────────────────────────────┘
                             │ SOCKS5
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│  TOR  :9050  (debian:12-slim — internal proxy_net only)             │
│  ├─ Persistent entry guards (2 guards, anti-timing-attack)          │
│  ├─ Geo-constrained exit policy (DE, IT, AD, MC, AL, MM, MV, VN)   │
│  ├─ Circuit rotation every 300 s / max-dirty 1800 s                 │
│  ├─ Connection padding (anti traffic-analysis)                      │
│  └─ Stream isolation per destination IP, port, and SOCKS auth       │
└────────────────────────────┬────────────────────────────────────────┘
                             │ Tor exit node
                             ▼
                         INTERNET

DNS (parallel, not in the proxy chain):
┌─────────────────────────────────────────────────────────────────────┐
│  UNBOUND  :53 / :853  (debian:12-slim)                              │
│  ├─ Full DNSSEC validation (auto-trust-anchor)                      │
│  ├─ DNS-over-TLS on :853                                            │
│  ├─ Ad/tracker sinkhole (StevenBlack/hosts → always_nxdomain)      │
│  └─ QName minimisation + harden-* flags                             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Components

| Service | Base Image | Exposed Port | Responsibility |
|---------|-----------|-------------|----------------|
| `mitmproxy` | python:3.12-slim | `0.0.0.0:8080` | Authenticated ingress, policy, scrubbing |
| `privoxy` | debian:12-slim | `127.0.0.1:8118` | HTTP→SOCKS5 bridge to Tor |
| `tor` | debian:12-slim | internal only (`:9050`) | Anonymizing exit layer |
| `unbound` | debian:12-slim | `127.0.0.1:5353`, `:853` | Local DNSSEC resolver + sinkhole |

---

## Docker Network

All services share the internal bridge network `proxy_net`.
Only mitmproxy is exposed to the host on `0.0.0.0:8080`.
Privoxy listens on all interfaces inside `proxy_net` so mitmproxy can reach it, but its host publication is
restricted to `127.0.0.1:8118`. Tor is not published to the host.

```
proxy_net (internal bridge)
├── mitmproxy  → host-exposed :8080
├── privoxy    → host-exposed :8118 (127.0.0.1 only, loopback)
├── tor        → proxy_net only
└── unbound    → host-exposed :5353/:853 (127.0.0.1 by default)
```

---

## Startup Dependency Order

```
unbound  ──────────────────────────────────────┐
tor ──► privoxy ──► mitmproxy  (depends_on)    ┘
```

mitmproxy waits for both privoxy and unbound before starting.

---

## Volumes

| Volume | Type | Mount Path |
|--------|------|-----------|
| `tor_logs` | named Docker volume | `/var/log/tor` in tor container |
| `privoxy_logs` | named Docker volume | `/var/log/privoxy` in privoxy container |
| `./logs` | bind mount | `/app/logs` in mitmproxy container |
| `./app` | bind mount (read-only) | `/app/app` in mitmproxy container |
| `./unbound` | bind mount | `/app/unbound` in mitmproxy container (blacklist.conf writable) |
| `./ssl-certificates` | bind mount (read-only) | `/etc/nginx/ssl-certificates` in unbound container |

---

## Design Rationale

### Why mitmproxy instead of HAProxy or Nginx?

mitmproxy allows full application-layer interception and modification of HTTP/HTTPS flows
via Python addons. HAProxy and Nginx operate at L4/L7 but cannot recursively scrub JSON
response bodies or remove individual ad-related fields from API responses.

### Why Privoxy as the HTTP→SOCKS5 bridge?

Tor exposes only a SOCKS5 endpoint. mitmproxy in `upstream` mode requires an HTTP upstream.
Privoxy translates HTTP CONNECT and plain HTTP requests to SOCKS5 via `forward-socks5t`,
maintaining correct tunneling for HTTPS flows.

### Why Unbound instead of systemd-resolved or dnsmasq?

Unbound natively supports full DNSSEC validation, DNS-over-TLS on port 853,
`local-zone: always_nxdomain` for the sinkhole, and granular performance tuning
(threads, cache sizes, socket buffers). No other lightweight resolver provides all three.

### Why geo-constrained Tor exit nodes?

The exit policy restricts egress to countries with lower advertiser CPM (cost per mille),
stronger GDPR posture, and no mandatory data-retention laws. Countries with 5-Eyes / 9-Eyes
membership or high ad-market pressure are excluded. See [services.md — Tor](services.md#3-tor--anonymization-layer)
for the full country list and exclusion rationale.

---

## Known Limitations

| Limitation | Details |
|------------|---------|
| **HTTPS tunnels bypass policy** | `CONNECT` requests skip whitelist/blacklist evaluation (`gatekeeper.py` lines 250–251). Only the authentication and rate-limiting checks apply. |
| **Proxy-only anonymization** | Only traffic routed through the proxy is anonymized. Direct host traffic does not pass through Tor. |
| **In-memory rate limiting** | `self.user_requests` resets on every mitmproxy restart — not suitable for persistent quota enforcement. |
| **Policy loaded at startup only** | Changes to `policy.yaml` or `users.yaml` require `docker compose restart mitmproxy`. |
| **`is_dns_blocked` is fail-closed** | If DNS resolution fails for any reason (Unbound down, network error), the domain is blocked with 403. |
| **No tests yet** | `pytest` is in `requirements-dev.txt` but no test files exist in the repository. |

---

*See also: [services.md](services.md) · [security.md](security.md) · [operations.md](operations.md)*
