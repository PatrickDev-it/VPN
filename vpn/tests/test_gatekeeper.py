"""
Unit tests for gatekeeper.py.

All tests use MagicMock for mitmproxy types so the test suite runs without
a live mitmproxy installation or Docker stack.
"""

import hashlib
import logging
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Stub out mitmproxy before importing gatekeeper
# ---------------------------------------------------------------------------

def _build_mitmproxy_stub():
    """Create a minimal mitmproxy package stub sufficient for gatekeeper.py."""
    mitmproxy_pkg = types.ModuleType("mitmproxy")
    http_mod = types.ModuleType("mitmproxy.http")

    class _Response:
        @staticmethod
        def make(status_code: int, content: bytes = b"", headers=None):
            r = MagicMock()
            r.status_code = status_code
            r.content = content
            return r

    http_mod.HTTPFlow = MagicMock
    http_mod.Response = _Response
    mitmproxy_pkg.http = http_mod

    sys.modules.setdefault("mitmproxy", mitmproxy_pkg)
    sys.modules.setdefault("mitmproxy.http", http_mod)


_build_mitmproxy_stub()

# Point env vars at local fixture files so gatekeeper loads them
_FIXTURE_DIR = Path(__file__).parent / "fixtures"

import os  # noqa: E402 (must come after stub registration)

os.environ.setdefault("POLICY_FILE", str(_FIXTURE_DIR / "policy.yaml"))
os.environ.setdefault("USERS_FILE",  str(_FIXTURE_DIR / "users.yaml"))
os.environ.setdefault("AUTH_LOG_FILE",     "/tmp/gatekeeper_test_auth.log")
os.environ.setdefault("TRAFFIC_LOG_FILE",  "/tmp/gatekeeper_test_traffic.log")

# Import the module under test
sys.path.insert(0, str(Path(__file__).parent.parent / "app"))
from gatekeeper import Gatekeeper, _setup_file_logger  # noqa: E402

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

ALICE_PASSWORD = "correcthorsebatterystaple"
ALICE_HASH = hashlib.sha256(ALICE_PASSWORD.encode()).hexdigest()


def test_file_logger_falls_back_to_stderr_when_storage_is_unavailable():
    log_name = "gatekeeper_test_unwritable_log"
    fallback_logger = logging.getLogger(log_name)
    fallback_logger.handlers.clear()

    with patch("gatekeeper.logging.FileHandler", side_effect=PermissionError("read-only mount")):
        configured = _setup_file_logger(log_name, "/unwritable/auth.log")

    assert len(configured.handlers) == 1
    assert isinstance(configured.handlers[0], logging.StreamHandler)
    fallback_logger.handlers.clear()


def _write_fixtures(policy: dict | None = None, users: dict | None = None):
    """Write YAML fixture files used by the Gatekeeper instance."""
    import yaml

    _FIXTURE_DIR.mkdir(parents=True, exist_ok=True)

    default_policy = {
        "msg_blocked_domain": "Site blocked by Gatekeeper",
        "msg_blocked_keyword": "Content blocked by Gatekeeper",
        "whitelist_domains": [r"trusted\.example\.com$"],
        "blacklist_domains": [r"blocked\.example\.com$"],
        "whitelist_keywords": ["/login"],
        "blacklist_keywords": ["badkeyword"],
        "ad_key_patterns": ["ad", "track", "stats"],
        "scrub_streaming_hosts": ["youtube.com"],
        "scrub_target_paths": ["/youtubei/"],
        "binary_replacements": [
            {"old": "adPlacements", "new": "xxPlacements"},
        ],
        "profiles": {
            "default": {},
            "strict": {
                "whitelist_domains": [r"internal\.corp$"],
                "blacklist_domains": [".*"],
                "whitelist_keywords": [],
                "blacklist_keywords": [],
            },
        },
    }
    if policy:
        default_policy.update(policy)

    default_users = {
        "users": {
            "alice": {
                "password_sha256": ALICE_HASH,
                "token": "valid-token-abc123",
            },
            "bob": {
                "password_sha256": "deadbeef" * 8,
                "token": "bob-token-xyz",
                "rate_limit_rpm": 1000,
            },
        }
    }
    if users:
        default_users["users"].update(users.get("users", {}))

    (_FIXTURE_DIR / "policy.yaml").write_text(
        yaml.dump(default_policy), encoding="utf-8"
    )
    (_FIXTURE_DIR / "users.yaml").write_text(
        yaml.dump(default_users), encoding="utf-8"
    )


@pytest.fixture(scope="module", autouse=True)
def write_fixtures():
    _write_fixtures()


@pytest.fixture()
def gk(write_fixtures):
    """Fresh Gatekeeper instance with fixture files loaded after fixtures exist."""
    with patch("gatekeeper.Gatekeeper._start_reload_watcher"):
        instance = Gatekeeper()
    return instance


