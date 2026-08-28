FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/bank ./cmd/bank

FROM alpine:3.20
RUN apk add --no-cache ca-certificates wget
COPY --from=build /out/bank /usr/local/bin/bank
EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/bank"]
