# Private Messenger Mobile

Flutter mobile shell for Android and iOS.

The current client includes screens, state boundaries, API serialization, sync and storage abstractions, manual device-link screens, and a crypto interface. Production message encryption and production QR/key verification are not implemented here; the default crypto service fails closed.

Local checks:

```sh
flutter test
```

Reviewed Android and iOS platform projects are committed. Android release
artifacts are left unsigned unless an explicit production signing setup is
provided; debug signing must never be used for releases.
