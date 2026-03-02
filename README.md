# VPS - Proxy Anonimizzazione con Accesso Autenticato

Stack implementato:

- Unbound (resolver DNS locale con DNSSEC e blacklist)
- Privoxy (forward proxy verso Tor)
- Mitmproxy (policy engine, autenticazione, rate limit, traffic control)
- Tor (uscita anonima con exit policy anti-ads, connection padding, circuit anti-profiling)

## Architettura

Flusso operativo del progetto:

`Client -> Mitmproxy (auth + policy + rate limit) -> Privoxy -> Tor -> Exit Node -> Target`

Componenti:

- `unbound`: risoluzione DNS locale/validata (no DNS leak lato host/client che punta a questo resolver).
- `mitmproxy`: punto di ingresso del proxy autenticato e layer di controllo traffico.
- `privoxy`: forward proxy intermedio che inoltra su SOCKS5 Tor.
- `tor`: layer di anonimizzazione IP con exit policy geografica anti-ads, connection padding e circuit anti-profiling.

Nota pratica: Privoxy non offre un modello nativo robusto per autenticazione utenti per-proxy comparabile a un auth gateway dedicato; in questo progetto l'autenticazione obbligatoria è implementata in `mitmproxy` (ingresso), mantenendo Privoxy come forwarding layer nel chain verso Tor.

## Struttura progetto

```
project-root/
├── app/
│   ├── gatekeeper.py
│   ├── policy.yaml
│   ├── users.yaml.example
│   └── __init__.py
├── unbound/
│   ├── unbound.conf
│   └── blacklist.conf
├── privoxy/
│   └── config
├── tor/
│   └── torrc
├── services/
│   ├── unbound/Dockerfile
│   ├── privoxy/Dockerfile
│   └── tor/Dockerfile
├── init/
│   ├── bootstrap.sh
│   ├── setup-vps.sh
│   ├── setup-domain.sh
│   ├── generate-certs.sh
│   └── vps-proxy-stack.service
├── ssl-certificates/           (generata automaticamente)
├── cron/
│   └── update_blacklist.sh
├── logs/
├── Dockerfile
├── docker-compose.yml
├── Makefile
├── requirements.txt
├── requirements-dev.txt
├── .env.example
└── README.md
```

## Setup completo VPS (Debian 12 da zero)

