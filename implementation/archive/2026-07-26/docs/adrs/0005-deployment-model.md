# ADR 0005: Single Binary First

## Status

Accepted.

## Decision

The primary deployment path is one server executable with local SQLite and local encrypted blob storage. Docker Compose and Caddy examples are secondary. Kubernetes is not a v1 goal.

## Rationale

The target self-hoster should be able to download, run, open setup, create an owner account, and invite users without operating multiple required services.

