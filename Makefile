.PHONY: install init build up down logs logs-auth logs-traffic logs-tor test lint update-blacklist verify smoke setup-vps setup-domain generate-certs deploy

VPN_DIR := vpn

# ---------------------------------------------------------------------------
# One-liner install (curl-pipe entry point)
# ---------------------------------------------------------------------------
install:
	sudo bash $(VPN_DIR)/install.sh

# ---------------------------------------------------------------------------
# VPN stack lifecycle
# ---------------------------------------------------------------------------
init:
	bash $(VPN_DIR)/init/bootstrap.sh

setup-vps:
	sudo bash $(VPN_DIR)/init/setup-vps.sh

setup-domain:
	bash $(VPN_DIR)/init/setup-domain.sh

generate-certs:
	bash $(VPN_DIR)/init/generate-certs.sh

build:
	docker compose -f $(VPN_DIR)/docker-compose.yml build

up:
	docker compose -f $(VPN_DIR)/docker-compose.yml up -d

down:
	docker compose -f $(VPN_DIR)/docker-compose.yml down

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
logs:
	docker compose -f $(VPN_DIR)/docker-compose.yml logs -f mitmproxy privoxy tor unbound

logs-auth:
	tail -f $(VPN_DIR)/logs/auth.log

logs-traffic:
	tail -f $(VPN_DIR)/logs/traffic.log

logs-tor:
	docker compose -f $(VPN_DIR)/docker-compose.yml exec tor tail -f /var/log/tor/notices.log

# ---------------------------------------------------------------------------
# Quality
# ---------------------------------------------------------------------------
test:
	docker compose -f $(VPN_DIR)/docker-compose.yml run --rm --no-deps mitmproxy \
	  sh -lc "python -m pip install --user --no-cache-dir -r requirements-dev.txt && python -m pytest"

lint:
	docker compose -f $(VPN_DIR)/docker-compose.yml run --rm --no-deps mitmproxy \
	  sh -lc "python -m pip install --user --no-cache-dir -r requirements-dev.txt && python -m ruff check ."

update-blacklist:
	docker compose -f $(VPN_DIR)/docker-compose.yml run --rm --no-deps mitmproxy \
	  bash cron/update_blacklist.sh

smoke:
	docker compose -f $(VPN_DIR)/docker-compose.yml run --rm --no-deps mitmproxy mitmdump --version

verify: lint smoke
	docker compose -f $(VPN_DIR)/docker-compose.yml config -q

# ---------------------------------------------------------------------------
# Multi-cloud deploy
# ---------------------------------------------------------------------------
deploy:
	@bash deploy/deploy.sh $(filter-out $@,$(MAKECMDGOALS))

%:
	@:
