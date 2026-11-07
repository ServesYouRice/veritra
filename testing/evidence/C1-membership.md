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
(one change, one use); use limit with a second pending request; revoked,
expired, used-up, unknown and malformed locators; creator demoted or deleted;
block in either direction; member limit at approval (rolled back, request
stays pending, use not counted); bounds (input, pending per account);
outsider, plain member and requester attempts; community leave, remove,
last owner, rank rule, channel-less community; the stored hash is not the
locator; one test vector shared with the Dart side.

## App (checked by CI on the pull request)

- `mobile/test/membership_invite_link_test.dart`: SHA-256 vectors, locator
  vector, link round trip, origin and shape rejection.
- `mobile/test/membership_api_test.dart`: requests against a loopback server
  (paths, bodies, no secret, parsing, malformed rows, error-code mapping).
- `mobile/test/app_state_membership_test.dart`: link made locally, foreign
  origin refused before any request, approvals, community leave and remove.

## Not covered

- No device run, no native MLS lifecycle test of approval or removal.
- No widget tests of the new screens.
