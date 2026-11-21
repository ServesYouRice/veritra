# G24 two-device matrix: what the owner does

G24 needs signed builds of one frozen commit and the matrix in
[`security-review.md`](security-review.md#signed-device-matrix-g24) run on real
phones. `scripts/g24-matrix.py` does everything that can be scripted; this page
is the rest. The record it keeps is `testing/evidence/G24-matrix.json`:
candidate commit, artifact digests, sanitized OS versions of two devices per
platform (D1, D2) and one result per row. It never holds a serial, IMEI, model,
account name or log.

## Before plugging anything in

1. **Signing pins** set in `release/release-policy.json` (Android certificate;
   iOS team and bundle ID), in a reviewed pull request, before the candidate is
   frozen. `scripts/release-rc.py --dry-run` lists what is still missing.
2. **A frozen candidate commit** in which messaging works: the matrix cannot run
   on a commit that still has `PM_CRYPTO_UNAVAILABLE` or
   `UnavailableCryptoService`. The preflight refuses such a commit and says why.
3. **Signed builds of that commit**: the Android `.apk` (play flavor, signed with
   the pinned key) and, for iOS, the signed `.ipa`. Build and sign them from the
   frozen commit only.
4. **A server both phones can reach over HTTPS**, with the TURN settings
   (`PRIVATE_MESSENGER_TURN_URLS`, shared secret) and the push credentials (FCM
   for the Android play build, an APNs key for iOS) configured
   ([`operations.md`](operations.md)). For the LAN TLS row, a private CA
   ([`https-second-pc.md`](https-second-pc.md)).
5. **Two Android phones and two iPhones** (D1 and D2 of each platform), Android 7
   (SDK 24) or newer, USB debugging on for the Android ones, a mobile data plan
   on one phone of each pair, and `adb` plus the Android build-tools
   (`apksigner`) on the computer.

## Android: plug the two phones in

```sh
python3 scripts/g24-matrix.py init --android-apk path/to/veritra-release.apk [--ios-ipa path/to/Veritra.ipa]
python3 scripts/g24-matrix.py preflight --android-apk path/to/veritra-release.apk --server https://your-server --write
python3 scripts/g24-matrix.py install   --android-apk path/to/veritra-release.apk
python3 scripts/g24-matrix.py checklist --platform android
```

`preflight` stops (and changes nothing) unless: HEAD is the commit in the
record and the tree is clean; messaging is switched on in that commit; the
certificate pin is set; the APK's sha256 is the one recorded and `apksigner`
shows it signed with exactly the pinned certificate; exactly two authorized
phones are attached, both on Android 7 or newer; and the server answers
`/readyz`. `--write` then records their Android versions and ABI as D1 and D2.
`install` puts the same APK on both.

Then do the nine rows on the phones, in order, following `checklist`, and record
each as you finish it:

```sh
python3 scripts/g24-matrix.py record --platform android --row setup-invite-dm-group --result pass
python3 scripts/g24-matrix.py record --platform android --row push-wake --result fail --note "arrived after 4 minutes"
```

A note says what happened, not who or which device: serials, long hex strings,
IMEI-like numbers and addresses are refused.

## iOS: checklist only

There is no script for the phones. Install the signed `.ipa` on both
(Xcode, Devices and Simulators, or your distribution tool), then:

```sh
python3 scripts/g24-matrix.py device --platform ios --label D1 --os 17.5
python3 scripts/g24-matrix.py device --platform ios --label D2 --os 17.5
python3 scripts/g24-matrix.py checklist --platform ios
python3 scripts/g24-matrix.py record --platform ios --row setup-invite-dm-group --result pass
```

Record the first signed `.ipa` against the structural checks too
([`security-review.md`](security-review.md#signed-artifact-evidence)): it
must show that Xcode writes no zip comment or ZIP64 records.

## When it is done

```sh
python3 scripts/g24-matrix.py status        # exits 0 only if every row of both platforms is a pass
python3 scripts/release-rc.py --dry-run     # G24 line changes from MISSING to DONE
```

Commit `testing/evidence/G24-matrix.json` in the pull request that records the
evidence. A failed row is fixed in a new candidate: the record belongs to one
commit, so start a new one with `init` for the new commit rather than editing
the old.

What this does **not** do: it does not sign anything, it is not read by
`scripts/check-release-evidence.py` or `release-readiness.sh` (the release gate
is unchanged), and a complete matrix does not open G25 (the independent review).
