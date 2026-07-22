# Security Model

> End-to-end security design across all layers.
> For service-specific hardening settings see [services.md](services.md).
> For operational procedures see [operations.md](operations.md).

---

## Defense in Depth

The stack implements security across five distinct layers:

```
┌─────────────────────────────────────────────────────┐
│  L1 — Host OS: UFW, Fail2Ban, kernel hardening      │
├─────────────────────────────────────────────────────┤
│  L2 — Container: capabilities, no-new-privileges    │
├─────────────────────────────────────────────────────┤
│  L3 — Application: auth, rate limiting, policy      │
├─────────────────────────────────────────────────────┤
│  L4 — DNS: DNSSEC, DoT, sinkhole                    │
├─────────────────────────────────────────────────────┤
│  L5 — Network: Tor exit geo-policy, padding         │
└─────────────────────────────────────────────────────┘
```

---

## L1 — Host OS Hardening

### UFW Firewall

Configured by `init/setup-vps.sh`:

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp         # SSH
ufw allow 80/tcp         # HTTP (TLS certificate renewal)
ufw allow 443/tcp        # HTTPS
ufw allow 8080/tcp       # Proxy ingress
# Optional:
ufw allow 5353/udp       # DNS (only if UNBOUND_BIND_IP=0.0.0.0)
ufw allow 5353/tcp
ufw allow 853/tcp        # DNS-over-TLS (only if publicly exposed)
ufw allow 8443/tcp       # CloudPanel UI (only if used)
```

### Fail2Ban

Configured on the `sshd` jail:
- `maxretry`: 3 failed attempts
- `bantime`: 86400 s (1 day)
- `findtime`: 600 s (10-minute observation window)

### Kernel Hardening (`/etc/sysctl.d/99-vps-proxy.conf`)

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `fs.file-max` | `2097152` | Max open file descriptors |
| `net.core.somaxconn` | `65535` | TCP connection backlog |
| `net.ipv4.tcp_tw_reuse` | `1` | Reuse TIME-WAIT sockets |
| `net.ipv4.ip_local_port_range` | `1024 65000` | Ephemeral port range |
| `vm.swappiness` | `10` | Prefer RAM over swap |
| `net.core.netdev_max_backlog` | `5000` | NIC packet queue depth |

### System Limits (`/etc/security/limits.d/vps-proxy.conf`)

```
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
```

Required to sustain thousands of concurrent proxy connections.

---

## L2 — Container Security

### Linux Capabilities

| Service | Dropped | Added |
|---------|---------|-------|
| mitmproxy | ALL | — |
| privoxy | ALL | — |
| tor | ALL | — |
| unbound | ALL | `NET_BIND_SERVICE` |

`NET_BIND_SERVICE` is the minimum capability required for Unbound to bind port 53.
No other capability is granted to any container.

### `no-new-privileges`

All services: `security_opt: no-new-privileges:true`

Prevents any child process from gaining privileges via setuid/setgid binaries.

### Unprivileged Runtime Users

| Service | Runtime User |
|---------|-------------|
| mitmproxy | `appuser` (created in Dockerfile) |
| tor | `debian-tor` |
| unbound | `unbound` |
| privoxy | default privoxy user |

### Init Process

All services configured with `init: true` — Docker uses an init process inside the container
for correct signal handling and zombie process reaping.

### Isolated Network

- Internal bridge `proxy_net` — services can only communicate with each other
- Only mitmproxy is exposed to the host on `0.0.0.0:8080`
- Privoxy listens on `proxy_net` but its host publication is loopback-only (`127.0.0.1:8118`)
- Tor has no exposed ports at all

---

## L3 — Application Security

### Proxy Authentication

**Mode `basic`:**
- Password hashed with SHA256 before storage
- Comparison via `hmac.compare_digest` (constant-time — immune to timing attacks)
- Challenge header on failure: `Proxy-Authenticate: Basic realm=Gatekeeper`

**Mode `token`:**
- Arbitrary token string, compared constant-time
- Accepted via `Proxy-Authorization: Bearer <token>` or `X-Proxy-Token: <token>`
- Challenge header on failure: `Proxy-Authenticate: Bearer`

**Unauthenticated response:** `407 Proxy Authentication Required`

### Rate Limiting

- Sliding window algorithm, per user, in-memory
- Default: 120 requests per 60-second window (configurable via `.env`)
- Response: `429 Too Many Requests` + `Retry-After: <window_sec>` header

### Revealing Header Removal

Removed from every forwarded request:

| Header | Risk if Leaked |
|--------|---------------|
| `X-Forwarded-For` | Exposes client real IP |
| `X-Real-IP` | Exposes client real IP |
| `Via` | Reveals proxy presence |
| `Proxy-Connection` | Proxy fingerprinting |
| `Sec-CH-UA` | Browser client hints (fingerprinting) |
| `Proxy-Authorization` | Credentials must not reach the upstream server |
| `Authorization` | Session credentials |

### Whitelist / Blacklist Policy

Defined in `vpn/app/policy.yaml`. See [gatekeeper.md](gatekeeper.md) for the evaluation order.

**Key rule:** whitelist always takes precedence over blacklist.
CONNECT requests (HTTPS tunnels) bypass policy evaluation — authentication still applies.

---

## L4 — DNS Security and Privacy

### DNSSEC Validation

- Full validation chain with `auto-trust-anchor-file`
- `val-permissive-mode: no` — DNSSEC is enforced, not advisory
- `harden-dnssec-stripped: yes` — rejects responses with stripped DNSSEC signatures

### DNS-over-TLS (DoT)

- Port 853/tcp
- TLS certificates managed by `bootstrap.sh` / `generate-certs.sh`
- Three certificate modes: `selfsigned`, `letsencrypt`, `cloudpanel`

### DNS Privacy Settings

```
hide-identity: yes           # does not reveal server hostname
hide-version: yes            # does not reveal Unbound version
qname-minimisation: yes      # sends only the necessary query portion to upstream
use-caps-for-id: yes         # 0x20 random-case encoding against cache poisoning
harden-glue: yes
harden-below-nxdomain: yes
harden-referral-path: yes
harden-algo-downgrade: yes
```

### Ad/Tracker DNS Sinkhole

- Source: [StevenBlack/hosts](https://github.com/StevenBlack/hosts) — updated every 6 hours
- Response format: `local-zone: "domain.com" always_nxdomain`
- Gatekeeper detects sinkhole responses (`127.0.0.1` / `0.0.0.0`) and returns `403`

---

## L5 — Network Anonymization (Tor)

### Entry Guards

`UseEntryGuards 1`, `NumEntryGuards 2`

Fixed entry guard nodes reduce the probability of guard–exit correlation attacks.

### Geo-Constrained Exit Policy

**Allowed:** `{de},{it},{ad},{mc},{al},{mm},{mv},{vn},{uz}`

**Excluded:** `{ch},{us},{gb},{au},{ca},{fr},{nl},{be},{ie},{se},{no},{dk},{fi},{jp},{kr},{cn},{ru}`

Exclusion criteria: 5-Eyes/9-Eyes/14-Eyes membership, mandatory data-retention laws,
internet censorship infrastructure, high-CPM advertising markets.

`StrictNodes 1` — Tor fails to build circuits rather than use a non-approved exit country.

### Anti-Profiling Circuit Rotation

- New circuit every 300 seconds (5 minutes)
- Circuit retired after 1800 seconds (30 minutes)
- Prevents traffic correlation across requests sent over the same circuit

### Traffic Padding

`ConnectionPadding 1` — adds dummy Tor cells to obscure traffic volume and timing patterns,
resisting traffic-analysis attacks that observe cell counts and inter-arrival times.

### Stream Isolation

```
IsolateDestAddr   — separate circuit per destination IP
IsolateDestPort   — separate circuit per destination port
IsolateSOCKSAuth  — separate circuit per SOCKS credential
```

---

## TLS Certificate Management

| Mode | Description | Auto-renewal |
|------|-------------|-------------|
| `selfsigned` | RSA 4096, SAN includes public IP, 365-day validity | Manual — re-run `make generate-certs` |
| `letsencrypt` | certbot ACME v2 standalone | Yes — cron script `/usr/local/bin/renew-proxy-certs.sh` at 04:00 |
| `cloudpanel` | Copies from `/etc/nginx/ssl-certificates/` | Yes — sync cron at 05:00 |

---

## Secrets and Sensitive Files

| File | Contents | Git Status |
|------|----------|-----------|
| `.env` | All configuration secrets | Excluded (`.gitignore`) |
| `vpn/app/users.yaml` | User credentials (hashes + tokens) | Excluded (`.gitignore`) |
| `vpn/ssl-certificates/` | Private TLS keys | Excluded (`.gitignore`) |
| `vpn/logs/` | Auth logs containing IP addresses | Excluded (`.gitignore`) |

## Supply-chain Gates

Every push to `main`, pull request, and weekly scheduled run executes:

- `pip-audit` against `vpn/requirements.txt`;
- Trivy filesystem scanning against `vpn/`;
- Trivy scanning against the built mitmproxy image.

High and critical findings with available fixes fail the workflow. Dependency updates must preserve
the unit-test contract and pass both source and container scans before the repository is presented as green.
Audit tooling is versioned independently in `vpn/requirements-audit.txt` so the scanner environment is
reproducible and does not inherit the runner's bundled package-manager vulnerabilities.

### Temporary upstream compatibility override

Mitmproxy 12.2.3 declares upper bounds of `msgpack<=1.1.2` and `tornado<=6.5.5`. Those versions are
affected by [GHSA-6v7p-g79w-8964](https://github.com/advisories/GHSA-6v7p-g79w-8964) and
[GHSA-pw6j-qg29-8w7f](https://github.com/advisories/GHSA-pw6j-qg29-8w7f). Until mitmproxy publishes
compatible metadata, the build installs `msgpack==1.2.1` and `tornado==6.5.7` from
`requirements-security-overrides.txt` after the base dependency resolution.

This is an explicit, tested exception—not a scanner suppression. Unit tests execute against the overridden
environment, pip-audit inspects the installed environment, and Trivy scans the resulting image. Remove the
override immediately after an upstream mitmproxy release permits both fixed versions through normal resolution.

---

## Operational Security Checklist

- [ ] Rotate tokens and passwords at least every 90 days
- [ ] Monitor `logs/auth.log` for unexpected denial spikes (brute-force attempts)
- [ ] Verify Fail2Ban is active: `sudo fail2ban-client status sshd`
- [ ] Verify Unbound is healthy before debugging 403 errors in Gatekeeper
- [ ] Do not expose Unbound on `0.0.0.0` unless public DoT is intentionally required — open resolvers can be abused for amplification attacks
- [ ] Restrict `access-control: 0.0.0.0/0 allow` in `unbound.conf` if DoT is for private use only
- [ ] Confirm `ClientOnly 1` remains in `torrc` — this prevents the host from acting as a Tor relay
- [ ] Review exit country list in `torrc` whenever geopolitical conditions change
- [ ] Review TLS certificate expiry: `openssl x509 -in ssl-certificates/server.crt -noout -dates`

---

*See also: [architecture.md](architecture.md) · [services.md](services.md) · [operations.md](operations.md)*
