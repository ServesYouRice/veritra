# C7 full mode against a real server (2026-11-21)

What ran: `scripts/test-c7-e2e.sh` (with `VERITRA_CRYPTO_LIBRARY` set to the
already built crypto library), which builds `server/cmd/messenger-server`,
starts it with `PRIVATE_MESSENGER_C7_HISTORY=1` and runs
`mobile/test/c7_e2e_test.dart`: three real app states (`AppState`,
`NativeCryptoService`, real OpenMLS, WebSocket sync) on one machine, Linux
x64, commit on branch `c5-c6-c7`.

Flow, run twice (full history, then the control with members from join):

1. The instance owner makes a community (C0 shared group); Carol joins
   through a community invitation link the owner approves.
2. The owner creates an open channel with the history setting; the record
   comes back in sync order and Carol's device holds the same setting.
3. The owner posts twice in the channel; the app sends two-part bodies
   (the server's switch reached it: `c7SealedBodies` is true).
4. Bob joins the same way, after the posts.
   - Full: Bob's device takes its `history_sync`, imports the channel's
     history from the server and shows both posts, each row naming the
     generation that sealed it (`c7Gen`), routed to the channel.
   - Control: after the same work passes Bob has neither post (MLS
     withholding and random body keys).
5. The owner removes Carol; the group moves to a new epoch; the owner posts
   again. Bob receives it; Carol's device, which kept every earlier post,
   never has it.

Result: both runs pass (about 9 s and 16 s), and passed again through the
script. Not covered here: "Load earlier posts" paging past the first page,
a channel switched on after posts already exist, private channels' own
groups (covered with real OpenMLS but a fake server in
`c7_full_native_test.dart` and `c3_channel_move_native_test.dart`), and
real devices (G24).
