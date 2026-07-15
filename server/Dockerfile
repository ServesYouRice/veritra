FROM --platform=$BUILDPLATFORM golang:1.25@sha256:c138bff780910acf4254ab3a6f7ff0f64bbd841f27bd82bfa986fe122c109538 AS build

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
