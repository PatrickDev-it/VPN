# Operations Guide

> Day-to-day commands for deploying, managing, and maintaining the proxy stack.
> For architecture see [architecture.md](architecture.md).
> For security constraints see [security.md](security.md).
> For CI/CD automation see [ci-cd.md](ci-cd.md).

---

## Initial Setup

### 1. Provision the Host (Debian 12, run as root)

```bash
git clone https://github.com/PatrickDev-it/VPN.git
cd VPN
sudo make setup-vps
```

`init/setup-vps.sh` installs: Docker CE, UFW, fail2ban, curl, openssl, cron.
Configures firewall (deny-all ingress), kernel parameters, file-descriptor limits, and Fail2Ban on SSH.

### 2. Configure Domain and TLS (optional)

```bash
make setup-domain
```

Interactive 7-step wizard:
1. Enter domain name (e.g. `proxy.example.com`)
2. Enter email (for Let's Encrypt / CloudPanel)
3. Choose TLS mode: `selfsigned` | `letsencrypt` | `cloudpanel`
4. Wizard verifies DNS propagation via `dig`
5. Updates `.env` with `MY_DOMAIN`, `MY_EMAIL`, `TLS_MODE`
6. Generates TLS certificates
7. Starts the stack

### 3. Manual Bootstrap

When skipping the domain wizard:

```bash
# Copy and customize the environment file
cp .env.example .env
nano .env            # set AUTH_MODE, RATE_LIMIT_*, ports, TLS_MODE, etc.

# Create the credentials file
cp app/users.yaml.example app/users.yaml
nano app/users.yaml  # add real users — see "User Management" below

# Run bootstrap: generate configs, certs, start stack, install systemd and cron
make init
```

---

## Daily Commands

### Start / Stop

```bash
make up              # docker compose up -d (all services)
make down            # docker compose down
make build           # rebuild all images
```

### Logs

```bash
make logs            # tail all services (mitmproxy, privoxy, tor, unbound)
make logs-auth       # tail logs/auth.log (authentication events)
make logs-traffic    # tail logs/traffic.log (request/response log)
make logs-tor        # tail /var/log/tor/notices.log (inside tor container)
```

### Stack Verification

```bash
make verify          # lint + smoke + docker compose config -q
make smoke           # mitmdump --version (validates Python runtime)
make lint            # ruff static analysis on app/gatekeeper.py
```

---

## User Management

### Add a User

1. Generate the SHA256 password hash:
   ```bash
   echo -n 'mypassword' | sha256sum | cut -d' ' -f1
   ```

2. Generate a random token:
   ```bash
   openssl rand -hex 32
   ```

3. Add the user block to `app/users.yaml`:
   ```yaml
   users:
     newuser:
       password_sha256: "<generated-hash>"
       token: "<generated-token>"
   ```

4. Restart mitmproxy (credentials are loaded only at startup):
   ```bash
   docker compose restart mitmproxy
   ```

5. Update `session.md` with a `[PATCH-NNN]` entry.

### Remove a User

Delete the user block from `app/users.yaml` and restart mitmproxy.

### Rotate Credentials

1. Generate new hash and/or token
2. Update `app/users.yaml`
3. `docker compose restart mitmproxy`
4. Distribute new credentials out-of-band

---

## Policy Management

Policy rules are defined in `app/policy.yaml` using Python regular expressions (case-insensitive).

### Schema

```yaml
whitelist_domains:    # if host matches → allow immediately, skip all blacklists
  - 'example\.com'
  - '^cdn\.'

whitelist_keywords:   # if full URL matches → allow immediately
  - '/login'
  - '/api/auth'

blacklist_domains:    # if host matches → HTTP 403
  - 'ads\.example\.com'

blacklist_keywords:   # if full URL matches → HTTP 403
  - 'tracking'
  - 'adunit'
```

### Evaluation Order

```
whitelist_domains → whitelist_keywords → blacklist_domains → blacklist_keywords
```

Whitelist always takes precedence over blacklist. If a domain is in both lists, it is allowed.
`CONNECT` requests (HTTPS tunnels) skip policy evaluation entirely.

### Apply Changes

```bash
docker compose restart mitmproxy
```

### Debug Policy Decisions

```bash
docker compose logs mitmproxy | grep -E "ALLOWED|BLOCKED"
```

---

## DNS Blocklist Management

### Manual Update

```bash
make update-blacklist
docker compose restart unbound
```

### Automatic Update (Cron)

Installed by `init/bootstrap.sh` when `INSTALL_CRON=1` in `.env`.
Default schedule: every 6 hours (`0 */6 * * *`).
Log: `logs/blacklist-cron.log`

### Change the Cron Schedule

Edit `.env`:
```
BLACKLIST_CRON_SCHEDULE=0 2 * * *   # daily at 02:00
```

Re-run `make init` to apply the updated cron entry on the host.

### Verify the Active Blocklist

```bash
# Count blocked domains
wc -l unbound/blacklist.conf

# Confirm a domain is sinkhled
docker compose exec unbound nslookup doubleclick.net 127.0.0.1
# Expected: NXDOMAIN
```

---

## TLS Certificate Management

### Generate or Renew Certificates

```bash
make generate-certs   # uses TLS_MODE from .env
```

### Certificate Modes

| `TLS_MODE` | Certificate Source | Auto-renewal |
|------------|-------------------|-------------|
| `selfsigned` | RSA 4096, 365-day, written to `ssl-certificates/` | No — run `make generate-certs` manually before expiry |
| `letsencrypt` | certbot ACME v2 standalone | Yes — daily cron at 04:00 via `/usr/local/bin/renew-proxy-certs.sh` |
| `cloudpanel` | Copied from `/etc/nginx/ssl-certificates/` | Yes — daily sync at 05:00 |

### Check Certificate Expiry

```bash
openssl x509 -in ssl-certificates/server.crt -noout -dates
```

---

## Tor Management

### View Circuit Status

```bash
docker compose logs tor
# or directly:
docker compose exec tor tail -f /var/log/tor/notices.log
```

### Verify Anonymization is Active

```bash
curl -x http://localhost:8080 \
     -U 'alice:mypassword' \
     https://check.torproject.org/api/ip
# Expected response: { "IsTor": true, "IP": "<exit-node-ip>" }
```

### Modify Exit Countries

1. Edit `ExitNodes` and/or `ExcludeNodes` in `tor/torrc`
2. `docker compose restart tor`
3. Update `session.md`

---

## Client Configuration

### Connection Parameters

| Field | Value |
|-------|-------|
| Host | `<server-ip>` or `<domain>` |
| Port | `8080` (default) |
| Type | HTTP Proxy |
| Auth | Username + Password (basic mode) |

### curl — Basic Auth

```bash
curl -x http://proxy.example.com:8080 -U 'alice:password' https://example.com
```

### curl — Token Auth

```bash
curl -x http://proxy.example.com:8080 \
     -H 'X-Proxy-Token: mytoken' \
     https://example.com
```

### Verify Exit IP (should be a Tor exit node)

```bash
curl -x http://proxy.example.com:8080 -U 'alice:password' https://api.ipify.org
```

### System-Wide Proxy (Linux / macOS)

```bash
export http_proxy=http://alice:password@proxy.example.com:8080
export https_proxy=http://alice:password@proxy.example.com:8080
```

### DNS-over-TLS Client (when Unbound is publicly exposed)

```bash
# Using kdig (knot-dnsutils)
kdig @proxy.example.com +tls-ca +tls-host=proxy.example.com example.com

# Using systemd-resolved (/etc/systemd/resolved.conf)
# DNS=proxy.example.com
# DNSOverTLS=yes
```

---

## Make Targets Reference

| Target | Command | Purpose |
|--------|---------|---------|
| `make init` | `bash init/bootstrap.sh` | Bootstrap: config + certs + stack up + systemd + cron |
| `make setup-vps` | `sudo bash init/setup-vps.sh` | Full Debian 12 host provisioning |
| `make setup-domain` | `bash init/setup-domain.sh` | Interactive domain + TLS wizard |
| `make generate-certs` | `bash init/generate-certs.sh` | Generate or renew TLS certificates |
| `make build` | `docker compose build` | Rebuild all Docker images |
| `make up` | `docker compose up -d` | Start all services |
| `make down` | `docker compose down` | Stop all services |
| `make logs` | compose logs -f | Tail all service logs |
| `make logs-auth` | `tail -f logs/auth.log` | Authentication event log |
| `make logs-traffic` | `tail -f logs/traffic.log` | Traffic log |
| `make logs-tor` | exec tor tail | Tor circuit log |
| `make update-blacklist` | compose run mitmproxy | Fetch and update DNS blocklist |
| `make lint` | ruff check | Python static analysis |
| `make test` | pytest | Run test suite |
| `make smoke` | mitmdump --version | Validate Python runtime |
| `make verify` | lint + smoke + config | Full pre-push check |

---

## Troubleshooting

### Stack does not start

```bash
docker compose config -q     # validate compose syntax
docker compose logs          # read startup errors from all services
```

### Every request returns 407

- Verify `app/users.yaml` exists and is correctly formatted
- Verify `AUTH_MODE` in `.env` matches how credentials are being sent
- Inspect the file inside the container:
  ```bash
  docker compose exec mitmproxy cat /app/app/users.yaml
  ```

### A legitimate site returns 403

1. Check if the domain is sinkhled by Unbound:
   ```bash
   docker compose exec unbound nslookup domain.com 127.0.0.1
   ```
2. Check mitmproxy logs for the block decision:
   ```bash
   docker compose logs mitmproxy | grep -i blocked
   ```
3. If blocked by DNS: add to Unbound allowlist or remove from blocklist
4. If blocked by policy: add to `whitelist_domains` in `policy.yaml`

### Tor is slow or fails to connect

```bash
make logs-tor
# Look for: circuit build failures, guard changes, WARN entries
```

If `StrictNodes 1` is preventing circuits due to no available exit in the geo list:
- Temporarily comment out `StrictNodes 1` in `tor/torrc`
- `docker compose restart tor`
- Investigate which exits are available before removing the constraint permanently

### DNS blocklist not updating

```bash
cat logs/blacklist-cron.log           # check cron job output
docker compose run --rm --no-deps mitmproxy bash cron/update_blacklist.sh
# Run manually and observe the output
```

### mitmproxy not scrubbing responses

- Verify the response `Content-Type` contains `json` or the path matches `target_paths`
- Check that `flow.response_streaming = False` is set for YouTube/Google domains
- Increase mitmproxy log verbosity for a specific flow:
  ```bash
  docker compose logs mitmproxy | grep "Surgery Completed"
  ```

---

*See also: [architecture.md](architecture.md) · [security.md](security.md) · [ci-cd.md](ci-cd.md)*
