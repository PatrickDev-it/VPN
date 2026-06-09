#!/usr/bin/env bash
# ===========================================================================
#  setup-vps.sh - Fully automated VPS bootstrap for the Proxy Stack
# ===========================================================================
#  Run as root on a clean Debian/Ubuntu host. Requires no interactive input.
#
#  Usage:
#    sudo bash init/setup-vps.sh
#
#  All configuration is read from .env (auto-created from .env.example).
#  Unattended switches (set in .env or as env vars before calling this script):
#    INSTALL_CLOUDPANEL=1   — install CloudPanel (default: 0)
#    AUTO_PROCEED=1         — skip preflight confirmation on warnings (default: 0)
#    MY_DOMAIN              — public hostname (empty = IP-only mode)
#    MY_EMAIL               — email for Let's Encrypt (required when MY_DOMAIN is set)
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"          # = repo/vpn/
REPO_ROOT="$(cd "${PROJECT_DIR}/.." && pwd)"           # = repo root
ENV_FILE="${REPO_ROOT}/.env"

# ---------------------------------------------------------------------------
# 0. Privilege check
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root (use 'sudo' or 'su -')."
  exit 1
fi

# ---------------------------------------------------------------------------
# 0b. Load .env
# ---------------------------------------------------------------------------
if [[ -f "${ENV_FILE}" ]]; then
  set -a; source "${ENV_FILE}"; set +a
  echo "[*] Loaded ${ENV_FILE}"
else
  cp "${REPO_ROOT}/.env.example" "${ENV_FILE}"
  set -a; source "${ENV_FILE}"; set +a
  echo "[!] ${ENV_FILE} not found; created from .env.example — edit it to customize."
fi

MY_DOMAIN="${MY_DOMAIN:-}"
MY_EMAIL="${MY_EMAIL:-}"
UNBOUND_DNS_PORT="${UNBOUND_DNS_PORT:-5353}"
UNBOUND_DOT_PORT="${UNBOUND_DOT_PORT:-853}"
MITMPROXY_BIND_PORT="${MITMPROXY_BIND_PORT:-8080}"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight_check() {
  local errors=0

  echo ""
  echo "=== Preflight checks ==="

  # OS check — Debian or Ubuntu only
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID}" in
      debian|ubuntu) ;;
      *)
        echo "[FAIL] Unsupported OS: ${ID}. This script requires Debian or Ubuntu."
        errors=$((errors + 1))
        ;;
    esac
  else
    echo "[WARN] /etc/os-release not found — OS check skipped."
  fi

  # Port availability — fail if proxy or DNS ports are already occupied
  for port in "${MITMPROXY_BIND_PORT}" "${UNBOUND_DNS_PORT}"; do
    if ss -tuln 2>/dev/null | grep -q ":${port} "; then
      echo "[FAIL] Port ${port}/tcp is already in use. Free it before running setup."
      errors=$((errors + 1))
    fi
  done

  # Disk space — require at least 2 GB free on /
  local free_kb
  free_kb=$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')
  if [[ -n "${free_kb}" && "${free_kb}" -lt 2097152 ]]; then
    echo "[FAIL] Insufficient disk space: ${free_kb} KB free, 2 GB required."
    errors=$((errors + 1))
  fi

  # Docker — check if already installed (non-fatal; install step handles it)
  if ! command -v docker &>/dev/null; then
    echo "[INFO] Docker not found — will be installed in step 2."
  else
    echo "[OK]   Docker present: $(docker --version)"
  fi

  # Domain + email consistency
  if [[ -n "${MY_DOMAIN}" && -z "${MY_EMAIL}" ]]; then
    echo "[WARN] MY_DOMAIN is set but MY_EMAIL is empty — Let's Encrypt cert generation will fail."
  fi

  if [[ "${errors}" -gt 0 ]]; then
    echo ""
    echo "[FAIL] ${errors} preflight check(s) failed. Fix the issues above and re-run."
    exit 1
  fi

  echo "[OK]   All preflight checks passed."
}

preflight_check

# ---------------------------------------------------------------------------
# 1. System update and base dependencies
# ---------------------------------------------------------------------------
echo ""
echo "=== [1/8] System update and dependencies ==="
apt-get update -qq && apt-get -y -qq upgrade
apt-get -y -qq install \
  curl wget sudo ufw ca-certificates gnupg lsb-release \
  fail2ban dnsutils openssl cron iproute2
echo "[OK]   Base packages installed."

# ---------------------------------------------------------------------------
# 2. Docker Engine
# ---------------------------------------------------------------------------
echo ""
echo "=== [2/8] Docker Engine ==="
if command -v docker &>/dev/null; then
  echo "[OK]   Docker already installed: $(docker --version)"