Per installare tutto su un VPS Debian 12 pulito (include Docker, CloudPanel, firewall, kernel tuning, Fail2Ban, e l'intero proxy stack):

```bash
git clone https://github.com/PatrickDev-it/VPS.git && cd VPS
cp .env.example .env
# Edita .env con dominio, email, porte desiderate
sudo bash init/setup-vps.sh
```

Lo script `setup-vps.sh` esegue in sequenza:

1. Aggiornamento sistema e installazione dipendenze (curl, ufw, fail2ban, openssl, ecc.)
2. Installazione Docker Engine + Compose Plugin (se non presente)
3. Installazione CloudPanel (opzionale, solo se `MY_DOMAIN` configurato)
4. Configurazione firewall UFW (deny-by-default, apre solo porte necessarie)
5. Ottimizzazione kernel (`sysctl`) e limiti sistema (`nofile`) per alta concorrenza
6. Fail2Ban con baseline SSH (3 tentativi, ban 1 giorno)
7. Generazione certificati TLS (in base a `TLS_MODE`)
8. Avvio completo proxy stack via `bootstrap.sh`

## Deploy manuale (host con Docker già installato)

Prerequisiti host:

1. Installare Docker Engine + Docker Compose Plugin.
2. Aprire solo le porte necessarie (`8080/tcp` per proxy ingress, `53/tcp+udp` e `853/tcp` se vuoi esporre Unbound Do53+DoT).
3. Bloccare tutto il traffico outbound diretto dei client verso internet, forzando il transito via proxy.

Setup:

1. Copia env:
	- `cp .env.example .env`
2. Crea file utenti:
	- `cp app/users.yaml.example app/users.yaml`
3. Genera hash password SHA-256:
	- `python3 -c "import hashlib;print(hashlib.sha256(b'PASSWORD_FORTE').hexdigest())"`
4. Inserisci hash/token in `app/users.yaml`.
5. Build e verifica:
	- `make build`
	- `make verify`
6. Avvio servizi:
	- `make up`
7. Aggiorna blacklist DNS:
	- `make update-blacklist`

## Init unico (avvio + persistenza reboot)

Per avviare tutto e installare persistenza su macchina Ubuntu/Debian:

- `make init`

Questo comando esegue `init/bootstrap.sh` e fa automaticamente:

1. Genera `privoxy/config` partendo da variabili in `.env`.
2. Genera certificati TLS se non presenti (in base a `TLS_MODE`).
3. Renderizza path TLS in `unbound/unbound.conf`.
4. Avvia stack completo (`unbound`, `tor`, `privoxy`, `mitmproxy`).
5. Installa service `systemd` (`vps-proxy-stack.service`) per restart automatico al reboot.
6. Installa cron persistente per aggiornare blacklist (`BLACKLIST_CRON_SCHEDULE`).

Toggle persistenza in `.env`:

- `INSTALL_SYSTEMD=1|0`
- `INSTALL_CRON=1|0`

## Configurazione dominio (accesso via DNS anziché IP)

Per usare il proxy tramite dominio (es. `proxy.example.com`) anziché IP:

```bash
make setup-domain
```

Il wizard guidato:

1. Chiede dominio (es. `proxy.example.com`) e email.
2. Mostra i record DNS A da configurare sul registrar.
3. Verifica propagazione DNS.
4. Offre scelta modalità TLS:
   - **cloudpanel** – certificati gestiti da CloudPanel/Nginx (Let's Encrypt automatico).
   - **letsencrypt** – certbot standalone diretto.
   - **selfsigned** – certificato autofirmato (nessun requisito esterno).
5. Genera/collega certificati e riavvia lo stack.

### Variabili dominio/TLS in `.env`

| Variabile | Default | Descrizione |
|---|---|---|
| `MY_DOMAIN` | *(vuoto)* | Dominio per il proxy (lascia vuoto = solo IP) |
| `MY_EMAIL` | *(vuoto)* | Email per Let's Encrypt / CloudPanel |
| `TLS_MODE` | `selfsigned` | Modalità cert: `selfsigned`, `letsencrypt`, `cloudpanel` |
| `TLS_CERT_DAYS` | `365` | Validità certificato self-signed (giorni) |

### Generazione certificati standalone

Se vuoi solo generare/rigenerare i certificati senza il wizard completo:

```bash
make generate-certs
```

Comportamento per modalità:

- **selfsigned**: genera RSA 4096-bit con SAN (hostname, IP pubblica, dominio se configurato). Rileva scadenza e rigenera se < 7 giorni.
- **letsencrypt**: `certbot certonly --standalone`, copia cert in `./ssl-certificates/`, installa cron rinnovo automatico.
- **cloudpanel**: copia da `/etc/nginx/ssl-certificates/<dominio>.*`, fallback a self-signed se non trovati, installa cron sync giornaliero.

## Config Privoxy richiesto (e customizzazione via env)

La config richiesta viene generata da script in forma equivalente:

- `listen-address 127.0.0.1:8118`
- `forward-socks5t / 127.0.0.1:9050 .`
- `socket-timeout 300`
- `forwarded-connect-retries 1`
- `max-client-connections 1024`
- `keep-alive-timeout 5`
- `tolerate-pipelining 1`

Variabili `.env` relative:

- `PRIVOXY_LISTEN_IP`, `PRIVOXY_LISTEN_PORT`
- `TOR_SOCKS_HOST`, `TOR_SOCKS_PORT`
- `PRIVOXY_SOCKET_TIMEOUT`
- `PRIVOXY_FORWARDED_CONNECT_RETRIES`
- `PRIVOXY_MAX_CLIENT_CONNECTIONS`
- `PRIVOXY_KEEP_ALIVE_TIMEOUT`
- `PRIVOXY_TOLERATE_PIPELINING`

Differenze sostanziali tra i parametri:

- `listen-address`: dove Privoxy accetta connessioni; `127.0.0.1` limita accesso locale e riduce superficie di attacco.
- `forward-socks5t`: instrada tutto verso Tor SOCKS5, quindi nessun egress diretto lato Privoxy.
- `socket-timeout`: timeout I/O verso upstream; troppo basso produce errori su circuiti Tor lenti, troppo alto aumenta connessioni bloccate.
- `forwarded-connect-retries`: tentativi su CONNECT; alzarlo migliora resilienza ma aumenta latenza in error path.
- `max-client-connections`: massime sessioni concorrenti; più alto = più throughput ma più memoria/FD consumati.
- `keep-alive-timeout`: durata riuso connessioni client; alto riduce handshake, basso riduce risorse occupate.
- `tolerate-pipelining`: migliora compatibilità client legacy con richieste multiple su stessa connessione.

Nota: nello snippet originale comparivano due `keep-alive-timeout` (300 e 5). La direttiva è unica; il valore finale effettivo è l'ultimo. Qui è parametrizzata con default `5` per ridurre occupazione connessioni.

## Config Tor (anti-ads, anti-profiling, privacy avanzata)

Il file `tor/torrc` implementa una configurazione orientata alla massima privacy e alla riduzione dell'esposizione pubblicitaria:

### Entry Guards

- `UseEntryGuards 1`, `NumEntryGuards 2`: usa solo 2 guard node persistenti. Riduce la superficie di attacco (meno nodi conoscono il client) ma aumenta il rischio se uno dei 2 è compromesso.

### Exit Policy — Anti Ads

- `ExitNodes {de},{it},{ad},{mc},{al},{mm},{mv},{vn},{uz}`: forza exit solo da paesi con basso CPM (Cost Per Mille), forte enforcement GDPR, e scarso interesse per advertiser premium.
- `ExcludeNodes {ch},{us},{gb},{au},{ca},{fr},{nl},{be},{ie},{se},{no},{dk},{fi},{jp},{kr},{cn},{ru}`: esclude anglosfera, mercati ad-premium, e stati con sorveglianza nota.
- `StrictNodes 1`: forza uso esclusivo della lista sopra. Senza questo flag, Tor potrebbe usare nodi esclusi come fallback.

Variabili in `.env`:

| Variabile | Default | Effetto |
|---|---|---|
| `TOR_EXIT_NODES` | `{de},{it},{ad},...` | Lista exit node consentiti (codici paese ISO) |
| `TOR_EXCLUDE_NODES` | `{ch},{us},{gb},...` | Lista nodi esclusi |
| `TOR_STRICT_NODES` | `1` | `1` = enforce rigido, `0` = fallback consentito |

### Circuit Lifetime (Anti Profiling)

- `NewCircuitPeriod 300`: nuovo circuito ogni 5 minuti (default Tor: 30s). Riduce la frequenza di switch per evitare pattern temporali.
- `MaxCircuitDirtiness 1800`: un circuito può essere riusato per 30 minuti (default: 10 min). Riduce cambio IP frequente che può triggerare captcha.
- `CircuitBuildTimeout 30`: timeout per costruire un circuito (30 secondi). Troppo basso = circuiti falliti; troppo alto = latenza iniziale.
- `MaxClientCircuitsPending 100`: massimo 100 circuiti in costruzione simultanea.

### Connection Padding (Anti Traffic Analysis)

- `ConnectionPadding 1`: abilita padding sulle connessioni tra relay. Rende difficile correlare traffico reale per volume/timing.
- `ReducedConnectionPadding 0`: non ridurre il padding (massima protezione). Aumenta overhead banda ~5-10%.

### SOCKS Isolation

- `IsolateDestAddr`: circuito separato per ogni IP di destinazione.
- `IsolateDestPort`: circuito separato per ogni porta di destinazione.
- `IsolateSOCKSAuth`: circuito separato per ogni credenziale SOCKS.

Questo significa: due richieste allo stesso sito sulla stessa porta dello stesso utente condividono il circuito; qualsiasi variazione crea un circuito nuovo. Massimo isolamento a costo di più circuiti attivi.

### Topology / OPSEC

- `EnforceDistinctSubnets 1`: ogni hop del circuito deve essere su una subnet diversa (/16). Riduce il rischio che un singolo operatore controlli più nodi del circuito.

### Logging

I log Tor sono persistiti nel volume Docker `tor_logs`:

- `notices.log`: bootstrap, eventi circuito, warning
- `info.log`: dettaglio connessioni, guard selection, padding events

Consulta con: `make logs-tor`

## Porte necessarie (dettaglio operativo)

- `MITMPROXY_BIND_PORT` (default `8080/tcp`): porta ingresso client autenticati.
	- Da aprire ai client autorizzati.
- `UNBOUND_DNS_PORT` (default `5353/tcp+udp`): DNS locale validato DNSSEC.
	- Se vuoi sostituire DNS host/LAN puoi usare `53`, ma verifica conflitti con `systemd-resolved`.
- `UNBOUND_DOT_PORT` (default `853/tcp`): DNS-over-TLS (DoT).
	- Richiede certificati montati in `UNBOUND_TLS_CERTS_DIR` con i file usati da `unbound.conf`.
- `PRIVOXY_BIND_PORT` (default `8118/tcp`): porta forward proxy intermedio.
	- Consigliato bind su loopback (`127.0.0.1`) e non esporla pubblicamente.
- `TOR_SOCKS_PORT` (default `9050/tcp`): SOCKS interno usato da Privoxy.
	- Non esporre all'esterno; deve restare interno alla chain.

Regola pratica firewall:

- Esporre pubblicamente solo la porta proxy ingresso (`8080`) e, se necessario, DNS (`53/udp+tcp`) + DoT (`853/tcp`).
- Bloccare accesso esterno a `8118`, `9050`.

## Modello di autenticazione

Implementazione nel layer `mitmproxy` (`app/gatekeeper.py`):

- Modalità `basic` o `token` configurata con `AUTH_MODE`.
- Credenziali lette da `USERS_FILE` (`app/users.yaml`).
- Basic auth: confronto hash SHA-256 password (`password_sha256`).
- Token auth: confronto constant-time (`hmac.compare_digest`).
- Risposta `407 Proxy Authentication Required` se non autorizzato.
- Logging auth separato in `AUTH_LOG_FILE`.

Formato `users.yaml`:

```yaml
users:
  alice:
	 password_sha256: "<sha256_password>"
	 token: "<token_random_lungo>"
```

## Rate limiting per utente

Gestito in `gatekeeper.py`:

- Finestra temporale: `RATE_LIMIT_WINDOW_SEC`
- Limite richieste per utente: `RATE_LIMIT_RPM`
- Se superato: risposta `429 Rate limit exceeded`

## Logging separato

- Auth log: `logs/auth.log`
  - evento login consentito/negato, utente, ip client, motivo
- Traffic log: `logs/traffic.log`
  - utente, metodo, host, path, status, bytes
- Tor log (notice): `/var/log/tor/notices.log` (dentro container, volume `tor_logs`)
  - bootstrap, circuit events, warning, errori relay
- Tor log (info): `/var/log/tor/info.log` (dentro container, volume `tor_logs`)
  - dettaglio connessioni, guard selection, padding events

## Sicurezza e hardening

Già applicato:

- Container non-root per `mitmproxy`.
- `no-new-privileges` e `cap_drop` sui servizi proxy/tor/privoxy.
- Tor con isolamento forte (`IsolateDestAddr`, `IsolateDestPort`, `IsolateSOCKSAuth`).
- Tor exit policy anti-ads: solo paesi a basso CPM / GDPR forte (`ExitNodes`), esclusione anglosfera e mercati ad-premium (`ExcludeNodes`, `StrictNodes 1`).
- Tor connection padding attivo (`ConnectionPadding 1`, `ReducedConnectionPadding 0`) – anti traffic analysis.
- Tor entry guards hardened (`UseEntryGuards 1`, `NumEntryGuards 2`).
- Tor circuit anti-profiling (`MaxCircuitDirtiness 1800`, `NewCircuitPeriod 300`, `CircuitBuildTimeout 30`).
- Tor topology protection (`EnforceDistinctSubnets 1`).
- Unbound con DNSSEC validation (`validator iterator`) + blacklist locale.
- Blacklist aggiornabile da feed esterno via job script (`cron/update_blacklist.sh`).

Hardening raccomandato host Ubuntu/Debian:

- Firewall deny-by-default (`ufw`/`nftables`), consentire solo ingress necessari.
- Egress filtering: i container client non devono uscire direttamente su WAN.
- Segregazione rete Docker dedicata e nessuna porta pubblica non necessaria.
- Rotazione segreti/token periodica e audit accessi.
- Backup cifrato dei file `app/users.yaml` e policy.

## Rischi e trade-off

- Latenza: chain multi-hop (`mitmproxy -> privoxy -> tor`) aumenta RTT; exit policy restrittiva può rallentare ulteriormente per carenza di relay nei paesi selezionati.
- Exit nodes limitati: `StrictNodes 1` con pochi paesi riduce pool relay disponibili; se i relay selezionati sono saturi o down, connessioni possono fallire.
- Connection padding: migliora privacy anti traffic-analysis ma aumenta banda consumata (~5-10% overhead).
- Fingerprinting: anche con Tor + padding, pattern TLS/HTTP possono identificare client/applicazione.
- MITM implications: intercettare traffico HTTPS richiede CA trust sul client e ha impatti compliance/privacy.
- Privoxy auth: non è un auth gateway enterprise-grade; auth obbligatoria è sul layer ingress `mitmproxy`.
- Stream isolation: `IsolateDestAddr + IsolateDestPort + IsolateSOCKSAuth` crea circuiti separati per ogni destinazione/porta/utente; questo migliora l'isolamento ma riduce il riuso dei circuiti.

## Failure points principali

- `app/users.yaml` mancante/malformato -> autenticazione impossibile.
- `blacklist.conf` corrotto -> startup/funzionamento Unbound degradato.
- Tor non raggiungibile -> proxy attivo ma nessun egress anonimo.
- Misconfigurazione firewall -> possibili bypass o leak DNS/egress.

## Miglioramenti consigliati

- Sostituire SHA-256 password con Argon2id/bcrypt.
- Aggiungere storage credenziali su vault (es. HashiCorp Vault / SOPS).
- Implementare metriche Prometheus + alerting (5xx, 407 burst, 429 burst).
- Aggiungere CI/CD con test config (`docker compose config`, lint, smoke auth).
- Introdurre mTLS per accesso proxy in ambienti enterprise.

## Target Makefile

### Setup e deploy
- `make setup-vps`: setup completo VPS Debian 12 (root richiesto)
- `make setup-domain`: wizard guidato configurazione dominio + HTTPS
- `make generate-certs`: genera/rigenera certificati TLS
- `make init`: bootstrap rapido (privoxy config + certs + compose up + systemd + cron)

### Operazioni
- `make build`: build immagini
- `make up`: avvio stack
- `make down`: stop stack
- `make logs`: log di tutti i servizi
- `make logs-auth`: tail auth log
- `make logs-traffic`: tail traffic log
- `make logs-tor`: tail Tor notice log (dal container)
- `make update-blacklist`: rigenera blacklist DNS

### Sviluppo
- `make lint`: lint Python
- `make test`: test Python
- `make smoke`: controllo versione mitmproxy
- `make verify`: lint + smoke + validazione compose