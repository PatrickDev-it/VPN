#!/usr/bin/env bash
# ===========================================================================
#  setup-vps.sh – Setup completo Debian 12 + CloudPanel + Proxy Stack
# ===========================================================================
#  Eseguire come root su un Debian 12 pulito.
#  Legge le variabili da ../.env (o usa default sicuri).
#
#  Uso:  sudo bash init/setup-vps.sh
# ===========================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Paths e variabili
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

if [[ $EUID -ne 0 ]]; then
  echo "Errore: Esegui lo script come root (usa 'sudo' o 'su -')."
  exit 1
fi

# Carica .env se presente (per MY_DOMAIN, MY_EMAIL, porte, ecc.)
if [[ -f "${ENV_FILE}" ]]; then
  set -a; source "${ENV_FILE}"; set +a
  echo "[*] Caricato ${ENV_FILE}"
else
  echo "[!] ${ENV_FILE} non trovato; uso default. Crea .env da .env.example per personalizzare."
fi

MY_DOMAIN="${MY_DOMAIN:-}"
MY_EMAIL="${MY_EMAIL:-}"

# Chiedi interattivamente se non presenti
if [[ -z "${MY_DOMAIN}" ]]; then
  read -rp "Inserisci il tuo dominio (es. example.com) [vuoto = solo IP]: " MY_DOMAIN
fi
if [[ -z "${MY_EMAIL}" && -n "${MY_DOMAIN}" ]]; then
  read -rp "Inserisci email per Let's Encrypt / CloudPanel: " MY_EMAIL
fi

UNBOUND_DNS_PORT="${UNBOUND_DNS_PORT:-53}"
UNBOUND_DOT_PORT="${UNBOUND_DOT_PORT:-853}"
MITMPROXY_BIND_PORT="${MITMPROXY_BIND_PORT:-8080}"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. Aggiornamento e dipendenze base
# ---------------------------------------------------------------------------
echo ""
echo "=== [1/8] Aggiornamento e Dipendenze Debian ==="
apt update && apt -y upgrade
apt -y install \
  curl wget sudo ufw ca-certificates gnupg lsb-release \
  fail2ban dnsutils openssl cron

# ---------------------------------------------------------------------------
# 2. Docker Engine (se non già presente)
# ---------------------------------------------------------------------------
echo ""
echo "=== [2/8] Docker Engine ==="
if command -v docker &>/dev/null; then
  echo "[✓] Docker già installato: $(docker --version)"
else
  echo "[*] Installazione Docker Engine..."
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
  echo "[✓] Docker installato: $(docker --version)"
fi

# ---------------------------------------------------------------------------
# 3. CloudPanel (opzionale – solo se dominio configurato)
# ---------------------------------------------------------------------------
echo ""
echo "=== [3/8] CloudPanel ==="
if [[ -n "${MY_DOMAIN}" ]]; then
  if [[ -d "/home/clp" ]]; then
    echo "[✓] CloudPanel già installato."
  else
    read -rp "Vuoi installare CloudPanel? (y/N): " INSTALL_CLP
    if [[ "${INSTALL_CLP,,}" == "y" ]]; then
      echo "[*] Installazione CloudPanel (MySQL 8.0)..."
      curl -sSL https://installer.cloudpanel.io/ce/v2/install.sh | sudo DB_ENGINE=MYSQL_8.0 bash
      echo "[✓] CloudPanel installato. Accedi a https://<IP>:8443 per completare il setup."
    else
      echo "[→] CloudPanel saltato."
    fi
  fi
else
  echo "[→] Nessun dominio configurato; CloudPanel non necessario."
fi

# ---------------------------------------------------------------------------
# 4. Firewall (UFW)
# ---------------------------------------------------------------------------
echo ""
echo "=== [4/8] Configurazione Firewall (UFW) ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp  comment 'SSH'
ufw allow 80/tcp  comment 'HTTP (cert renewal)'
ufw allow 443/tcp comment 'HTTPS'

if [[ -n "${MY_DOMAIN}" ]]; then
  ufw allow 8443/tcp comment 'CloudPanel UI'
fi

# DNS ports (solo se esposti pubblicamente)
if [[ "${UNBOUND_BIND_IP:-127.0.0.1}" == "0.0.0.0" ]]; then
  ufw allow "${UNBOUND_DNS_PORT}/udp" comment 'DNS Standard'
  ufw allow "${UNBOUND_DNS_PORT}/tcp" comment 'DNS Standard'
  ufw allow "${UNBOUND_DOT_PORT}/tcp" comment 'DNS-over-TLS'
fi

# Proxy ingress
ufw allow "${MITMPROXY_BIND_PORT}/tcp" comment 'Proxy ingress (mitmproxy)'

ufw --force enable
echo "[✓] Firewall configurato."

# ---------------------------------------------------------------------------
# 5. Ottimizzazione Kernel & Limiti di Sistema
# ---------------------------------------------------------------------------
echo ""
echo "=== [5/8] Ottimizzazione Kernel & Limiti ==="
cat <<'SYSCTL' > /etc/sysctl.d/99-vps-proxy.conf
# VPS Proxy Stack – tuning per migliaia di connessioni concorrenti
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
echo "[✓] Kernel e limiti ottimizzati."

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
echo "[✓] Fail2Ban attivo."

# ---------------------------------------------------------------------------
# 7. Genera certificati TLS (se necessario)
# ---------------------------------------------------------------------------
echo ""
echo "=== [7/8] Certificati TLS ==="
bash "${SCRIPT_DIR}/generate-certs.sh"

# ---------------------------------------------------------------------------
# 8. Avvia Proxy Stack (bootstrap.sh)
# ---------------------------------------------------------------------------
echo ""
echo "=== [8/8] Avvio Proxy Stack ==="
bash "${SCRIPT_DIR}/bootstrap.sh"

# ---------------------------------------------------------------------------
# Riepilogo finale
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "  SETUP VPS COMPLETATO"
echo "=========================================================="
echo ""
echo "Servizi attivi:"
echo "  - Proxy ingress (mitmproxy): porta ${MITMPROXY_BIND_PORT}"
echo "  - DNS locale (Unbound):      porta ${UNBOUND_DNS_PORT} + DoT ${UNBOUND_DOT_PORT}"
echo "  - Tor anonimizzazione:        SOCKS interno 9050"
echo ""
if [[ -n "${MY_DOMAIN}" ]]; then
  echo "Prossimi passi con dominio '${MY_DOMAIN}':"
  echo "  1. Accedi a https://<IP>:8443 e crea l'utente CloudPanel."
  echo "  2. Aggiungi il sito '${MY_DOMAIN}' e attiva SSL Let's Encrypt."
  echo "  3. Dopo SSL attivo, esegui: bash init/setup-domain.sh"
  echo "     per agganciare i certificati al proxy e Unbound DoT."
else
  echo "Nessun dominio configurato."
  echo "  - Proxy raggiungibile via IP: http://<IP>:${MITMPROXY_BIND_PORT}"
  echo "  - Certificati DoT: self-signed in ./ssl-certificates/"
  echo "  - Per aggiungere un dominio: bash init/setup-domain.sh"
fi
echo ""
echo "Comandi utili:"
echo "  make logs        – log tutti i servizi"
echo "  make logs-auth   – log autenticazione"
echo "  make down        – stop stack"
echo "=========================================================="
