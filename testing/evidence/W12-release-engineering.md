# W12 release engineering: what was measured (2026-11-07)

Scripts: `scripts/repro/` (see docs/release-engineering.md). Linux container,
Rust 1.91.0, Flutter 3.44.0. Two builds of one commit from two different paths.

| Target | Result | Evidence |
|---|---|---|
| Rust crypto library, Linux (`crypto-linux`) | **Byte-identical** (sha256 `40d01698...bc73c12`) | `W12-repro-crypto-linux.md`; run twice, same digest both times |
| Linux desktop bundle (`linux`) | **Not yet reproducible**: 18 of 30 files match (including the runner binary after the C/C++ path fix), 12 differ: `libapp.so` (Dart AOT) and the 11 C++ plugin `.so` files | `W12-repro-linux.md` |
| Android APK | Not run: no Android SDK/NDK (host not reachable from here); script written, untested | n/a |
| macOS | Not run: needs a Mac; script reuses the tested crypto script | n/a |
| Windows, installer | Not run: needs Windows; scripts and `.iss` are drafts | n/a |
| F-Droid recipe | Draft, parses as YAML, not submitted. Blocked by Firebase dependency, G24/G25 and a missing signing key | n/a |

Not yet explained (confidence low, about 40%): the plugin `.so` files probably
still embed paths or build ids because Flutter's CMake plugin builds do not
pick up `CFLAGS`/`LDFLAGS`; `libapp.so` may embed the Dart snapshot's
paths/hash. Next step: diff one plugin (`readelf`, `strings`) from both builds.
The `verify.sh linux` exit code is 1 and stays 1 until fixed; nothing relies on
it (not wired into CI or any release gate).

Not touched: `scripts/release-readiness.sh`, G24/G25/G27, `PM_CRYPTO_UNAVAILABLE`,
`STATE.md`, counters, dependencies.

Second-PC HTTPS (docs/https-second-pc.md): documentation only, not tested on a
second PC.

## Linux bundle report (build A digests)

  (checkout at /tmp/veritra-repro.L8Hgag/a/src)
```
0a4861061c86a619daee6d4da00dc5cf1535d9785ff634293ff07a38277a1280  data/flutter_assets/AssetManifest.bin
28b1eb2b3d2e1ad60b8c8b0f9100b1ccbf492f7fa97f5bebb51ea97e73926e7d  data/flutter_assets/FontManifest.json
fb16734c4b83c72da03a3504536ec4fd11b1f5e950a208cf18fe054e88f13f38  data/flutter_assets/NOTICES.Z
1edf667bed54efd3aa0e9fe30207673a653a899af0b7f3e041b2825b7bd35966  data/flutter_assets/NativeAssetsManifest.json
397afd7bb5b0fed86c812c2d7068455ea69f0ecfb2c4f6e144b553769a5f31e1  data/flutter_assets/assets/tray/veritra.ico
d75dd512210acf895210b5e5306030edd39de9bbe5222bd499a107a31906e7ec  data/flutter_assets/assets/tray/veritra.png
d9865b671a09d683d13a863089d8825e0f61a37696ce5d7d448bc8023aa62453  data/flutter_assets/fonts/MaterialIcons-Regular.otf
1fe8436a743884cb65078fe8c7b38e18f5365f2a2961270916f426fd13c604af  data/flutter_assets/shaders/ink_sparkle.frag
62a899ff4e168ac6ca888ce7c2f40e5d3fbf8ca20a1c3ded781a116a6d7907e2  data/flutter_assets/shaders/stretch_effect.frag
7afd6eadb4d994d5939a94d47a353bddae6b114d8c7d0541f285793bc024783c  data/flutter_assets/version.json
998367809a821d595928089c197b3f7959f0420f81f79d4d0daee53378492ed5  data/icudtl.dat
d75dd512210acf895210b5e5306030edd39de9bbe5222bd499a107a31906e7ec  data/veritra-icon.png
5b12f6c80e444336effc12e33deae0dac9eaaeaa0f1f0a43c0b672810bbf849d  lib/libapp.so
b57c21dcb6034f25aa3b27b3b089b324aabd5f69bdc3d6b81da239e0250f4785  lib/libaudioplayers_linux_plugin.so
cb0564ee1bdf2fc81618b6e8c9e5a344c7dcb8ca6ee7e9e6a24cb0a05ee35aca  lib/libdartjni.so
741434873ede5796cbe528893d168de71c9857270905396e02a3e0ff6afdc916  lib/libdesktop_drop_plugin.so
eead48c5bd5e0254454938eab2336a3033097663aa7583b8b71a544cf523067f  lib/libfile_selector_linux_plugin.so
88a520b9543a2c32048868692dac3f930137d8dd1783b79787c7c4c5c49074cb  lib/libflutter_linux_gtk.so
5f387efb1cfc4d9a3c89503593a66cc5c58274a10051dbb3ab3c6a981f3e63a8  lib/libflutter_secure_storage_linux_plugin.so
32c29e4c630af1b031fac657595ab5d6c9a06da3ba1a1b8350fcf38a50292ea2  lib/libflutter_webrtc_plugin.so
f2751c46fac647c82980aee21afb35e41e3c257b3ad866cb999ab3195de1f448  lib/liblocal_notifier_plugin.so
451c9b8611103d8dda6eca228102f3dca35cd5dd666460150d870306ef62bc71  lib/libpasteboard_plugin.so
40d0169843cb4cb845215874d8ae3481a6f7a851f2928e089db282eebeb73c12  lib/libprivate_messenger_crypto.so
cf76aded40b2b1dcb4610fc69a6b6c9abe1853de2edccaade9fb93c7dc9ac0a8  lib/librecord_linux_plugin.so
ab084fb171c7bf33ddba9de17e4196083ceac9fc9cddb260a2204a467bcad157  lib/libscreen_retriever_linux_plugin.so
32d8d11b86b5d5be97d15d0bbabc0fc4a7b132b722d49cd9805ac24200df2daf  lib/libsqlite3mc.so
755c57454b56cf33b51555f408917aa6602593d5caa5be2a26354d3ff01b19dc  lib/libtray_manager_plugin.so
7e4832d92764c1041448155916529f63dcc6ea724c542e42ce2284eaf8fa70e1  lib/libwebrtc.so
b7754f44e6079944e277286d58afbf1587cab2ad0045aeca00528341e163e9c0  lib/libwindow_manager_plugin.so
de423d26f2795586740a5eb271dd683e46bf12ee13df0c3ba8213069ef254679  private_messenger
```

