#!/usr/bin/env bash
# ===========================================================================
#  setup-vps.sh - Full Debian 12 + CloudPanel + Proxy Stack bootstrap
# ===========================================================================
#  Run as root on a clean Debian 12 host.
#  Loads variables from ../.env (or uses safe defaults).
#
#  Usage: sudo bash init/setup-vps.sh
# ===========================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Paths and variables
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root (use 'sudo' or 'su -')."
  exit 1
fi

# Load .env if available (MY_DOMAIN, MY_EMAIL, ports, etc.)
if [[ -f "${ENV_FILE}" ]]; then
  set -a; source "${ENV_FILE}"; set +a
  echo "[*] Loaded ${ENV_FILE}"
else
  echo "[!] ${ENV_FILE} not found; using defaults. Create .env from .env.example to customize."
fi

MY_DOMAIN="${MY_DOMAIN:-}"
MY_EMAIL="${MY_EMAIL:-}"

# Interactive prompts for missing values
if [[ -z "${MY_DOMAIN}" ]]; then
  read -rp "Enter your domain (e.g. example.com) [leave empty = IP only]: " MY_DOMAIN
fi
if [[ -z "${MY_EMAIL}" && -n "${MY_DOMAIN}" ]]; then
  read -rp "Enter email for Let's Encrypt / CloudPanel: " MY_EMAIL
fi

UNBOUND_DNS_PORT="${UNBOUND_DNS_PORT:-5353}"
UNBOUND_DOT_PORT="${UNBOUND_DOT_PORT:-853}"
MITMPROXY_BIND_PORT="${MITMPROXY_BIND_PORT:-8080}"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. System update and base dependencies
# ---------------------------------------------------------------------------
echo ""
echo "=== [1/8] Debian update and dependencies ==="
apt update && apt -y upgrade
apt -y install \
  curl wget sudo ufw ca-certificates gnupg lsb-release \
  fail2ban dnsutils openssl cron

# ---------------------------------------------------------------------------
# 2. Docker Engine (if missing)
# ---------------------------------------------------------------------------
echo ""
echo "=== [2/8] Docker Engine ==="
if command -v docker &>/dev/null; then
  echo "[✓] Docker already installed: $(docker --version)"
else
  echo "[*] Installing Docker Engine..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt update
  apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  echo "[✓] Docker installed: $(docker --version)"
fi

# ---------------------------------------------------------------------------
# 3. CloudPanel (optional - only if domain is configured)
# ---------------------------------------------------------------------------
echo ""
echo "=== [3/8] CloudPanel ==="
if [[ -n "${MY_DOMAIN}" ]]; then
  if [[ -d "/home/clp" ]]; then
    echo "[✓] CloudPanel already installed."
  else
    read -rp "Install CloudPanel? (y/N): " INSTALL_CLP
    if [[ "${INSTALL_CLP,,}" == "y" ]]; then
      echo "[*] Installing CloudPanel (MySQL 8.0)..."
      curl -sSL https://installer.cloudpanel.io/ce/v2/install.sh | sudo DB_ENGINE=MYSQL_8.0 bash
      echo "[✓] CloudPanel installed. Access https://<IP>:8443 to complete setup."
    else
      echo "[→] CloudPanel skipped."
    fi
  fi
else
  echo "[→] No domain configured; CloudPanel not required."
fi

# ---------------------------------------------------------------------------
# 4. Firewall (UFW)
# ---------------------------------------------------------------------------
echo ""
echo "=== [4/8] Firewall configuration (UFW) ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp  comment 'SSH'
ufw allow 80/tcp  comment 'HTTP (cert renewal)'
ufw allow 443/tcp comment 'HTTPS'

if [[ -n "${MY_DOMAIN}" ]]; then
  ufw allow 8443/tcp comment 'CloudPanel UI'
fi

# DNS ports (only if publicly exposed)
if [[ "${UNBOUND_BIND_IP:-127.0.0.1}" == "0.0.0.0" ]]; then
  ufw allow "${UNBOUND_DNS_PORT}/udp" comment 'DNS Standard'
  ufw allow "${UNBOUND_DNS_PORT}/tcp" comment 'DNS Standard'
  ufw allow "${UNBOUND_DOT_PORT}/tcp" comment 'DNS-over-TLS'
fi

# Proxy ingress
ufw allow "${MITMPROXY_BIND_PORT}/tcp" comment 'Proxy ingress (mitmproxy)'

ufw --force enable
echo "[✓] Firewall configured."

# ---------------------------------------------------------------------------
# 5. Kernel tuning and system limits
# ---------------------------------------------------------------------------
echo ""
echo "=== [5/8] Kernel tuning and limits ==="
cat <<'SYSCTL' > /etc/sysctl.d/99-vps-proxy.conf
# VPS Proxy Stack - tuning for high concurrency
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
vm.swappiness = 10
net.core.netdev_max_backlog = 5000
SYSCTL
sysctl --system >/dev/null 2>&1

cat <<'LIMITS' > /etc/security/limits.d/vps-proxy.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
echo "[✓] Kernel and limits tuned."

# ---------------------------------------------------------------------------
# 6. Fail2Ban
# ---------------------------------------------------------------------------
echo ""
echo "=== [6/8] Fail2Ban Security Baseline ==="
cat <<'F2B' > /etc/fail2ban/jail.local
[sshd]
enabled  = true
port     = 22
maxretry = 3
bantime  = 1d
F2B
systemctl enable --now fail2ban
echo "[✓] Fail2Ban enabled."

# ---------------------------------------------------------------------------
# 7. Generate TLS certificates (if required)
# ---------------------------------------------------------------------------
echo ""
echo "=== [7/8] TLS certificates ==="
bash "${SCRIPT_DIR}/generate-certs.sh"

# ---------------------------------------------------------------------------
# 8. Start proxy stack (bootstrap.sh)
# ---------------------------------------------------------------------------
echo ""
echo "=== [8/8] Starting proxy stack ==="
bash "${SCRIPT_DIR}/bootstrap.sh"

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "  VPS SETUP COMPLETED"
echo "=========================================================="
echo ""
echo "Active services:"
echo "  - Proxy ingress (mitmproxy): port ${MITMPROXY_BIND_PORT}"
echo "  - Local DNS (Unbound):       port ${UNBOUND_DNS_PORT} + DoT ${UNBOUND_DOT_PORT}"
echo "  - Tor anonymization:         internal SOCKS 9050"
echo ""
if [[ -n "${MY_DOMAIN}" ]]; then
  echo "Next steps for domain '${MY_DOMAIN}':"
  echo "  1. Access https://<IP>:8443 and create your CloudPanel account."
  echo "  2. Add site '${MY_DOMAIN}' and enable Let's Encrypt SSL."
  echo "  3. After SSL is active, run: bash init/setup-domain.sh"
  echo "     to bind certificates to proxy and Unbound DoT."
else
  echo "No domain configured."
  echo "  - Proxy reachable by IP: http://<IP>:${MITMPROXY_BIND_PORT}"
  echo "  - DoT certificates: self-signed in ./ssl-certificates/"
  echo "  - To add a domain later: bash init/setup-domain.sh"
fi
echo ""
echo "Useful commands:"
echo "  make logs        - tail logs for all services"
echo "  make logs-auth   - tail authentication logs"
echo "  make down        - stop stack"
echo "=========================================================="
