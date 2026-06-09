#!/usr/bin/env bash
# ===========================================================================
#  install.sh — Single-command installer for VPN Platform
# ===========================================================================
#  Designed for curl-pipe usage on a fresh Debian/Ubuntu VPS:
#
#    curl -fsSL https://raw.githubusercontent.com/your-org/vpn-platform/main/vpn/install.sh \
#      | sudo bash
#
#  What this script does:
#    1. Installs git if missing
#    2. Clones (or pulls) the repository to INSTALL_DIR
#    3. Creates .env from .env.example at the repo root if absent
#    4. Creates vpn/app/users.yaml from example if absent
#    5. Delegates to vpn/init/setup-vps.sh
#
#  Overrides (export before piping or set in .env):
#    INSTALL_DIR   — clone destination (default: /opt/vpn-platform)
#    REPO_URL      — git repository URL
#    REPO_BRANCH   — branch to checkout (default: main)
# ===========================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/vpn-platform}"
REPO_URL="${REPO_URL:-https://github.com/your-org/vpn-platform.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this installer as root (sudo bash vpn/install.sh)."
  exit 1
fi

echo "======================================================"
echo "  VPN Platform — Installer"
echo "  Directory : ${INSTALL_DIR}"
echo "  Repo      : ${REPO_URL}  [${REPO_BRANCH}]"
echo "======================================================"
echo ""

# 1. git
if ! command -v git &>/dev/null; then
  apt-get update -qq && apt-get -y -qq install git
  echo "[OK] git installed"
fi

# 2. Clone or update
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  git -C "${INSTALL_DIR}" fetch --quiet origin
  git -C "${INSTALL_DIR}" checkout --quiet "${REPO_BRANCH}"
  git -C "${INSTALL_DIR}" reset --hard --quiet "origin/${REPO_BRANCH}"
  echo "[OK] Repository updated → $(git -C "${INSTALL_DIR}" rev-parse --short HEAD)"
else
  git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
  echo "[OK] Repository cloned"
fi

cd "${INSTALL_DIR}"

# 3. .env at repo root
if [[ ! -f ".env" ]]; then
  cp ".env.example" ".env"
  echo "[OK] .env created — edit before first run if needed"
fi

# 4. users.yaml inside vpn/
if [[ ! -f "vpn/app/users.yaml" ]]; then
  cp "vpn/app/users.yaml.example" "vpn/app/users.yaml"
  echo "[OK] vpn/app/users.yaml created — add real credentials before starting"
fi

# 5. Hand off
echo ""
echo "[*] Starting VPS provisioning..."
exec bash "${INSTALL_DIR}/vpn/init/setup-vps.sh"
