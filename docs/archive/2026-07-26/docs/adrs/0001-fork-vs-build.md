# ADR 0001: Build Original Project

## Status

Accepted.

## Decision

Build an original AGPL-3.0-or-later project instead of forking Signal, Matrix, SimpleX, Mattermost, Rocket.Chat, Stoat/Revolt, or another messenger.

## Rationale

Forking would bring product shape, scale assumptions, licensing complexity, and code volume that conflict with the desired simple, mobile-first, self-hostable messenger. The project should study reference systems but keep its own small modular monolith and E2EE boundaries.

