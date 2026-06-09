FROM debian:12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends unbound ca-certificates dns-root-data \
    && rm -rf /var/lib/apt/lists/*

CMD ["unbound", "-d", "-c", "/etc/unbound/unbound.conf"]
