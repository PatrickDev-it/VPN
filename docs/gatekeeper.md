# Gatekeeper — mitmproxy Addon Reference

> Complete documentation for `app/gatekeeper.py`.
> For architectural context see [architecture.md](architecture.md).
> For user and policy management see [operations.md](operations.md).

---

## Overview

`Gatekeeper` is a **mitmproxy addon** that intercepts every HTTP/HTTPS flow and applies,
in strict order:

1. User authentication (Basic or Token)
2. Per-user rate limiting
3. Revealing-header stripping
4. DNS sinkhole check
5. Whitelist / blacklist policy evaluation
6. Response scrubbing (JSON recursive + binary fallback)

This file is the **core logic** of the entire project. Changes here directly affect proxy behavior.

---

## Initialization — `__init__()`

```python
class Gatekeeper:
    def __init__(self):
        self.load_policy()      # loads app/policy.yaml
        self.load_users()       # loads app/users.yaml
        self.auth_mode = os.getenv("AUTH_MODE", "basic").lower()
        self.rate_limit_rpm = int(os.getenv("RATE_LIMIT_RPM", "120"))
        self.rate_limit_window = int(os.getenv("RATE_LIMIT_WINDOW_SEC", "60"))
        self.user_requests = {}  # {username: [timestamps]} — in-memory, resets on restart
```

**Ad patterns compiled at startup:**

```python
# JSON key pattern (applied recursively to response dict keys)
self.ad_patterns = re.compile(
    r"^(ad|adv|track|adsense|monitoring|stats|heartbeat|impression|"
    r"suggested_ad|offsets|watermark|affiliation).*",
    re.IGNORECASE,
)

# Binary body pattern (fallback when JSON parsing fails)
self.bin_ad_pattern = re.compile(
    rb"(ad_placement|adsense|tracking|stats|heartbeat|impression|"
    rb"suggested_ad|offsets|watermark|affiliation)",
    re.IGNORECASE,
)

# Target paths for forced YouTube/Google API scrubbing
self.target_paths = ["/youtubei/", "/api/stats/", "/ptracking/", "/log_event/", "/player"]
```

> **Critical:** `load_policy()` and `load_users()` are called **once at startup**.
> Any change to either YAML file requires `docker compose restart mitmproxy`.

---

## Hook: `request(flow)` — Ingress Pipeline

Called by mitmproxy for every incoming request before it is forwarded upstream.

### Flow Diagram

```
request(flow)
│
├─ _verify_user(flow)
│   ├─ returns None → _log_auth("denied", "invalid_credentials") + HTTP 407 → RETURN
│   └─ returns username → continue
│
├─ _is_rate_limited(username)
│   ├─ True  → _log_auth("denied", "rate_limited") + HTTP 429 + Retry-After → RETURN
│   └─ False → continue
│
├─ _log_auth("allowed", "ok")
├─ flow.metadata["auth_user"] = username
│
├─ If host contains "youtube.com" or "googleapis.com":
│   └─ flow.response_streaming = False  (required to buffer body for scrubbing)
│
├─ Strip headers:
│   X-Forwarded-For · X-Real-IP · Via · Proxy-Connection
│   Sec-CH-UA · Proxy-Authorization · Authorization
├─ Inject: X-Authenticated-User: <username>
│
├─ If Accept header contains "application/x-protobuf":
│   └─ Override Accept → "application/json, text/plain, */*"
│
├─ If method == "CONNECT":
│   └─ RETURN  (HTTPS tunnel — policy evaluation skipped)
│
├─ is_dns_blocked(domain) → True: HTTP 403 "DNS Blocked" → RETURN
│
├─ whitelist_domains  → regex match on host → RETURN (allow)
├─ whitelist_keywords → regex match on full URL → RETURN (allow)
├─ blacklist_domains  → regex match on host → HTTP 403 "Blocked by VPS Gatekeeper"
└─ blacklist_keywords → regex match on full URL → HTTP 403 "Content blocked by VPS Gatekeeper"
```

### CONNECT Tunnel Behavior

Requests using the `CONNECT` method (standard HTTPS tunneling) **bypass policy evaluation**
(source lines 250–251). Authentication and rate limiting still apply. The HTTPS payload is
end-to-end encrypted and therefore cannot be scrubbed at this layer.

---

## Hook: `response(flow)` — Egress Pipeline

Called by mitmproxy for every response received from the upstream.

```
response(flow)
│
├─ Guard: if body is empty → RETURN
├─ Log traffic (user, method, host, path, status, bytes)
│
├─ flow.response.decode()  — decompress gzip/brotli if present
│
└─ If Content-Type contains "json" OR path is in target_paths:
    ├─ Body starts with "data:application/json;base64,":
    │   └─ base64-decode → scrub_json() → base64-re-encode → write back
    ├─ Valid JSON body:
    │   └─ json.loads → scrub_json() → json.dumps → flow.response.text
    └─ JSON parse failure:
        └─ binary_scrub(flow)  ← fallback
```

---

## Authentication — `_verify_user(flow)`

### Mode `basic` (default)

Expected header: `Proxy-Authorization: Basic <base64(username:password)>`

Process:
1. Decode base64 → `username:password`
2. Look up `users[username]`
3. `SHA256(password) == user_data["password_sha256"]` via `hmac.compare_digest` (constant-time)

### Mode `token`

Expected headers (checked in order):
1. `Proxy-Authorization: Bearer <token>`
2. `X-Proxy-Token: <token>`

Process: iterate all users, compare each `user_data["token"]` via `hmac.compare_digest`.

