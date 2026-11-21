#!/usr/bin/env bash
# Rollback across a schema change, rehearsed with real server binaries.
#
#   scripts/rehearse-schema-rollback.sh OLD_REV [WORKDIR]
#
# Builds the server at HEAD and at OLD_REV (a commit with fewer migrations),
# starts HEAD on a fresh data directory, runs the deployment smoke client
# against it (owner setup, login, attachment, push registration), stops it,
# then starts the OLD binary on the same data directory (the rollback) and
# runs the smoke client's `verify` (login, old data intact, new writes, push
# registration), and finally starts HEAD again (roll forward) and verifies
# once more. Prints what each step did; exits 0 only when every step the
# script expects to work did. A step that fails is reported, not hidden:
# it is the finding (the old binary cannot serve that schema).
#
# Local only; uses loopback port ROLLBACK_PORT (default 18181), the Go build
# cache in GOCACHE, and no network. The data is throwaway.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
OLD_REV="${1:?usage: rehearse-schema-rollback.sh OLD_REV [WORKDIR]}"
WORK="${2:-$(mktemp -d)}"
PORT="${ROLLBACK_PORT:-18181}"
BASE="http://127.0.0.1:$PORT"
mkdir -p "$WORK/old" "$WORK/data" "$WORK/secrets" "$WORK/logs"
STATUS=0
SERVER_PID=""

say() { printf '%s\n' "$*"; }
stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null
    for _ in $(seq 1 60); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$SERVER_PID" 2>/dev/null
  fi
  SERVER_PID=""
}
trap stop_server EXIT

say "== build HEAD ($(git -C "$ROOT" rev-parse --short HEAD)) and OLD ($(git -C "$ROOT" rev-parse --short "$OLD_REV"))"
(cd "$ROOT/server" && go build -trimpath -o "$WORK/server-head" ./cmd/messenger-server) || { say "build of HEAD failed"; exit 1; }
git -C "$ROOT" archive "$OLD_REV" server .go-version | tar -x -C "$WORK/old"
(cd "$WORK/old/server" && go build -trimpath -o "$WORK/server-old" ./cmd/messenger-server) || { say "build of $OLD_REV failed"; exit 1; }
(cd "$ROOT/scripts/smoke-deploy" && go build -o "$WORK/smoke-client" smoke-client.go) || { say "smoke client build failed"; exit 1; }
say "migrations: HEAD $(ls "$ROOT/server/migrations" | grep -c '\.sql$'), OLD $(git -C "$ROOT" ls-tree --name-only "$OLD_REV" server/migrations/ | grep -c '\.sql$')"

"$WORK/server-head" generate-setup-token > "$WORK/secrets/setup_token"
"$WORK/server-head" generate-setup-token > "$WORK/secrets/turn_shared_secret"
VAPID_PUBLIC="$("$WORK/smoke-client" vapid-keys -private-out "$WORK/secrets/vapid_private_key")"

