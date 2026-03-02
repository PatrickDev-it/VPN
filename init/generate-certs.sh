#!/usr/bin/env bash
# ===========================================================================
#  generate-certs.sh – Genera certificati TLS per Unbound DoT
# ===========================================================================
#  Supporta 3 modalità (TLS_MODE in .env):
#
#    selfsigned   → genera .key + .crt autofirmati in ./ssl-certificates/
#    letsencrypt  → certbot standalone (richiede dominio + porta 80 libera)
#    cloudpanel   → usa i certificati già generati da CloudPanel/Nginx
#
#  Uso:  bash init/generate-certs.sh
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a; source "${ENV_FILE}"; set +a
fi

TLS_MODE="${TLS_MODE:-selfsigned}"
MY_DOMAIN="${MY_DOMAIN:-}"
MY_EMAIL="${MY_EMAIL:-}"
SSL_DIR="${PROJECT_DIR}/ssl-certificates"
CERT_DAYS="${TLS_CERT_DAYS:-365}"

# Paths di output (default per selfsigned / letsencrypt)
KEY_FILE="${SSL_DIR}/server.key"
CRT_FILE="${SSL_DIR}/server.crt"

mkdir -p "${SSL_DIR}"

# ---------------------------------------------------------------------------
case "${TLS_MODE}" in

  # =========================================================================
  # SELF-SIGNED: nessun dominio richiesto, funziona subito
  # =========================================================================
  selfsigned)
    if [[ -f "${KEY_FILE}" && -f "${CRT_FILE}" ]]; then
      echo "[✓] Certificati self-signed già presenti in ${SSL_DIR}/"
      # Verifica scadenza
      if openssl x509 -checkend 604800 -noout -in "${CRT_FILE}" 2>/dev/null; then
        echo "    Scadenza OK (> 7 giorni)."
      else
        echo "[!] Certificato in scadenza o scaduto. Rigenero..."
        rm -f "${KEY_FILE}" "${CRT_FILE}"
      fi
    fi

    if [[ ! -f "${KEY_FILE}" ]]; then
      echo "[*] Genero certificato self-signed (${CERT_DAYS} giorni)..."

      # CN = dominio se configurato, altrimenti hostname
      CN="${MY_DOMAIN:-$(hostname -f 2>/dev/null || echo 'vps-proxy')}"

      # SAN: include IP, hostname, dominio (se presente)
      SAN="DNS:${CN},DNS:localhost,IP:127.0.0.1"
      if [[ -n "${MY_DOMAIN}" ]]; then
        SAN="${SAN},DNS:*.${MY_DOMAIN}"
      fi
      # Tenta di aggiungere IP pubblica
      PUBLIC_IP="$(curl -4 -s --max-time 5 https://ifconfig.me || true)"
      if [[ -n "${PUBLIC_IP}" ]]; then
        SAN="${SAN},IP:${PUBLIC_IP}"
      fi

      openssl req -x509 -newkey rsa:4096 -sha256 \
        -days "${CERT_DAYS}" -nodes \
        -keyout "${KEY_FILE}" \
        -out "${CRT_FILE}" \
        -subj "/CN=${CN}" \
        -addext "subjectAltName=${SAN}" \
        2>/dev/null

      chmod 600 "${KEY_FILE}"
      chmod 644 "${CRT_FILE}"
      echo "[✓] Certificato self-signed generato:"
      echo "    Key: ${KEY_FILE}"
      echo "    Crt: ${CRT_FILE}"
      echo "    CN:  ${CN}"
      echo "    SAN: ${SAN}"
    fi

    # Imposta path per unbound
    export TLS_SERVICE_KEY="/etc/nginx/ssl-certificates/server.key"
    export TLS_SERVICE_PEM="/etc/nginx/ssl-certificates/server.crt"
    ;;

  # =========================================================================
  # LET'S ENCRYPT: richiede dominio, email, porta 80 aperta
  # =========================================================================
  letsencrypt)
    if [[ -z "${MY_DOMAIN}" ]]; then
      echo "Errore: TLS_MODE=letsencrypt richiede MY_DOMAIN nel .env"
      exit 1
    fi
    if [[ -z "${MY_EMAIL}" ]]; then
      echo "Errore: TLS_MODE=letsencrypt richiede MY_EMAIL nel .env"
      exit 1
    fi

    LE_DIR="/etc/letsencrypt/live/${MY_DOMAIN}"
    KEY_FILE="${LE_DIR}/privkey.pem"
    CRT_FILE="${LE_DIR}/fullchain.pem"

    if [[ -f "${KEY_FILE}" && -f "${CRT_FILE}" ]]; then
      echo "[✓] Certificati Let's Encrypt già presenti per ${MY_DOMAIN}"
      # Rinnova se necessario
      if command -v certbot &>/dev/null; then
        certbot renew --quiet || true
      fi
    else
      echo "[*] Richiedo certificato Let's Encrypt per ${MY_DOMAIN}..."

      # Installa certbot se mancante
      if ! command -v certbot &>/dev/null; then
        echo "[*] Installo certbot..."
        apt-get update && apt-get install -y --no-install-recommends certbot
      fi

      # Ferma temporaneamente servizi su porta 80
      echo "[!] Certbot necessita porta 80 libera (standalone mode)."
      certbot certonly --standalone \
        -d "${MY_DOMAIN}" \
        --email "${MY_EMAIL}" \
        --agree-tos --non-interactive \
        --preferred-challenges http

      echo "[✓] Certificato Let's Encrypt ottenuto per ${MY_DOMAIN}"
    fi

    # Copia in ssl-certificates/ per il mount Docker
    cp -L "${KEY_FILE}" "${SSL_DIR}/server.key"
    cp -L "${CRT_FILE}" "${SSL_DIR}/server.crt"
    chmod 600 "${SSL_DIR}/server.key"
    chmod 644 "${SSL_DIR}/server.crt"

    # Cron per rinnovo automatico
    RENEW_SCRIPT="/usr/local/bin/renew-proxy-certs.sh"
    cat > "${RENEW_SCRIPT}" <<RENEW
