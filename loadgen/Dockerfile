FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/cdc-load ./main.go

FROM scratch
COPY --from=build /out/cdc-load /usr/local/bin/cdc-load
ENTRYPOINT ["/usr/local/bin/cdc-load"]
