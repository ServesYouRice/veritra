# Local demo

Run Veritra on your own machine: one local server, and apps that talk to it.
The demo uses the real OpenMLS encryption, which has **not** been
independently reviewed yet. Every demo app shows a "Demo build · unreviewed
encryption" banner. Do not use it for real secrets.

## 1. Start the server

You need Go (the version in `.go-version`). Rust (`rust-toolchain.toml`) is
needed for the apps.

| System | Command |
|---|---|
| Linux, macOS | `scripts/demo.sh` |
| Windows | `powershell -File scripts\demo.ps1` |

It prints the server URL (`http://localhost:8080`) and a setup token.

- `--reset` (`-Reset` on Windows) wipes the demo data.
- `--port 9000` (`-Port 9000`) uses another port.
- Data is kept in `data/demo`, so accounts and chats survive a restart.

The server only listens on `127.0.0.1`. Nothing outside this machine can
reach it.

## 2. Start an app

Every app runs from `mobile/` with the demo entry point:

```sh
flutter run -t lib/main_demo.dart --dart-define=VERITRA_DEMO=true
```

Without `--dart-define=VERITRA_DEMO=true` the demo entry point refuses to
start.

| App | Before `flutter run` | Server URL in the app |
|---|---|---|
| Android emulator | `scripts/build-mobile-crypto.sh android`, start the emulator, then `adb reverse tcp:8080 tcp:8080` (the demo script does this if the emulator is already running) | `http://localhost:8080` |
| iOS simulator (macOS) | `scripts/build-mobile-crypto.sh ios` | `http://localhost:8080` |
| Linux desktop | `scripts/build-desktop-crypto.sh linux`; needs GTK 3 and libsecret dev packages and a running keyring (see below) | `http://localhost:8080` |
| Windows desktop | `scripts\build-desktop-crypto.ps1`; needs Visual Studio with "Desktop development with C++" | `http://localhost:8080` |

Run a desktop app with `flutter run -d linux` or `flutter run -d windows`
plus the demo arguments above. CI also builds unsigned demo bundles for both
(`desktop-linux` and `desktop-windows` artifacts).

The connect screen fills in the URL for you.

### Linux notes

- Packages (Debian/Ubuntu): `clang cmake ninja-build pkg-config libgtk-3-dev
  libsecret-1-dev liblzma-dev`.
- The app keeps its database key in the Secret Service keyring (GNOME
  Keyring or KWallet). A normal desktop session has one. Without it the app
  opens its recovery screen instead of starting.
- On Windows you can run the Linux app in WSL2 (WSLg). It reaches a server
  started on Windows at `http://localhost:8080`.

### Two accounts on one computer

Each desktop window needs its own profile, with its own data and keys:

```sh
flutter run -d linux -t lib/main_demo.dart --dart-define=VERITRA_DEMO=true \
  --dart-entrypoint-args=--profile=alice
```

A built app takes `--profile alice` directly. Names are 1-20 lowercase
letters or digits. Opening the same profile twice shows a message instead
of a second copy.

On desktop, Enter sends and Shift+Enter starts a new line. Messages keep
syncing while the window is in the background.

## 3. Demo script

1. First app: the app sees a fresh server. Paste the setup token, pick an
   owner name and password, and tap **Create owner**.
2. Owner: **Settings → Invites → Create invite**. Copy the code.
3. Second app: choose **Join with an invite**, paste the code, pick a name,
   and tap **Join with invite**.
4. Owner: start a direct message with the second account and send a message.
5. Long-press a message (right-click on desktop) to react, reply, copy, or,
   for your own messages, edit or delete.
6. Add a third account the same way and create a group with all three.

## Limits of the demo

- One device per account, and group members are fixed when the group is
  created (D24). "Add member" and "Link device" are hidden.
- Attachments and calls are not in the demo yet.
- Offline use (reading history and queueing messages with the server down)
  arrives in Stage 4.
- Cross-machine demos need HTTPS and are not covered yet.

## Automated check

`scripts/test-demo-e2e.sh` starts a throwaway server and runs three real
clients through the same flow: direct message, reply, edit, reaction,
delete, a group of three, and an app restart. CI runs it on every push.