def _make_flow(
    *,
    username: str = "alice",
    password: str = ALICE_PASSWORD,
    host: str = "example.com",
    path: str = "/",
    method: str = "GET",
    url: str | None = None,
    auth_header: str | None = None,
) -> MagicMock:
    """Build a minimal HTTPFlow mock."""
    import base64

    flow = MagicMock()
    flow.metadata = {}
    flow.response = None
    flow.response_streaming = True

    # Encode Basic credentials unless caller supplies custom auth_header
    if auth_header is None:
        creds = base64.b64encode(f"{username}:{password}".encode()).decode()
        auth_header = f"Basic {creds}"

    flow.request.headers = {
        "Proxy-Authorization": auth_header,
    }
    flow.request.host    = host
    flow.request.path    = path
    flow.request.method  = method
    flow.request.pretty_url = url or f"http://{host}{path}"
    flow.client_conn.peername = ("127.0.0.1", 12345)
    return flow


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestAuthentication:
    def test_valid_basic_auth_sets_metadata(self, gk):
        """Valid credentials must set flow.metadata['auth_user'] and not set a response."""
        flow = _make_flow()
        gk.request(flow)
        assert flow.metadata.get("auth_user") == "alice"
        assert flow.response is None

    def test_wrong_password_returns_407(self, gk):
        """Wrong password must produce a 407 Proxy Authentication Required response."""
        flow = _make_flow(password="wrongpassword")
        gk.request(flow)
        assert flow.response is not None
        assert flow.response.status_code == 407

    def test_missing_auth_returns_407(self, gk):
        """Missing Proxy-Authorization header must return 407."""
        flow = _make_flow(auth_header="")
        gk.request(flow)
        assert flow.response is not None
        assert flow.response.status_code == 407


class TestPolicyEnforcement:
    def test_blacklisted_domain_returns_403(self, gk):
        """Requests to blacklisted domains must be blocked with 403."""
        with patch("gatekeeper.Gatekeeper.is_dns_blocked", return_value=False):
            flow = _make_flow(host="blocked.example.com", url="http://blocked.example.com/")
            gk.request(flow)
        assert flow.response is not None
        assert flow.response.status_code == 403

    def test_whitelisted_domain_bypasses_blacklist(self, gk):
        """Whitelisted domains must bypass all blacklist checks, including blacklisted keywords."""
        with patch("gatekeeper.Gatekeeper.is_dns_blocked", return_value=False):
            flow = _make_flow(
                host="trusted.example.com",
                url="http://trusted.example.com/badkeyword",
            )
            gk.request(flow)
        assert flow.metadata.get("auth_user") == "alice"
        assert flow.response is None


class TestScrubbing:
    def test_scrub_json_zeros_ad_keys(self, gk):
        """scrub_json must zero out keys matching ad_key_patterns."""
        data = {
            "adPlacements": [{"ad": "value"}],
            "trackingParams": "abc123",
            "normalKey": "keep_me",
            "stats": {"views": 1000},
        }
        result = gk.scrub_json(data, gk.config)
        assert result["adPlacements"] == []
        assert result["trackingParams"] == ""
        assert result["normalKey"] == "keep_me"
        assert result["stats"] == {}

    def test_binary_scrub_replaces_bytes(self, gk):
        """binary_scrub must replace known binary ad patterns byte-for-byte."""
        flow = MagicMock()
        flow.response = MagicMock()
        flow.response.content = b'{"adPlacements":[]}'
        flow.request.path = "/youtubei/v1/player"
        gk.binary_scrub(flow, gk.config)
        assert b"xxPlacements" in flow.response.content
        assert b"adPlacements" not in flow.response.content


class TestRateLimiting:
    def test_per_user_rate_limit_rpm_override(self, gk):
        """User with rate_limit_rpm=1000 must not be blocked after 10 rapid requests."""
        gk.user_requests.clear()
        user_data = gk.users.get("bob", {})
        assert int(user_data.get("rate_limit_rpm", gk.rate_limit_rpm)) == 1000

        # Simulate 10 requests and verify not rate-limited
        gk.user_requests["bob"] = []
        for _ in range(10):
            limited = gk._is_rate_limited("bob", user_data)
        assert not limited


class TestCodeQuality:
    def test_no_italian_strings_in_source(self):
        """The gatekeeper source file must contain no Italian text."""
        source = (Path(__file__).parent.parent / "app" / "gatekeeper.py").read_text(encoding="utf-8")
        italian_markers = [
            "Sito bloccato",
            "Contenuto bloccato",
            "bloccato",
            "consentito",
            "errore",
            "vietato",
        ]
        for marker in italian_markers:
            assert marker.lower() not in source.lower(), (
                f"Italian string found in gatekeeper.py: {marker!r}"
            )
