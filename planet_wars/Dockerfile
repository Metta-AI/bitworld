# Build Docker.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/bitworld
COPY nimby.lock .
RUN nimby --global sync nimby.lock && \
  cat nim.cfg >> /root/.nimby/nim/config/nim.cfg

COPY . .
WORKDIR /workspace/bitworld/planet_wars
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
ARG NimCommand="c"
ARG NimMain="planet_wars.nim"
RUN nim $NimCommand \
  $NimFlags \
  --nimcache:/tmp/bitworld-nimcache \
  --out:planet_wars \
  $NimMain

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/bitworld
COPY --from=build \
  /workspace/bitworld/planet_wars/planet_wars \
  /bin/planet_wars
COPY --from=build /workspace/bitworld/planet_wars/*.json ./planet_wars/
COPY --from=build /workspace/bitworld/among_them/tiny5.aseprite ./planet_wars/
COPY --from=build /workspace/bitworld/client/*.html ./client/
COPY --from=build /workspace/bitworld/client/*.js ./client/
COPY --from=build /workspace/bitworld/client/data ./client/data

WORKDIR /workspace/bitworld/planet_wars
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=2s --start-period=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1
CMD ["/bin/planet_wars", "--address:0.0.0.0", "--port:8080"]
