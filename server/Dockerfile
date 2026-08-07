FROM --platform=$BUILDPLATFORM golang:1.26.4@sha256:f96cc555eb8db430159a3aa6797cd5bae561945b7b0fe7d0e284c63a3b291609 AS build

ARG VERSION=dev
ARG COMMIT=unknown
ARG TARGETOS=linux
ARG TARGETARCH=amd64

WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -buildvcs=false -ldflags="-buildid= -X main.version=${VERSION} -X main.commit=${COMMIT}" -o /out/messenger-server ./cmd/messenger-server
RUN mkdir -p /out/data && chown 65532:65532 /out/data

FROM scratch

WORKDIR /app
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/messenger-server /usr/local/bin/messenger-server
COPY --from=build --chown=65532:65532 /out/data /data
VOLUME ["/data"]
ENV PRIVATE_MESSENGER_ADDR=:8080
ENV PRIVATE_MESSENGER_DATA_DIR=/data
EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/messenger-server"]
CMD ["serve"]
