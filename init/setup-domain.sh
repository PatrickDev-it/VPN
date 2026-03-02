#!/usr/bin/env bash
# ===========================================================================
#  setup-domain.sh – Wizard guidato per configurare dominio + HTTPS
# ===========================================================================
#  Configura il dominio per usare il proxy via DNS anziché IP.
#  Aggiorna automaticamente .env, genera/collega certificati TLS,
#  e riconfigura lo stack.
#
#  Uso:  bash init/setup-domain.sh
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
# Assicurati che .env esista
# ---------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${PROJECT_DIR}/.env.example" "${ENV_FILE}"
  echo "[*] Creato ${ENV_FILE} da .env.example"
fi

set -a; source "${ENV_FILE}"; set +a

# ---------------------------------------------------------------------------
# Step 1: Dominio
# ---------------------------------------------------------------------------
print_header "CONFIGURAZIONE DOMINIO"

CURRENT_DOMAIN="${MY_DOMAIN:-}"
if [[ -n "${CURRENT_DOMAIN}" ]]; then
  echo "Dominio attuale: ${CURRENT_DOMAIN}"
  read -rp "Vuoi cambiarlo? (y/N): " CHANGE_DOMAIN
  if [[ "${CHANGE_DOMAIN,,}" != "y" ]]; then
    MY_DOMAIN="${CURRENT_DOMAIN}"
  else
    read -rp "Nuovo dominio (es. proxy.example.com): " MY_DOMAIN
  fi
else
  read -rp "Inserisci il tuo dominio (es. proxy.example.com): " MY_DOMAIN
fi

if [[ -z "${MY_DOMAIN}" ]]; then
  echo "Errore: dominio obbligatorio per questo wizard."
  echo "Per usare il proxy solo via IP, usa certificati self-signed (TLS_MODE=selfsigned)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Email
# ---------------------------------------------------------------------------
CURRENT_EMAIL="${MY_EMAIL:-}"
if [[ -z "${CURRENT_EMAIL}" ]]; then
  read -rp "Email per Let's Encrypt / CloudPanel (es. admin@${MY_DOMAIN}): " MY_EMAIL
else
  echo "Email: ${CURRENT_EMAIL}"
  read -rp "Vuoi cambiarla? (y/N): " CHANGE_EMAIL
  if [[ "${CHANGE_EMAIL,,}" == "y" ]]; then
    read -rp "Nuova email: " MY_EMAIL
  else
    MY_EMAIL="${CURRENT_EMAIL}"
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: Modalità TLS
# ---------------------------------------------------------------------------
print_header "MODALITÀ CERTIFICATI TLS"

echo "Scegli come generare i certificati HTTPS/DoT per '${MY_DOMAIN}':"
echo ""
echo "  1) cloudpanel  – Usa certificati gestiti da CloudPanel (Let's Encrypt automatico)"
echo "                    Requisiti: CloudPanel installato, sito aggiunto con SSL attivo."
echo ""
echo "  2) letsencrypt – Certbot standalone (Let's Encrypt diretto)"
echo "                    Requisiti: porta 80 libera, DNS A record puntato al server."
echo ""
echo "  3) selfsigned  – Certificato autofirmato (nessun requisito esterno)"
echo "                    Nota: i client vedranno warning 'certificato non attendibile'."
echo ""

read -rp "Scelta [1/2/3] (default: 1): " TLS_CHOICE
case "${TLS_CHOICE}" in
  2) TLS_MODE="letsencrypt" ;;
  3) TLS_MODE="selfsigned"  ;;
  *) TLS_MODE="cloudpanel"  ;;
esac

# ---------------------------------------------------------------------------
# Step 4: Guida DNS
# ---------------------------------------------------------------------------
print_header "CONFIGURAZIONE DNS"

# Rileva IP pubblica
PUBLIC_IP="$(curl -4 -s --max-time 5 https://ifconfig.me || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
fi

echo "Per usare '${MY_DOMAIN}' come endpoint del proxy, configura questi record DNS:"
echo ""
echo "  ┌─────────┬──────────────────────────┬──────────────────┬───────┐"
echo "  │  Tipo   │  Nome                    │  Valore          │  TTL  │"
echo "  ├─────────┼──────────────────────────┼──────────────────┼───────┤"
printf "  │  A      │  %-24s│  %-16s│  300  │\n" "${MY_DOMAIN}" "${PUBLIC_IP:-<IP_SERVER>}"
echo "  └─────────┴──────────────────────────┴──────────────────┴───────┘"
echo ""

