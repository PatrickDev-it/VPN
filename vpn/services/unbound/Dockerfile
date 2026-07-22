FROM debian:12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends unbound ca-certificates dns-root-data \
    && install -d -o unbound -g unbound /var/lib/unbound \
    && install -o unbound -g unbound -m 0644 /usr/share/dns/root.key /var/lib/unbound/root.key \
    && rm -rf /var/lib/apt/lists/*

CMD ["unbound", "-d", "-c", "/etc/unbound/unbound.conf"]
