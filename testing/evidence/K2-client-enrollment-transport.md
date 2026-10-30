# K2 v3 client enrollment transport - 2026-10-28

Implemented typed public-context/reservation/frozen-claim/completion models and
v3 enrollment HTTP methods in `mobile/lib/core/api_client.dart`. This slice is
not wired into enrollment UI or durable pending identity storage yet. It never
constructs a Session from a server completion response.

Requests keep raw claim credentials in the custom header; device and session
credentials stay client-owned. JSON claims carry only their committed hashes.
Models bound binary lengths, names, canonical origin/IDs, protocol, state,
chronology, seven-day approval deadline and exact allowed keys. Decode failures
omit offending values. Claim tokens are bounded before decoding. The unchanged
origin canonicalizer moved to `server_origin.dart`, still exported by ApiClient.

An independent agent reviewed the new files against the actual Go handlers.
Two findings were fixed and given HTTP regressions: claim acknowledgements must
match the full durable reservation identity/context, and approved retries must
not regress state or change known approval/deadline/tag/completion fields.
Completion separately pins the precommitted initial-session hash and local
identity/transcript. Native MAC verification and atomic local identity promotion
are mandatory future service steps; a typed public record is not crypto proof.

Checks with the pinned local Dart/Flutter toolchain:

```text
flutter test --no-pub --concurrency 1 test/device_link_v3_api_test.dart test/transport_policy_test.dart
PASS: 9 (6 real loopback HTTP tests, 3 existing transport-policy tests)
dart analyze lib/core/api_client.dart lib/core/device_link_v3_models.dart lib/core/server_origin.dart lib/core/transport_policy.dart test/device_link_v3_api_test.dart
PASS: no issues
```

The HTTP tests cover all eight enrollment methods, request shape, receipt-only
completion, every pinned receipt/reservation substitution, approved-state
regression/deadline/tag changes, malformed fields, local preflight rejection,
sanitized exceptions and a real second-origin redirect trap proving no claim
header is forwarded. They use a controlled HTTP server; this is not yet a live
Go/Rust/Dart K2 transfer or a device-platform check. Repository-wide verification
for the combined new slices remains the coordinator's next checkpoint.
