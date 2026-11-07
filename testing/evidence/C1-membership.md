# C1 membership: evidence

2026-11-07, branch `agent/c1`. Design and rules: `docs/designs/C1-invite-format.md`.

## Server (run locally)

- `go test ./...` in `server/`: all packages pass.
- `go test -race ./internal/storage` (includes the new tests): passes.
- New tests: `server/internal/storage/membership_invite_test.go`,
  `server/internal/httpapi/membership_invite_handlers_test.go`.

What they exercise: group and community round trips (preview, request,
list, approve, roster with usernames); a pending request grants nothing;
repeated and opposite decisions; four concurrent approvals of one request
(one change, one use); use limit (the last use closes the other pending requests); revoked,
expired, used-up, unknown and malformed locators; creator demoted or deleted;
block in either direction; member limit at approval (rolled back, request
stays pending, use not counted); bounds (input, pending per account); dead requests (link used up, expired, creator demoted or deleted) are neither listed, counted against the caps, nor shown as waiting to the requester; a hand-added member's pending requests are cancelled;
outsider, plain member and requester attempts; community leave, remove,
last owner, rank rule, channel-less community; the stored hash is not the
locator; one test vector shared with the Dart side.

## App (run locally, then by CI on the pull request)

Flutter 3.44.0 from the SDK archive, run in `mobile/`. The SDK pins intl
0.20.2 while `pubspec.yaml` on main says 0.20.3, so intl was pinned to 0.20.2
locally to resolve; that change is not in the branch.

- `flutter analyze`: no issues. `dart format --set-exit-if-changed .`: clean.
- `mobile/test/membership_invite_link_test.dart`: SHA-256 vectors, locator
  vector, link round trip, origin and shape rejection.
- `mobile/test/membership_api_test.dart`: requests against a loopback server
  (paths, bodies, no secret, parsing, malformed rows, error-code mapping).
- `mobile/test/app_state_membership_test.dart`: link made locally, foreign
  origin refused before any request, approvals, community leave and remove.
- `mobile/test/membership_screens_test.dart` (7 widget tests): join by link,
  created link shown once and copied, approve and decline, community details
  for an owner and for a plain member.
- Also passed: `l10n_locales_test`, `api_contract_test`, `ui_remaining_test`,
  `conversation_quality_test`, `k0_recovery_no_peer_test`.

## Invitation binding (D90), 2026-11-07

- Server, run locally: `go test ./...` in `server/` (storage, httpapi and the
  rest) passes. New: `membership_invite_binding_test.go` (binding stored and
  returned with the preview and the request answer; a body whose key, device
  or tag does not match the creating device is refused; an invitation stops
  working when its device is revoked; the tag vector), and binding cases in
  `membership_invite_handlers_test.go`.
- Dart, locally: the pure-Dart parts (SHA-256, HMAC-SHA256, the binding tag and
  its verifier, binding JSON) were run with the Dart 3.12.0 SDK against the
  RFC 4231 cases 1, 2 and 6, an empty key and message, and the tag vector
  shared with the server (all equal to Python's `hmac`); `dart analyze` is
  clean on those three files; `dart format --language-version=3.4` was run
  on every changed Dart file. The Flutter tests (`membership_invite_link_test`,
  `membership_api_test`, `app_state_membership_test`,
  `membership_screens_test`) are not run locally (no Flutter); CI on the pull
  request runs them.
- Covered by those tests: a creating app sends the engine's device key and a
  tag that verifies against its own link; no invitation without an engine that
  reads the key; a preview refused for another target, kind, account, device,
  key, a tag of another link, or a malformed tag, with no request filed; a
  request answered with another binding or none is withdrawn and refused.

## Not covered

- No device run, no native MLS lifecycle test of approval or removal.
- The binding is a MAC, not a device signature, and the inviting device's key
  is not checked against a device list or the MLS roster (needs L1 and C7).
