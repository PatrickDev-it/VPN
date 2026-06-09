FROM debian:12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends privoxy ca-certificates \
    && rm -rf /var/lib/apt/lists/*

CMD ["privoxy", "--no-daemon", "/etc/privoxy/config"]
