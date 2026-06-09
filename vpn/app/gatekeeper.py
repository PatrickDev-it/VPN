"""
gatekeeper.py — mitmproxy addon for the VPS Proxy Stack.

Responsibilities (in request pipeline order):
  1. User authentication    — Basic SHA256 or Bearer token
  2. Per-user rate limiting — sliding window, in-memory
  3. Header stripping       — remove revealing / fingerprinting headers
  4. DNS sinkhole check     — block domains resolving to 127.0.0.1 / 0.0.0.0
  5. Policy enforcement     — per-user whitelist / blacklist (regex, YAML-driven)
  6. Response scrubbing     — recursive JSON ad-field zeroing + binary fallback

All configuration is read from policy.yaml and users.yaml.
Both files are hot-reloaded every CONFIG_RELOAD_INTERVAL_SEC seconds (default: 30).
Changes to either file take effect without restarting mitmproxy.
"""

import base64
import hashlib
import hmac
import json
import logging
import os
import re
import socket
import threading
import time
from pathlib import Path

import yaml
from mitmproxy import http

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("Gatekeeper")


# ---------------------------------------------------------------------------
# File logger factory
# ---------------------------------------------------------------------------

def _setup_file_logger(name: str, file_path: str) -> logging.Logger:
    log = logging.getLogger(name)
    log.setLevel(logging.INFO)
    log.propagate = False
    Path(file_path).parent.mkdir(parents=True, exist_ok=True)
    if not log.handlers:
        handler = logging.FileHandler(file_path)
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        log.addHandler(handler)
    return log


# ---------------------------------------------------------------------------
# Optional Tor ControlPort client
# ---------------------------------------------------------------------------

class TorController:
    """Sends NEWNYM to Tor when a user's preferred exit countries are set.

    Active only when TOR_CONTROL_ENABLED=1. stem is imported lazily so the
    container works without it when the feature is disabled.

    Limitation: NEWNYM rotates circuits globally (Tor architecture constraint),
    not per-user. True per-user isolation requires a dedicated Tor instance per
    user and is out of scope for this release.
    """

    def __init__(self) -> None:
        self._enabled = os.getenv("TOR_CONTROL_ENABLED", "0") == "1"
        self._controller = None
        if self._enabled:
            self._connect()

    def _connect(self) -> None:
        try:
            from stem.control import Controller  # lazy import
            self._controller = Controller.from_port(
                address=os.getenv("TOR_CONTROL_HOST", "tor"),
                port=int(os.getenv("TOR_CONTROL_PORT", "9051")),
            )
            self._controller.authenticate()
            logger.info("Tor ControlPort connected")
        except Exception as exc:
            logger.warning("Tor ControlPort unavailable: %s — NEWNYM disabled", exc)
            self._controller = None

    def request_new_circuit(self, countries: list[str]) -> None:
        """Send NEWNYM signal. Reconnects once on failure."""
        if not self._controller:
            return
        try:
            from stem import Signal  # lazy import
            self._controller.signal(Signal.NEWNYM)
            logger.debug("NEWNYM sent (preferred exits: %s)", countries)
        except Exception as exc:
            logger.warning("NEWNYM failed: %s — reconnecting", exc)
            self._controller = None
            self._connect()


# ---------------------------------------------------------------------------
# Gatekeeper addon
# ---------------------------------------------------------------------------

