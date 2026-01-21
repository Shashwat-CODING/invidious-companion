# syntax=docker/dockerfile:1

############################
# Builder (Deno)
############################
FROM denoland/deno:alpine-2.6.5 AS builder

ENV DENO_DIR=/deno-dir \
    DENO_V8_FLAGS="--max-old-space-size=128"

WORKDIR /app

# Copy config first for better cache
COPY deno.json deno.lock ./

# Cache deps
RUN deno cache src/main.ts || true

# Copy source
COPY src ./src

# Compile to single binary
RUN deno compile \
    --allow-net \
    --allow-env \
    --allow-read \
    --allow-write \
    --no-check \
    --output invidious_companion \
    src/main.ts


############################
# Runtime (distroless)
############################
FROM gcr.io/distroless/cc

ENV HOST=0.0.0.0 \
    PORT=8282 \
    SERVER_BASE_PATH=/companion \
    YT_DISABLE_CACHE=1 \
    DENO_V8_FLAGS="--max-old-space-size=96"

WORKDIR /app

# Non-root
USER nonroot:nonroot

COPY --from=builder /app/invidious_companion /app/invidious_companion
COPY config ./config

EXPOSE 8282

ENTRYPOINT ["/app/invidious_companion"]
