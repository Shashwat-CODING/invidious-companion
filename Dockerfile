# syntax=docker/dockerfile:1

ARG THC_VERSION='0.39.0' \
    TINI_VERSION='0.19.0'

ARG DENO_DIR='/deno-dir' \
    GH_BASE_URL='https://github.com' \
    THC_PORT_NAME='PORT' \
    HOST='0.0.0.0' \
    PORT='8282'

ARG THC_AMD64_SHA256='cb1797948015da46c222764a99ee30c06a6a9a30f5b87f212a28ea3c6d07610d' \
    THC_ARM64_SHA256='c177033fd474af673bd64788d47e13708844f3946e1eb51cce6a422a23a5e8cc' \
    TINI_AMD64_SHA256='93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c' \
    TINI_ARM64_SHA256='07952557df20bfd2a95f9bef198b445e006171969499a1d361bd9e6f8e5e0e81'

FROM alpine:3.23 AS dependabot-alpine
FROM debian:13-slim AS dependabot-debian
FROM denoland/deno:bin-2.6.4 AS deno-bin

FROM dependabot-alpine AS user-stage
RUN adduser -u 10001 -S appuser

FROM dependabot-debian AS debian-curl
RUN DEBIAN_FRONTEND='noninteractive' && export DEBIAN_FRONTEND && \
    apt-get update && apt-get install -y curl xz-utils

FROM debian-curl AS thc-download
ARG GH_BASE_URL THC_VERSION THC_AMD64_SHA256 THC_ARM64_SHA256 CHECK_CHECKSUMS
RUN arch="$(uname -m)" && \
    gh_url() { printf -- "${GH_BASE_URL}/%s/releases/download/%s/%s\n" "$@" ; } && \
    URL="$(gh_url dmikusa/tiny-health-checker v${THC_VERSION} tiny-health-checker-${arch}-unknown-linux-musl.tar.xz)" && \
    curl -fsSL --output /tiny-health-checker-${arch}-unknown-linux-musl.tar.xz "${URL}" && \
    if [ "${CHECK_CHECKSUMS}" = "1" ] ; then \
        echo "Checking THC binary sha256 checksum" && \
        if [ "$arch" = "aarch64" ]; then \
            echo "${THC_ARM64_SHA256}  /tiny-health-checker-${arch}-unknown-linux-musl.tar.xz" | sha256sum -c; \
        else \
            echo "${THC_AMD64_SHA256}  /tiny-health-checker-${arch}-unknown-linux-musl.tar.xz" | sha256sum -c; \
        fi \
    fi && \
    tar -xvf /tiny-health-checker-${arch}-unknown-linux-musl.tar.xz && \
    mv /tiny-health-checker-${arch}-unknown-linux-musl/thc /thc && \
    chmod -v 00555 /thc

FROM scratch AS thc-bin
ARG THC_VERSION
ENV THC_VERSION="${THC_VERSION}"
COPY --from=thc-download /thc /thc

FROM debian-curl AS tini-download
ARG GH_BASE_URL TINI_VERSION TINI_AMD64_SHA256 TINI_ARM64_SHA256 CHECK_CHECKSUMS
RUN arch="$(dpkg --print-architecture)" && \
    gh_url() { printf -- "${GH_BASE_URL}/%s/releases/download/%s/%s\n" "$@" ; } && \
    URL="$(gh_url krallin/tini v${TINI_VERSION} tini-${arch})" && \
    curl -fsSL --output /tini "${URL}" && \
    if [ "${CHECK_CHECKSUMS}" = "1" ] ; then \
        echo "Checking TINI binary sha256 checksum" && \
        if [ "$arch" = "arm64" ]; then \
            echo "${TINI_ARM64_SHA256}  /tini" | sha256sum -c; \
        else \
            echo "${TINI_AMD64_SHA256}  /tini" | sha256sum -c; \
        fi \
    fi && \
    chmod -v 00555 /tini

FROM scratch AS tini-bin
ARG TINI_VERSION
ENV TINI_VERSION="${TINI_VERSION}"
COPY --from=tini-download /tini /tini

FROM dependabot-debian AS debian-git
RUN DEBIAN_FRONTEND='noninteractive' && export DEBIAN_FRONTEND && \
    apt-get update && apt-get install -y git

FROM debian-git AS debian-deno
RUN mkdir -v -p /var/tmp/youtubei.js
ARG DENO_DIR
RUN useradd --uid 1993 --user-group deno \
  && mkdir -v "${DENO_DIR}" \
  && chown deno:deno "${DENO_DIR}"

ENV DENO_DIR="${DENO_DIR}" \
    DENO_INSTALL_ROOT='/usr/local'

COPY --from=deno-bin /deno /usr/bin/deno

FROM debian-deno AS builder
WORKDIR /app
COPY deno.lock ./
COPY deno.json ./
COPY ./src/ ./src/

RUN --mount=type=bind,rw,source=.git,target=/app/.git \
    --mount=type=cache,target="${DENO_DIR}" \
    deno task compile

FROM debian:13-slim AS app
LABEL "language"="deno"
LABEL "framework"="hono"

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=user-stage /etc/group /etc/group
COPY --from=user-stage /etc/passwd /etc/passwd
COPY --from=thc-bin /thc /thc
COPY --from=tini-bin /tini /tini
COPY --from=builder --chown=appuser:nogroup /var/tmp/youtubei.js /var/tmp/youtubei.js

WORKDIR /app
COPY --from=builder /app/invidious_companion ./

ARG HOST PORT THC_VERSION THC_PORT_NAME TINI_VERSION
EXPOSE "${PORT}/tcp"

ENV SERVER_BASE_PATH=/companion \
    HOST="${HOST}" \
    PORT="${PORT}" \
    THC_PORT_NAME="${THC_PORT_NAME}" \
    THC_PATH="/healthz" \
    THC_VERSION="${THC_VERSION}" \
    TINI_VERSION="${TINI_VERSION}"

COPY ./config/ ./config/

USER appuser

ENTRYPOINT ["/tini", "--", "/app/invidious_companion"]

HEALTHCHECK --interval=5s --timeout=5s --start-period=10s --retries=5 CMD ["/thc"]