else
  echo "[*]    Installing Docker Engine..."

  # Detect distro to pick the correct Docker apt repo
  # shellcheck source=/dev/null
  source /etc/os-release
  case "${ID}" in
    ubuntu) DOCKER_DISTRO="ubuntu" ;;
    *)      DOCKER_DISTRO="debian" ;;
  esac

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${DOCKER_DISTRO} $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get -y -qq install \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  echo "[OK]   Docker installed: $(docker --version)"
fi

# ---------------------------------------------------------------------------
# 3. CloudPanel (optional)
# ---------------------------------------------------------------------------
echo ""
echo "=== [3/8] CloudPanel ==="
if [[ "${INSTALL_CLOUDPANEL:-0}" == "1" && -n "${MY_DOMAIN}" ]]; then
  if [[ -d "/home/clp" ]]; then
    echo "[OK]   CloudPanel already installed."
  else
    echo "[*]    Installing CloudPanel (MySQL 8.0)..."
    curl -sSL https://installer.cloudpanel.io/ce/v2/install.sh | bash -s -- DB_ENGINE=MYSQL_8.0
    echo "[OK]   CloudPanel installed. Access https://<IP>:8443 to complete setup."
  fi
elif [[ -n "${MY_DOMAIN}" ]]; then
  echo "[→]    CloudPanel skipped (set INSTALL_CLOUDPANEL=1 in .env to enable)."
else
  echo "[→]    No domain configured; CloudPanel not needed."
fi

# ---------------------------------------------------------------------------
# 4. Firewall (UFW)
# ---------------------------------------------------------------------------
echo ""
echo "=== [4/8] Firewall (UFW) ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment 'SSH'
ufw allow 80/tcp    comment 'HTTP (cert renewal)'
ufw allow 443/tcp   comment 'HTTPS'

if [[ -n "${MY_DOMAIN}" ]]; then
  ufw allow 8443/tcp comment 'CloudPanel UI'
fi

if [[ "${UNBOUND_BIND_IP:-127.0.0.1}" == "0.0.0.0" ]]; then
  ufw allow "${UNBOUND_DNS_PORT}/udp" comment 'DNS'
  ufw allow "${UNBOUND_DNS_PORT}/tcp" comment 'DNS'
  ufw allow "${UNBOUND_DOT_PORT}/tcp" comment 'DNS-over-TLS'
fi

ufw allow "${MITMPROXY_BIND_PORT}/tcp" comment 'Proxy ingress (mitmproxy)'
ufw --force enable
echo "[OK]   Firewall configured."

# ---------------------------------------------------------------------------
# 5. Kernel tuning and system limits
# ---------------------------------------------------------------------------
echo ""
echo "=== [5/8] Kernel tuning ==="
cat > /etc/sysctl.d/99-vps-proxy.conf <<'SYSCTL'
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
vm.swappiness = 10
net.core.netdev_max_backlog = 5000
SYSCTL
sysctl --system >/dev/null 2>&1

cat > /etc/security/limits.d/vps-proxy.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
echo "[OK]   Kernel and limits tuned."

# ---------------------------------------------------------------------------
# 6. Fail2Ban
# ---------------------------------------------------------------------------
echo ""
echo "=== [6/8] Fail2Ban ==="
cat > /etc/fail2ban/jail.local <<'F2B'
[sshd]
enabled  = true
port     = 22
maxretry = 3
bantime  = 1d
F2B
systemctl enable --now fail2ban
echo "[OK]   Fail2Ban enabled."

# ---------------------------------------------------------------------------
# 7. TLS certificates
# ---------------------------------------------------------------------------
echo ""
echo "=== [7/8] TLS certificates ==="
bash "${SCRIPT_DIR}/generate-certs.sh"

# ---------------------------------------------------------------------------
# 8. Start proxy stack
# ---------------------------------------------------------------------------
echo ""
echo "=== [8/8] Starting proxy stack ==="
bash "${SCRIPT_DIR}/bootstrap.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "  VPS SETUP COMPLETED"
echo "=========================================================="
echo ""
echo "Active services:"
echo "  Proxy ingress (mitmproxy) : port ${MITMPROXY_BIND_PORT}"
echo "  Local DNS (Unbound)       : port ${UNBOUND_DNS_PORT} + DoT ${UNBOUND_DOT_PORT}"
echo "  Tor anonymization         : SOCKS 9050 (internal)"
echo ""
if [[ -n "${MY_DOMAIN}" ]]; then
  echo "Next steps for domain '${MY_DOMAIN}':"
  echo "  1. Access https://<IP>:8443 → create CloudPanel account."
  echo "  2. Add site '${MY_DOMAIN}' → enable Let's Encrypt SSL."
  echo "  3. Run: bash init/setup-domain.sh"
else
  echo "No domain configured."
  echo "  Proxy reachable via: http://<SERVER_IP>:${MITMPROXY_BIND_PORT}"
  echo "  To add a domain later: bash init/setup-domain.sh"
fi
echo ""
echo "Useful commands:"
echo "  make logs        — tail all service logs"
echo "  make logs-auth   — tail authentication log"
echo "  make down        — stop all services"
echo "=========================================================="
