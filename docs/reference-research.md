# Reference Research

Date: 2026-05-28

This document records projects studied for architecture, deployment, licensing, crypto, realtime sync, mobile, and self-hosting ideas. No source code was copied.

| Project | URL | License | Compatible with AGPL-3.0-or-later? | Stack / Deployment | What to Learn | What Not to Copy | Fork? |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Signal / libsignal | https://github.com/signalapp/libsignal | AGPL-3.0 | Yes, with AGPL obligations | Rust core with Java/Swift/TS bindings | Production-grade Signal Protocol, device model, safety-number style verification | Signal service assumptions, branding, large app code | No |
| OpenMLS | https://github.com/openmls/openmls | MIT | Yes, preserve notices | Rust MLS library | MLS group messaging, key package model, supported mobile targets | Do not invent missing protocol semantics | No |
| Matrix / Element Synapse | https://github.com/element-hq/synapse | AGPL-3.0 or commercial | Yes under AGPL | Python/Twisted + Rust; multi-process at scale | Federated sync, event timeline design, E2EE constraints, media auth | Federation complexity, operational weight | No |
| Matrix legacy Synapse | https://github.com/matrix-org/synapse | Apache-2.0 for older Matrix.org repo | Yes | Python/Twisted | Older docs and schema ideas | Outdated maintenance state | No |
| SimpleX Chat | https://github.com/simplex-chat/simplex-chat | AGPL-3.0 | Yes, with AGPL obligations | Haskell core; mobile clients | Metadata-minimization, no phone-number identity, queue/server separation | Complex network model for this MVP | No |
| Mattermost | https://github.com/mattermost/mattermost | Mixed; server source AGPL-family per Mattermost docs | Possibly, but complex | Go + React; self-hosted team collaboration | Modular monolith lessons, permissions, operational docs | Open-core licensing complexity, Slack-first product shape | No |
| Zulip | https://github.com/zulip/zulip | Apache-2.0 | Yes | Python/Django + TS; PostgreSQL | Thread/topic UX, tests, docs quality | Enterprise/team-chat-first mental model | No |
| Rocket.Chat | https://github.com/RocketChat/Rocket.Chat | MIT for community source outside EE directories | Yes, preserve notices | TypeScript/Meteor; MongoDB | Realtime API and self-hosted admin lessons | MongoDB requirement, large workspace model | No |
| Stoat/Revolt | https://github.com/stoatchat/stoatchat | Not evaluated for reuse | N/A; no code reused | Rust services plus self-host compose | Discord-like communities and deployment examples | Discord-first scope and prior security issues | No |
| PocketBase | https://github.com/pocketbase/pocketbase | MIT | Yes, preserve notices | Go single binary, SQLite, realtime | Single executable setup, embedded DB, admin UX | Generic backend framework as app core | No |
| Pion WebRTC | https://github.com/pion/webrtc | MIT | Yes, preserve notices | Go WebRTC library | Self-hosted WebRTC primitives, signaling integration | Building full SFU too early | No |
| LiveKit | https://github.com/livekit/livekit | Apache-2.0 | Yes, preserve notices | Go SFU, Docker/single binary/Kubernetes | Production call architecture and Flutter SDK | Mandatory external media service in v1 | No |
| Caddy | https://github.com/caddyserver/caddy | Apache-2.0 | Yes, preserve notices | Go reverse proxy with automatic HTTPS | Simple HTTPS docs and reverse-proxy defaults | Embedding Caddy before needed | No |
| UnifiedPush | https://github.com/UnifiedPush | Mixed; many Apache-2.0/MIT/LGPL components | Depends per component | Android push specs and connectors | User-choice push model for Android | LGPL components without review | No |
| ntfy | https://github.com/binwiederhier/ntfy | Apache-2.0 / GPL-2.0 dual | Use Apache-2.0 option where applicable | Go server, mobile apps | Optional self-hosted notification patterns | Message content in notifications | No |
| MiroTalk | https://github.com/miroslavpejic85/mirotalk | AGPL-3.0 | Yes, with AGPL obligations | Node/WebRTC | Small self-hosted call UX and deployment references | Copying UI/media code | No |

## Conclusion

Build an original project. Forking would import product direction, operational complexity, licensing obligations, and code volume that do not match the mobile-first, E2EE-everywhere, simple self-hosting goal.
