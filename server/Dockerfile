ARG GO_VERSION=1.25.13
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}@sha256:cbff9d1a9041b316010f2da6b701b6c0d597718cb90928c85eb597334a0d23d4 AS build

ARG GO_VERSION
ARG VERSION=dev
ARG COMMIT=unknown
ARG TARGETOS=linux
ARG TARGETARCH=amd64

WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN test "$(go env GOVERSION)" = "go${GO_VERSION}"
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -buildvcs=false -ldflags="-buildid= -X main.version=${VERSION} -X main.commit=${COMMIT}" -o /out/messenger-server ./cmd/messenger-server
RUN mkdir -p /out/data && chown 65532:65532 /out/data

FROM scratch

ARG GO_VERSION
ARG COMMIT=unknown
LABEL org.veritra.go-toolchain="${GO_VERSION}" \
      org.opencontainers.image.revision="${COMMIT}"
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