#!/usr/bin/env bash
certbot renew --quiet
cp -L "${KEY_FILE}" "${SSL_DIR}/server.key"
cp -L "${CRT_FILE}" "${SSL_DIR}/server.crt"
cd "${PROJECT_DIR}" && docker compose restart unbound
RENEW
    chmod +x "${RENEW_SCRIPT}"
    # Aggiunge cron se non presente
    CRON_TAG="# VPS_CERT_RENEW"
    current_cron="$(crontab -l 2>/dev/null || true)"
    if ! grep -q "${CRON_TAG}" <<< "${current_cron}"; then
      { echo "${current_cron}"; echo "0 4 * * * ${RENEW_SCRIPT} ${CRON_TAG}"; } | crontab -
      echo "[✓] Cron rinnovo certificati installato (ogni giorno alle 04:00)."
    fi

    export TLS_SERVICE_KEY="/etc/nginx/ssl-certificates/server.key"
    export TLS_SERVICE_PEM="/etc/nginx/ssl-certificates/server.crt"
    ;;

  # =========================================================================
  # CLOUDPANEL: usa i certificati generati da CloudPanel per il dominio
  # =========================================================================
  cloudpanel)
    if [[ -z "${MY_DOMAIN}" ]]; then
      echo "Errore: TLS_MODE=cloudpanel richiede MY_DOMAIN nel .env"
      exit 1
    fi

    # Percorsi standard CloudPanel / Nginx
    CLP_KEY="/etc/nginx/ssl-certificates/${MY_DOMAIN}.key"
    CLP_CRT="/etc/nginx/ssl-certificates/${MY_DOMAIN}.crt"

    if [[ -f "${CLP_KEY}" && -f "${CLP_CRT}" ]]; then
      echo "[✓] Certificati CloudPanel trovati per ${MY_DOMAIN}"
      # Copia in ssl-certificates/ per il mount Docker
      cp -L "${CLP_KEY}" "${SSL_DIR}/server.key"
      cp -L "${CLP_CRT}" "${SSL_DIR}/server.crt"
      chmod 600 "${SSL_DIR}/server.key"
      chmod 644 "${SSL_DIR}/server.crt"
    else
      echo "[!] Certificati CloudPanel non trovati:"
      echo "    Attesi: ${CLP_KEY}"
      echo "             ${CLP_CRT}"
      echo ""
      echo "    Assicurati di:"
      echo "    1. Accedere a CloudPanel (https://<IP>:8443)"
      echo "    2. Aggiungere il sito '${MY_DOMAIN}'"
      echo "    3. Attivare SSL (Let's Encrypt) dal pannello"
      echo "    4. Rieseguire: bash init/generate-certs.sh"
      echo ""
      echo "[→] Genero certificati self-signed temporanei come fallback..."
      export TLS_MODE=selfsigned
      exec bash "${BASH_SOURCE[0]}"
    fi

    # Cron per aggiornare i cert dalla dir CloudPanel
    SYNC_SCRIPT="/usr/local/bin/sync-cloudpanel-certs.sh"
    cat > "${SYNC_SCRIPT}" <<SYNC
#!/usr/bin/env bash
cp -L "${CLP_KEY}" "${SSL_DIR}/server.key"
cp -L "${CLP_CRT}" "${SSL_DIR}/server.crt"
cd "${PROJECT_DIR}" && docker compose restart unbound
SYNC
    chmod +x "${SYNC_SCRIPT}"
    CRON_TAG="# VPS_CLP_CERT_SYNC"
    current_cron="$(crontab -l 2>/dev/null || true)"
    if ! grep -q "${CRON_TAG}" <<< "${current_cron}"; then
      { echo "${current_cron}"; echo "0 5 * * * ${SYNC_SCRIPT} ${CRON_TAG}"; } | crontab -
      echo "[✓] Cron sync certificati CloudPanel installato (ogni giorno alle 05:00)."
    fi

    export TLS_SERVICE_KEY="/etc/nginx/ssl-certificates/server.key"
    export TLS_SERVICE_PEM="/etc/nginx/ssl-certificates/server.crt"
    ;;

  *)
    echo "Errore: TLS_MODE='${TLS_MODE}' non valido. Usa: selfsigned | letsencrypt | cloudpanel"
    exit 1
    ;;
esac

echo ""
echo "[*] TLS_MODE=${TLS_MODE} – certificati pronti in ${SSL_DIR}/"
