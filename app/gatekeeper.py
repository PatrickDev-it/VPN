import base64
import hashlib
import hmac
import json
import logging
import os
import re
import socket
import time
from pathlib import Path

import yaml
from mitmproxy import http

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("Gatekeeper")


def _setup_file_logger(name: str, file_path: str) -> logging.Logger:
    log = logging.getLogger(name)
    log.setLevel(logging.INFO)
    log.propagate = False
    Path(file_path).parent.mkdir(parents=True, exist_ok=True)
    if not log.handlers:
        handler = logging.FileHandler(file_path)
        handler.setFormatter(
            logging.Formatter("%(asctime)s %(levelname)s %(message)s")
        )
        log.addHandler(handler)
    return log


class Gatekeeper:
    def __init__(self):
        self.load_policy()
        self.load_users()
        self.auth_mode = os.getenv("AUTH_MODE", "basic").lower()
        self.rate_limit_rpm = int(os.getenv("RATE_LIMIT_RPM", "120"))
        self.rate_limit_window = int(os.getenv("RATE_LIMIT_WINDOW_SEC", "60"))
        self.user_requests = {}
        auth_log_path = os.getenv("AUTH_LOG_FILE", "/app/logs/auth.log")
        traffic_log_path = os.getenv("TRAFFIC_LOG_FILE", "/app/logs/traffic.log")
        self.auth_logger = _setup_file_logger("gatekeeper_auth", auth_log_path)
        self.traffic_logger = _setup_file_logger(
            "gatekeeper_traffic", traffic_log_path
        )
        self.ad_patterns = re.compile(
            r"^(ad|adv|track|adsense|monitoring|stats|heartbeat|impression|suggested_ad|offsets|watermark|affiliation).*",
            re.IGNORECASE,
        )
        self.bin_ad_pattern = re.compile(
            rb"(ad_placement|adsense|tracking|stats|heartbeat|impression|suggested_ad|offsets|watermark|affiliation)",
            re.IGNORECASE,
        )
        self.target_paths = [
            "/next",
            "/youtubei/",
            "/api/stats/",
            "/ptracking/",
            "/log_event/",
            "/player",
        ]

    def load_policy(self):
        policy_file = os.getenv("POLICY_FILE", "/app/app/policy.yaml")
        try:
            with open(policy_file, "r") as stream:
                self.config = yaml.safe_load(stream)
        except Exception:
            self.config = {
                "whitelist_domains": [],
                "blacklist_domains": [],
                "blacklist_keywords": [],
                "whitelist_keywords": [],
            }

    def load_users(self):
        users_file = os.getenv("USERS_FILE", "/app/app/users.yaml")
        self.users = {}
        try:
            with open(users_file, "r") as stream:
                data = yaml.safe_load(stream) or {}
            self.users = data.get("users", {})
        except Exception:
            self.users = {}

    def _extract_basic_credentials(self, flow: http.HTTPFlow):
        auth_header = flow.request.headers.get("Proxy-Authorization", "")
        if not auth_header.lower().startswith("basic "):
            return None, None
        try:
            decoded = base64.b64decode(auth_header.split(" ", 1)[1]).decode("utf-8")
            username, password = decoded.split(":", 1)
            return username, password
        except Exception:
            return None, None

    def _extract_token(self, flow: http.HTTPFlow):
        header_value = flow.request.headers.get("Proxy-Authorization", "")
        if header_value.lower().startswith("bearer "):
            return header_value.split(" ", 1)[1]
        return flow.request.headers.get("X-Proxy-Token")

    def _verify_user(self, flow: http.HTTPFlow):
        if not self.users:
            return None

        if self.auth_mode == "token":
            token = self._extract_token(flow)
            if not token:
                return None
            for username, user_data in self.users.items():
                saved_token = str(user_data.get("token", ""))
                if saved_token and hmac.compare_digest(saved_token, token):
                    return username
            return None

        username, password = self._extract_basic_credentials(flow)
        if not username or not password:
            return None

        user_data = self.users.get(username)
        if not user_data:
            return None

        expected_hash = str(user_data.get("password_sha256", "")).lower()
        if not expected_hash:
            return None

        password_hash = hashlib.sha256(password.encode("utf-8")).hexdigest()
        if hmac.compare_digest(expected_hash, password_hash):
            return username
        return None

    def _is_rate_limited(self, username: str):
        now = time.time()
        if username not in self.user_requests:
            self.user_requests[username] = []
        recent = [
            ts
            for ts in self.user_requests[username]
            if now - ts <= self.rate_limit_window
        ]
        self.user_requests[username] = recent
        if len(recent) >= self.rate_limit_rpm:
            return True
        self.user_requests[username].append(now)
        return False

    def _proxy_auth_required(self, flow: http.HTTPFlow):
        flow.response = http.Response.make(
            407,
            b"Proxy authentication required",
            {
                "Proxy-Authenticate": "Basic realm=Gatekeeper" if self.auth_mode == "basic" else "Bearer",
                "Content-Type": "text/plain",
            },
        )

    def _log_auth(self, username: str, client_ip: str, status: str, reason: str = ""):
        self.auth_logger.info(
            "user=%s client_ip=%s status=%s reason=%s",
            username,
            client_ip,
            status,
            reason,
        )

    def scrub_json(self, data):
        if isinstance(data, dict):
            clean_dict = {}
            for key, value in data.items():
                if key in ["premium_membership", "is_premium", "isPremium"]:
                    clean_dict[key] = "active" if isinstance(value, str) else True
                    continue

                if "Enforcement" in key or "enforcement" in key:
                    continue

                if self.ad_patterns.match(key):
                    if isinstance(value, list):
                        clean_dict[key] = []
                    elif isinstance(value, dict):
                        clean_dict[key] = {}
                    elif isinstance(value, bool):
                        clean_dict[key] = False
                    elif isinstance(value, (int, float)):
                        clean_dict[key] = 0
                    else:
                        clean_dict[key] = ""
                    continue

                if isinstance(value, str) and len(value) > 30:
                    if value.startswith(("ey", "W3")):
                        try:
                            decoded = base64.b64decode(value).decode("utf-8")
                            if decoded.startswith(("{", "[")):
                                cleaned_value = self.scrub_json(json.loads(decoded))
                                value = base64.b64encode(
                                    json.dumps(cleaned_value).encode("utf-8")
                                ).decode("utf-8")
                        except Exception:
                            pass

                clean_dict[key] = self.scrub_json(value)
            return clean_dict
        if isinstance(data, list):
            return [self.scrub_json(item) for item in data]
        return data

    def request(self, flow: http.HTTPFlow):
        client_ip = flow.client_conn.peername[0] if flow.client_conn.peername else "unknown"
        username = self._verify_user(flow)
        if username is None:
            self._log_auth("unknown", client_ip, "denied", "invalid_credentials")
            self._proxy_auth_required(flow)
            return

        if self._is_rate_limited(username):
            self._log_auth(username, client_ip, "denied", "rate_limited")
            flow.response = http.Response.make(
                429,
                b"Rate limit exceeded",
                {"Retry-After": str(self.rate_limit_window), "Content-Type": "text/plain"},
            )
            return

        self._log_auth(username, client_ip, "allowed", "ok")
        flow.metadata["auth_user"] = username

        if any(x in flow.request.host for x in ["youtube.com", "googleapis.com"]):
            flow.response_streaming = False

        headers_to_remove = [
            "X-Forwarded-For",
            "X-Real-IP",
            "Via",
            "Proxy-Connection",
            "Sec-CH-UA",
            "Proxy-Authorization",
            "Authorization",
        ]
        for header in headers_to_remove:
            flow.request.headers.pop(header, None)

        flow.request.headers["X-Authenticated-User"] = username

        if "application/x-protobuf" in flow.request.headers.get("Accept", ""):
            flow.request.headers["Accept"] = "application/json, text/plain, */*"

        if flow.request.method == "CONNECT":
            return

        url = flow.request.pretty_url
        domain = flow.request.host
        if self.is_dns_blocked(domain):
            flow.response = http.Response.make(403, b"DNS Blocked")

        for pattern in self.config.get("whitelist_domains", []):
            if re.search(pattern, domain, re.IGNORECASE):
                logger.info("ALLOWED (Whitelist Domain): %s", domain)
                return

        for pattern in self.config.get("whitelist_keywords", []):
            if re.search(pattern, url, re.IGNORECASE):
                logger.info("ALLOWED (Whitelist Keyword): %s", url)
                return

        for pattern in self.config.get("blacklist_domains", []):
            if re.search(pattern, domain, re.IGNORECASE):
                logger.warning("BLOCKED (Blacklist Domain): %s", domain)
                flow.response = http.Response.make(403, b"Sito Bloccato da VPS Gatekeeper")
                return

        for pattern in self.config.get("blacklist_keywords", []):
            if re.search(pattern, url, re.IGNORECASE):
                logger.warning("BLOCKED (Blacklist Keyword): %s", url)
                flow.response = http.Response.make(
                    403, b"Contenuto Filtrato da VPS Gatekeeper"
                )
                return

    def response(self, flow: http.HTTPFlow):
        if not flow.response or not flow.response.content:
            return

        username = flow.metadata.get("auth_user", "unknown")
        status_code = flow.response.status_code
        response_size = len(flow.response.content or b"")
        self.traffic_logger.info(
            "user=%s method=%s host=%s path=%s status=%s bytes=%s",
            username,
            flow.request.method,
            flow.request.host,
            flow.request.path,
            status_code,
            response_size,
        )

        flow.response.decode()
        content_type = flow.response.headers.get("Content-Type", "").lower()
        is_target_path = any(x in flow.request.path.lower() for x in self.target_paths)

        if "json" in content_type or is_target_path:
            try:
                raw_text = flow.response.get_text()
                if not raw_text:
                    return

                if raw_text.startswith("data:application/json;base64,"):
                    prefix, b64_data = raw_text.split(",", 1)
                    decoded = base64.b64decode(b64_data).decode("utf-8")
                    clean_json = self.scrub_json(json.loads(decoded))
                    new_b64 = base64.b64encode(
                        json.dumps(clean_json).encode("utf-8")
                    ).decode("utf-8")
                    flow.response.text = f"{prefix},{new_b64}"
                else:
                    data = json.loads(raw_text)
                    flow.response.text = json.dumps(self.scrub_json(data))

                logger.info("Surgery Completed: %s", flow.request.path[:40])
            except Exception:
                self.binary_scrub(flow)

    def binary_scrub(self, flow):
        content = flow.response.content
        replacements = [
            (rb"adPlacements", rb"xxPlacements"),
            (rb"ad_placement", rb"xx_placement"),
            (rb"trackingParams", rb"xxxxxxxParams"),
            (rb"adBreakHeartbeatParams", rb"xxBreakHeartbeatParams"),
        ]
        for old, new in replacements:
            if old in content:
                content = content.replace(old, new)
        flow.response.content = content

    def is_dns_blocked(self, domain):
        try:
            ip = socket.gethostbyname(domain)
            return ip in ["127.0.0.1", "0.0.0.0"]
        except Exception:
            return True


addons = [Gatekeeper()]