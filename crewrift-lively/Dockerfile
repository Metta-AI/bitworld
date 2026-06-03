FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /app/crewrift-lively .

FROM alpine:3.20
COPY --from=builder /app/crewrift-lively /app/crewrift-lively
ENTRYPOINT ["/app/crewrift-lively"]
