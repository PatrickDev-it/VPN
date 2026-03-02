FROM debian:12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends tor ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/lib/tor && chown -R debian-tor:debian-tor /var/lib/tor

CMD ["tor", "-f", "/etc/tor/torrc"]
