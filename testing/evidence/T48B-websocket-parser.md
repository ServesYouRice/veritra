# T48B — WebSocket parser evidence

Tested commit: `38ab190` (base `1912eda`). Date: 2026-10-22.
Toolchain: go1.26.8 linux/amd64. Parser: in-house `server/internal/realtime`
(retained; no dependency added).

## Autobahn|Testsuite (fuzzingclient)

Image `crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074`
(AutobahnTestSuite 25.10.1). Target: the production upgrade and frame reader
in echo mode (`TestAutobahnEchoServer`, test-only). Excluded: 12.\*, 13.\*
(permessage-deflate is not negotiated).

| Result | Cases |
|---|---|
| OK | 256 |
| INFORMATIONAL (7.1.6, 7.13.1, 7.13.2) | 3 |
| NON-STRICT (6.4.3, 6.4.4) | 2 |
| FAILED (9.1.2-9.1.6, 9.2.2-9.2.6, 9.3.x, 9.4.x, 9.5.x, 9.6.x) | 40 |
| **Total** | 301 |

- Sections 1-7 and 10: all OK, apart from the two NON-STRICT cases. These
  check fail-fast UTF-8 *inside* one frame that arrives in pieces. The parser
  checks UTF-8 at frame boundaries, so it rejects the bad input with 1007
  once the frame is complete.
- All 40 FAILED cases send a message larger than 64 KiB. The server closes
  them with 1009, which is the intended behaviour. The sync socket only
  pushes from server to client, so its inbound bound is 64 KiB. 9.1.1/9.2.1
  (64 KiB), 9.7.x and 9.8.x pass.

Reproduce: start dockerd, then
`VERITRA_AUTOBAHN_LISTEN=127.0.0.1:9001 go test -run TestAutobahnEchoServer -timeout 0 ./internal/realtime`,
and `docker run --rm --network host -v $DIR:/autobahn crossbario/autobahn-testsuite wstest -m fuzzingclient -s /autobahn/fuzzingclient.json`
with servers `ws://127.0.0.1:9001` and `exclude-cases: ["12.*","13.*"]`.
Reports were not committed.

## In-repo protocol tests

`TestRFC6455Conformance` runs 100 cases over real TCP, grouped like
Autobahn sections 1-7 and 9 plus a masking case. It runs on every `go test`.

## Fuzzing (`go test -fuzz=<T> -fuzztime=30s ./internal/realtime`)

| Target | Execs | Result |
|---|---|---|
| FuzzFrameReader (raw bytes, invariants) | 870k | PASS |
| FuzzFragmentation (structured frames vs reference model) | 526k | PASS |
| FuzzControlFrame (opcode 0x8-0xf, FIN, payload) | 30k (most of the 30 s spent minimizing new inputs) | PASS |
| FuzzUTF8Prefix (incremental vs `utf8.Valid`) | 1.06M | PASS |

No crashers were found, so `testdata/fuzz` was not added.
