FROM golang:1.25 AS build

WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/messenger-server ./cmd/messenger-server
RUN mkdir -p /out/data && chown 65532:65532 /out/data

FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /app
COPY --from=build /out/messenger-server /usr/local/bin/messenger-server
COPY --from=build --chown=65532:65532 /out/data /data
VOLUME ["/data"]
ENV PRIVATE_MESSENGER_ADDR=:8080
ENV PRIVATE_MESSENGER_DATA_DIR=/data
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/messenger-server"]
CMD ["serve"]
