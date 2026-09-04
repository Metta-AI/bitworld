# Build Docker.
FROM alpine AS build

RUN apk add --no-cache build-base curl gcompat git

RUN if [ "$(apk --print-arch)" = "x86_64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(apk --print-arch)" = "aarch64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(apk --print-arch)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/bitworld
COPY nimby.lock .
RUN nimby --global sync nimby.lock && \
  cat nim.cfg >> /root/.nimby/nim/config/nim.cfg

COPY . .
WORKDIR /workspace/bitworld/party_progressor
RUN nim c \
  -d:release \
  --nimcache:/tmp/bitworld-nimcache \
  --out:party_progressor \
  party_progressor.nim

# Run Docker.
FROM alpine

WORKDIR /workspace/bitworld
COPY --from=build \
  /workspace/bitworld/party_progressor/party_progressor \
  /bin/party_progressor
COPY --from=build /workspace/bitworld/party_progressor/data ./party_progressor/data
COPY --from=build /workspace/bitworld/client/*.html ./client/
COPY --from=build /workspace/bitworld/client/*.js ./client/
COPY --from=build /workspace/bitworld/client/data ./client/data

WORKDIR /workspace/bitworld/party_progressor
CMD ["/bin/party_progressor", "--address:0.0.0.0", "--port:8080"]
