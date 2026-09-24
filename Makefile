.PHONY: build test lint dev server-test mobile-test

# The default goal only compiles the server. CodeQL's Go autobuild runs a bare
# `make`; running the full suite there starts Docker containers that leave
# root-owned Flutter files in the checkout and fail the scan.
build:
	cd server && go build ./...

test:
	./scripts/test.sh

lint:
	./scripts/lint.sh

dev:
	./scripts/dev.sh

server-test:
	cd server && go test ./...

mobile-test:
	cd mobile && flutter test