> **Scaling note:** token lookup is O(n) over the user list. With more than ~100 users,
> consider indexing users by token hash in `__init__()`.

### `users.yaml` Schema

```yaml
users:
  alice:
    password_sha256: "13dc8554..."   # SHA256 hex digest of the plaintext password
    token: "tok-xxxxxxxxxxxxxxxx"    # arbitrary secret string for Bearer/token mode
  bob:
    password_sha256: "aabbcc..."
    token: "tok-yyyyyyyyyyyyyyyy"
```

Generate a password hash:
```bash
echo -n 'mypassword' | sha256sum | cut -d' ' -f1
```

---

## Rate Limiting — `_is_rate_limited(username)`

**Algorithm:** sliding window, in-memory, per user.

```python
def _is_rate_limited(self, username):
    now = time.time()
    recent = [ts for ts in self.user_requests[username] if now - ts <= self.rate_limit_window]
    self.user_requests[username] = recent
    if len(recent) >= self.rate_limit_rpm:
        return True
    self.user_requests[username].append(now)
    return False
```

Response when limited: `429 Too Many Requests` with header `Retry-After: <window_sec>`.

**Limitation:** `self.user_requests` is in-memory — it resets on every container restart.

---

## DNS Sinkhole Check — `is_dns_blocked(domain)`

```python
def is_dns_blocked(self, domain):
    try:
        ip = socket.gethostbyname(domain)
        return ip in ["127.0.0.1", "0.0.0.0"]
    except Exception:
        return True   # fail-closed: blocked if DNS resolution fails for any reason
```

Works in conjunction with Unbound: domains in `blacklist.conf` resolve to `127.0.0.1` via
`always_nxdomain`. Gatekeeper detects the sinkhole IP and returns `403 DNS Blocked`.

> **Fail-closed behavior:** if Unbound is unreachable or returns an error, all domains
> are blocked. Monitor Unbound health to avoid false positives.

---

## JSON Scrubbing — `scrub_json(data)`

Recursive operation on Python dict/list structures.

### Transformation Rules

| Condition | Action |
|-----------|--------|
| Key is `premium_membership`, `is_premium`, or `isPremium` | Set to `"active"` (string) or `True` (bool) — premium spoofing |
| Key contains `Enforcement` or `enforcement` | Remove the key entirely |
| Key matches `ad_patterns` regex | Zero the value: `[]` / `{}` / `False` / `0` / `""` based on type |
| String value > 30 chars starting with `ey` or `W3` | Attempt base64-decode → recursive scrub → base64-re-encode |
| Everything else | Recurse into `scrub_json(value)` |

### Ad Key Pattern (regex, `re.IGNORECASE`)

```
^(ad|adv|track|adsense|monitoring|stats|heartbeat|impression|
  suggested_ad|offsets|watermark|affiliation).*
```

Example keys matched and zeroed: `adPlacements`, `adBreakHeartbeatParams`,
`trackingParams`, `statsEndpoint`, `impressionData`, `advertisingConfig`.

---

## Binary Fallback Scrubbing — `binary_scrub(flow)`

Applied when JSON parsing fails. Hardcoded byte-level replacements:

| Pattern Found | Replacement | Length |
|---------------|-------------|--------|
| `adPlacements` | `xxPlacements` | 12 bytes = 12 bytes |
| `ad_placement` | `xx_placement` | 12 bytes = 12 bytes |
| `trackingParams` | `xxxxxxxxParams` | 14 bytes = 14 bytes |
| `adBreakHeartbeatParams` | `xxBreakHeartbeatParams` | 22 bytes = 22 bytes |

> **Rule:** old and new patterns **must be equal byte length** to preserve binary offsets
> in the payload. Adding new replacements requires matching lengths exactly.

---

## Logging Format

### Authentication Log (`logs/auth.log`)

```
2026-06-09 12:00:00 INFO user=alice client_ip=1.2.3.4 status=allowed reason=ok
2026-06-09 12:00:01 INFO user=unknown client_ip=1.2.3.4 status=denied reason=invalid_credentials
2026-06-09 12:00:02 INFO user=alice client_ip=1.2.3.4 status=denied reason=rate_limited
```

If the configured log directory is unavailable or read-only, Gatekeeper emits a warning and redirects
authentication and traffic events to container `stderr`. This preserves service availability while keeping
the persistence fault visible through `docker compose logs mitmproxy`.

### Traffic Log (`logs/traffic.log`)

```
2026-06-09 12:00:00 INFO user=alice method=GET host=example.com path=/api/data status=200 bytes=4096
```

---

## Extending the Gatekeeper

### Add a JSON field pattern to scrub

Edit `self.ad_patterns` in `__init__()` (source line 47–50):
```python
self.ad_patterns = re.compile(
    r"^(ad|adv|track|adsense|monitoring|stats|heartbeat|impression|"
    r"suggested_ad|offsets|watermark|affiliation|newpattern).*",
    re.IGNORECASE,
)
```

### Add a binary replacement

Edit `binary_scrub()` (source lines 327–335):
```python
replacements = [
    (rb"adPlacements", rb"xxPlacements"),      # 12 == 12
    (rb"newAdPattern", rb"xxAdPattern_"),      # must match byte length
]
```

### Add a new mitmproxy hook

mitmproxy supports additional hooks beyond `request` and `response`:
- `http_connect(flow)` — intercept CONNECT handshake
- `tls_start_client(data)` — intercept TLS handshake
- `responseheaders(flow)` — headers only, before body is received

Add the method to the `Gatekeeper` class — mitmproxy registers it automatically.

---

*See also: [architecture.md](architecture.md) · [services.md](services.md) · [operations.md](operations.md)*