# Se il dominio ha subdomain (es. proxy.example.com), suggerisci anche root
ROOT_DOMAIN="$(echo "${MY_DOMAIN}" | awk -F. '{if(NF>2) print $(NF-1)"."$NF; else print $0}')"
if [[ "${ROOT_DOMAIN}" != "${MY_DOMAIN}" ]]; then
  echo "  Se vuoi anche il dominio root:"
  echo ""
  echo "  ┌─────────┬──────────────────────────┬──────────────────┬───────┐"
  printf "  │  A      │  %-24s│  %-16s│  300  │\n" "${ROOT_DOMAIN}" "${PUBLIC_IP:-<IP_SERVER>}"
  echo "  └─────────┴──────────────────────────┴──────────────────┴───────┘"
  echo ""
fi

echo "Dove configurare (dipende dal tuo registrar):"
echo "  - Cloudflare:  DNS → Add Record"
echo "  - Namecheap:   Advanced DNS → Add New Record"
echo "  - OVH:         DNS Zone → Add Entry"
echo "  - Hetzner:     DNS Console → Add Record"
echo ""

# Verifica DNS
echo "[*] Verifico risoluzione DNS per ${MY_DOMAIN}..."
RESOLVED_IP="$(dig +short A "${MY_DOMAIN}" 2>/dev/null | head -1 || true)"
if [[ -n "${RESOLVED_IP}" && "${RESOLVED_IP}" == "${PUBLIC_IP}" ]]; then
  echo "[✓] DNS OK: ${MY_DOMAIN} → ${RESOLVED_IP}"
elif [[ -n "${RESOLVED_IP}" ]]; then
  echo "[!] DNS risolve a ${RESOLVED_IP}, ma l'IP del server è ${PUBLIC_IP:-sconosciuto}."
  echo "    Aggiorna il record A e riprova."
  read -rp "Vuoi continuare comunque? (y/N): " CONT
  [[ "${CONT,,}" != "y" ]] && exit 1
else
  echo "[!] DNS non ancora propagato per ${MY_DOMAIN}."
  echo "    Configura il record A e attendi propagazione (può richiedere 1-60 min)."
  read -rp "Vuoi continuare comunque? (y/N): " CONT
  [[ "${CONT,,}" != "y" ]] && exit 1
fi

# ---------------------------------------------------------------------------
# Step 5: Aggiorna .env
# ---------------------------------------------------------------------------
print_header "AGGIORNAMENTO CONFIGURAZIONE"

update_env "MY_DOMAIN" "${MY_DOMAIN}"
update_env "MY_EMAIL" "${MY_EMAIL}"
update_env "TLS_MODE" "${TLS_MODE}"

echo "[✓] .env aggiornato:"
echo "    MY_DOMAIN=${MY_DOMAIN}"
echo "    MY_EMAIL=${MY_EMAIL}"
echo "    TLS_MODE=${TLS_MODE}"

# ---------------------------------------------------------------------------
# Step 6: Genera certificati
# ---------------------------------------------------------------------------
print_header "GENERAZIONE CERTIFICATI"
bash "${SCRIPT_DIR}/generate-certs.sh"

# ---------------------------------------------------------------------------
# Step 7: Rigenera config e restart stack
# ---------------------------------------------------------------------------
print_header "RIAVVIO STACK"
bash "${SCRIPT_DIR}/bootstrap.sh"

# ---------------------------------------------------------------------------
# Riepilogo
# ---------------------------------------------------------------------------
print_header "SETUP DOMINIO COMPLETATO"

echo "Il proxy è ora configurato per '${MY_DOMAIN}'."
echo ""
echo "Configurazione client proxy:"
echo "  Host:  ${MY_DOMAIN}"
echo "  Porta: ${MITMPROXY_BIND_PORT:-8080}"
echo "  Auth:  Basic (user/password) o Token (Proxy-Authorization: Bearer <token>)"
echo ""
echo "DNS-over-TLS (DoT):"
echo "  Host:  ${MY_DOMAIN}"
echo "  Porta: ${UNBOUND_DOT_PORT:-853}"
if [[ "${TLS_MODE}" == "selfsigned" ]]; then
  echo "  Nota:  certificato self-signed → i client devono accettare il cert manualmente."
fi
echo ""
echo "Test rapido:"
echo "  curl -x http://${MY_DOMAIN}:${MITMPROXY_BIND_PORT:-8080} \\"
echo "       -U 'alice:password' \\"
echo "       https://check.torproject.org/api/ip"
echo ""
