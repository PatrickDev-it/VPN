FROM python:3.12-slim

ARG PIP_VERSION=26.1.2

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
	&& apt-get install -y --no-install-recommends curl \
	&& rm -rf /var/lib/apt/lists/*

COPY requirements.txt requirements-security-overrides.txt ./
RUN python -m pip install --no-cache-dir --upgrade "pip==${PIP_VERSION}" \
	&& pip install --no-cache-dir -r requirements.txt \
	&& pip install --no-cache-dir --no-deps --upgrade -r requirements-security-overrides.txt

COPY . .

RUN useradd --create-home --shell /usr/sbin/nologin appuser \
	&& chown -R appuser:appuser /app

USER appuser
CMD ["mitmdump", "-s", "app/gatekeeper.py"]