class Gatekeeper:
    def __init__(self):
        # Env-var backed settings (read once at startup)
        self.auth_mode = os.getenv("AUTH_MODE", "basic").lower()
        self.rate_limit_rpm = int(os.getenv("RATE_LIMIT_RPM", "120"))
        self.rate_limit_window = int(os.getenv("RATE_LIMIT_WINDOW_SEC", "60"))
        self._reload_interval = int(os.getenv("CONFIG_RELOAD_INTERVAL_SEC", "30"))

        # Per-user sliding-window state (in-memory; resets on restart)
        self.user_requests: dict[str, list[float]] = {}

        # File loggers
        auth_log_path = os.getenv("AUTH_LOG_FILE", "/app/logs/auth.log")
        traffic_log_path = os.getenv("TRAFFIC_LOG_FILE", "/app/logs/traffic.log")
        self.auth_logger = _setup_file_logger("gatekeeper_auth", auth_log_path)
        self.traffic_logger = _setup_file_logger("gatekeeper_traffic", traffic_log_path)

        # Thread-safety for hot-reload
        self._lock = threading.RLock()

        # Optional Tor circuit controller
        self.tor = TorController()

        # Initial load
        self.load_policy()
        self.load_users()

        # Track mtimes for hot-reload watcher
        self._policy_mtime = self._file_mtime(os.getenv("POLICY_FILE", "/app/app/policy.yaml"))
        self._users_mtime = self._file_mtime(os.getenv("USERS_FILE", "/app/app/users.yaml"))

        # Start background watcher
        self._start_reload_watcher()

    # -----------------------------------------------------------------------
    # Configuration loading
    # -----------------------------------------------------------------------

    def load_policy(self) -> None:
        """Load (or reload) policy.yaml and compile all derived objects."""
        policy_file = os.getenv("POLICY_FILE", "/app/app/policy.yaml")
        defaults: dict = {
            "whitelist_domains": [],
            "blacklist_domains": [],
            "blacklist_keywords": [],
            "whitelist_keywords": [],
            "ad_key_patterns": [
                "ad", "adv", "track", "adsense", "monitoring", "stats",
                "heartbeat", "impression", "suggested_ad", "offsets",
                "watermark", "affiliation",
            ],
            "scrub_streaming_hosts": ["youtube.com", "googleapis.com"],
            "scrub_target_paths": [
                "/youtubei/", "/api/stats/", "/ptracking/", "/log_event/", "/player",
            ],
            "binary_replacements": [
                {"old": "adPlacements",          "new": "xxPlacements"},
                {"old": "ad_placement",          "new": "xx_placement"},
                {"old": "trackingParams",        "new": "xxxxxxxParams"},
                {"old": "adBreakHeartbeatParams","new": "xxBreakHeartbeatParams"},
            ],
            "msg_blocked_domain":  "Site blocked by Gatekeeper",
            "msg_blocked_keyword": "Content blocked by Gatekeeper",
            "profiles": {},
        }
        try:
            with open(policy_file) as fh:
                loaded = yaml.safe_load(fh) or {}
            config = {**defaults, **loaded}
        except Exception as exc:
            logger.warning("Failed to load policy file '%s': %s — using defaults", policy_file, exc)
            config = defaults

        # Compile ad-key regex from YAML list
        terms = config.get("ad_key_patterns") or defaults["ad_key_patterns"]
        joined = "|".join(re.escape(str(t)) for t in terms)
        config["_ad_patterns_re"] = re.compile(rf"^({joined}).*", re.IGNORECASE)

        # Compile binary replacements — validate equal byte length, skip mismatches
        validated: list[tuple[bytes, bytes]] = []
        for entry in (config.get("binary_replacements") or []):
            old_b = entry["old"].encode()
            new_b = entry["new"].encode()
            if len(old_b) != len(new_b):
                logger.warning(
                    "binary_replacement length mismatch: %r (%d B) vs %r (%d B) — skipped",
                    entry["old"], len(old_b), entry["new"], len(new_b),
                )
                continue
            validated.append((old_b, new_b))
        config["_binary_replacements"] = validated

        # Encode block messages to bytes
        config["_msg_blocked_domain"]  = config["msg_blocked_domain"].encode("utf-8")
        config["_msg_blocked_keyword"] = config["msg_blocked_keyword"].encode("utf-8")

        self.config = config

    def load_users(self) -> None:
        """Load (or reload) users.yaml."""
        users_file = os.getenv("USERS_FILE", "/app/app/users.yaml")
        try:
            with open(users_file) as fh:
                data = yaml.safe_load(fh) or {}
            self.users: dict = data.get("users", {})
        except Exception as exc:
            logger.warning("Failed to load users file: %s — no users loaded", exc)
            self.users = {}

    # -----------------------------------------------------------------------
    # Hot-reload watcher
    # -----------------------------------------------------------------------

    @staticmethod
    def _file_mtime(path: str) -> float:
        try:
            return Path(path).stat().st_mtime
        except OSError:
            return 0.0

    def _start_reload_watcher(self) -> None:
        """Start a daemon thread that polls policy.yaml and users.yaml for changes."""
        policy_file = os.getenv("POLICY_FILE", "/app/app/policy.yaml")
        users_file  = os.getenv("USERS_FILE",  "/app/app/users.yaml")

        def _watch() -> None:
            while True:
                time.sleep(self._reload_interval)
                try:
                    pm = self._file_mtime(policy_file)
                    if pm != self._policy_mtime:
                        with self._lock:
                            self.load_policy()
                            self._policy_mtime = pm
                        logger.info("policy.yaml reloaded")

                    um = self._file_mtime(users_file)
                    if um != self._users_mtime:
                        with self._lock:
                            self.load_users()
                            self._users_mtime = um
                        logger.info("users.yaml reloaded")
                except Exception as exc:
                    logger.warning("Config reload error: %s", exc)

        t = threading.Thread(target=_watch, daemon=True, name="config-watcher")
        t.start()

    # -----------------------------------------------------------------------
    # Authentication helpers
    # -----------------------------------------------------------------------

    def _extract_basic_credentials(self, flow: http.HTTPFlow) -> tuple[str | None, str | None]:
        auth_header = flow.request.headers.get("Proxy-Authorization", "")
        if not auth_header.lower().startswith("basic "):
            return None, None
        try:
            decoded = base64.b64decode(auth_header.split(" ", 1)[1]).decode("utf-8")
            username, password = decoded.split(":", 1)
            return username, password
        except Exception:
            return None, None

    def _extract_token(self, flow: http.HTTPFlow) -> str | None:
        header_value = flow.request.headers.get("Proxy-Authorization", "")
        if header_value.lower().startswith("bearer "):
            return header_value.split(" ", 1)[1]
        return flow.request.headers.get("X-Proxy-Token")

    def _verify_user(self, flow: http.HTTPFlow) -> str | None:
        """Return authenticated username or None."""
        with self._lock:
            users_snapshot = self.users
            auth_mode = self.auth_mode

        if not users_snapshot:
            return None

        if auth_mode == "token":
            token = self._extract_token(flow)
            if not token:
                return None
            for username, user_data in users_snapshot.items():
                saved = str(user_data.get("token", ""))
                if saved and hmac.compare_digest(saved, token):
                    return username
            return None

        username, password = self._extract_basic_credentials(flow)
        if not username or not password:
            return None

        user_data = users_snapshot.get(username)
        if not user_data:
            return None

        expected_hash = str(user_data.get("password_sha256", "")).lower()
        if not expected_hash:
            return None

        password_hash = hashlib.sha256(password.encode("utf-8")).hexdigest()
        return username if hmac.compare_digest(expected_hash, password_hash) else None

    # -----------------------------------------------------------------------
    # Rate limiting
    # -----------------------------------------------------------------------

    def _is_rate_limited(self, username: str, user_data: dict) -> bool:
        """Sliding-window rate limiter. Respects per-user rate_limit_rpm override."""
        user_rpm = int(user_data.get("rate_limit_rpm", self.rate_limit_rpm))
        now = time.time()
        if username not in self.user_requests:
            self.user_requests[username] = []
        recent = [ts for ts in self.user_requests[username] if now - ts <= self.rate_limit_window]
        self.user_requests[username] = recent
        if len(recent) >= user_rpm:
            return True
        self.user_requests[username].append(now)
        return False

    # -----------------------------------------------------------------------
    # Policy resolution
    # -----------------------------------------------------------------------

    def _get_effective_config(self, username: str, config_snapshot: dict) -> dict:
        """Return the effective policy dict for this user.

        If the user has a `policy_profile` field pointing to a key in `profiles:`,
        that profile is returned. Otherwise the top-level config is used.
        Profile resolution is a full replacement (not inheritance).
        """
        with self._lock:
            users_snapshot = self.users
        user_data = users_snapshot.get(username, {})
        profile_name = user_data.get("policy_profile")
        if profile_name:
            profiles = config_snapshot.get("profiles", {})
            profile = profiles.get(profile_name)
            if profile and profile:  # non-empty profile
                # Merge compiled objects from top-level into profile snapshot
                merged = dict(config_snapshot)
                merged.update(profile)
                return merged
        return config_snapshot

    # -----------------------------------------------------------------------
    # Auth responses and logging
    # -----------------------------------------------------------------------

    def _proxy_auth_required(self, flow: http.HTTPFlow) -> None:
        flow.response = http.Response.make(
            407,
            b"Proxy authentication required",
            {
                "Proxy-Authenticate": (
                    "Basic realm=Gatekeeper" if self.auth_mode == "basic" else "Bearer"
                ),
                "Content-Type": "text/plain",
            },
        )

    def _log_auth(self, username: str, client_ip: str, status: str, reason: str = "") -> None:
        self.auth_logger.info(
            "user=%s client_ip=%s status=%s reason=%s",
            username, client_ip, status, reason,
        )

    # -----------------------------------------------------------------------
    # mitmproxy hooks
    # -----------------------------------------------------------------------

    def request(self, flow: http.HTTPFlow) -> None:
        client_ip = flow.client_conn.peername[0] if flow.client_conn.peername else "unknown"

        # --- Authentication ---
        username = self._verify_user(flow)
        if username is None:
            self._log_auth("unknown", client_ip, "denied", "invalid_credentials")
            self._proxy_auth_required(flow)
            return

        # Take consistent snapshots for this request (avoids holding lock during I/O)
        with self._lock:
            config_snapshot = self.config
            users_snapshot  = self.users

        user_data = users_snapshot.get(username, {})

        # --- Rate limiting ---
        if self._is_rate_limited(username, user_data):
            self._log_auth(username, client_ip, "denied", "rate_limited")
            flow.response = http.Response.make(
                429,
                b"Rate limit exceeded",
                {"Retry-After": str(self.rate_limit_window), "Content-Type": "text/plain"},
            )
            return

        self._log_auth(username, client_ip, "allowed", "ok")
        flow.metadata["auth_user"] = username

        # Signal Tor to rotate circuits when user has preferred exit countries.
        exit_countries = user_data.get("exit_countries")
        if exit_countries:
            flow.metadata["exit_countries"] = exit_countries
            self.tor.request_new_circuit(exit_countries)

        # --- Buffering for scrubbing (disable streaming for known hosts) ---
        streaming_hosts = config_snapshot.get("scrub_streaming_hosts", [])
        if any(h in flow.request.host for h in streaming_hosts):
            flow.response_streaming = False

        # --- Strip revealing headers ---
        for header in (
            "X-Forwarded-For", "X-Real-IP", "Via", "Proxy-Connection",
            "Sec-CH-UA", "Proxy-Authorization", "Authorization",
        ):
            flow.request.headers.pop(header, None)
        flow.request.headers["X-Authenticated-User"] = username

        # Force JSON Accept for protobuf requests (enables scrubbing)
        if "application/x-protobuf" in flow.request.headers.get("Accept", ""):
            flow.request.headers["Accept"] = "application/json, text/plain, */*"

        # CONNECT tunnels: auth + rate-limit only — policy skipped (encrypted tunnel)
        if flow.request.method == "CONNECT":
            return

        url    = flow.request.pretty_url
        domain = flow.request.host

        # --- DNS sinkhole check ---
        if self.is_dns_blocked(domain):
            flow.response = http.Response.make(403, b"DNS Blocked")
            return

        # --- Per-user effective policy ---
        effective = self._get_effective_config(username, config_snapshot)

        for pattern in effective.get("whitelist_domains", []):
            if re.search(pattern, domain, re.IGNORECASE):
                logger.info("ALLOWED (whitelist_domain): %s", domain)
                return

        for pattern in effective.get("whitelist_keywords", []):
            if re.search(pattern, url, re.IGNORECASE):
                logger.info("ALLOWED (whitelist_keyword): %s", url)
                return

        for pattern in effective.get("blacklist_domains", []):
            if re.search(pattern, domain, re.IGNORECASE):
                logger.warning("BLOCKED (blacklist_domain): %s", domain)
                flow.response = http.Response.make(
                    403, config_snapshot["_msg_blocked_domain"]
                )
                return

        for pattern in effective.get("blacklist_keywords", []):
            if re.search(pattern, url, re.IGNORECASE):
                logger.warning("BLOCKED (blacklist_keyword): %s", url)
                flow.response = http.Response.make(
                    403, config_snapshot["_msg_blocked_keyword"]
                )
                return

    def response(self, flow: http.HTTPFlow) -> None:
        if not flow.response or not flow.response.content:
            return

        with self._lock:
            config_snapshot = self.config

        username      = flow.metadata.get("auth_user", "unknown")
        status_code   = flow.response.status_code
        response_size = len(flow.response.content or b"")

        self.traffic_logger.info(
            "user=%s method=%s host=%s path=%s status=%s bytes=%s",
            username, flow.request.method, flow.request.host,
            flow.request.path, status_code, response_size,
        )

        flow.response.decode()
        content_type   = flow.response.headers.get("Content-Type", "").lower()
        target_paths   = config_snapshot.get("scrub_target_paths", [])
        is_target_path = any(p in flow.request.path.lower() for p in target_paths)

        if "json" in content_type or is_target_path:
            try:
                raw_text = flow.response.get_text()
                if not raw_text:
                    return
                if raw_text.startswith("data:application/json;base64,"):
                    prefix, b64_data = raw_text.split(",", 1)
                    decoded  = base64.b64decode(b64_data).decode("utf-8")
                    clean    = self.scrub_json(json.loads(decoded), config_snapshot)
                    new_b64  = base64.b64encode(json.dumps(clean).encode("utf-8")).decode("utf-8")
                    flow.response.text = f"{prefix},{new_b64}"
                else:
                    data = json.loads(raw_text)
                    flow.response.text = json.dumps(self.scrub_json(data, config_snapshot))
                logger.info("Scrub completed: %s", flow.request.path[:60])
            except Exception:
                self.binary_scrub(flow, config_snapshot)

    # -----------------------------------------------------------------------
    # Scrubbing
    # -----------------------------------------------------------------------

    def scrub_json(self, data, config: dict):
        """Recursively zero out ad-related keys in a JSON structure."""
        ad_re: re.Pattern = config.get("_ad_patterns_re")

        if isinstance(data, dict):
            clean: dict = {}
            for key, value in data.items():
                # Premium membership spoofing
                if key in ("premium_membership", "is_premium", "isPremium"):
                    clean[key] = "active" if isinstance(value, str) else True
                    continue
                # Enforcement key removal
                if "Enforcement" in key or "enforcement" in key:
                    continue
                # Ad-pattern zeroing
                if ad_re and ad_re.match(key):
                    if isinstance(value, list):
                        clean[key] = []
                    elif isinstance(value, dict):
                        clean[key] = {}
                    elif isinstance(value, bool):
                        clean[key] = False
                    elif isinstance(value, (int, float)):
                        clean[key] = 0
                    else:
                        clean[key] = ""
                    continue
                # Decode and scrub inline base64-encoded JSON
                if isinstance(value, str) and len(value) > 30 and value.startswith(("ey", "W3")):
                    try:
                        decoded = base64.b64decode(value).decode("utf-8")
                        if decoded.startswith(("{", "[")):
                            value = base64.b64encode(
                                json.dumps(self.scrub_json(json.loads(decoded), config)).encode()
                            ).decode("utf-8")
                    except Exception:
                        pass
                clean[key] = self.scrub_json(value, config)
            return clean

        if isinstance(data, list):
            return [self.scrub_json(item, config) for item in data]
        return data

    def binary_scrub(self, flow: http.HTTPFlow, config: dict) -> None:
        """Byte-level fallback scrubbing when JSON parsing fails."""
        replacements: list[tuple[bytes, bytes]] = config.get("_binary_replacements", [])
        content = flow.response.content
        for old_b, new_b in replacements:
            if old_b in content:
                content = content.replace(old_b, new_b)
        flow.response.content = content

    # -----------------------------------------------------------------------
    # DNS sinkhole helper
    # -----------------------------------------------------------------------

    def is_dns_blocked(self, domain: str) -> bool:
        """Return True if the domain resolves to a sinkhole address (fail-closed)."""
        try:
            ip = socket.gethostbyname(domain)
            return ip in ("127.0.0.1", "0.0.0.0")
        except Exception:
            return True


# mitmproxy addon registration
addons = [Gatekeeper()]
