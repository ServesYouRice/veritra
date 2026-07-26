# ADR 0003: SQLite First

## Status

Accepted.

## Decision

Use SQLite as the default database for v1, with repository interfaces that do not prevent a future PostgreSQL adapter.

## Rationale

SQLite fits the 2-25 user target, supports cheap self-hosting, keeps the single-binary deployment simple, and can scale far enough for the MVP if writes are kept modest.

