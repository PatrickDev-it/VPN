#!/usr/bin/env bash
# ===========================================================================
#  install.sh — Single-command installer for VPS Proxy Stack
# ===========================================================================
#  Designed for curl-pipe usage on a fresh Debian/Ubuntu VPS:
#
#    curl -fsSL https://raw.githubusercontent.com/your-org/vps-proxy-stack/main/install.sh \
#      | sudo bash
#
#  What this script does:
#    1. Installs git if missing
#    2. Clones (or pulls) the repository to INSTALL_DIR
#    3. Creates .env from .env.example if absent
#    4. Creates app/users.yaml from users.yaml.example if absent
#    5. Delegates to init/setup-vps.sh for the full VPS provisioning
#
#  Environment variable overrides (export before running or set in .env):
#    INSTALL_DIR    — clone destination (default: /opt/vps-proxy-stack)
#    REPO_URL       — git repository URL
#    REPO_BRANCH    — git branch to checkout (default: main)
# ===========================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/vps-proxy-stack}"
REPO_URL="${REPO_URL:-https://github.com/your-org/vps-proxy-stack.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"

# ---------------------------------------------------------------------------
# Privilege check
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Error: run this installer as root (use 'sudo bash install.sh')."
  exit 1
fi

echo "======================================================"
echo "  VPS Proxy Stack — Installer"
echo "======================================================"
echo "  Install directory : ${INSTALL_DIR}"
echo "  Repository        : ${REPO_URL}"
echo "  Branch            : ${REPO_BRANCH}"
echo "======================================================"
echo ""

# ---------------------------------------------------------------------------
# 1. Ensure git is available
# ---------------------------------------------------------------------------
if ! command -v git &>/dev/null; then
  echo "[*] git not found — installing..."
  apt-get update -qq
  apt-get -y -qq install git
  echo "[OK] git installed: $(git --version)"
else
  echo "[OK] git present: $(git --version)"
fi

# ---------------------------------------------------------------------------
# 2. Clone or update the repository
# ---------------------------------------------------------------------------
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  echo "[*] Repository found at ${INSTALL_DIR} — pulling latest..."
  git -C "${INSTALL_DIR}" fetch --quiet origin
  git -C "${INSTALL_DIR}" checkout --quiet "${REPO_BRANCH}"
  git -C "${INSTALL_DIR}" reset --hard --quiet "origin/${REPO_BRANCH}"
  echo "[OK] Repository updated to $(git -C "${INSTALL_DIR}" rev-parse --short HEAD)"
else
  echo "[*] Cloning repository to ${INSTALL_DIR}..."
  git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
  echo "[OK] Repository cloned."
fi

cd "${INSTALL_DIR}"

# ---------------------------------------------------------------------------
# 3. Create .env from example if absent
# ---------------------------------------------------------------------------
if [[ ! -f ".env" ]]; then
  cp ".env.example" ".env"
  echo "[OK] .env created from .env.example — edit it to customize your deployment."
else
  echo "[OK] .env already exists — skipping (edit manually to change configuration)."
fi

# ---------------------------------------------------------------------------
# 4. Create users.yaml from example if absent
# ---------------------------------------------------------------------------
if [[ ! -f "app/users.yaml" ]]; then
  cp "app/users.yaml.example" "app/users.yaml"
  echo "[OK] app/users.yaml created — add real credentials before starting the stack."
else
  echo "[OK] app/users.yaml already exists — skipping."
fi

# ---------------------------------------------------------------------------
# 5. Hand off to the full VPS setup script
# ---------------------------------------------------------------------------
echo ""
echo "[*] Starting VPS provisioning via init/setup-vps.sh..."
echo ""
exec bash "${INSTALL_DIR}/init/setup-vps.sh"