start() { # BINARY LABEL
  PRIVATE_MESSENGER_ENV=development PRIVATE_MESSENGER_ADDR="127.0.0.1:$PORT" \
    PRIVATE_MESSENGER_DATA_DIR="$WORK/data" \
    PRIVATE_MESSENGER_SETUP_TOKEN_FILE="$WORK/secrets/setup_token" \
    PRIVATE_MESSENGER_TURN_URLS="turn:127.0.0.1:3478?transport=udp" \
    PRIVATE_MESSENGER_TURN_SHARED_SECRET_FILE="$WORK/secrets/turn_shared_secret" \
    PRIVATE_MESSENGER_VAPID_SUBSCRIBER="mailto:rehearsal@example.invalid" \
    PRIVATE_MESSENGER_VAPID_PUBLIC_KEY="$VAPID_PUBLIC" \
    PRIVATE_MESSENGER_VAPID_PRIVATE_KEY_FILE="$WORK/secrets/vapid_private_key" \
    "$1" serve > "$WORK/logs/$2.log" 2>&1 &
  SERVER_PID=$!
  if "$WORK/smoke-client" wait -base "$BASE" >/dev/null 2>&1; then
    say "$2: started, /readyz 200"
    return 0
  fi
  say "$2: did not become ready (exit/log tail follows)"
  tail -n 5 "$WORK/logs/$2.log" | sed 's/^/    /'
  stop_server
  return 1
}
# probe LABEL: signs in with the smoke owner and creates a community with two
# request bodies, printing only HTTP status codes. Informational: it shows a
# write path whose tables a newer migration changed (0082 dropped the
# plaintext name columns of communities), which `verify` does not touch.
probe() {
  python3 - "$WORK/state.json" "$BASE" "$1" <<'PY'
import json, sys, urllib.request, urllib.error
state, base, label = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
def call(path, body, token=None):
    request = urllib.request.Request(base + path, json.dumps(body).encode(), {"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return error.code, {}
status, body = call("/api/v1/auth/login", {"username": state["username"], "password": state["password"], "device_id": state["device_id"], "device_secret": state["device_secret"]})
if status != 200:
    print(f"{label}: probe login -> {status}"); sys.exit(0)
for name, payload in (("no name", {}), ("with a name", {"name": "rollback probe"})):
    code, _ = call("/api/v1/communities", payload, body["token"])
    print(f"{label}: probe, create a community ({name}) -> HTTP {code}")
PY
}
applied() { # prints how many schema_migrations rows the data directory holds
  python3 - "$WORK/data" <<'PY'
import sqlite3, sys, glob
db = glob.glob(sys.argv[1] + "/*.db")[0]
c = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
print(c.execute("select count(*), max(version) from schema_migrations").fetchone())
PY
}

say "== 1. HEAD on a fresh data directory, then the first-run smoke"
start "$WORK/server-head" head-1 || exit 1
"$WORK/smoke-client" run -base "$BASE" -state "$WORK/state.json" -sensitive-out "$WORK/client-sensitive.txt" \
  -turn-out "$WORK/turn-credentials" -setup-token-file "$WORK/secrets/setup_token" \
  -turn-secret-file "$WORK/secrets/turn_shared_secret" -turn-urls "turn:127.0.0.1:3478?transport=udp" \
  -vapid-public "$VAPID_PUBLIC" > "$WORK/logs/run.log" 2>&1 || { say "first-run smoke failed"; tail -5 "$WORK/logs/run.log"; exit 1; }
say "first-run smoke: ok"
probe "HEAD"
say "applied migrations: $(applied)"
stop_server

say "== 2. rollback: the OLD binary on the same data directory"
if start "$WORK/server-old" old; then
  say "applied migrations after the old binary started: $(applied)"
  if "$WORK/smoke-client" verify -base "$BASE" -state "$WORK/state.json" > "$WORK/logs/verify-old.log" 2>&1; then
    say "old binary on the newer schema: verify ok"
  else
    say "old binary on the newer schema: verify FAILED"; STATUS=1
    sed 's/^/    /' "$WORK/logs/verify-old.log" | tail -8
  fi
  probe "OLD on the newer schema"
  grep -i -c "error\|fail" "$WORK/logs/old.log" | sed 's/^/old server log lines with error or fail: /'
  stop_server
else
  say "old binary refused or failed to start the newer schema (see above)"; STATUS=1
fi

say "== 3. roll forward: HEAD again"
if start "$WORK/server-head" head-2; then
  if "$WORK/smoke-client" verify -base "$BASE" -state "$WORK/state.json" > "$WORK/logs/verify-head.log" 2>&1; then
    say "HEAD after the rollback: verify ok"
    probe "HEAD after the rollback"
  else
    say "HEAD after the rollback: verify FAILED"; STATUS=1; tail -8 "$WORK/logs/verify-head.log" | sed 's/^/    /'
  fi
  stop_server
else
  STATUS=1
fi
say "logs and data: $WORK"
exit "$STATUS"
