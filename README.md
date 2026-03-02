# VPS - Proxy Anonimizzazione con Accesso Autenticato

Stack implementato:

- Unbound (resolver DNS locale con DNSSEC e blacklist)
- Privoxy (forward proxy verso Tor)
- Mitmproxy (policy engine, autenticazione, rate limit, traffic control)
- Tor (uscita anonima e rotazione circuiti)

## Architettura

Flusso operativo del progetto:

`Client -> Mitmproxy (auth + policy + rate limit) -> Privoxy -> Tor -> Exit Node -> Target`

Componenti:

- `unbound`: risoluzione DNS locale/validata (no DNS leak lato host/client che punta a questo resolver).
- `mitmproxy`: punto di ingresso del proxy autenticato e layer di controllo traffico.
- `privoxy`: forward proxy intermedio che inoltra su SOCKS5 Tor.
- `tor`: layer di anonimizzazione IP e rotazione circuiti.

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

## Deploy production (Ubuntu / Debian)

Prerequisiti host:

1. Installare Docker Engine + Docker Compose Plugin.
2. Aprire solo le porte necessarie (`8080/tcp` per proxy ingress, `53/tcp+udp` se vuoi esporre Unbound).
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
2. Avvia stack completo (`unbound`, `tor`, `privoxy`, `mitmproxy`).
3. Installa service `systemd` (`vps-proxy-stack.service`) per restart automatico al reboot.
4. Installa cron persistente per aggiornare blacklist (`BLACKLIST_CRON_SCHEDULE`).

Toggle persistenza in `.env`:

- `INSTALL_SYSTEMD=1|0`
- `INSTALL_CRON=1|0`

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

## Porte necessarie (dettaglio operativo)

- `MITMPROXY_BIND_PORT` (default `8080/tcp`): porta ingresso client autenticati.
	- Da aprire ai client autorizzati.
- `UNBOUND_DNS_PORT` (default `5353/tcp+udp`): DNS locale validato DNSSEC.
	- Se vuoi sostituire DNS host/LAN puoi usare `53`, ma verifica conflitti con `systemd-resolved`.
- `PRIVOXY_BIND_PORT` (default `8118/tcp`): porta forward proxy intermedio.
	- Consigliato bind su loopback (`127.0.0.1`) e non esporla pubblicamente.
- `TOR_SOCKS_PORT` (default `9050/tcp`): SOCKS interno usato da Privoxy.
	- Non esporre all'esterno; deve restare interno alla chain.
- `9051/tcp` (Tor ControlPort): controllo Tor.
	- Tenere interno/non esposto; utile solo per gestione locale.

Regola pratica firewall:

- Esporre pubblicamente solo la porta proxy ingresso (`8080`) e, se necessario, DNS (`53/udp+tcp` o `5353`).
- Bloccare accesso esterno a `8118`, `9050`, `9051`.

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

## Sicurezza e hardening

Già applicato:

- Container non-root per `mitmproxy`.
- `no-new-privileges` e `cap_drop` sui servizi proxy/tor/privoxy.
- Tor con `IsolateSOCKSAuth`, `IsolateClientAddr`, rotazione circuiti (`MaxCircuitDirtiness`, `NewCircuitPeriod`).
- Unbound con DNSSEC validation (`validator iterator`) + blacklist locale.
- Blacklist aggiornabile da feed esterno via job script (`cron/update_blacklist.sh`).

Hardening raccomandato host Ubuntu/Debian:

- Firewall deny-by-default (`ufw`/`nftables`), consentire solo ingress necessari.
- Egress filtering: i container client non devono uscire direttamente su WAN.
- Segregazione rete Docker dedicata e nessuna porta pubblica non necessaria.
- Rotazione segreti/token periodica e audit accessi.
- Backup cifrato dei file `app/users.yaml` e policy.

## Rischi e trade-off

- Latenza: chain multi-hop (`mitmproxy -> privoxy -> tor`) aumenta RTT.
- Fingerprinting: anche con Tor, pattern TLS/HTTP possono identificare client/applicazione.
- MITM implications: intercettare traffico HTTPS richiede CA trust sul client e ha impatti compliance/privacy.
- Privoxy auth: non è un auth gateway enterprise-grade; auth obbligatoria è sul layer ingress `mitmproxy`.
- Stream isolation: Tor isola stream a livello SOCKS/client, ma isolamento perfetto per-utente richiede governance rigorosa su credenziali e policy applicative.

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

- `make build`: build immagini
- `make up`: avvio stack
- `make down`: stop stack
- `make logs`: log di tutti i servizi
- `make logs-auth`: tail auth log
- `make logs-traffic`: tail traffic log
- `make update-blacklist`: rigenera blacklist DNS
- `make lint`: lint Python
- `make test`: test Python
- `make smoke`: controllo versione mitmproxy
- `make verify`: lint + smoke + validazione compose