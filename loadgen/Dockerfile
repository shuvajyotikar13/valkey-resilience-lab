FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod main.go ./
# The source archive intentionally does not require a host Go installation.
# Resolve the complete module graph inside the build container, generate the
# checksum data, and then compile without allowing further module changes.
RUN go mod tidy \
    && CGO_ENABLED=0 GOOS=linux go build -mod=readonly -trimpath \
       -ldflags="-s -w" -o /out/cdc-load ./main.go

FROM scratch
COPY --from=build /out/cdc-load /usr/local/bin/cdc-load
ENTRYPOINT ["/usr/local/bin/cdc-load"]
