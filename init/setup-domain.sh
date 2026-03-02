#!/usr/bin/env bash
# ===========================================================================
#  setup-domain.sh - Guided wizard for domain + HTTPS setup
# ===========================================================================
#  Configures domain access for the proxy (DNS instead of raw IP),
#  updates .env, provisions/links TLS certificates,
#  and reconfigures the running stack.
#
#  Usage: bash init/setup-domain.sh
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
print_header() {
  echo ""
  echo "==========================================================="
  echo "  $1"
  echo "==========================================================="
  echo ""
}

update_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
}

# ---------------------------------------------------------------------------
# Ensure .env exists
# ---------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${PROJECT_DIR}/.env.example" "${ENV_FILE}"
  echo "[*] Created ${ENV_FILE} from .env.example"
fi

set -a; source "${ENV_FILE}"; set +a

# ---------------------------------------------------------------------------
# Step 1: Domain
# ---------------------------------------------------------------------------
print_header "DOMAIN CONFIGURATION"

CURRENT_DOMAIN="${MY_DOMAIN:-}"
if [[ -n "${CURRENT_DOMAIN}" ]]; then
  echo "Current domain: ${CURRENT_DOMAIN}"
  read -rp "Do you want to change it? (y/N): " CHANGE_DOMAIN
  if [[ "${CHANGE_DOMAIN,,}" != "y" ]]; then
    MY_DOMAIN="${CURRENT_DOMAIN}"
  else
    read -rp "New domain (e.g. proxy.example.com): " MY_DOMAIN
  fi
else
  read -rp "Enter your domain (e.g. proxy.example.com): " MY_DOMAIN
fi

if [[ -z "${MY_DOMAIN}" ]]; then
  echo "Error: domain is required for this wizard."
  echo "To keep IP-only mode, use self-signed certificates (TLS_MODE=selfsigned)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Email
# ---------------------------------------------------------------------------
CURRENT_EMAIL="${MY_EMAIL:-}"
if [[ -z "${CURRENT_EMAIL}" ]]; then
  read -rp "Email for Let's Encrypt / CloudPanel (e.g. admin@${MY_DOMAIN}): " MY_EMAIL
else
  echo "Email: ${CURRENT_EMAIL}"
  read -rp "Do you want to change it? (y/N): " CHANGE_EMAIL
  if [[ "${CHANGE_EMAIL,,}" == "y" ]]; then
    read -rp "New email: " MY_EMAIL
  else
    MY_EMAIL="${CURRENT_EMAIL}"
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: TLS mode
# ---------------------------------------------------------------------------
print_header "TLS CERTIFICATE MODE"

echo "Choose how HTTPS/DoT certificates should be provisioned for '${MY_DOMAIN}':"
echo ""
echo "  1) cloudpanel  - Use certificates managed by CloudPanel (automatic Let's Encrypt)"
echo "                    Requirements: CloudPanel installed, site added, SSL enabled."
echo ""
echo "  2) letsencrypt - Direct certbot standalone mode"
echo "                    Requirements: port 80 available, DNS A record points to this server."
echo ""
echo "  3) selfsigned  - Self-signed certificate (no external dependency)"
echo "                    Note: clients will see an untrusted certificate warning."
echo ""

read -rp "Select [1/2/3] (default: 1): " TLS_CHOICE
case "${TLS_CHOICE}" in
  2) TLS_MODE="letsencrypt" ;;
  3) TLS_MODE="selfsigned"  ;;
  *) TLS_MODE="cloudpanel"  ;;
esac

# ---------------------------------------------------------------------------
# Step 4: DNS guidance
# ---------------------------------------------------------------------------
print_header "DNS CONFIGURATION"

# Detect public IP
PUBLIC_IP="$(curl -4 -s --max-time 5 https://ifconfig.me || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
fi

echo "To use '${MY_DOMAIN}' as proxy endpoint, configure these DNS records:"
echo ""
echo "  ┌─────────┬──────────────────────────┬──────────────────┬───────┐"
echo "  │  Tipo   │  Nome                    │  Valore          │  TTL  │"
echo "  ├─────────┼──────────────────────────┼──────────────────┼───────┤"
printf "  │  A      │  %-24s│  %-16s│  300  │\n" "${MY_DOMAIN}" "${PUBLIC_IP:-<IP_SERVER>}"
echo "  └─────────┴──────────────────────────┴──────────────────┴───────┘"
echo ""

