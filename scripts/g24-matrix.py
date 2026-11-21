#!/usr/bin/env python3
"""G24 signed-device matrix: preflight, install, checklist and evidence record.

Usage (docs/g24-device-matrix.md has the whole procedure):

  g24-matrix.py init       --android-apk FILE [--ios-ipa FILE] [--commit SHA]
  g24-matrix.py preflight  [--server https://host] [--write]
  g24-matrix.py install
  g24-matrix.py checklist  [--platform android|ios]
  g24-matrix.py record     --platform P --row ID --result pass|fail [--note TEXT]
  g24-matrix.py device     --platform ios --label D1 --os 17.5
  g24-matrix.py status     [--platform P]

The record is testing/evidence/G24-matrix.json. It holds the candidate commit,
the sha256 of each signed artifact, sanitized platform versions of two devices
per platform (D1, D2) and one result per row. It never holds a device serial,
an IMEI, a model, an account name or a log: adb serials are used in memory to
talk to the phones and are not printed or written, and a note that looks like
an identifier is refused. Android is scripted (adb); iOS has the checklist and
the record only.

Exit status 0 means the step succeeded. `status` exits 0 only when every row of
the chosen platforms is a recorded `pass`. Nothing here changes a release gate:
scripts/check-release-evidence.py and release-readiness.sh do not read this
file, and scripts/release-rc.py only reports whether it is complete.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RECORD = ROOT / "testing" / "evidence" / "G24-matrix.json"
POLICY = ROOT / "release" / "release-policy.json"
SCHEMA = "veritra-g24-matrix/1"
PLATFORMS = ("android", "ios")
RESULTS = ("pending", "pass", "fail")
PACKAGE = "org.veritra.private_messenger"
MIN_SDK = 24

# One entry per row of the matrix in docs/security-review.md (a test keeps the
# two lists identical). Steps name D1 and D2, the two phones of the platform.
ROWS = (
    {
        "id": "setup-invite-dm-group",
        "name": "Setup, invite, DM/group",
        "steps": (
            "D1: open the app, enter the server URL, create the first account with the setup token, finish onboarding.",
            "D1: create an invite. D2: install the same signed build, join through the invite (link, QR or code), create the account.",
            "D1 and D2: send a direct message both ways.",
            "D1: create a group with D2 and post both ways, with a reply and a reaction.",
            "Pass when: every message arrives once, in order, on both phones, and no error or 'messaging unavailable' notice appears.",
        ),
    },
    {
        "id": "device-link-sas",
        "name": "Device link and SAS",
        "steps": (
            "D1 is signed in. D2 is a fresh install: choose 'link this device' and sign in as the same account.",
            "Compare the short authentication string (SAS) on both screens: they must be identical. Approve on D1.",
            "Repeat once and make the strings differ on purpose (decline on D1): the link must be refused and D2 must stay signed out.",
            "After a successful link, send a message from each phone: both receive it.",
            "Pass when: matching SAS links, a declined or mismatched one never links, and both devices then work.",
        ),
    },
    {
        "id": "offline-catchup-restart",
        "name": "Offline catch-up and restart",
        "steps": (
            "D2: airplane mode on. D1: send 20 messages in a DM and a group, one with an attachment.",
            "D2: force-stop the app, turn the network on, open the app.",
            "Pass when: all 20 messages arrive on D2 once, in order, with no 'sync stopped' state.",
            "Restart both phones, open the apps: no new sign-in, no duplicate or missing message.",
        ),
    },
    {
        "id": "attachment-backup-restore",
        "name": "Attachment and backup restore",
        "steps": (
            "D1 and D2: send an image and a file of about 5 MB both ways and open each on the receiver.",
            "D1: make a backup (Settings, Backup) and keep the file. Uninstall the app, install it again, restore the backup.",
            "Finish the restore the way the app asks (device link). Pass when: the account works, history is readable and the earlier attachments open.",
            "A backup made before the restore must not give D1 a second, cloned device: only one D1 appears in the device list.",
        ),
    },
    {
        "id": "revocation-reconnect-order",
        "name": "Revocation reconnect ordering",
        "steps": (
            "D1: Settings, Devices: revoke D2 while D2 is online and while D1 keeps sending messages.",
            "D2: must stop and show it was signed out. D1 keeps working and sees the device list change once.",
            "Link D2 again while D1 sends. Pass when: D2 reconnects, no 'sync stopped' or 'recovery required' state is stuck, and D2 never shows messages sent while it was revoked.",
            "Send from both: all messages arrive once, in order.",
        ),
    },
    {
        "id": "push-wake",
        "name": "FCM/APNs background wake",
        "steps": (
            "Needs the push credentials on the server (FCM project for the Android play build, APNs key for iOS) and the app's push permission granted.",
            "D2: close the app (swipe it away), lock the screen, leave it for 10 minutes (Doze). D1: send a message.",
            "Pass when: D2 shows a generic notification within a minute with no message text and no sender name, and tapping it opens the app with the message present.",
            "Repeat with D2 in the foreground-less state after a restart.",
        ),
    },
    {
        "id": "turn-call-network-change",
        "name": "TURN call under network changes",
        "steps": (
            "Needs the server's TURN settings (PRIVATE_MESSENGER_TURN_URLS and shared secret). D1 on Wi-Fi, D2 on mobile data, so the call cannot go direct.",
            "D1 calls D2 (voice), both answer, speak both ways.",
            "D1: switch from Wi-Fi to mobile data during the call, then back. Pass when: audio resumes within about 10 seconds each time and the call ends cleanly.",
            "Repeat once with video on.",
        ),
    },
    {
        "id": "lan-tls-private-ca",
        "name": "LAN TLS with a private CA (T48B)",
        "steps": (
            "Serve the server over HTTPS on the LAN with a certificate from a private CA (docs/https-second-pc.md).",
            "D1 and D2: install the CA (Android: Settings, Security, Install a certificate, CA certificate; iOS: install the profile, then enable full trust).",
            "Connect the app to the LAN https:// address. Pass when: it connects and messages flow.",
            "Remove the CA from D2 and try again. Pass when: the app refuses the connection and offers no bypass.",
        ),
    },
    {
        "id": "accessibility",
        "name": "TalkBack/VoiceOver/large text/reduced motion",
        "steps": (
            "Screen reader on (TalkBack on Android, VoiceOver on iOS): sign in, open a chat, send a message, open Settings. Pass when: every control has a label and the focus order is sensible.",
            "Largest font size and largest display size: chat list, composer and Settings show no clipped or overlapping text.",
            "Remove animations (Android) or Reduce Motion (iOS): nothing needs an animation to work.",
        ),
    },
)

SERIAL_LIKE = re.compile(r"\b[0-9A-Fa-f]{12,}\b|\b\d{14,16}\b|[\w.+-]+@[\w-]+\.[\w.]+")


class MatrixError(Exception):
    pass


# --- record ----------------------------------------------------------------


def blank_platform() -> dict:
    return {
        "devices": [],
        "rows": [{"id": r["id"], "name": r["name"], "result": "pending", "note": ""} for r in ROWS],
    }


def load(path: Path | None = None) -> dict:
    path = path or RECORD
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise MatrixError(f"cannot read {path}: {exc} (run g24-matrix.py init first)") from exc
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        raise MatrixError(f"{path} is not a {SCHEMA} record")
    for platform in PLATFORMS:
        rows = data.get("platforms", {}).get(platform, {}).get("rows")
        if not isinstance(rows, list) or [r.get("id") for r in rows] != [r["id"] for r in ROWS]:
            raise MatrixError(f"{path}: the {platform} rows do not match this script's rows")
        if any(r.get("result") not in RESULTS for r in rows):
            raise MatrixError(f"{path}: a {platform} result is not one of {RESULTS}")
    return data


def save(data: dict, path: Path | None = None) -> None:
    path = path or RECORD
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(*args: str) -> str:
    proc = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise MatrixError(f"git {' '.join(args)} failed")
    return proc.stdout.strip()


def init(args: argparse.Namespace) -> None:
    out = Path(args.out)
    if out.exists():
        raise MatrixError(f"{out} already exists; it is a record and is not overwritten")
    commit = args.commit or git("rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise MatrixError("--commit must be a full 40-character SHA")
    artifacts = {}
    for platform, value in (("android", args.android_apk), ("ios", args.ios_ipa)):
        if value:
            path = Path(value)
            if not path.is_file() or path.stat().st_size == 0:
                raise MatrixError(f"artifact not found or empty: {path}")
            artifacts[platform] = {"file": path.name, "sha256": sha256_file(path)}
    if "android" not in artifacts:
        raise MatrixError("--android-apk is required")
    save(
        {
            "schema": SCHEMA,
            "candidate_commit": commit,
            "artifacts": artifacts,
            "platforms": {p: blank_platform() for p in PLATFORMS},
        },
        out,
    )
    print(f"wrote {out} for {commit}")


def record(args: argparse.Namespace) -> None:
    data = load()
    row = next((r for r in data["platforms"][args.platform]["rows"] if r["id"] == args.row), None)
    if row is None:
        raise MatrixError(f"unknown row {args.row}; rows: " + ", ".join(r["id"] for r in ROWS))
    note = args.note or ""
    if len(note) > 300:
        raise MatrixError("the note is longer than 300 characters")
    if SERIAL_LIKE.search(note):
        raise MatrixError("the note looks like it holds an identifier (serial, IMEI, long hex or an address); record what happened, not who or which device")
    for serial in attached_serials():
        if serial in note:
            raise MatrixError("the note contains a device serial")
    row["result"] = args.result
    row["note"] = note
    save(data)
    print(f"{args.platform} / {args.row}: {args.result}")


def device_record(args: argparse.Namespace) -> None:
    if args.platform != "ios":
        raise MatrixError("Android devices are written by preflight --write")
    data = load()
    if not re.fullmatch(r"D[12]", args.label) or not re.fullmatch(r"\d{1,2}(\.\d{1,2}){0,2}", args.os):
        raise MatrixError("--label is D1 or D2 and --os a plain version such as 17.5")
    devices = [d for d in data["platforms"]["ios"]["devices"] if d["label"] != args.label]
    devices.append({"label": args.label, "os": args.os})
    data["platforms"]["ios"]["devices"] = sorted(devices, key=lambda d: d["label"])
    save(data)
    print(f"ios {args.label}: iOS {args.os}")


def status(args: argparse.Namespace) -> int:
    data = load()
    complete = True
    for platform in args.platform or PLATFORMS:
        rows = data["platforms"][platform]["rows"]
        print(f"{platform}: {sum(r['result'] == 'pass' for r in rows)} of {len(rows)} rows passed; devices recorded: {len(data['platforms'][platform]['devices'])}")
        for row in rows:
            print(f"  {row['result']:<7} {row['id']}" + (f"  ({row['note']})" if row["note"] else ""))
            complete &= row["result"] == "pass"
        if len(data["platforms"][platform]["devices"]) != 2:
            print("  two devices (D1, D2) are not recorded yet")
            complete = False
    print("G24 matrix COMPLETE" if complete else "G24 matrix NOT complete")
    return 0 if complete else 1


def checklist(args: argparse.Namespace) -> None:
    for platform in [args.platform] if args.platform else PLATFORMS:
        print(f"== {platform} (two phones: D1 and D2, the signed candidate build on both) ==")
        for number, row in enumerate(ROWS, 1):
            print(f"\n{number}. {row['name']}   [record: --platform {platform} --row {row['id']}]")
            for step in row["steps"]:
                print(f"   - {step}")
        print()


# --- adb and signing -------------------------------------------------------


def adb(*args: str) -> str:
    adb_path = shutil.which("adb")
    if adb_path is None:
        raise MatrixError("adb is not installed (Android platform-tools)")
    proc = subprocess.run([adb_path, *args], capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        # adb's own message can name the serial, so it is not repeated here.
        raise MatrixError(f"adb {args[0] if args[0] != '-s' else args[2]} failed (exit {proc.returncode})")
    return proc.stdout


def attached_serials() -> list[str]:
    if shutil.which("adb") is None:
        return []
    try:
        out = adb("devices")
    except MatrixError:
        return []
    return [line.split("\t")[0] for line in out.splitlines()[1:] if line.endswith("\tdevice")]


def prop(serial: str, name: str, pattern: str) -> str:
    value = adb("-s", serial, "shell", "getprop", name).strip()
    if not re.fullmatch(pattern, value):
        raise MatrixError(f"unexpected {name} value")
    return value


def read_devices() -> list[tuple[str, dict]]:
    """[(serial, sanitized info)] for exactly two attached phones, in adb order."""
    serials = attached_serials()
    if len(serials) != 2:
        raise MatrixError(f"{len(serials)} authorized Android device(s) attached; exactly 2 are needed (unplug the others, accept the USB debugging prompt)")
    devices = []
    for index, serial in enumerate(serials, 1):
        info = {
            "label": f"D{index}",
            "os": prop(serial, "ro.build.version.release", r"\d{1,2}(\.\d{1,2}){0,2}"),
            "sdk": int(prop(serial, "ro.build.version.sdk", r"\d{2}")),
            "abi": prop(serial, "ro.product.cpu.abi", r"[a-z0-9_-]{3,20}"),
        }
        if info["sdk"] < MIN_SDK:
            raise MatrixError(f"{info['label']} runs Android SDK {info['sdk']}; the app needs {MIN_SDK} or later")
        devices.append((serial, info))
    return devices


def find_apksigner() -> str | None:
    found = shutil.which("apksigner")
    if found:
        return found
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if sdk:
        candidates = sorted(Path(sdk, "build-tools").glob("*/apksigner"))
        if candidates:
            return str(candidates[-1])
    return None


def apk_certificate(apk: Path) -> str:
    apksigner = find_apksigner()
    if apksigner is None:
        raise MatrixError("apksigner not found (Android build-tools); it proves the APK is signed with the pinned key")
    proc = subprocess.run([apksigner, "verify", "--print-certs", str(apk)], capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise MatrixError("apksigner verify failed: the APK is not validly signed")
    digests = re.findall(r"certificate SHA-256 digest: ([0-9a-fA-F]{64})", proc.stdout)
    if len(digests) != 1:
        raise MatrixError("the APK must have exactly one signer")
    return digests[0].lower()


def policy_pin() -> str | None:
    try:
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        pin = policy["android"]["release_certificate_sha256"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return pin if isinstance(pin, str) and re.fullmatch(r"[0-9a-f]{64}", pin) else None


def candidate_problems(data: dict) -> list[str]:
    problems = []
    try:
        head = git("rev-parse", "HEAD")
        dirty = git("status", "--porcelain", "--untracked-files=no")
    except MatrixError:
        return ["cannot read git state"]
    if head != data["candidate_commit"]:
        problems.append(f"HEAD is {head[:12]}, the record is for {data['candidate_commit'][:12]}: check out the frozen candidate")
    if dirty:
        problems.append("the working tree has uncommitted changes to tracked files")
    for relative, marker in (("crypto/rust/src/lib.rs", "PM_CRYPTO_UNAVAILABLE"), ("mobile/lib/main.dart", "UnavailableCryptoService")):
        try:
            if marker in (ROOT / relative).read_text(encoding="utf-8"):
                problems.append(f"{marker} is still in {relative}: messaging is switched off in this commit, so the matrix cannot run on it")
        except OSError:
            problems.append(f"cannot read {relative}")
    return problems


def apk_path(data: dict, given: str | None) -> Path:
    if not given:
        raise MatrixError("--android-apk is required (the file recorded by init)")
    apk = Path(given)
    if not apk.is_file():
        raise MatrixError(f"APK not found: {apk}")
    if sha256_file(apk) != data["artifacts"]["android"]["sha256"]:
        raise MatrixError("the APK's sha256 differs from the one recorded for this candidate")
    return apk


def check_server(url: str) -> None:
    if not re.fullmatch(r"https://[^/\s]+/?", url):
        raise MatrixError("--server must be an https:// address (no path)")
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/readyz", timeout=10) as response:
            if response.status != 200:
                raise MatrixError(f"{url}/readyz answered {response.status}")
    except urllib.error.URLError as exc:
        raise MatrixError(f"{url}/readyz is not reachable from this computer: {exc.reason}") from exc


def preflight(args: argparse.Namespace) -> int:
    data = load()
    problems = candidate_problems(data)
    pin = policy_pin()
    if pin is None:
        problems.append("release-policy.json android.release_certificate_sha256 is not pinned: pin it first (docs/security-review.md)")
    devices: list[tuple[str, dict]] = []
    try:
        apk = apk_path(data, args.android_apk)
        signer = apk_certificate(apk)
        if pin is not None and signer != pin:
            problems.append("the APK is signed with a certificate other than the pinned one")
        elif pin is not None:
            print("PASS  APK digest is the recorded one and it is signed with the pinned certificate")
    except MatrixError as exc:
        problems.append(str(exc))
    try:
        devices = read_devices()
        print("PASS  two Android phones attached: " + ", ".join(f"{info['label']} Android {info['os']} (SDK {info['sdk']}, {info['abi']})" for _, info in devices))
    except MatrixError as exc:
        problems.append(str(exc))
    if args.server:
        try:
            check_server(args.server)
            print("PASS  the server answers /readyz")
        except MatrixError as exc:
            problems.append(str(exc))
    else:
        print("NOTE  no --server given: not checked that the server is reachable")
    for problem in problems:
        print(f"FAIL  {problem}")
    if problems:
        print("G24 preflight FAILED; nothing was changed")
        return 1
    if args.write:
        data["platforms"]["android"]["devices"] = [info for _, info in devices]
        save(data)
        print("recorded the sanitized device versions (no serials)")
    print("G24 preflight passed: run `g24-matrix.py install`, then `checklist` and `record`")
    return 0


def install(args: argparse.Namespace) -> int:
    code = preflight(argparse.Namespace(android_apk=args.android_apk, server=None, write=True))
    if code:
        return code
    apk = apk_path(load(), args.android_apk)
    for serial, info in read_devices():
        adb("-s", serial, "install", "-r", str(apk))
        installed = adb("-s", serial, "shell", "pm", "list", "packages", PACKAGE)
        if f"package:{PACKAGE}" not in installed:
            print(f"FAIL  {info['label']}: the app is not installed after adb install")
            return 1
        print(f"installed on {info['label']}")
    print("Both phones have the signed build. Run `g24-matrix.py checklist --platform android`.")
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    i = sub.add_parser("init")
    i.add_argument("--android-apk")
    i.add_argument("--ios-ipa")
    i.add_argument("--commit")
    i.add_argument("--out", default=str(RECORD))
    for name in ("preflight", "install"):
        s = sub.add_parser(name)
        s.add_argument("--android-apk")
        if name == "preflight":
            s.add_argument("--server")
            s.add_argument("--write", action="store_true")
    c = sub.add_parser("checklist")
    c.add_argument("--platform", choices=PLATFORMS)
    r = sub.add_parser("record")
    r.add_argument("--platform", required=True, choices=PLATFORMS)
    r.add_argument("--row", required=True)
    r.add_argument("--result", required=True, choices=("pass", "fail"))
    r.add_argument("--note")
    d = sub.add_parser("device")
    d.add_argument("--platform", required=True, choices=PLATFORMS)
    d.add_argument("--label", required=True)
    d.add_argument("--os", required=True)
    s = sub.add_parser("status")
    s.add_argument("--platform", action="append", choices=PLATFORMS)
    return p


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "init":
            init(args)
        elif args.command == "preflight":
            return preflight(args)
        elif args.command == "install":
            return install(args)
        elif args.command == "checklist":
            checklist(args)
        elif args.command == "record":
            record(args)
        elif args.command == "device":
            device_record(args)
        else:
            return status(args)
    except MatrixError as exc:
        print(f"g24-matrix: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
