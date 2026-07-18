# Private Messenger Mobile

Flutter mobile shell for Android and iOS.

The current client includes screens, state boundaries, API serialization, sync
and protected-storage abstractions, QR device-link screens, enrollment
preflight, and a reviewed ABI-v2 Dart binding. Native MLS libraries, full group
orchestration, and credential-derived QR/SAS verification are not yet wired;
the default crypto service therefore remains fail-closed.

Local checks:

```sh
flutter test
```

Reviewed Android and iOS platform projects are committed. Android release
artifacts are left unsigned unless an explicit production signing setup is
provided; debug signing must never be used for releases.