# If this is a subdomain (e.g. proxy.example.com), suggest root record too
ROOT_DOMAIN="$(echo "${MY_DOMAIN}" | awk -F. '{if(NF>2) print $(NF-1)"."$NF; else print $0}')"
if [[ "${ROOT_DOMAIN}" != "${MY_DOMAIN}" ]]; then
  echo "  Optional root domain record:"
  echo ""
  echo "  ┌─────────┬──────────────────────────┬──────────────────┬───────┐"
  printf "  │  A      │  %-24s│  %-16s│  300  │\n" "${ROOT_DOMAIN}" "${PUBLIC_IP:-<IP_SERVER>}"
  echo "  └─────────┴──────────────────────────┴──────────────────┴───────┘"
  echo ""
fi

echo "Where to configure records (depends on your DNS provider):"
echo "  - Cloudflare:  DNS → Add Record"
echo "  - Namecheap:   Advanced DNS → Add New Record"
echo "  - OVH:         DNS Zone → Add Entry"
echo "  - Hetzner:     DNS Console → Add Record"
echo ""

# Verify DNS
echo "[*] Checking DNS resolution for ${MY_DOMAIN}..."
RESOLVED_IP="$(dig +short A "${MY_DOMAIN}" 2>/dev/null | head -1 || true)"
if [[ -n "${RESOLVED_IP}" && "${RESOLVED_IP}" == "${PUBLIC_IP}" ]]; then
  echo "[✓] DNS OK: ${MY_DOMAIN} → ${RESOLVED_IP}"
elif [[ -n "${RESOLVED_IP}" ]]; then
  echo "[!] DNS resolves to ${RESOLVED_IP}, but server public IP is ${PUBLIC_IP:-unknown}."
  echo "    Update the A record and try again."
  read -rp "Continue anyway? (y/N): " CONT
  [[ "${CONT,,}" != "y" ]] && exit 1
else
  echo "[!] DNS not propagated yet for ${MY_DOMAIN}."
  echo "    Configure the A record and wait for propagation (typically 1-60 minutes)."
  read -rp "Continue anyway? (y/N): " CONT
  [[ "${CONT,,}" != "y" ]] && exit 1
fi

# ---------------------------------------------------------------------------
# Step 5: Update .env
# ---------------------------------------------------------------------------
print_header "CONFIGURATION UPDATE"

update_env "MY_DOMAIN" "${MY_DOMAIN}"
update_env "MY_EMAIL" "${MY_EMAIL}"
update_env "TLS_MODE" "${TLS_MODE}"

echo "[✓] .env updated:"
echo "    MY_DOMAIN=${MY_DOMAIN}"
echo "    MY_EMAIL=${MY_EMAIL}"
echo "    TLS_MODE=${TLS_MODE}"

# ---------------------------------------------------------------------------
# Step 6: Generate certificates
# ---------------------------------------------------------------------------
print_header "CERTIFICATE GENERATION"
bash "${SCRIPT_DIR}/generate-certs.sh"

# ---------------------------------------------------------------------------
# Step 7: Regenerate config and restart stack
# ---------------------------------------------------------------------------
print_header "STACK RESTART"
bash "${SCRIPT_DIR}/bootstrap.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_header "DOMAIN SETUP COMPLETED"

echo "Proxy is now configured for '${MY_DOMAIN}'."
echo ""
echo "Proxy client configuration:"
echo "  Host:  ${MY_DOMAIN}"
echo "  Port:  ${MITMPROXY_BIND_PORT:-8080}"
echo "  Auth:  Basic (user/password) or Token (Proxy-Authorization: Bearer <token>)"
echo ""
echo "DNS-over-TLS (DoT):"
echo "  Host:  ${MY_DOMAIN}"
echo "  Port:  ${UNBOUND_DOT_PORT:-853}"
if [[ "${TLS_MODE}" == "selfsigned" ]]; then
  echo "  Note:  self-signed certificate requires manual trust on clients."
fi
echo ""
echo "Quick test:"
echo "  curl -x http://${MY_DOMAIN}:${MITMPROXY_BIND_PORT:-8080} \\"
echo "       -U 'alice:password' \\"
echo "       https://check.torproject.org/api/ip"
echo ""
