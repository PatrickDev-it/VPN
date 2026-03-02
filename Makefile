.PHONY: init build up down logs logs-auth logs-traffic logs-tor test lint update-blacklist verify smoke setup-vps setup-domain generate-certs

init:
	bash init/bootstrap.sh

setup-vps:
	sudo bash init/setup-vps.sh

setup-domain:
	bash init/setup-domain.sh

generate-certs:
	bash init/generate-certs.sh

build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f mitmproxy privoxy tor unbound

logs-auth:
	tail -f logs/auth.log

logs-traffic:
	tail -f logs/traffic.log

logs-tor:
	docker compose exec tor tail -f /var/log/tor/notices.log

test:
	docker compose run --rm --no-deps mitmproxy sh -lc "python -m pip install --user --no-cache-dir -r requirements-dev.txt && python -m pytest"

lint:
	docker compose run --rm --no-deps mitmproxy sh -lc "python -m pip install --user --no-cache-dir -r requirements-dev.txt && python -m ruff check ."

update-blacklist:
	docker compose run --rm --no-deps mitmproxy bash cron/update_blacklist.sh

smoke:
	docker compose run --rm --no-deps mitmproxy mitmdump --version

verify: lint smoke
	docker compose config -q