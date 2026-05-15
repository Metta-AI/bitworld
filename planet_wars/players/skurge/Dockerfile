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
WORKDIR /workspace/bitworld/planet_wars/players/skurge
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
ARG NimCommand="c"
ARG NimMain="skurge.nim"
RUN nim $NimCommand \
  $NimFlags \
  --nimcache:/tmp/bitworld-nimcache \
  --out:skurge \
  $NimMain

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/bitworld
COPY --from=build \
  /workspace/bitworld/planet_wars/players/skurge/skurge \
  /bin/skurge

WORKDIR /workspace/bitworld/planet_wars/players/skurge
CMD ["/bin/skurge", "--address:host.docker.internal", "--port:8080"]
