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
WORKDIR /workspace/bitworld/fancy_cookout
RUN nim c \
  -d:release \
  --nimcache:/tmp/bitworld-nimcache \
  --out:fancy_cookout \
  fancy_cookout.nim

# Run Docker.
FROM alpine

WORKDIR /workspace/bitworld
COPY --from=build \
  /workspace/bitworld/fancy_cookout/fancy_cookout \
  /bin/fancy_cookout
COPY --from=build /workspace/bitworld/fancy_cookout/data ./fancy_cookout/data
COPY --from=build /workspace/bitworld/clients/*.html ./clients/
COPY --from=build /workspace/bitworld/clients/*.js ./clients/
COPY --from=build /workspace/bitworld/clients/data ./clients/data

WORKDIR /workspace/bitworld/fancy_cookout
CMD ["/bin/fancy_cookout", "--address:0.0.0.0", "--port:8080"]
