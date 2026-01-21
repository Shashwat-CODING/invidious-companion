# syntax=docker/dockerfile:1

############################
# Base image: Deno (slim)
############################
FROM denoland/deno:alpine-2.6.4 AS builder

# Reduce memory usage during build
ENV DENO_DIR=/deno-dir \
    DENO_V8_FLAGS="--max-old-space-size=128"

WORKDIR /app

# Copy only dependency files first (better cache)
COPY deno.json deno.lock ./

# Cache deps
RUN deno cache --lock=deno.lock --lock-write src/main.ts || true

# Copy source
COPY src ./src

# Compile to single binary (VERY memory efficient at runtime)
RUN deno compile \
    --allow-net \
    --allow-env \
    --allow-read \
    --allow-write \
    --no-check \
    --output invidious_companion \
    src/main.ts


############################
# Runtime image (tiny)
############################
FROM gcr.io/distroless/cc

# Memory + GC limits at runtime
ENV DENO_V8_FLAGS="--max-old-space-size=96" \
    HOST=0.0.0.0 \
    PORT=8282 \
    SERVER_BASE_PATH=/companion \
    YT_DISABLE_CACHE=1

WORKDIR /app

# Non-root user (distroless compatible)
USER nonroot:nonroot

# Copy only the compiled binary
COPY --from=builder /app/invidious_companion /app/invidious_companion

EXPOSE 8282

ENTRYPOINT ["/app/invidious_companion"]
