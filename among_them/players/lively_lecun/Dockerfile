FROM golang:1.24-bookworm AS build

WORKDIR /workspace/bitworld/among_them/players/lively_lecun
COPY among_them/players/lively_lecun/go.mod .
COPY among_them/players/lively_lecun/go.sum .
RUN go mod download

COPY among_them/players/lively_lecun .
RUN CGO_ENABLED=0 go build \
  -trimpath \
  -ldflags="-s -w" \
  -o /out/lively_lecun .

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/lively_lecun /bin/lively_lecun

USER nonroot:nonroot
CMD ["/bin/lively_lecun"]
