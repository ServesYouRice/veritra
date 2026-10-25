# Issues this plan fixes

## pm_crypto_buffer_free zeroing is an eliminable dead store and intermediate plaintext copies are never wiped

medium · accepted · C-cce3cb6047a3

The header promises that freeing zeroes buffer contents. The implementation has three gaps:
- buffer_free writes zeros with a plain fill(0) and then drops the Box immediately. Ordinary stores to memory that is deallocated right afterwards are eligible for dead-store elimination, because rustc marks the global deallocator as a free function for LLVM. The wipe can therefore vanish in optimized builds.
- output() calls into_boxed_slice(), which reallocates whenever capacity exceeds length. The original buffer, holding plaintext, signatures or sealed state, is freed without being wiped.
- Error paths drop plaintext Vecs without wiping them, for example when output() rejects its target after a successful decryption.

## Identical plaintext and ciphertext limits can prevent message round trips

medium · accepted · C-9ec35734298f

The FFI applies the same size ceiling to plaintext and serialized MLS ciphertext, although encryption requires authentication and framing overhead. Encryption also returns its output without checking that it fits the decrypt-side ceiling. Consequently, a successful encryption near the plaintext limit can produce ciphertext that this ABI refuses to decrypt. The exact failing boundary depends on the unsupplied MlsDevice implementation and its additional limits.

## Duplicate device identities can make revocation remove only one active leaf

high · accepted · C-b99d39c26015

The wrapper does not enforce uniqueness of the account/device credential across additions or the existing roster. Distinct signing keys can carry identical BasicCredential identities. However, member_index selects only the first matching leaf, and stage_membership_commit resolves each requested device removal through that single-result lookup. If duplicate identities enter a group, successfully removing a logical device can leave another leaf for that same device active.

## process_commit merges incoming commits without validating added or updated credentials or authorizing the committer

high · accepted · C-18f27e622c55

`process_commit` processes any valid commit and merges it immediately. It never inspects the staged commit first: not the add proposals and their credentials, not the update-path leaf nodes, not the removals, and not the committer. OpenMLS leaves credential validation to the application and exposes the staged commit's proposals and credentials for that purpose. Because the merge happens inside this function, callers cannot add validation afterwards. Sender attribution in `decrypt` then relies on whatever credentials were merged.

## join_group accepts any Welcome with the expected group id without validating the inviter or the members in the tree

high · accepted · C-af8e480d909e

`join_group` accepts any Welcome that decrypts with a local key package and carries the expected group id. It does not check who sent the Welcome. It does not validate the credentials or signature keys of the members in the ratchet tree, which arrives in the Welcome because the ratchet-tree extension is enabled. It does not compare the membership with the expected conversation participants. Key packages are published through the server, so the server can create its own group with the expected id, fill it with leaves claiming arbitrary identities, and add the victim.

## sign_enrollment_challenge signs raw caller bytes with the MLS identity key, creating a cross-protocol signing oracle

high · accepted · C-c53e50865a2d

The public method `MlsDevice::sign_enrollment_challenge` passes the challenge straight to the same Ed25519 `SignatureKeyPair` that signs this device's MLS LeafNode, KeyPackage and FramedContent structures. The only check is that the challenge is non-empty. The doc comment puts domain separation on the server, but elsewhere the module treats the server as untrusted. OpenMLS produces MLS signatures by serializing `SignContent` (a varint-length-prefixed label "MLS 1.0 <Label>" followed by the content) and signing those bytes with pure Ed25519. Whoever controls the challenge can therefore get a valid MLS signature over any MLS structure they choose. `create_enrollment_credential` adds a prefix, so it is safe, but the raw signer stays public, and the tests call it directly with an arbitrary challenge.

## A removed device can keep injecting authentic-looking messages through the two retained past epochs

medium · accepted · C-9ed73a4277a3

`max_past_epochs(2)` keeps the message secrets of the two previous epochs. `decrypt()` returns plaintext for any application message whose sender credential matches the label. It does not expose the message's epoch or check whether the sender is still in the current membership. A device removed at epoch N still holds its epoch-N group state and signing key, so it can keep creating new, validly signed application messages under epoch N (and N-1) by simply not processing the removal commit. Remaining members accept those messages until two more epochs pass.

## v1 state from the previous OpenMLS release is rejected with the same error as corruption

medium · accepted · C-751a4fa4641d

State sealed by builds on OpenMLS 0.8.1 (format version 1) is deliberately rejected and there is no migration. The rejection returns MlsError::InvalidState, the same error used for tampering, a wrong key, or corruption. The platform cannot tell 'state from an older app version' apart from 'corrupt or attacked state', so it cannot pick a safe recovery path such as a re-provision or rejoin flow with an explanation to the user.

## Device-link SAS is derived from only 32 bits of the transcript hash

medium · accepted · C-6ca77c23d72e

The documentation says the SAS is formatted from the first four bytes of the transcript hash. The peer signing key and link nonce are supplied in-band. Unless the protocol commits to keys before revealing the nonce, or delivers the nonce out of band, an active MITM can substitute keys toward both devices. It can then grind its own Ed25519 keys offline until both sides display the same SAS. With only 32 bits, this collision search is cheap.

## The 8-digit device-link SAS has no commitment step and can be ground if its inputs are visible to a relay

high · accepted · C-7ad8f79b06fc

The device-link SAS is 8 decimal digits, about 26.6 bits, taken from the first 4 bytes of SHA-256 modulo 1e8. Every transcript input is supplied by the caller, and this code has no commit-then-reveal step. Suppose the nonce and peer keys pass through a channel a man-in-the-middle can see before the SAS is displayed. The attacker picks the key shown to each side, so it only needs the two transcripts' 8-digit values to collide. By the birthday bound that takes roughly 10^4 key generations per side. The code itself notes, for the conversation number, that short values can be ground.

## Push events reach the Flutter EventSink from FCM background threads

high · accepted · C-6e5ce2fcc71e

PushEventBridge.emit calls EventChannel.EventSink.success on whichever thread calls it. It does not hop to the main thread. VeritraFirebaseMessagingService.onMessageReceived reaches emit through markWake, and onNewToken calls emit directly. Both callbacks run on Firebase's background executor. Flutter's Android embedding requires platform-to-Dart channel sends to run on the main thread: FlutterJNI.dispatchPlatformMessage throws RuntimeException ('Methods marked with @UiThread must be executed on the main thread') when called off the main looper. Whenever the Dart side is subscribed (sink is non-null), each FCM wake or token refresh would therefore throw on the FCM worker thread.

## Endpoint rotations are discarded when Flutter is not listening

high · accepted · C-756306a5d202

Both endpoint callbacks only emit an in-memory event. When Android starts a messaging service without a Flutter engine/listener, the nullable sink silently discards the replacement endpoint and its keys. Unlike wake events, endpoint updates have no durable pending record or background delivery mechanism in the supplied implementation. A later foreground registration may recover, but cannot maintain delivery while the app remains closed.

## Unregister does not invalidate pending registration callbacks

medium · accepted · C-b1f6f8510281

The unregister branch neither invalidates registration attempts nor clears the current registration configuration. A previously started distributor-selection callback can subsequently register its captured instance again. A late FCM failure can also enter the still-configured UnifiedPush fallback. Consequently, successful unregister does not establish a stable unregistered state.

## Automatic redirects can disclose custom authentication headers

high · accepted · C-1b5121723ad0

These requests leave HttpClientRequest.followRedirects enabled by default. Dart forwards custom headers during redirects; its protection for standard Authorization headers does not protect these custom credentials. A cross-origin redirect can therefore disclose a recovery token or device-link claim token before this code examines the final response.

## Failed call setup leaves microphone, camera, and peer resources running

high · accepted · C-37dd3ba13da5

start() and answer() acquire live media before several fallible operations, but have no failure cleanup. If SDP processing, encryption, or signaling fails, the stream and peer connection are never inserted into _calls and are therefore also missed by service disposal. _createConnection similarly lacks cleanup when media acquisition or addTrack fails after peer creation.

## Local ICE candidates are dropped because onIceCandidate is installed after a network round trip

high · accepted · C-14f86bd63da2

ICE gathering starts when setLocalDescription is called (line 69 for the caller, line 103 for the callee). onIceCandidate is only assigned later, in _installCallbacks. On the caller that happens after the encryption FFI call and api.createCall. On the callee it happens after encryption and api.transitionCall. flutter_webrtc passes candidate events to whatever Dart callback is set when the event arrives, and drops them while the callback is null. Nothing buffers candidates in the meantime. The SDP that is sent comes from createOffer/createAnswer before gathering, so it contains no candidates. As a result, host and server-reflexive candidates, and often relay candidates, are never signalled.

## Callee loses the caller's remote tracks: onTrack is installed after setRemoteDescription and broadcast events have no listener

high · accepted · C-37a5491e2382

With unified plan, track events fire as a result of setRemoteDescription(offer). In answer(), the remote description is applied at line 99, but onTrack is not assigned until line 120. In between are createAnswer, setLocalDescription, encryption and a network transition, so the caller's track events are discarded. Even with the callback in place, remoteStreams is a broadcast StreamController. Broadcast controllers drop events that have no listener, and nobody can subscribe before answer() returns. Streams added during _drainEarly are lost the same way. ActiveCall does not expose the current remote streams any other way. The caller side has the same problem if the answer was buffered and drained inside start().

## WebRTC handlers are installed after negotiation events can fire

high · accepted · C-e6be8ab7c222

Both setup paths apply the local description and then await encryption and an HTTP request before installing ICE callbacks. ICE gathering can finish during those awaits, losing candidates. The transmitted SDP is the earlier offer/answer snapshot, not a subsequently gathered local description. The answer path also applies the remote description before installing onTrack, so initial remote-track events can be missed.

## Incoming signals are processed concurrently, out of order, and their errors are unhandled

medium · accepted · C-dc0b7a9d2142

Stream.listen does not await an async handler, so _handleIncoming runs concurrently for back-to-back signals. An 'ice' signal can reach addCandidate while the preceding 'answer' setRemoteDescription is still pending. Ordering against _drainEarly is not preserved either. Errors are not caught anywhere: FormatException, TypeError from casting peer-controlled fields, and native setRemoteDescription or addCandidate failures all escape as unhandled asynchronous errors. The subscription also has no onError. Outbound errors, by contrast, are routed to signalErrors.

## ActiveCall.session can fall back to a stale version; _drainEarly discards the newer pending session

medium · accepted · C-5acd3110b8e4

active.session is overwritten with no version comparison. It takes whichever arrives last: an outbound send's HTTP response (line 212) or a pushed incoming session (line 224). A send response that lands after a newer push sets the version back. Separately, _drainEarly removes and discards the latest pending session. That session was recorded while the call was not yet in _calls, for example caller ICE pushes that arrive during answer()'s transitionCall await. The ActiveCall therefore keeps the older 'updated' session, and the next outbound send uses a stale expectedVersion.

## Both peers write the same per-call version token for every signal, with no retry on conflict

high · accepted · C-af418ecfa1cf

Every signal (answer, each ICE candidate, reject) is sent as a server state transition guarded by the single per-call expectedVersion. enqueueSend only serializes this device's own sends. The remote peer writes the same version at the same time: the caller keeps trickling ICE while the callee answers, and both sides trickle after the answer. When writes overlap, one is rejected as stale. A rejected ICE send is only pushed to signalErrors and is never refreshed and retried, so that candidate is lost for good. answer() and reject() simply throw. reject() removes the pending session before sending its request, so a retry falls back to the original stale session that was passed in.

## Call version handling races remote updates and hang-up

high · accepted · C-99c4615b8705

The outbound queue serializes local ICE sends, but cannot prevent the other participant from advancing the shared version while a request is in flight. Conflicts are reported without reconciliation or retry. A delayed HTTP response can also overwrite a newer incoming session. Additionally, end() bypasses the queue and removes the active call before its terminal transition succeeds, allowing an in-flight ICE send to win the version race and leave the remote call unended.

## end() bypasses the outbound queue and can leave the server-side call open with no way to retry

medium · accepted · C-e64a9a054685

end() sends its 'ended' transition directly instead of through active.enqueueSend. It reads active.session.version while a queued ICE send may be in flight with the same version, which is exactly the race the queue is meant to prevent. If 'ended' is rejected, the call has already been removed from _calls and is disposed in the finally block. A retry with end(callId) then throws StateError unless the caller passes an expectedVersion it has no way to know. Queued ICE sends also keep running after disposal, and their errors are dropped because signalErrors is closed.

## Remote end or reject never tears down the local call; late signals keep refilling the pending maps

medium · accepted · C-d432af9a7400

For an active call, an incoming session update only replaces active.session. _applySignal handles only 'answer' and 'ice', and nothing checks incoming.call.state for terminal states, disposes the ActiveCall, or notifies the UI. For calls that are not in _calls, every late signal re-creates entries in _pendingSessions and _earlySignals. This covers calls already ended or rejected locally and ringing calls the caller cancelled. Those entries are only cleared by dispose().

## TURN is said to be required, but iceTransportPolicy 'all' exposes device IP addresses to peers

medium · accepted · C-9dea2af11aa7

The code says a self-hosted TURN service is required but only checks that the server list is non-empty, so a STUN-only entry passes. It also sets iceTransportPolicy to 'all'. Host (LAN) and server-reflexive (public IP) candidates are therefore sent to the peer, and direct paths are preferred, so any participant who receives a call learns the device's local and public IP addresses. The TURN requirement provides no IP privacy, despite the privacy framing of the transport.

## iOS user notification relies on app execution for a background push

medium · accepted · C-8e1bfa0c1b2f

The only user-visible notification on iOS is a local notification posted from application(_:didReceiveRemoteNotification:fetchCompletionHandler:). It runs only when iOS grants the app background execution for the push. iOS throttles content-available (background) pushes, may delay or drop them under Low Power Mode or budget limits, and never launches an app the user has force-quit. Under those conditions no notification appears at all. If the server instead sends visible alert pushes, this handler posts a second local notification on top of the system one.

## Fixed 30 s timeout bounds the whole streamed attachment/backup upload and does not abort the request

high · accepted · C-833369053b46

uploadEncryptedAttachment and uploadEncryptedBackup stream up to 50 MiB and 100 MiB of ciphertext. They wrap the body transfer (addStream) in the same 30-second Future.timeout used for small JSON calls. addStream completes only after the socket has absorbed the source stream, so the deadline effectively covers the whole body. Finishing in 30 s needs roughly 14 Mbit/s of sustained upstream bandwidth for a 50 MiB attachment and roughly 28 Mbit/s for a 100 MiB backup. A second 30 s timeout then covers request.close(), which includes the server's time to persist the body. Future.timeout only stops waiting. On timeout the HttpClientRequest is neither aborted nor closed, so the upload keeps running in the background with no owner. The caller receives a raw TimeoutException rather than an API error.

## Attachment and backup download streams have no read or idle timeout and can hang forever

medium · accepted · C-82032cb906a6

Once response headers arrive, downloadEncryptedAttachment and recoverEncryptedBackup hand the body to _countBytes. _countBytes iterates the source with no timeout. HttpClient.connectionTimeout only covers connection setup, and HttpClient.idleTimeout only applies to idle keep-alive connections, not to an active response body. A body that stops arriving therefore leaves the returned stream pending indefinitely. _readBounded, used for JSON bodies, does apply a per-event timeout, so the two paths are inconsistent.

## Resumed backup download accepts a 200 full-body response as if it started at the requested offset

medium · accepted · C-74e850bb34c4

recoverEncryptedBackup sends a Range header when startOffset is given, but accepts any 2xx status. It never checks for 206 Partial Content or validates Content-Range against the requested start and end. A server, CDN or proxy that ignores Range answers 200 with the whole object starting at byte 0, and the client returns those bytes as if they began at startOffset. The size bound also assumes the body starts at startOffset. As a result, a full 200 body can be wrongly rejected as too large, or accepted and misplaced.

## Account export pages carry message ciphertext but use the 2 MiB JSON cap with no page shrinking

medium · accepted · C-41b9f9fcc358

exportAccountPage returns pages that keep message bodies as ciphertext, and it accepts limits up to 5000. It still calls _jsonRequest with the default 2 MiB response cap and without _shrinkingPage. The other ciphertext list endpoints raise the cap to 16 MiB and halve the page on overflow, precisely because a single envelope can be up to 1 MiB. Any export page above 2 MiB throws ApiResponseTooLargeException. Retrying the same cursor fails the same way.

## MLS send responses use the smaller ordinary-JSON response cap

medium · accepted · C-53799fc3c6bb

sendMlsMessage decodes an MlsMessage response but does not select the larger ciphertext response allowance used by mlsMessage. If the POST returns the full message payload, a supported large payload exceeds the 2 MiB default after base64 encoding. The client then reports failure after the server may already have accepted the message. The POST response shape requires confirmation from the server handler.

## Logout closes the client before requesting token revocation

high · accepted · C-bfea51179a4d

logout() captures the active client, but _clearLocalSession() closes that client before the remote logout request. If close() closes the request transport, revocation fails even online and its exception is silently swallowed. relinkAfterSyncRecovery() repeats this ordering.

## Successful refreshes can publish data into a replacement session

high · accepted · C-5b288a3a125b

These refreshes capture a session before awaiting network operations but do not validate ownership before publishing successful results. Public refreshes are not serialized through the session-transition queue. If an old request completes after logout or replacement authentication, it can repopulate the shared state with the previous session's data. The conversation refresh additionally prunes composer drafts and persists the resulting projection.

## Failed initial MLS key-package publication has no restart retry

high · accepted · C-63455d7b09c5

Owner creation and registration save the authenticated session before publishing initial key packages. Publication failure exits through _run without undoing the session or recording retryable bootstrap work, and sync startup is skipped. Neither password login nor cold-session restoration invokes initial publication. The other replenishment call occurs only after receiving a Welcome, which a device with no published packages cannot normally receive.

## A failed key-package top-up is never made up, so the published supply shrinks permanently

medium · accepted · C-ceef0153b196

Each Welcome consumes one published key package, and `_replenishKeyPackage` publishes exactly one replacement. On failure the error is swallowed, and the comment says the top-up is retried on the next Welcome. The next Welcome consumes another package and again publishes only one, so the earlier shortfall is never restored. Inside the inspected code, the only other publish path is the initial publish (`_publishInitialMlsKeyPackages`), which by search is called only from session-establishment paths. No path compares the server-side supply with a target.

## A commit refused with 400/403/422 is abandoned and immediately staged again, with no backoff, re-claiming other devices' key packages each time

high · accepted · C-59e3c2b15f1f

On any refused bundle, the flush abandons the commit, sets _mlsReconcileRequested, and starts a catch-up at once. Refused here means 409, 403, 400 or 422. The catch-up runs _reconcileMlsMembership, which claims key packages again and stages the same change. A coordinator acts immediately, and every device acts when coordinatorDeviceId is null. The epoch has not changed, the abandoned bundle no longer counts as pending MLS work, and staged == true triggers _flushMlsOutbox. For 400/403/422 the server refuses for the same reason again, so the loop closes. The 3-minute fallback does not apply to coordinators, and nothing records the refusal.

## MLS local-finalization failures can leave no retry scheduled

medium · accepted · C-77265877a921

Local completion happens outside the send-error catch that records nextAttemptAt. If the server accepts a first-attempt message but local completion fails, the outer worker suppresses the error. A still-queued head with no previous nextAttemptAt is then excluded by the retry scheduler, so no retry timer is created.

## Failed history publication loses its retry work after cursor advancement

medium · accepted · C-83c811af14c1

Received messages are processed and committed before their histories are loaded for publication. If the history read and the immediate catch-path retry both fail, received is discarded when this catch-up exits. The next catch-up starts from the committed cursor and has no retained publication work. An empty successful catch-up therefore cannot repair the missing in-memory messages or history.

## One undecryptable or malformed application message, call signal or control message from any peer stops all sync for the receiving device

high · accepted · C-7992361edae2

When an application envelope or call signal fails to decrypt or parse, it may be tombstoned only if its own expiresAt proves it has expired. Otherwise it throws applicationUndecryptable. A control message failure throws mlsState or mlsControlMalformed. _recoveryFailureFor treats these as durable, saves a SyncRecovery record, and every later catch-up returns early while that record exists. The device's sync stream is global, so one bad event from any member of any conversation blocks all later events for the device. In the visible code the only exits are retry, which hits the same event again, and the destructive relink.

## Unreadable request preferences silently accept cached strangers

medium · accepted · C-326afb1eec5e

Restoration passes grandfather: true whenever a cached snapshot exists. A preference-read or JSON-decoding failure leaves known false, so the fallback accepts every cached DM peer and group, discards declined timestamps, and saves this replacement state. A storage error is therefore treated as permission to bypass existing message-request decisions rather than failing closed.

## A transient or unparseable message-request setting is treated as first run and overwrites the persisted state

medium · accepted · C-38c80a2d6964

_loadRequestState wraps both localStore.loadSetting and jsonDecode in a bare catch (_). Any exception there, such as a transient encrypted-DB read error or a value in an unexpected format, leaves known=false. The code then treats this as first run and immediately calls _saveRequestState, which overwrites the stored accepted peers, accepted groups and declined map. On a normal cold start with a cached snapshot, grandfather is true. Every DM peer and group currently in the list is then accepted, including pending requests from strangers. On the non-grandfather path, all prior acceptances and declines are erased.

## Storage errors from loadSyncRecovery and saveSyncRecovery escape _runOwnedCatchUp, leaving sync stalled with no state change or retry

medium · accepted · C-645e6ca1de57

localStore.loadSyncRecovery() is awaited before the try block. localStore.saveSyncRecovery(recovery) runs inside the catch block. The localStorage recovery path is taken precisely when the store is failing durably, so saving the recovery record to that same store is likely to throw as well. In both cases the exception leaves _runOwnedCatchUp without setting syncError, changing connection status or scheduling _scheduleCatchUpRetry. Callers mostly use unawaited(_catchUpSyncEvents()), so the error also becomes an unhandled async error.

## One failing revocation aborts every other revocation and skips membership reconcile on each catch-up

medium · accepted · C-632a7fff2d69

`_processMlsRevocations` has no per-revocation error handling. An exception from `mlsRevocations`, `createRevocationCommit`, `hasAppliedMlsControlMessage` or `confirmMlsRevocation` for any single revocation stops the loop, so later revocations are neither committed nor confirmed. The catch-up caller awaits it with no try/catch, unlike the reconcile step right after it, which is wrapped and documented as never blocking sync. The exception therefore escapes the catch-up after the page loop and skips `_reconcileMlsMembership`.

## One failing conversation aborts membership reconciliation for every later conversation and re-claims key packages on every catch-up

medium · accepted · C-12cdfebbc237

_reconcileMlsMembership walks all pending changes in one loop with no per-change error handling. Several calls can throw: groupEpoch, claimDeviceKeyPackages (a non-401 4xx) and stageMembershipChange (for example, a claimed key package is invalid). Any such exception aborts the whole pass, and changes later in the list are never reconciled. The caller sets _mlsReconcileRequested = true, so the next catch-up repeats the same pass. Every sync frame triggers a catch-up, and each pass claims the same key packages again before failing at the same point.

## Catch-up refetches whole projections from the server once per sync event, up to 200 times per page

medium · accepted · C-96e64bea2b01

Every non-crypto event calls _refreshProjectionForSyncEvent before it commits. Each device.* event performs two full fetches (devices and conversations). Each conversation.*, membership.* and retention.updated event fetches the whole conversation list, and reactions in the selected chat reload its messages. Bursts of these events are fetched one by one, not coalesced. The T49C batching applies only to received messages.

## Async sync-startup failures bypass session recovery

medium · accepted · C-dd5721de576c

_startSync returns a Future, but restore and authentication callers neither await it nor attach an error handler. It performs fallible asynchronous lease operations before installing the sync owner. Their errors therefore bypass the surrounding restore/_run handlers while the caller reports readiness. Foreground resume only requests the existing owner and does not recreate a missing one.

## restoreFromBackup reports success even when the restored session fails to come up

medium · accepted · C-230aedaedbeb

restoreFromBackup runs service.recover and then calls _tryRestoreSession() inside _runScoped. _tryRestoreSession catches every error itself. It sets lifecycle to recoveryRequired, or returns ready with no session when nothing was stored, or clears the session on a 401. It never rethrows. The _runScoped body therefore always completes normally, succeeded becomes true, and restoreFromBackup returns true with no Ops.restore error. This happens even when the device ends up in recovery mode or signed out. The call does not race the transition queue, because it already runs inside _runScoped's queued action.

## Removing a member updates server membership only; sends are not held until the MLS removal commit lands

medium · accepted · C-113dccfcab87

`removeConversationMember` removes the member server-side, then only flags an asynchronous MLS reconcile. `_sendPayload` blocks only when `mlsConversationFailed` is true. It does not wait for a pending removal commit, so messages sent right after a removal can be encrypted under an epoch the removed member's devices still hold. The doc comment says MLS removal is still pending and the UI must say so, while the code comment claims reconcile handles it; the two disagree. `addConversationMember` is gated on `membershipChangesAvailable`, but removal is not, so builds that lack membership-change support still perform server-side removals.

## Newest-page refresh rewinds backward pagination

medium · accepted · C-56e1224e0b73

_fetchMessages retains previously loaded older envelopes but replaces their pagination cursor with the newest page's nextBefore. This discards the deepest loaded position, including an exhausted null cursor. Subsequent loadOlderMessages calls fetch already-loaded pages again before they can reach additional history.

## Delayed message loads mark conversations read after navigation away

medium · accepted · C-712c22c38d05

The load sends a receipt after asynchronous fetch/history operations without checking whether its conversation remains selected or visible. Navigating from A to B does not cancel A's load. When A completes, markNewestMessageRead checks request eligibility but not selection or foreground visibility, sends the receipt and clears A's unread count even for messages that were never displayed.

## Application outbox storage failures escape unawaited futures

medium · accepted · C-981939d38548

The initial storage read is outside the per-envelope catch, and _flushOutbox() has only try/finally. Its unawaited callers therefore receive an unhandled asynchronous error when that read fails. The retry scheduler independently performs unguarded storage reads and is also launched unawaited. unawaited() does not consume exceptions.

## Account export and manual retry hold the shared session queue, blocking sends and logout

medium · accepted · C-93e3c1d0573d

`_run` and `_runScoped` both execute their bodies through `_enqueueSessionTransition`, so every global and op-scoped action shares one serial queue. `exportAccount` runs its entire paged download inside `_run`: up to 2000 network round trips of 250 items each, with a 256 MiB cap. `retryEnvelope` awaits a full `_flushOutbox()` inside `_runScoped`. While either runs, all other queued work waits, including `_sendPayload`, member changes, blocks, mutes and `logout`. This contradicts the `_sendPayload` and `sendMessageTo` contracts, which say a slow connection never holds the composer. Scoping only separates the busy/error fields, not execution.

## Encrypted backup header (chunk count, plaintext size) is unauthenticated, so trailing chunks can be dropped without detection

high · accepted · C-dfc3a3745b08

The backup file starts with magic, nonce, chunkCount and plaintextSize written in the clear. That header is not part of the AEAD context: each chunk is bound only to 'veritra-backup-v1' plus the recovery token and its chunk index. There is also no final-chunk marker. On restore, _decryptAndRestore takes chunkCount and plaintextSize straight from the unauthenticated header. It checks only that the two values agree with each other, that each chunk decrypts, and that the file ends after chunkCount chunks. Every chunk except the last is exactly 1 MiB. So anyone who can modify the stored blob can truncate it to its first N chunks and rewrite the header to chunkCount=N, plaintextSize=N*1 MiB. All checks then pass, and a truncated prefix goes to localStore.restoreBackup as if it were the complete backup. Attachments are not exposed this way, because their chunk count and size come from the end-to-end-encrypted manifest.

## Range rejection bypasses the stale-prefix retry

medium · accepted · C-0dcee1fa500e

<quotes>
      if (error.statusCode == 416) {
        // The saved prefix is not from this backup any more.
        await sink?.close();
        sink = null;
        await file.delete();
        throw const BackupException(BackupFailureKind.corrupt);
</quotes>
The fresh-download fallback catches only decryption failures. A 416 from the preceding download deletes the saved file and escapes that fallback. An already-complete partial file, or a prefix longer than a different requested backup, therefore causes a valid recovery attempt to fail as corrupt instead of authenticating locally or restarting.

## 'Read receipts off' fails open on keystore errors, and a failed load is memoized

medium · accepted · C-00f109c700c8

Turning read receipts off is a privacy choice, yet any keystore read error makes load() return null. ReceiptPreferences then keeps its default of true and sends receipts. The 'loaded' future is cached with ??=. A transient failure is therefore never retried in that process, for example a first_unlock_this_device item read before first unlock during a background launch, or an Android keystore error. save() swallows write errors, so a user's 'off' choice silently reverts to 'on' at the next launch with no indication.

## Native output buffers are freed twice if the copy in _take throws

medium · accepted · C-9a6399d408f5

Two places own each native output buffer. Once validation passes, _take always frees the buffer in its own finally. The callers (_output, _twoOutputs, createEnrollmentCredential, stageCommit) also free the buffer in their finally blocks unless data has been set to nullptr, and they only do that after _take returns normally. If Uint8List.fromList throws inside _take's try, for example with OutOfMemoryError while copying up to 32 MiB, the following happens in order: _take frees the buffer, the exception skips the caller's nulling step, and the caller's finally calls pm_crypto_buffer_free on the same pointer again.

## 8-digit device-link SAS is only safe with a key commitment that this code does not enforce

medium · accepted · C-47c2548063d1

The device-link SAS takes the first 32 bits of the native transcript hash, reduced modulo 10^8, which gives about 26.6 bits. A string this short resists a man-in-the-middle only if each side is committed to its key material before the other values in the transcript are revealed. Commit-then-reveal, or a nonce that is unknown to the relay, would provide that. The binding hashes a peerSigningKey and linkNonce that arrive from the peer. If an attacker relaying the link can choose the substituted signing keys after seeing the nonce, roughly 2^13–2^14 generated keypairs per side are enough to make both devices show the same 8 digits. Nothing here enforces or documents such a commitment. The modulo also adds a small bias, which is negligible on its own.

## safeAttachmentName leaves bidi, format and C1 control characters, so a sender can spoof the file extension

medium · accepted · C-5560907efa80

The sanitiser says the name is safe to show and to use as a suggested save name. It only removes C0 controls (U+0000-U+001F) and DEL. It keeps C1 controls (U+0080-U+009F), Unicode bidi controls (U+200E/U+200F, U+202A-U+202E, U+2066-U+2069), zero-width and other format characters (Cf), and line or paragraph separators (U+2028/U+2029). The file name comes from the sender and is untrusted. A name such as 'invoice' + U+202E + 'fdp.exe' renders as 'invoiceexe.pdf' in the chat bubble and in the save dialog. The sanitiser also does nothing about characters or names that Windows does not allow (for example ':' '*' '?' '"' '|', trailing dots or spaces, CON or NUL), and the desktop build uses this name too.

## An interrupted attachment decryption leaves plaintext files behind that block every later attempt

medium · accepted · C-bce206bd7e97

decryptFile writes authenticated plaintext to '<destination>.part' and then copies it into the destination file. Cleanup happens only in the Dart catch block. If the process is killed, crashes, or is evicted by the OS during a decryption of up to 48 MiB, the plaintext .part file and/or a partially written destination remain on disk. Nothing in this file cleans up orphans, unlike BackupService._cleanupOrphans. Every later call runs _requireAbsent on both paths and throws 'attachment destination already exists'. If callers derive the destination path deterministically, that attachment can never be opened again. A partially published destination also looks like a normal file to other code. encryptFile has the same gap for its '.attachment-*.ciphertext' temp files.

## Revocation coordinator can make a second revocation commit after draining the first, using stale 'pending' state

medium · accepted · C-a345be8cc270

`_processMlsRevocations` fetches the revocation list once, before any flush. For a pending revocation coordinated by this device, it drains the outbox when the conversation has pending MLS work. If the drain succeeds, it falls through to `createRevocationCommit(revocation)` with the revocation object read before the drain. The comment names the main case: a revocation commit queued before a restart, which the server still reports as 'pending' until delivery. In that case the drain delivers the original commit, `_hasPendingMlsWork` turns false, and the code creates a second revocation commit for a revocation the server has already moved to `commit_submitted`. This is the outcome the comment says would fork the group. The safe path, where the drain is a no-op because another flush is running (single-flight return), hides the problem whenever a flush happens to be in progress.

## Durable non-API MLS outbox failures are retried forever, labeled 'retryable:network', and never surface as paused

medium · accepted · C-b3d3a1103123

`_recordMlsOutboxFailure` treats a failure as terminal only when it is an `ApiException`. A non-API error that `_isTransientSyncError` classifies as non-transient gets `retryable == false`, but `terminal` is still false. Examples are a `FormatException` from `MlsCommitBundle.decode`, which runs inside the send try, and a durable storage error, which the classifier documents as durable. The message is rescheduled with backoff capped at 256 s, recorded with failure class 'retryable:network', and never added to `failed`. `mlsConversationFailed` stays false, so the composer does not report the conversation as paused, while the failing head holds back later control messages and the application messages queued behind them.

## Expiry reload failure can retain stale history without another retry

medium · accepted · C-ab26bddbe8f0

After database deletion, a failed _loadHistory() leaves the previous cached history intact and skips notifyListeners(). The catch only increases a backoff. If the purge removed the final expiring record, nextMessageExpiry() returns null, so that backoff never creates a timer and the failed history refresh is not retried by this path.

## startConversation creates a new MLS group and resets local state even when the server returns an existing DM

medium · accepted · C-c28ca69a0f4c

The code acknowledges that `createConversationDetailed` may return a DM the peer already created. It still unconditionally calls `_setUpConversationGroup`, which claims the members' key packages and calls `mls.initializeConversation` to create a fresh MLS group and send Welcomes. It does this for a conversation that may already have a group created by the peer. The code then prepends the conversation without de-duplicating by id, unlike `createChannel`. It also overwrites `messagesByConversation[conversation.id]` with an empty list, discarding any history already loaded for that id.

## login/createOwner abort before _startSync when a post-authentication step fails, leaving a signed-in app without sync

medium · accepted · C-e15286a4b901

In login and createOwner the session is saved first. MLS activation, key-package publication (owner only), cursor reset and the network refreshes then run sequentially, with _startSync() last. A failure in any of them, such as a transient network error in _refreshConversations or _refreshDevices or a key-package publish failure, makes _run record an error. Because the error is not a 401, the session is kept, but _startSync is never called. _tryRestoreSession tolerates the same refresh failures and still starts sync.

## markPeerVerified records whatever safety number is current instead of the one the user compared

medium · accepted · C-f17197783c6e

`markPeerVerified` takes no proof of what the user checked. It re-derives `conversationSafetyNumber` at the moment of marking and persists that transcript hash as verified. Comparing a code (`safetyCodeMatches`, or showing the number) and recording it are separate asynchronous steps. If the conversation's member devices change in between, the new, never-compared hash is stored as verified. Later `peerVerificationStatus` calls then report `verified` for a device set the user never saw. A search of mobile/lib found no callers of `markPeerVerified` or `safetyCodeMatches`, so the flow may not be wired yet.

## completeCommitBundle reports a fork when sync has already merged the same commit and applied later ones

medium · accepted · C-23490e6e517f

completeCommitBundle requires the group epoch to equal exactly bundle.epoch + 1, and it never checks whether the outbox entry is still unresolved. The own-commit sync path can merge the same commit first and resolve the same outbox key (L2), then apply further commits from other devices. When the worker later calls completeCommitBundle with the item it holds in memory, the group is at E+2 or later. The call throws 'accepted MLS commit does not match the group' although the state is correct. Even with no further commits, the call commits state again and resolves a key that is already resolved.

## A single undecryptable message or unappliable commit blocks the global sync cursor indefinitely

medium · accepted · C-bfa50c29822d

Two kinds of failure roll back and rethrow without recording the event: any native decrypt error other than senderMismatch, and any failure in joinGroup or processCommit. Because no marker is written and the cursor (loaded globally by loadSyncCursor) does not advance, the same event fails on every retry. Some of these failures are permanent: a message from an epoch this device never had (the code relies on server filtering for this, L4), a message whose epoch secrets are gone, a duplicate Welcome, or a corrupted or hostile ciphertext.

## If tray setup fails, close-to-tray stays active with no tray, so closing the window hides the app with no way back

medium · accepted · C-373f4b25415b

start() turns on prevent-close and registers the window listener before it creates the tray icon and menu. If setIcon, setToolTip or setContextMenu throws, startIfSupported catches the error and returns null. The listener stays registered and prevent-close stays on. Closing the window then hides it through onWindowClose, but there is no tray icon to reopen or quit the app, and because startIfSupported returned null, detach and dispose never run.

## Notification previews fail open before privacy settings load

high · accepted · C-57328ff8bca4

<quotes>
  bool _hidePreview = false;
</quotes>
<quotes>
    } catch (_) {
      return null;
    }
</quotes>
Notifications can run before the saved privacy preference is available. A user who previously hid previews therefore temporarily gets the preview-enabled default. A storage read failure leaves that default enabled for the entire run because load() ignores null. The display path can consequently send message text and conversation titles to the operating system despite the saved opt-out.

## In-flight plaintext notifications are not invalidated on detach or session change

medium · accepted · C-dc9f9e1ca73c

<quotes>
  void detach() {
    if (state.onMessagesPublished == _onPublished) {
      state.onMessagesPublished = null;
    }
  }
</quotes>
<quotes>
      await _setup();
      final notification = LocalNotification(title: title, body: body);
      notification.onClick = onClick;
      await notification.show();
</quotes>
handle captures the session and plaintext candidates before asynchronous window and mute checks, but never verifies that the same session is still active before displaying them. detach only prevents future callbacks; it does not invalidate work already running. The notifier also awaits setup after receiving plaintext without a cancellation check. Consequently, notification work can finish after detach or sign-out and disclose the previous session's text. The application's sign-out lifecycle was not supplied.

## Submission combines a stale server origin with subsequently edited credentials

high · accepted · C-d3c99a8b6e41

<quotes>
      case AuthMode.join:
        return widget.state.registerWithInvite(
          raw,
          inviteCode.text.trim(),
          username.text.trim(),
          password.text,
        );
</quotes>
_submit captures the URL before asynchronous preflight but reads the mode and credentials afterward. The form remains editable, and submission does not reject changes to the URL or form during either await. When the authentication mode remains unchanged, credentials entered for a newly selected server are passed to the originally captured server.

## Submit button stays enabled during _submit's pre-flight network probe, allowing duplicate owner/registration/login requests

medium · accepted · C-ced4c32cabe2

The submit button is disabled only by widget.state.busy. _submit performs two awaits before calling the mutating AppState operation: probeSetup, then hasStoredDeviceIdentityForOrigin. Nothing in this file sets a busy or submitting flag during those awaits. If probeSetup does not toggle busy, a second tap starts a second _submit, and both proceed to createOwner, registerWithInvite or login.

## URL controller listener treats caret/selection changes as URL edits, discarding the user's manually chosen auth mode and re-probing

medium · accepted · C-4289e29c97f7

_scheduleSetupProbe is registered with url.addListener. A TextEditingController notifies listeners on every TextEditingValue change, including selection and composing-range changes, not only text changes. Each notification unconditionally sets _modeManuallySelected = false, resets _probeResult to probing, clears setupRequired and schedules a new network probe. When that probe completes, the mode is overwritten with the probe's choice because the manual flag was cleared. _submit has the same effect: with the flag cleared it switches mode and returns without submitting.

## An earlier expiry timer can delete a newly opened attachment

medium · accepted · C-e0f10106d345

<quotes>
  Timer(_openedFileLifetime, () async {
    try {
      if (await file.exists()) await file.delete();
</quotes>
Every open reuses a filename-based path, while earlier timers remain scheduled. A Dart File identifies a pathname, not the original on-disk file. Reopening the same filename replaces the file at that path, so the previous timer deletes the replacement before its own lifetime expires.

## Peer-supplied image bytes are decoded at full intrinsic resolution (no cacheWidth/cacheHeight), enabling a decompression-bomb crash

medium · accepted · C-8c8e2f07b827

AttachmentImageScreen passes decrypted, sender-controlled bytes straight to Image.memory without cacheWidth or cacheHeight and without any pre-check of the declared dimensions. Flutter decodes images at their full declared size, so a small compressed file declaring an enormous pixel count can allocate gigabytes.

## Clipboard image takes precedence over text, so pasting text from Office-style apps attaches an image instead

medium · accepted · C-5609bdb38b8a

readClipboardFiles looks for files first, then an image, and treats the clipboard as text only when both are absent. It never checks whether the clipboard also holds plain text. Many desktop apps put a text format and a bitmap or PDF format on the clipboard for one copy, for example cells copied in Excel or text copied in Word or PowerPoint. In those cases the image branch wins and _PasteFilesAction returns without running the text paste, so the user gets a picture of the copied text instead of the text.

## Bubble Semantics uses excludeSemantics, hiding attachment open actions from assistive technology

medium · accepted · C-00fa66380836

_bubble wraps the whole bubble in Semantics(excludeSemantics: true), which drops all descendant semantics, including the AttachmentTile tap targets. Attachment messages also get no onActions, because actions are limited to the text kind. The merged node therefore exposes no action at all for attachment bubbles.

## quotedPreview truncates by UTF-16 code unit and can split surrogate pairs, producing malformed text

medium · accepted · C-0ff652cccde9

text.substring(0, 80) cuts at a UTF-16 code-unit index. When code units 80/81 form a surrogate pair (emoji or other astral characters), the result ends with a lone high surrogate. Flutter's paragraph builder rejects strings that are not well-formed UTF-16, and grapheme clusters such as ZWJ emoji sequences are split visibly either way.

## Search jumping accesses a detached scroll controller after awaiting a frame

medium · accepted · C-2021946beec4

<quotes>
              scroll.position.maxScrollExtent == position.maxScrollExtent) {
</quotes>
The screen can be disposed during the frame await. The continuation then accesses scroll.position without rechecking mounted or scroll.hasClients. The check at the beginning of the loop cannot protect accesses after this asynchronous boundary.

## Attachment removed from the tray during an in-flight send is still sent

medium · accepted · C-14e274a4a518

sendPendingAttachments takes a snapshot of the tray once with `tray.items`, which returns an unmodifiable copy. It then awaits one encrypted send per item. During that loop the AttachmentTray chips keep an active delete action, and remove() takes the item off the live list and deletes temporary copies. The loop never checks whether an item is still in the tray before sending it. A file the user removed mid-send is therefore still encrypted and sent. For a pasted image, the file is deleted underneath the pending send, which then fails or races with the read. The same applies to clear() during a send. Nothing in this file stops sendPendingAttachments from running twice at once, which would send duplicates.

## Removing a queued attachment does not remove it from the send batch

medium · accepted · C-dbd2a70149d7

Sending iterates a copied list and never checks whether later items remain queued. The tray exposes removal without a sending guard. Unless an omitted caller freezes the tray, removing a later file while an earlier upload is pending only changes the live tray: the removed file is still sent from the snapshot.

## Pasted images are written as plaintext to a fixed folder in the platform temp directory, which is not private on desktop

medium · accepted · C-d4bccb3c0fef

writePastedImage is documented as writing to a 'private cache file'. It actually uses getTemporaryDirectory() with a fixed, predictable subfolder `veritra-paste`, creates it with `create(recursive: true)`, which silently accepts a pre-existing directory, and writes the plaintext image with default permissions. On desktop targets getTemporaryDirectory resolves to the system or user temp directory, not an app-private sandbox. On Linux this is typically the shared /tmp. There, another local user can pre-create the folder they own, or simply read files created under a permissive umask. purgePastedImages also deletes the whole shared folder at startup. A second app instance would therefore delete another instance's pending pastes.

## Emoji grid buttons lose their screen-reader activation action

medium · accepted · C-31550ebf3656

excludeSemantics removes the descendant InkWell's semantics, including its tap action. The replacement Semantics node supplies a label and button flag but no onTap action, so accessibility services receive an announced button that they cannot activate.

## QR scan shows 'codes match, verified' even when saving the verification failed

medium · accepted · C-8e4489dc32ba

_saveVerification catches any exception from markPeerVerified, shows safetySaveFailed, and returns normally. The caller cannot tell whether the save worked. After a matching scan, _scan awaits _saveVerification and then always shows safetyCodesMatchVerified.

## Completing verification after navigation calls setState on a disposed screen

medium · accepted · C-3334ccfbc562

After the asynchronous save completes, _saveVerification calls _load regardless of mounted state. _load immediately calls setState before its try block or mounted check. Navigating away during saving therefore causes an unhandled post-disposal exception.

## Peer verification is saved without binding it to the safety number the user actually compared

high · accepted · C-90c7439c999f

The screen loads the safety number once, through initState and _load. It never re-reads the number while it is open. Unlike the other screens, it does not listen to AppState. The manual path (_markVerified then _saveVerification) and the scan path (_scan then _saveVerification) both call markPeerVerified(conversationId, peer). Neither passes the displayed or scanned safety number. The scan path also checks the code with safetyCodeMatches and then saves with a separate markPeerVerified call. So whatever gets recorded as verified is computed from the group state at save time, not from the digits or QR the user compared. If a device joins, leaves or rotates its signing key between display or comparison and the save, the verification can be stored for a group composition the user never checked.

## Safety-number verification status stays stale while the screen is open

medium · accepted · C-bf77cea348f6

The screen caches the number and verification status on entry and after saving, but never subscribes to AppState or MLS changes. A fingerprint change while this route remains mounted therefore leaves the old number and previously verified status visible.

## Tapping an account result has no in-flight guard, so repeated taps start concurrent DMs and push multiple chats

medium · accepted · C-ebfb2c1c733e

Each tap on an account row runs an async closure that calls startConversation(kind: 'dm') and then pushes a ChatScreen. The row stays enabled and nothing tracks a pending request. Two quick taps run two concurrent startConversation calls. The code relies on startConversation reusing an existing DM, but two concurrent calls can both miss it before either completes. Each completion also pushes its own ChatScreen route.

## Admin accounts and audit tabs share one error field and loaded flags, so a failed audit-log load can render as an empty log

medium · accepted · C-a2d2bd170caa

Both tabs read the single _error field. _fail always sets both _accountsLoaded and _eventsLoaded. _loadAccounts clears _error when it starts, but _loadEvents never clears it. Sequence: an audit-events load fails, so _error is set and _eventsLoaded is true with no events. The admin then refreshes the Accounts tab, which clears _error. The audit tab now meets the empty-state condition and shows 'no events' instead of an error. Two other effects follow. An accounts error is shown on the audit tab. A successful audit refresh leaves a stale error banner above the fresh list.

## One-time backup recovery code is silently discarded if the Backup screen is left while the backup is being created

high · accepted · C-eb466f2fe855

_create awaits widget.state.createBackup() and then returns early when the BuildContext is no longer mounted. The recovery code is returned only to this widget and is never stored anywhere else. The file's own comments say the code is shown only once and is not kept by the app. A new backup also replaces the previous one, so the previous recovery code stops working. While createBackup runs, only the Make backup button is disabled. The AppBar back button and the system back gesture are still active. If the user leaves the screen, the backup operation in AppState finishes, but its recovery code is dropped without being shown.

## Recovery-code dialog can be dismissed by system back despite barrierDismissible: false

medium · accepted · C-35eb50726f57

barrierDismissible: false only blocks taps on the modal barrier. The Android back button or predictive back gesture still pops the dialog route, because no PopScope or WillPopScope is present. This dialog is the only place the one-time recovery code appears. The design clearly expects the user to leave through the explicit 'saved it' button.

## Reset can delete a database key that could not be archived

high · accepted · C-8c721a61e1e3

_completeReset conflates a failed key read with an absent key. It then moves the database files and deletes the original key even though no archival key was written. If the read failure was temporary and deletion succeeds, the quarantined database becomes permanently unreadable.

## Quarantine reset bypasses profile ownership locks

high · accepted · C-ceddc40fc135

The public quarantine method closes only its own cached database and runs reset without acquiring the ownership locks used by database opening. An instance rejected because another process owns the profile can therefore still initiate reset and rename that owner's database files. The same path is not serialized against concurrent opens in its own process.

## Legacy import drops envelope expiry metadata

medium · accepted · C-4876869de390

importLegacy() inserts envelope JSON without populating expiresAt and never backfills or purges imported expiry metadata. Imported envelopes containing expires_at therefore receive a NULL expiry column. The expiry scheduler and purge use that column rather than parsing the JSON, so these records escape normal expiration.

## Legacy-record migration failures escape as raw StateError, leak the opened database and block every future open

medium · accepted · C-46d96923b9c2

_migrateLegacyRecord runs after the database opened successfully but outside the error classification in _openDatabaseLocked. Any of the following escapes as a raw error, and the opened database handle is never closed: a corrupt legacy record, a failed verification, or a secure-storage read exception. Because no migration marker is written, every open repeats the same failing migration. The legacy key is also read before the marker check, so a storage read failure blocks opening even after migration has completed.

## exportBackup reads crypto state, cursor and MLS outbox in separate unsynchronized reads, so a backup can be internally inconsistent

medium · accepted · C-6cf318d20291

exportBackup builds the backup from about eight independent awaited reads: session, snapshot, crypto state, sync cursor, outbox, MLS outbox, history and reactions. It does not use a transaction, hold the sync lease or block writers. The MLS state is read before the cursor and the MLS outbox. A commitMlsTransition or commitOutgoingMlsTransition that lands between these reads produces a backup whose cursor or MLS outbox belongs to a newer epoch than its crypto state.

## Backup round trips reset MLS outbox failure state

medium · accepted · C-d21357b2bfa1

The backup encoder omits attemptCount, nextAttemptAt, failureClass and terminal. The decoder reconstructs each MLS outbox item using the constructor defaults, so a terminally failed item becomes nonterminal and scheduled retries lose their backoff. This is deterministic loss of persisted delivery state during backup recovery.

## Destructive replace-backup confirmation is skipped while backup status is unknown or failed to load

medium · accepted · C-30b1c68b9bb0

The replace confirmation is shown only when lastBackupAt is non-null. Backup status is fetched asynchronously after the screen opens. Until that fetch completes, or if it fails, lastBackupAt can be null even though a backup exists on the server. The Make backup button is gated only on Ops.backup being busy, not on the status having loaded. The user can therefore replace an existing backup without the destructive warning, and the old recovery code stops working.

## Invite screen never shows revoke or load failures, and does not itself trigger the first fetch

medium · accepted · C-640873b76c05

Only invite creation reports an error, through a SnackBar. revokeInvite's result is ignored, and build has no error rendering for refresh or revoke failures. The State has no initState that calls refreshInvites, unlike the Blocked and Backup screens. The spinner depends entirely on invitesLoaded becoming true elsewhere. If the initial fetch is never started, or fails without setting invitesLoaded, the screen can show a spinner indefinitely with no error.

## Push status row reports notifications as active while OS permission is still notDetermined

medium · accepted · C-cf7ad5b01608

_PushStatusRow treats only NotificationPermission.denied as blocking. When pushState is registered and the permission is NotificationPermission.notDetermined, it shows the 'active' title and detail, sets warn = false, and uses the verified (green) tint. notDetermined is the state in which the same screen offers 'Allow notifications'. The class's own contract says the row must never imply that push works when it does not, and this branch violates it.

## snippetFor slices by UTF-16 code unit and can emit unpaired surrogates (emoji split at excerpt edges)

medium · accepted · C-467758018250

The fallback snippet builder works in UTF-16 code-unit offsets and never checks code-point boundaries. It computes the window start as first - radius and the end as start + 2 * radius, then copies code units one at a time with flat[index]. In the branch where lower-casing changes the length, it truncates with flat.substring(0, 2 * radius). If any of these boundaries falls between the high and low surrogate of an astral character, the snippet starts with a lone low surrogate or ends with a lone high surrogate. Astral characters include emoji and supplementary CJK. The FTS5 snippet path is token/byte based and does not do this, so the two paths behave differently.

## Realtime WebSocket sets no pingInterval, so half-open connections are never detected or reconnected

medium · accepted · C-f46ccc7b6cfb

After the handshake the socket is listened to, and reconnect happens only when onDone or onError fires. The client never sends data and never sets socket.pingInterval, so dart:io performs no liveness checking. On mobile, a network handover, NAT timeout or radio sleep commonly leaves the TCP connection half-open. No FIN or RST ever arrives, so done.future never completes and the reconnect loop stays parked.

## Recovery actions become unreachable when recovery content exceeds screen height

medium · accepted · C-5761c9101eac

The recovery screen places its explanation and actions in a vertically constrained, non-scrollable Column. mainAxisSize.min does not shrink overflowing children. On short viewports or with enlarged text, the content exceeds the available height and lower recovery actions fall outside the reachable viewport.

## NavigationBar indicator recoloured to primary while the selected icon keeps onSecondaryContainer, so the active destination's icon is nearly invisible

medium · accepted · C-d0203a5c2574

navigationBarTheme sets indicatorColor to scheme.primary but does not set iconTheme. Material 3 NavigationBar defaults the selected icon colour to colorScheme.onSecondaryContainer, because the default indicator is secondaryContainer. Here onSecondaryContainer is the text colour, and primary is the accent. In dark mode the selected icon is darkText #f3effa on darkAccent #ede4da, about 1.1:1 by the WCAG formula. In light mode it is lightText #1a1620 on lightAccent #3a2e42, about 1.4:1. Both are far below the 3:1 non-text minimum. labelTextStyle is also forced to labelSmall for every state, which is the muted micro style. The selected label therefore has the same colour as unselected labels, and the only selection cue is an indicator pill whose icon cannot be seen.

## Stale account lookups remain selectable after editing or clearing the field

medium · accepted · C-d7ada6331c19

<quotes>
    final query = value.trim();
    final generation = ++_lookupGeneration;
</quotes>
<quotes>
      controller.clear();
      matches = &lt;SelectedAccount&gt;[];
      searched = false;
</quotes>
Editing the field neither invalidates the current request nor clears existing results. The generation advances only after the debounce expires, so an older response arriving during that interval passes the generation check. Selecting an account also leaves pending timers and requests valid; controller.clear() does not invoke TextField.onChanged. Consequently, obsolete results can remain visible or reappear after selection and remain tappable.

## Device-link SAS check feeds the owner side the new device's signing key locally instead of via the server

medium · accepted · C-6a48cf4db1ed

In the device-link flow, the claiming device derives its verification from server-relayed data (linkReservation.existingSigningKey). The existing (owner) device instead derives its verification with peerSigningKey taken directly from the in-process linkedNative object. The link is fetched from the server only before the claim. The test never exercises the route or model through which the existing device would learn the claimant's signing key after the claim, so the SAS comparison cannot detect the server relaying a wrong or substituted key. The claimant's verification is also derived twice with identical arguments (lines 396-402 and 404-410). This is redundant, and it would silently diverge if derivation were ever non-deterministic.

## Claiming-device transcript binding is not exercised and fake server checks are permissive

medium · accepted · C-9d12bb2740ea

On the claimer side, the fakes accept anything:
- completeDeviceLinkClaim ignores expectedTranscriptHash and always returns a session.
- claimDeviceLink ignores the DeviceLinkVerification argument.
- approveDeviceLink checks only the hash length and its first byte.
The fail-closed mutation loop (lines 288-314) covers only the owner's refresh path. No test makes the claiming device reject a mismatched transcript, nonce or account. The test 'app state drives device link claim through approval' never performs or checks an approval.

## Device-link SAS tests cannot tell a locally derived code from a server-supplied one

medium · accepted · C-f5d9ee939df9

FakeDeviceLinkApiClient._link builds DeviceLink objects directly, bypassing fromJson, which the suite shows discards server codes. It sets verificationCode to '65432101' for every non-pending link. That is the same value the tests expect to be displayed and the value the user types to approve. So the refresh assertions (lines 249, 272, 301) and the claimer assertion (line 176) pass whether AppState derives the SAS from the verified transcript or passes through the server-provided field. Only the create and approve responses are tested with a dishonest server code.

## Crypto-state rollback test never tries a lower counter or checks the crypto state survived

medium · accepted · C-f8e6ff6e8ea0

The test 'crypto state and cursor commit together and reject rollback' only tries to save a state with the same counter (4) as the stored one. It never tries a strictly lower counter, which is an actual rollback. After the rejected save it re-checks only the sync cursor. It never checks that loadCryptoState() still returns the original state (counter 4, stateKey of 7s, sealedState [1,2,3]). Two faulty implementations would pass: one that rejects only equal counters, and one that writes the crypto state before throwing on the cursor.

## Account-export check for auth_secret leakage cannot fail because no push subscription ever exists

medium · accepted · C-2d744a17c672

The live contract test checks that the account export does not contain 'auth_secret'. Immediately before that, it asserts that the contract server refuses web-push registration with push_provider_unavailable. No push subscription is ever created, so the export has no record that could carry a Web Push auth secret. The negative assertion is therefore vacuous. It would still pass if the export serializer included raw push subscription secrets.

## No Dart-level test would detect chunk-index/nonce reuse, chunk reordering, or key/nonce-prefix reuse in chunked AES-GCM

medium · accepted · C-2bab92568f72

AttachmentCryptoService computes the chunkIndex it passes to the native bindings for each chunk. The real-native tests check only four things: round-trip equality, a single-byte flip at the very end of a single-chunk (100-byte) ciphertext, and truncation/extension/header changes of a 5-byte single-chunk ciphertext. Suppose the Dart service passed the same chunkIndex for every chunk, or reused the key or nonce_prefix across attachments. Encryption and decryption would agree, so every existing test would still pass. No test does any of the following: swap, duplicate or reorder full chunk frames of a multi-chunk ciphertext; record the chunk indices sent to the bindings (the _CancellingBindings spy forwards chunkIndex without recording it); or assert that two encryptions produce different key and nonce_prefix values. Native library tests cannot catch a Dart-side index bug because the index is supplied by Dart.

## All real-native attachment crypto tests and every backup restore test are skipped unless VERITRA_CRYPTO_LIBRARY is set

medium · accepted · C-45efd070bbb4

Each test in the 'real native attachment crypto pipeline' group is skipped when the VERITRA_CRYPTO_LIBRARY environment variable is absent. That group covers the round-trip, tamper, wrong key/conversation/action, manifest bounds, truncation/extension/header framing, cancellation cleanup and pre-existing file preservation tests. Every test in backup_service_test.dart is skipped under the same condition: create/restore, wrong code, damaged, truncated, not found, interrupted resume and device-not-empty. flutter test reports a skip as a non-failure. A CI job that does not build the native library and export the variable therefore stays green without exercising any authenticated-encryption, fail-closed framing, partial-file cleanup or restore behaviour. Only the _DummyBindings validation tests and the fake-crypto AppState tests run unconditionally.

## loadAttachment stages decrypted attachment plaintext in a file despite the test claiming in-memory decryption; failure-path cleanup is untested

medium · accepted · C-44e6c3864448

The fake decryptFile writes the plaintext 'hello' to destinationPath. AppState.loadAttachment then returns exactly those bytes, so loadAttachment must read the decrypted plaintext back from a file it created in the attachment working directory. The decryption therefore is not done in memory, despite the test title. The tests check cleanup in only two cases, the happy path and a size mismatch detected before decryption, and in both they look only for names containing '.veritra-'. No test covers decryptFile throwing after it has written or partially written the destination, cancellation, or stale files left by a crash or kill between decryption and deletion.

## Removed-member check reads Bob's store once and can pass before Bob's sync has caught up

medium · accepted · C-7edd601be887

After removing Bob, the test waits only for Carol and the owner to receive 'without bob'. It then reads Bob's local store once and asserts the message is absent. Bob's client is still running its own sync. Nothing proves Bob has processed everything up to that point: no wait for his removal to apply, no epoch or membership check, and no later marker message. The file itself documents that the shared per-address rate limit can refuse catch-ups, with retries up to a minute later. If removal enforcement regressed so Bob could still decrypt, 'without bob' could reach his store after the assertion and the test would still pass.

## Unreadable-mute notification case likely passes vacuously because envelope m2 has no local message

medium · accepted · C-7b8723ba333f

The test 'a muted chat stays quiet, and so does one whose mute is unreadable' seeds history with a LocalMessage for 'm1' only. It then exercises the unreadable-mute branch with envelope 'm2', which has no matching LocalMessage. Elsewhere in this file, every envelope expected to reach the mute check has a matching LocalMessage. The notifier needs it for the title and body, the kind, and the own-message checks. The skipped-messages test also asserts that muteReads stays 0 for envelopes the notifier drops early. Without a LocalMessage for 'm2', MessageNotifier very likely drops it before calling loadConversationMuted. In that case expect(notifier.shown, isEmpty) holds no matter how an unreadable mute is handled. The test never asserts muteReads, so it cannot detect that the mute lookup was skipped.

## Session-expiry mute-clearing assertion is vacuous: no mute is saved before the keepDrafts clear

medium · accepted · C-9751eb86eba2

The test saves a mute at line 276 and then calls the sign-out style clearCachedState(preserveOutbox: true) at line 278. After that it asserts only that drafts are empty. It re-saves a draft, but not a mute, before calling clearCachedState(preserveOutbox: true, keepDrafts: true) at line 284, and then asserts that mutes are empty at line 286. This leaves two possibilities, and neither is verified. If the first clear removed the mute, the line-286 assertion passes whatever the keepDrafts path does with mutes. If the first clear did not remove the mute, the sign-out path's failure to clear mutes is never asserted (line 279 checks drafts only). In either case one of the two mute-clearing behaviours the test title claims ('sign-out wipes both', session expiry refetches mutes) has no coverage.

## No coverage for a debounced, unflushed draft edit pending at sign-out or session expiry

medium · accepted · C-72d69e36050f

Draft writes are debounced: the test at line 436 shows nothing is persisted immediately after setText. ComposerDrafts.clear() deliberately does not emit change notifications. The sign-out and session-expiry tests only cover drafts that were already persisted before start() returns. No test types text and then signs out within the debounce window. In that scenario a debounce timer that is not cancelled could write the draft back after the wipe, so the draft survives sign-out. The opposite is also untested: on session expiry, unsaved in-memory edits could be dropped instead of flushed, losing user text.

## MLS rollback test's message check passes when the snapshot or conversation messages are missing

medium · accepted · C-cedf62df65e4

After each injected-failure restart, the test checks messages with a null-aware chain and `isNot(contains('msg_2'))`. In package:matcher, `contains` returns false for any value that is not a String, Iterable or Map, null included. `isNot` therefore passes when `loadSnapshot()` returns null or when `conv_1` has no message list. The test also never asserts that the pre-existing `msg_1` survives. The cursor and crypto-counter checks do not catch this case. Suppose a failed commit deletes or rewrites the conversation's existing envelopes, for example with a delete-then-insert upsert that is not fully rolled back, but leaves the cursor and counter at 1. The test still passes.

## Hard-coded string guard scans one line at a time and misses wrapped literals and common string parameters

medium · accepted · C-5db8c0c83cde

The T44C guard promises that a new hard-coded English string cannot slip back in, but it cannot keep that promise.

1. It runs `_literal` against each line of each file separately. The trigger (`Text`, `tooltip:`, `hintText:` and so on) must sit on the same line as the opening quote. `dart format` routinely writes `Text(` on one line and puts a long literal on the next. Neither line matches, because one has no quote and the other has no trigger keyword. Long user-facing sentences are the literals most likely to be wrapped this way.
2. The trigger list leaves out many common ways to pass user-visible text:
   - String `label:` arguments (NavigationDestination, BottomNavigationBarItem, Semantics).
   - `Tooltip(message:` and `Tab(text:`.
   - `errorText:`, `counterText:`, `prefixText:` and `suffixText:`.
   - `TextSpan(text:`.
   - `SelectableText(`, because `\bText` has no word boundary inside `SelectableText`.
   - Raw strings such as `Text(r'...')`.
   - Named arguments placed before the positional literal.
3. The self-test only checks single-line positive cases, so none of these gaps is covered.

## Message expiry appears to come from server-stamped envelope metadata; the first own echo is trusted without bounds

medium · accepted · C-9aaa958909c8

The tests describe a design in which the server stamps expiry and the client adopts it:
- The receive helper, documented as doing what the native service does, copies the envelope's expiresAt into the stored message.
- The sender's local copy learns its expiry from the server echo.
- Only the first echo is honoured; later echoes cannot move or shorten it.
The test at line 338 states that server listings are not authenticated. No test shows the stamped expiry being checked against an authenticated value, such as a timer carried in the MLS plaintext or group context, or bounded below by createdAt plus the conversation's configured timer. A server can therefore choose a past or near-immediate expiry on the first echo and delete the sender's own copy. For received messages, a past expiry means the message is consumed (MLS state and cursor advance) but never stored. Messages a server can shorten this way contradict the property tested at line 332, that a server cannot erase history.

## Attachment manifest-binding assertions run while the conversation is still a request, so the manifest check is never exercised

medium · accepted · C-7a39b59b924a

All three loadAttachment assertions run while 'new' is still in RequestBucket.request. The first assertion uses a manifest whose conversation matches ('new') and still expects a StateError. So the request gate alone throws StateError for this conversation. The next two assertions (manifest naming 'other', and an empty manifest) expect the same StateError type. They therefore pass whether or not loadAttachment checks the manifest's conversation_id against the caller's conversation. The comment states the manifest binding is what is under test, but nothing exercises it. After acceptance at line 223 no attachment assertion is repeated, so the manifest check is never tested on a non-request conversation.

## Schema 11 upgrade test sets up an attachment row but never checks the backfill excludes it

medium · accepted · C-c7877f034e8d

The upgrade test inserts an attachment message whose body is 'attachment'. After the upgrade it only searches for 'index', which the attachment could never match. It never searches for 'attachment' and never inspects indexedTerms. The migration backfill could therefore index attachment, unverifiable or action bodies, and this test would still pass. Attachment bodies carry key material, as the 'only message text is indexed' test shows. Separately, the schema-11 database is synthesized by stripping v12 search objects from a v12 database rather than loaded from a real v11 fixture, so other v11 differences are not exercised.

## 'Never calls the server' check only watches searchMetadata while other real ApiClient calls go unchecked

medium · accepted · C-d59c93f1bd5c

The privacy property is that message text never reaches the server. The test verifies it only by checking that searchMetadata was not called. _SearchApi extends the real ApiClient and overrides just a few methods. Any other endpoint the search or chat code calls goes through the real implementation unobserved, including sync and push calls made by tryRestoreSession, which the outbox tests have to stub. Inside testWidgets those requests typically get a mocked 400 response instead of failing the test. A regression that sent the query or snippet through any other endpoint would pass.

## Native MLS service tests skip silently in CI when VERITRA_CRYPTO_LIBRARY is unset

medium · accepted · C-528a9f749790

native_crypto_service_test.dart skips all six tests whenever VERITRA_CRYPTO_LIBRARY is unset, and it applies no CI guard. The sibling native_outbox_test.dart deliberately fails when CI=true and the library is missing. The skipped tests are the only ones in scope that run real OpenMLS against forged edits, spoofed senders, stale-ratchet reload after another service advanced the state, device add and remove, and commit races. If the variable goes missing, they report as skipped and the CI run stays green.

## The only native crypto ABI test is silently skipped when VERITRA_CRYPTO_LIBRARY is unset

medium · accepted · C-b053c658e4bb

The FFI lifecycle, sender-binding and sealing test runs only if an environment variable points to a built host library. Otherwise it is skipped and the suite still reports success. Unless a CI job builds the library and sets the variable, the Dart-to-native ABI contract (ownership, sender mismatch, seal and restore) is never exercised.

## Native test does not verify self-update keeps groups in sync or that a removed member loses decryption

medium · accepted · C-68c90ce3f18d

After bob processes alice's self-update, the only check is that decrypting the one-byte garbage ciphertext [1] fails with operationFailed. Malformed input fails like that whether or not the commit was applied, so the assertion does not depend on processCommit at all. After removal, the test checks only that bob cannot encrypt. The security-relevant property is that bob cannot decrypt alice's messages sent after the removal, and that is never tested.

## Commit-race test never delivers the winning commit to the loser, despite its name and comments

medium · accepted · C-1364ac990f6d

The test is titled 'the winner applies cleanly', and its comment says the winning commit arrives before Bob's refusal and is applied. However, _accept is called with an empty members list, so Bob never receives Alice's winning commit. The test then asserts that Bob ends at epoch 1 with no pending commit, while Alice and Carol are at epoch 2. Two production paths are therefore untested: (a) processing a foreign commit while an own staged commit is pending, and (b) applying the winner after abandonCommitBundle. The test actually encodes a forked group as its final expected state. The alicesCommit variable is also misnamed and duplicates an assertion that _accept already makes.

## 'Merges the staged commit once' test never runs the outbox completion that follows the echo

medium · accepted · C-95bafb18f37d

The test models the sync stream delivering Alice's own accepted commit before her outbox worker sees the server's answer. It then stops. The outbox worker would still call completeCommitBundle(item) for the same bundle, and that second step is the 'once' part of the title. The test also never redelivers the echo. A double merge, an exception from merging with no pending commit, or a second epoch advance would all go undetected.

## Device removal is never verified: no epoch check and no check that the removed device cannot read

medium · accepted · C-51e7b8038a93

After staging removal of dev_tablet, the test only checks that Bob can read 'bye'. It has no epoch assertions for the removal, although the add path has them. The tablet is never given the removal commit, and nothing asserts that the tablet cannot decrypt messages sent after removal. Suppose the remove proposal were dropped or ignored while the epoch still advanced. The tablet would process the commit and keep reading, and this test would still pass.

## Database teardown relies on a fixed 300 ms sleep for un-awaited AppState work

medium · accepted · C-8b871e5ee48e

_disposeQuietly disposes AppState and then sleeps 300 ms. It assumes that the outbox and sync bookkeeping 'started without awaiting' has finished by then. Afterwards the callers or tearDown close every EncryptedLocalDatabase and recursively delete the temp directory. Nothing observes when that background work actually completes, so correctness depends on host speed.

## Device-link approval test never checks that a wrong 8-digit code is rejected

medium · accepted · C-047d0c6e1691

The approval test covers two inputs only. It enters 7 digits and expects the button to be disabled. It then enters '12345678', which is exactly the link's verificationCode, and expects one approval. No case enters 8 digits that differ from the verification code. The _ApproveApi fake only counts calls and never sees the typed code. An implementation that validates only the length of the typed code, rather than comparing it with the locally held verification code, would pass this test. The test title, 'exactly 8 typed digits', describes only the length check.

## The '320dp and 200 percent text' test actually lays out at the full 800x600 test surface

medium · accepted · C-c7d631489505

The widget under test is passed directly as MaterialApp.home. Inside MaterialApp, the Navigator/Overlay gives the route page tight constraints equal to the test surface (800x600 by default). SizedBox(width: 320) cannot override tight parent constraints, so the Column is laid out 800 logical pixels wide. MediaQueryData(size: Size(320, 640)) changes only what MediaQuery reports. It does not change layout constraints. The test therefore never builds SectionHeader or StatusPill at 320dp. An overflow that appears only at narrow widths with 2x text would not raise an exception, and takeException() would still return null. The other test in this file sets tester.view.physicalSize, which is the correct technique, but this test does not.

## Tests indicate the production MLS/OpenMLS encryption engine is a stub, and no test exercises a real CryptoService

high · accepted · C-b46338989ea6

describeError is tested against a 'crypto stub' error, StateError('Production MLS/OpenMLS encryption is not integrated'), and maps it to a user-facing 'encryption engine' message. This strongly suggests that the production CryptoService throws this error instead of encrypting. Every AppState in scope is built with TestOnlyCryptoService, which emits fake ciphertext tagged 'test-only-not-production'. The real encryption, enrollment and device-link verification paths therefore have no coverage here.

## Crypto build provenance can record an empty or misleading source revision without failing

medium · accepted · C-258642b314a4

write_metadata gets the revision with `$(git -C "$ROOT" rev-parse HEAD)` inside an `echo` argument. Under `set -eu`, a failing command substitution inside a non-assignment command does not abort the script. When git fails (no .git in an exported or tarball tree, or a dubious-ownership rejection in a container), the script writes `source_revision=` and continues. The Cargo.lock digest has the same weakness: the pipeline's status is awk's, so a failed sha256sum or shasum produces an empty hash. The PowerShell variant never checks `$LASTEXITCODE` after `git` or `rustc`, and `$ErrorActionPreference = "Stop"` does not apply to native exit codes. None of the three scripts checks for uncommitted changes, so a library built from a modified working tree is labelled with the clean HEAD commit.

## Crypto builds can package stale binaries when Cargo uses another target directory

medium · accepted · C-89bed98493c6

Cargo honors CARGO_TARGET_DIR and build.target-dir configuration, but these scripts always collect binaries from the crate's literal target directory. With an alternate target directory, a successful build is followed by either a missing-file failure or, if an earlier binary remains there, successful packaging of that stale binary. The macOS lipo inputs have the same mismatch.

## CI evidence lookup can reject an already verified release commit

medium · accepted · C-7d869dd4cbba

The GitHub query retrieves only the latest 20 completed push runs across the workflow, and commit matching happens afterward. A successful run for the requested SHA outside that window is invisible, so the script reports missing evidence even when qualifying evidence exists.

## Go coverage totals incorrectly count duplicate blocks

medium · accepted · C-c7ac7e429333

<quotes>
            stmts_hit += num_stmts
</quotes>
parse_go_report() counts every row independently. Valid Go coverprofiles can contain repeated source ranges, which standard Go coverage tooling merges before calculating coverage. Two entries for the same one-statement block with counts 1 and 0 produce 50% here instead of 100%. Repeated covered blocks can also disproportionately inflate the aggregate.

## Dart license gate scans the global pub cache rather than resolved dependencies and passes with zero packages

medium · accepted · C-74dbecc1998a

The script enumerates whatever directories exist under `${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev`; it does not read the packages resolved in pubspec.lock. If that directory exists but is empty, or belongs to a different cache from the one the Flutter tool used, the glob matches nothing and the script prints `present: 0 packages` and exits 0. Dependencies resolved from git (`$PUB_CACHE/git`), from other hosted servers or from path sources are never examined. Unrelated stale cache entries are examined, which can cause false failures.

## Native-crypto construction scan misses named constructors and tear-offs, and its exemptions match any path depth

medium · accepted · C-b4f44320e621

The offender scan only matches the literal text `NativeCryptoService(` or `TransportPolicy.demo`. It misses several ways of obtaining the service: named constructors and static accessors (`NativeCryptoService.create()`, `NativeCryptoService.instance`), constructor tear-offs (`NativeCryptoService.new`), whitespace before the parenthesis, typedef aliases, and factory functions or top-level instances declared inside the exempt crypto/native_crypto_service.dart that other files call. The `grep -v` exemptions are suffix matches, so a file named main_demo.dart, crypto/native_crypto_service.dart or core/transport_policy.dart at any depth under mobile/lib is exempt. The scan also covers only mobile/lib, so local path packages are never inspected.

## Go toolchain check never verifies that the pinned image digest is actually golang:${GO_VERSION}

medium · accepted · C-481956b08ea8

When a Dockerfile uses FROM golang:${GO_VERSION}@sha256:..., Docker resolves the image by digest and ignores the tag. The script checks three things: the ARG default equals .go-version, the digest is syntactically a 64-hex sha256, and the wrappers use the same digest. It never checks that the digest belongs to golang:${GO_VERSION}. If someone bumps .go-version, go.mod and the ARG but leaves a stale digest, Docker and wrapper builds keep running the old Go toolchain while setup-go in CI uses the new one, and the script still prints that the toolchain is aligned.

## Dynamic Gradle version scan misses common dynamic forms, covers one file, and fails open if that file is absent

medium · accepted · C-a46c8fe2b8e8

The pattern catches only ':latest', ':release', lowercase ':snapshot' and three-part 'X.Y.Z+' versions. It misses the most common dynamic forms: '1.+', '1.2.+', a bare '+', ranges like '[1.0,2.0)', and uppercase '-SNAPSHOT' suffixes. It scans only mobile/android/app/build.gradle.kts, not other modules, the root build file, plugin versions in settings.gradle.kts, version catalogs or Groovy build.gradle files. If app/build.gradle.kts does not exist, for example in a Groovy-based Flutter project, grep exits with status 2. The `if` treats that as no match, and the script prints that the policy passed.

## Dependency gate misses common mutable Gradle versions

medium · accepted · C-d98e14887245

The filter misses ordinary Gradle selectors such as 1.+, 1.2.+, +, version ranges, and changing versions such as 1.2.3-SNAPSHOT. It also examines only the app's Kotlin build script. The gate can therefore report pinned inputs while accepting mutable dependency declarations.

## Gradle wrapper check accepts any scheme or host and does not require a distribution checksum

medium · accepted · C-a61bf2b85fbb

The wrapper check only requires distributionUrl to contain gradle-<version>-(bin|all).zip. The leading .* accepts any scheme and host, including plain http and arbitrary mirrors. No distributionSha256Sum is required, so the downloaded distribution is not integrity-pinned. gradle-wrapper.properties is also outside the later repository-URL scan, which only reads *.gradle and *.gradle.kts files. gradle-wrapper.jar, executable code committed to the repo, is never validated. The script still reports pinned Gradle inputs.

## release-image.sh reads HEAD again at build time, so the pushed image can differ from the commit that was checked and recorded

medium · accepted · C-1b57b9760118

The script checks for a clean tree once (line 61) and captures COMMIT, TAG and VERSION from HEAD at lines 68-70. It then runs gofmt, go vet, go test, govulncheck and cargo audit against the working tree, which can take minutes. After that it builds the image with `git archive --format=tar HEAD`, which resolves HEAD again instead of using the captured $COMMIT. If HEAD moves during the run (a commit, checkout, rebase or pull in the same worktree), the image is built from a different commit than the one tested. It is still tagged $TAG, labelled COMMIT=$COMMIT, and recorded in the infra commit as coming from $COMMIT. If working-tree files change during the run, the checks also verify code that matches neither commit.

## Server release can build, push and pin any local commit, including unpushed or unreviewed ones

medium · accepted · C-bacac5c1a07c

With no hosted CI, this script is the only server release gate. It checks only that the tree is clean. It never fetches or verifies that HEAD is on the protected default branch, or that the commit exists on the remote. Any local branch or unpushed commit can be built, pushed to ghcr.io and pinned into the infra kustomization. The image still carries `org.opencontainers.image.source` pointing at the public GitHub repository, even though that commit may not exist there. The mobile gate (release-readiness.sh), by contrast, deliberately anchors approvals to the protected default branch.

## minSdkVersion is decoded as unsigned, so negative values pass the Android 7.0 floor

medium · accepted · C-3f7d18a5772e

The attribute's typed data is unpacked as an unsigned 32-bit integer and used directly as minSdkVersion. Android's package parser treats this data as a signed Java int (minVers = val.data). It accepts any minVers no greater than the platform SDK, so negative values are accepted. A minSdkVersion of -1 (0xFFFFFFFF), or any value of 0x80000000 or above, reads here as a value in the billions and passes the floor of 24. Android reads the same value as negative and allows installation on Android 6.0 and earlier. Those releases verify only v1 (JAR) signatures, which this checker deliberately does not read, and the floor exists to exclude them.

## Non-Android attributes can satisfy or overwrite the minimum-SDK check

medium · accepted · C-64b01f0a421d

The name-only alternative treats an unnamespaced or custom-namespaced minSdkVersion as Android's framework attribute. Android ignores that attribute when determining its minimum SDK. A value of 24 can therefore replace the checker's default of 1, or overwrite an actual android:minSdkVersion below 24. Different namespaces and resource IDs also allow both attributes through the duplicate checks.

## Nested uses-sdk elements incorrectly establish the release minimum

medium · accepted · C-f96d62a9b7ca

manifest_facts counts start elements but does not track XML depth or parentage. Consequently, a uses-sdk nested inside application can establish a minimum of 24 even though Android only recognizes uses-sdk as a direct manifest child. With no real manifest-level uses-sdk, Android retains its lower default while this checker returns 24.

## IPA validation accepts zips whose central directory is not where the end record says

medium · accepted · C-b62b63cbd39e

For IPAs, the only layout checks are zip_layout_error and zip_entries_error. zip_layout_error checks that the end record is the last 22 bytes, that it is unique, and that the archive is not ZIP64 or multi-disk. It never checks that cd_offset + cd_size == eocd. For APKs that check exists, but only in apk_signing_block, which ipa_errors never calls. When the offsets disagree, Python's zipfile computes concat = eocd - cd_size - cd_offset and silently shifts the central directory start and every local header offset by concat. It then reads the central directory that sits immediately before the end record. A reader that trusts the recorded cd_offset, or a streaming reader that walks local headers from offset 0, sees a different set of entries. Local entries that the central directory does not reference are never inspected at all. The docstring says the IPA zip 'must be as unambiguous as an APK's', but this path does not enforce that.

## Android tests never check an APK whose signing block names the pinned certificate but whose signature does not verify

medium · accepted · C-9c1cb6dd25ec

android_cases appears in full in this window. The tests imply that the checker accepts an APK because its v2/v3 signing block contains the pinned certificate bytes, while trusting the record's self-reported fields 'verifier' and 'verification'. The valid fixtures are built with a synthetic helper, apk_signer(RELEASE_CERT, APK_V2). No case builds an APK whose block carries the real pinned certificate but has wrong signatures, a wrong public key, or digests that do not cover the APK contents. Two cases do change bytes after signing: prepending PREFIX, and renaming classes.dexX to classes.dex followed by a NUL byte. Both assert only parsing or ambiguity errors, never a signature or digest failure. The release certificate is public, because it is embedded in every shipped APK. If the checker only matches certificate fingerprints, anyone who can supply the evidence can copy the certificate into an unsigned APK's block and pass the gate. That depends on the checker's implementation, which was not visible in this window.

## Fixture never commits release-policy.json and runs approval positives off the candidate checkout, so no test binds the policy or checkout to the candidate

medium · accepted · C-bcd2b9e19b66

fixture() checks out the candidate and then writes release/release-policy.json (and .go-version) into the working tree without adding them. The policy the checker enforces is therefore in no commit. approval_cases then moves HEAD: approved() calls commit_on, which detaches and commits. It expects valid results while HEAD sits at approval or merge commits. qa02_cases edits the working-tree policy (the ios pins) and expects the checker's verdict to change. These tests pass only if the checker does two things: it reads its gate rules (required_ci_jobs, android.release_certificate_sha256, ios team/bundle pins, the toolchain) from whatever file is in --root's working tree, and it does not require --root's checkout to be --expected-commit. No case in this window checks that a working-tree policy differing from the candidate's committed policy is rejected, or that a root checked out at another commit is rejected. If the checker added either binding, these fixtures would fail.

## Each advisory exception requires a 'scope', but the ignore it produces applies to the whole dependency graph

medium · accepted · C-a378f12b51ca

Every exception must carry a non-empty `scope` string, but the field is only checked for presence. cargo_audit_flags emits a bare `--ignore <id>`, which suppresses the advisory wherever it appears in the dependency graph. Nothing in the in-scope code limits an exception to the crate or path its `scope` describes. The reasons these advisories are safe to ignore exist only as source comments: RUSTSEC-2026-0330/0331 are described as 'never built', and RUSTSEC-2026-0387 as 'never runs on our keys' because an X25519/Ed25519 suite is pinned. Comments are not evidence. For 0387, no visible mechanism checks that the NIST-curve code stays unreachable.

## Shell lint wrapper can discard gofmt failures

medium · accepted · C-28c46d206d15

The command runs in a new shell without errexit or an explicit check of gofmt's exit status. If gofmt fails while producing no filenames on stdout, execution proceeds to go vet, whose successful exit makes the Go lint stage pass. The parent shell's set -e does not enable errexit in this child shell.

## Readiness polling budgets do not bound individual requests

medium · accepted · C-c69acba77eea

waitReady checks its deadline only after c.status returns, while that request and its response-body drain can take up to the HTTP client's 15-minute timeout. Consequently, the configured readiness timeout is not enforced. The contract harness likewise limits polling attempts but gives curl no request timeout, allowing a single probe to hang indefinitely.

## verify.sh leaves a previous run's summary in place until the very end, so an interrupted run can leave stale 'pass' evidence

medium · accepted · C-8c73991468a2

The summary path is fixed (default dist/verify-summary.json). The full-run path only writes it once, at line 62, after every step has finished. Nothing removes or invalidates the existing file at startup. If the run is killed (CI timeout, OOM, cancellation, runner loss) or exits early under `set -eu`, the file from an earlier successful run is still there. It still says status 'pass'. The summary also records no commit, tree hash, or timestamp, so a consumer cannot tell a stale file from a fresh one.

## build_manifest accepts a policy with a missing or empty approvals section and emits a manifest with no approvals

medium · accepted · C-f0d8ea5263c6

`policy.get("approvals", {})` defaults to an empty dict, and an empty dict passes the isinstance check. As a result, a policy with no 'approvals' key, or with `{}`, produces a manifest whose approvals hold only the approvals commit. The error text 'release policy has no approvals' shows the author meant missing approvals to be fatal, but only a non-dict value triggers it. The tests cover only the non-dict case.

## Release policy and Go toolchain are read from the working tree, not from the candidate commit being attested

medium · accepted · C-14b62ffc3221

The manifest attests a specific candidate commit, taken from RELEASE_COMMIT or falling back to GITHUB_SHA. Approvals are fetched from git at a pinned approvals commit. However, the release policy and .go-version are read from whatever is checked out under ROOT. Nothing checks that the working tree matches the candidate commit. The recorded 'toolchain' is the contents of .go-version, not the toolchain that actually built the container.

## binary_commit and container.commit are copies of the candidate commit rather than measured provenance, and the digest format is unchecked

medium · accepted · C-5002a0494aa8

The manifest sets both 'binary_commit' and 'container.commit' to the input commit by assignment. It never derives them from the built image, for example from OCI labels, SLSA provenance, or `go version -m` build info. A downstream check that binary_commit equals candidate_commit is therefore always true. CONTAINER_DIGEST is only checked for being non-empty, so any string, such as a tag or a typo, is accepted as the digest.

## Recovery acts on journal contents read before acquiring its lock

medium · accepted · C-4842ca148784

A running restore can update or remove the journal between recovery's read and lock acquisition. If the restore releases its lock during that interval, recovery successfully acquires the lock but still interprets stale bytes. It can treat a completed activation as unfinished, or fail removing a journal that the successful restore already removed.

## Recovery reads the journal before taking the restore lock and then acts on a stale copy

medium · accepted · C-7dad8e8851ea

recoverInterruptedRestore reads the journal into raw, then acquires the lock, then parses and acts on raw without reading the file again. The code's own comment notes the journal may belong to a running restore. That restore could finish between ReadFile and acquireRestoreLock: it writes 'activated', removes the journal, removes staging, and its deferred lock.Release runs last. Recovery then proceeds with a stale 'activating' copy and runs rollBackRestore on a completed restore. The restored database cannot be moved into the deleted StagingDir, but the original -wal/-shm rollback copies are still renamed next to the restored database. With a stale 'activated' copy instead, os.Remove(path) fails and the command errors for no reason.

## Journal rollback path validation accepts directory traversal

medium · accepted · C-57783dea9fb7

A lexical prefix does not establish path containment. A rollback path such as base + '.pre-restore-x/../../victim' passes validation but resolves outside the intended directory when the prefixed directory exists. Recovery can move that external file into the live database path; successful cleanup can then delete the previous live database moved into staging.

## Restore error cleanup deletes staging still required by recovery

high · accepted · C-6fae49367c3a

If writing the activated journal fails before replacing the activating journal, restore retains an unfinished journal but deletes its staging directory. Recovery then cannot move the live replacement into that directory before restoring the original. A rollback error can leave the same condition. Recovery continues failing with a missing-directory error even after the original transient fault clears.

## Rollback puts the original WAL/SHM back even when the database was not put back, pairing them with the restored database

high · accepted · C-d4d6acdf2a93

rollBackRestore calls putBack separately for the database and for each companion file. A putBack error is only collected; nothing stops the next move. Suppose the database putBack fails while moving the restored live database into StagingDir. The companion loop still runs. For each companion whose live path is absent, which is normal because the restored database has no -wal, putBack renames the original -wal/-shm into place next to the restored database. The code itself says the WAL holds committed data and must move with its database. SQLite does not check that a WAL belongs to the database file, so on the next open it replays the original instance's committed frames into the restored database. If the second database rename (rollback to live) fails instead, the original WAL ends up at live-wal with no matching database at all.

## Restore commits without syncing a separately located blob directory's parent

high · accepted · C-35fc5f3e8f87

Blob preservation, activation, and rollback change entries in the blob directory's parent, but only the database parent is synced. When those parents differ, the activated journal can become durable without the blob renames being durable. Recovery trusts the activated state and does not repair the resulting database/blob mismatch.

## Backups of instances with roughly 6,000+ attachments cannot be restored because restore caps the manifest at 1 MiB

high · accepted · C-ddd6d2608dca

backup adds one indented JSON entry for each referenced blob and writes the manifest with no size limit. Each entry holds storage_key, a 64-hex sha256 and size_bytes. readAndValidateBackupManifest rejects any manifest larger than 1<<20 bytes, and both restore and verify-backup call it. Under MarshalIndent each blob entry takes about 143 bytes of fixed structure plus the key and the size digits, so roughly 150-190 bytes. Once an instance references about 5,500-7,000 blobs, backup still reports success, but every restore and every restore drill of that backup fails with 'backup manifest is too large'. The size check also runs only after os.ReadFile has read the whole file, so it does not limit memory use.

## Input size limits are checked only after unbounded file reads

medium · accepted · C-aaef55d7981b

Both paths allocate and read the entire input before enforcing their respective 1 MiB and 1024-byte limits. Oversized input can exhaust memory before either intended validation error is returned.

## reset-owner-password always rejects the password file on Windows

medium · accepted · C-8feb7b4e48d3

The password-file check uses POSIX mode bits: `info.Mode().Perm()&0o077 != 0`. On Windows, Go's os.Stat builds the FileMode from the read-only attribute. Writable files report 0666 and read-only files report 0444. Both values have group and other bits set, so the condition is always true and the command fails before it reads the file. The command package is built for Windows (restore_lock_windows.go, and instance_lock.go mentions LockFileEx on Windows), so offline owner recovery cannot succeed on a Windows host.

## Only serve takes the data-directory and resource locks; migrate, init and reset-owner-password write without them

medium · accepted · C-985d5c99c4a2

The comment says every storage command is "locked as one resource (I46)", but acquireInstanceLock and acquireResourceLocks are called only in serve. migrate opens the store and applies migrations with no process lock, and init writes the same way through migrate. reset-owner-password runs a one-second ProbeDatabaseExclusive and then opens the store in a separate step. A server that starts after the probe runs alongside the reset, and neither process detects the other. The restore lock is a separate file (<db>.restore.lock) that serve never takes, so it does not exclude a running server either.

## Restore does not acquire the server's shared blob-storage exclusion

high · accepted · C-33503defbd0c

Serve explicitly locks both canonical resources, but the supplied restore path takes only a database-keyed restore lock and probes that database before replacing blob storage. A server using another database but the same overridden blob directory is invisible to this database probe. Unless an additional interlock exists in the omitted helper implementations, restore can replace storage owned by that running server.

## Offsite failures bypass local backup retention

high · accepted · C-6fd6111f0d15

Each attempt creates a local backup before copying offsite, but an offsite failure returns before local pruning. Repeated failures therefore accumulate local backups without respecting Keep. The default backup directory is beneath the live data directory.

## Local-target guard is bypassed by HTTP redirects that the load client follows automatically

medium · accepted · C-de4739817e20

checkTarget validates only the literal hostname of -target. newAPIClient builds an http.Client without a CheckRedirect policy, so Go's default behaviour follows up to 10 redirects to any host. For 307/308 responses Go replays the same method and body, because the request body is a bytes.Reader and GetBody is therefore available. On a cross-host redirect Go strips only sensitive headers such as Authorization and Cookie. It copies every other header to the new host, including X-Forwarded-For and any custom headers supplied through request.headers, which enroll forwards from its caller. A loopback or private target that redirects elsewhere therefore receives only the first hop. All seeding, enrollment and load traffic then goes to the redirect destination, even though the code documents that public targets are refused unless -allow-remote is set.

## Response draining suppresses transport failures

medium · accepted · C-4268a369343a

The response-discard branch ignores io.Copy's error and returns nil. A response that sends successful headers and then truncates, resets, or times out is therefore returned as a successful HTTP response rather than a failed transfer.

## A failed or partial 'before' metrics scrape turns lifetime server counters into per-step deltas

medium · accepted · C-a26f24667cab

scrape returns nil on any request error. It does not check resp.StatusCode, so a non-200 body produces an empty map, and it never checks scanner.Err(), so a truncated or overlong-line response produces a partial map. serverSummary only rejects an empty 'after' map. Any key missing from 'before' reads as 0, so delta() returns the full cumulative counter, including seeding traffic and earlier steps. That value is then reported as the window's figure for http_5xx_delta, rate_limit_rejections_delta, realtime_dropped_events_delta, writer/reader waits, writer_mean_queue (lifetime wait seconds divided by the window seconds), writer acquire mean and the p99 bucket.

## Capping each exponential send gap at 2 minutes makes devices send faster than the labelled step rate

medium · accepted · C-2260f45480c6

runSender draws an exponential gap with mean 60/rate seconds, truncates it at 2 minutes, and then always sends. Truncating instead of redrawing shortens the mean gap to m(1-e^(-2/m)) minutes, where m = 1/rate. The real per-device rate is therefore rate/(1-e^(-2*rate)) per minute. That is about +2% at 2/min, +16% at 1/min, +58% at 0.5/min, +154% at 0.25/min and about 5.5x at 0.1/min. The arrivals are also no longer Poisson. Each step, and rated_messages_per_device_minute, still reports the configured rate rather than the rate actually delivered.

## Synchronous sends reduce offered load as server latency increases

medium · accepted · C-97da4ef9d232

Each device waits for its sampled gap, performs any upload and send synchronously, and only then samples the next gap. Actual interarrival time includes server service time, so this is not the advertised Poisson arrival process at the configured rate. Offered load falls precisely when the server slows down.

## Step summaries are computed while operations started in the window are still in flight

medium · accepted · C-45cf491c4438

timed records an operation only when it completes, tagged with its start time. execute calls summarize(measureFrom, measureTo) as soon as the window ends and does not wait for operations still running. Operations that start near the end of the window and are slow, or eventually time out, are not yet recorded. If summarize selects by start time, as the recorded 'started' value suggests, these operations are never attributed to any step. The excluded operations are disproportionately the slowest ones and the errors.

## Pending send entries accumulate for the entire run

medium · accepted · C-1b1d24a9a0c4

Every attempted live send inserts a unique key, but the supplied workload only loads entries and never deletes them. Successful deliveries, failed sends, and messages with no online recipients all remain retained until execute returns. Memory use grows with total attempted messages rather than outstanding work.

## Lost realtime deliveries are absent from delivery measurements

medium · accepted · C-343a73f56f3c

Only matching socket events that actually arrive produce delivery records, always marked successful. The supplied workload does not register expected recipient deliveries or expire missing ones into failures. Its optional verification fetches acknowledged messages using the sender's device, which checks persistence rather than recipient delivery. Delivery latency is therefore conditional on successful observation.

## Attachment downloads use a fixed pool of 4 workers and are silently dropped when the queue is full

medium · accepted · C-2d04cc7fa48e

The workload model says every online recipient downloads each attachment. In the code, runSocket queues downloads on a 1024-slot channel with a non-blocking send, and the default branch discards the job without recording anything. Only four goroutines drain that queue for all online devices and companion sockets. When the server slows, or 25 MiB attachments occupy the workers, the queue fills and later downloads vanish from both the offered load and the statistics. Download concurrency is also capped at 4 no matter how many devices are online.

## Initial sync failures bypass workload error recording

medium · accepted · C-844fa6257863

The initial cursor request is issued directly through client.json. On failure, it continues without recording latency or an error, leaving the cursor uninitialized. Only subsequent pagination uses w.timed. A client whose initialization repeatedly fails can therefore generate sync failures throughout measurement without contributing any sync-error samples.

## Cancelled verification can report unchecked messages as checked

medium · accepted · C-9e5c914c4c84

Checked is initialized to the total acknowledged count before any requests run. parallel stops scheduling when the context is cancelled, but its error is discarded. execute does not recheck cancellation after verification. Consequently, unattempted messages remain counted as checked; cancellation before workers start can return a positive checked count with zero missing and zero errors.

## Companion clients reuse the primary device's session instead of a separately linked device

medium · accepted · C-90660cd50e90

When companion is true, runDevice starts a second socket, catch-up and reads trio with the same *device, meaning the same bearer token and device ID. The admission package's device_links limit implies that real companions are separately linked devices, each with its own per-device fan-out, cursor and deliveries. Here the server sees two connections for one device. The model adds no extra fan-out or storage cost, and it records delivery latency and attachment downloads twice for the same device. If the server keeps only one socket per device, the two sockets would displace each other. Because backoff resets to 1 s after every successful dial, they would then reconnect about once a second.

## Budget eviction discards unrefilled account quotas

medium · accepted · C-69c794d6ff9d

When the table is full and the sampled buckets have not fully refilled, eviction nevertheless deletes a depleted bucket. Its account's next reservation creates a full bucket, forgetting previously consumed deliveries, bytes, or debt. The memory bound therefore changes admission policy into a fail-open quota reset.

## A failed filesystem probe clears an existing low-disk guard

medium · accepted · C-48ab81f02b9f

Each sample starts with low=false and ignores failed probes. If a previously low volume becomes unobservable and the other volume is not low, the sampler clears the write guard without establishing that capacity recovered. The flag is passed to the HTTP API.

## A full address table evicts live buckets, so an attacker holding one IPv6 /48 can recycle exhausted credential-route budgets

medium · accepted · C-565133a3f00e

rateLimitHost groups IPv6 clients only by /64, and nothing aggregates at a coarser prefix. The address table, which also holds the auth (credential) and enrollment counters, is capped at 65536 entries. When a new key arrives and the table is full, bucketLocked calls evictOneLocked. That function deletes a live, unexpired bucket: the one with the earliest reset among up to 32 entries taken from map iteration. It does not refuse the request or fall back to a shared key. Evicting a bucket throws away its auth and enrollment counts before the minute is up. The struct comment says the tables are split so that evictions cannot 'reset their credential budgets', but the address table itself still allows exactly that. A /48 holds 65536 /64s, so one routed /48 has enough distinct keys to fill the table by itself. Once the table is full, each new attacker key evicts an entry that is probably one of the attacker's own older, exhausted buckets. When the attacker cycles back to that /64, it gets a fresh budget even though its one-minute window has not ended.

## Stored bcrypt cost is not bounded before verification

medium · accepted · C-c700691a2d50

The real legacy-hash branch forwards the stored bcrypt cost directly to the primitive without enforcing a ceiling. Bcrypt accepts costs above the application's maximum of 15, up to 31. A syntactically valid out-of-policy stored hash can consequently initiate extremely long computation while holding a password slot. The request context cannot interrupt bcryptCompare once it starts.

## Historical password parameters defeat verification timing equalization

medium · accepted · C-765bb9e60c95

Matching primitive counts does not equalize computational cost. An incorrect password for the explicitly supported older Argon2id profile runs with 19 MiB, while an unknown account runs the 64 MiB dummy. Likewise, a legacy account uses its stored bcrypt cost, while unknown and migrated accounts use the configured dummy cost. Failed verification therefore depends on account existence and stored hash profile.

## Concurrent backup-status writers can lose updates or interfere with replacement

medium · accepted · C-79260030c62b

The recorders perform unsynchronized read-modify-write operations and share one temporary pathname. Overlapping calls can overwrite each other's status fields; overlapping temporary-file writes can also interfere before rename or cause one rename to fail because another writer already moved the file. Whether production commands permit this overlap requires verification because caller-level locking was not supplied.

## Production safety checks are skipped when PRIVATE_MESSENGER_ENV is unset, because the environment defaults to development

medium · accepted · C-e8f8995e9c39

When PRIVATE_MESSENGER_ENV is unset or empty, Environment falls back to "development". Every safety check is gated on Environment == "production", so all of them are skipped: setup-token strength and placeholder rejection (both in Load and in ValidateServe), the trusted-proxy requirement for a non-loopback listener, and the metrics bind restriction. A deployment that omits the variable gets no warning and none of the guards. A placeholder such as PRIVATE_MESSENGER_SETUP_TOKEN=change-me is accepted, even though ValidateSetupToken explicitly lists it as reserved.

## A symlinked backup directory bypasses ownership checks

medium · accepted · C-cfacb269c719

<quotes>
	case c.DatabasePath == backups || within(c.DatabasePath, backups):
		return errors.New("database must not be inside the data directory's backups directory")
	case c.StoragePath == backups || within(c.StoragePath, backups) || within(backups, c.StoragePath):
		return errors.New("blob storage must not overlap the data directory's backups directory")
</quotes>
ResolvePaths canonicalizes the configured database and blob paths, but validateOwnership constructs the implicit backup path without resolving its symlinks. If DataDir/backups points to the configured blob directory, these string-based comparisons accept a layout in which backups and live blobs occupy the same actual directory. A database inside the symlink target similarly bypasses the database restriction.

## Opening a FIFO secret file can hang startup before validation

medium · accepted · C-5c00a9e65e3c

The regular-file check occurs after a blocking os.Open. On Unix, opening a FIFO read-only waits for a writer, so a FIFO without a writer never reaches the rejection check. The subsequent read-size limit does not bound this wait.

## Privileged admin actions commit before, and separately from, their audit record

medium · accepted · C-a876595c1e53

Account status changes and invite revocations are committed by the store first. The audit event is written afterwards by a separate recordAuditEvent call whose result is not checked in the handler. The audit write uses r.Context(), which is cancelled when the client disconnects. If the client drops the connection after the store commit, or the database rejects the second write (busy, disk full), the privileged change persists with no audit record. The handler still returns success.

## One-time recovery capability can be re-read repeatedly because only a transfer reaching the end consumes it

medium · accepted · C-59873370daeb

The test fixes the contract of the recovery capability, and that contract looks risky. The server serves bytes 0-19 and then serves bytes 12 onward again, so bytes it already sent can be re-requested. The capability is marked consumed only when a transfer reaches the end of the blob. Nothing in this window bounds how many range reads are allowed or binds the capability to the first requester. Anyone holding the X-Recovery-Token can therefore request every byte except the last one as often as they like without consuming the capability. The legitimate user's later full download still succeeds, so the one-time-use property no longer reveals that the token was used. Whether the handler applies other limits (attempt counts, expiry, session binding, audit logging) is not visible in this window.

## No test that non-authors or non-members are refused when editing or deleting messages

medium · accepted · C-64f65ae423ee

A file-wide search finds the edit route only at lines 121 and 778, both called by the message author. Delete in this window is also called only by the author. TestConversationScopedWritesRequireMembership covers non-member attachments, calls, reactions and read receipts, but not edit, delete or envelope creation. No test checks that a member who did not write a message, or an outsider, is refused when editing or deleting it.

## Single-use key packages, no tested last-resort package, and non-consensual conversation creation allow targeted key-package exhaustion

medium · accepted · C-75108eb30606

The test expects each device to hold one consumable key package, so a repeat claim returns 409 key_package_unavailable. Any registered user can create a conversation with arbitrary member_account_ids without the invitee accepting (owner adds the member at 644-647; the member creates a DM with the owner at 705-708). Any member can then claim key packages for every other member. Together these let a user drain a target's key packages by repeatedly creating conversations that include the target and claiming. The target then cannot be added to legitimate groups until it re-uploads. No last-resort key-package behaviour is tested.

## Plaintext-persistence check reads only the main SQLite file while the app is still open, so it can miss data held in WAL or journal files

medium · accepted · C-7cefafa11536

TestMessageAPIRejectsPlaintextFields checks that a rejected plaintext sentinel never reached storage by calling os.ReadFile(dbPath) on the main database file. The application is still open at that point, because t.Cleanup closes it only after the test returns. If SQLite runs in write-ahead-log mode, committed pages stay in the -wal file until a checkpoint, so a wrongly persisted sentinel would not appear in dbPath. The rollback journal, the -wal/-shm files and the blob directory are never scanned. Both rejection requests also check only for HTTP 400, not the error code. A handler that writes first and then returns 400 would still pass.

## Metadata-search disclosure assertion misses base64 ciphertext

medium · accepted · C-9bb55d85ee8d

The test searches the response for the original ciphertext bytes, although its message helper submits those bytes as base64. A metadata-search regression returning the base64 ciphertext would pass this non-disclosure assertion.

## Transient TouchSession failures are reported as 401 Unauthorized on an already-validated session

medium · accepted · C-b08f77bb7f96

In withAuth, SessionPrincipal has already checked the session's expiry, idle expiry, account status and device revocation. The later TouchSession is only an activity-timestamp write. Despite that, any error from it returns 401 "unauthorized". This includes database busy or locked errors, I/O errors and context cancellation. The code itself separates ErrUnauthorized from other errors, but only to decide whether to log; both paths write the same 401. That path also bypasses refuseUnauthenticated, which the other unauthenticated exits use, so response handling is inconsistent.

## Username-only login backoff key lets anyone lock a known user out of login

medium · accepted · C-061480cbf99f

One login backoff key depends only on the lower-cased username, and RetryAfterAny rejects a request if any of its keys is in backoff. Any client from any IP, using any device_id, records failures against that key, including requests whose account lookup failed. Legitimate attempts are rejected with 429 before their correct credentials are checked.

## Device-link claim-status consumes the link before a separate transcript read that can fail and discard the session token

medium · accepted · C-3b2f98f5e3bc

The claim-status branch first calls ConsumeApprovedDeviceLink. That call commits the new session (sessionTokenHash) and consumes the approved link. Only afterwards does the handler run a separate DeviceLinkTranscriptForClaim query keyed on the same claim token. If the second query fails, the handler returns 400 invalid_device_link and drops sessionToken. Causes include a transient storage error, context cancellation, or consumption altering the claim state the query relies on. Every failure, including infrastructure errors, is reported as a client error.

## Server apparently accepts 64 zero bytes as a device key package; non-production check looks like a content denylist

medium · accepted · C-c7d0739db3c8

Owner setup, member registration and device linking all upload make([]byte, 64) as device_key_package and expect success. The production handler therefore accepts an all-zero blob as a key package. TestSetupRejectsNonProductionKeyPackage shows that a payload containing a placeholder string is rejected with non_production_device_key_package. This suggests validation matches known placeholder content instead of parsing an MLS KeyPackage (version, cipher suite, credential, leaf signature). The config.Config passed to app.New sets no test-mode flag, so the same validation would run in production.

## WebSocket admission can race session revocation

medium · accepted · C-b9634b1bb7f7

Authentication precedes hub registration without a subsequent session-validity check. A WebSocket request can authenticate, pause while logout deletes its session and disconnects existing clients, then register after that disconnection. The supplied handler passes account/device identifiers and the original expiry, but no session identity or revocation generation. Unless the unavailable realtime implementation independently prevents stale admissions, the revoked session can establish a surviving subscription.

## The full /128 IPv6 address is the throttle and connection-limit key, so IPv6 clients can rotate past limits

medium · accepted · C-4b56109b1ebd

ClientIP returns the full canonical address (ip.String()). syncWebSocket passes that value directly to Hub.Register as the per-IP connection-limit key, and the resolver is documented as the key for HTTP throttles too. IPv6 clients normally control at least a /64. They can send each request or open each connection from a different address and get a new identity every time.

## Login backoff eviction ignores failure count and can erase an account's accumulated brute-force budget

medium · accepted · C-1b85cd1104d4

When the in-memory table reaches 32768 entries, the first failure for each new identity calls evictOneLocked. That function samples 32 entries in map iteration order. It evicts the entry with the earliest expiresAt among the unblocked ones, and otherwise the earliest-expiring entry even if it is blocked. The failure count is never considered. An account-scope entry under sustained guessing has an old expiresAt, because expiresAt is fixed at the first failure. Between its short block windows (at most 32s) it counts as unblocked. That makes it a preferred eviction victim over the attacker's fresh one-failure filler entries. Each eviction resets the target's counter, so it again gets 2 free attempts and short delays.

## Attachment and backup downloads accept unbounded multi-range requests that re-seek and re-verify chunks

medium · accepted · C-c72eb3abd6f2

serveEncryptedBlob passes the request, including any Range header, unchanged to http.ServeContent. The recovery path rejects comma-separated ranges, but attachment and backup downloads accept multipart/byteranges. net/http drops a range set only when the summed length exceeds the file size; it does not cap how many ranges there are. Verification is per chunk: the code verifies 'the chunk holding' the current position, and the multipart branch relies on chunks being 'verified on read'. A header with tens of thousands of 1-byte ranges alternating between two different 1 MiB chunks can therefore force a seek plus a full chunk read and hash for each range.

## Recovery transfer progress counts bytes the server buffered, not bytes the client received

medium · accepted · C-e445a98b0e8a

blobResponseWriter.written increases by whatever the underlying ResponseWriter accepted. net/http buffers output in bufio and kernel socket buffers, so Write reports success long before the client has the data. The final buffered bytes are flushed only after the handler returns. serveRecoveryBlob passes this count to CompleteRecoveryTransfer as progress, and its comment treats bytes 'handed to the connection' as delivered. If the connection drops during that final flush, the server records written == expected for a transfer the client never completed.

## Key package claim endpoint has no visible rate limit, dedup or cap, allowing a member to drain other devices' one-time key packages

medium · accepted · C-5843e4c6eccf

Any member device can call claimConversationKeyPackages repeatedly. Without a device list, it claims a package for every other member device. With a list, it claims for an arbitrary caller-supplied set of device IDs, up to the 64 KiB body limit, with no deduplication or count cap. The handler applies no rate limit and does not check whether the claim is needed, for example whether the target devices are already in the MLS group. Each claim consumes one-time key packages.

## Transient storage failures permanently discard queued delivery advances

medium · accepted · C-0811c6c5cd59

Candidates are removed from the queue before persistence. If ApplyDeliveries fails before committing, writeDeliveries logs and returns without retrying or restoring them. Once the client advances beyond the served sync page, an empty subsequent page cannot reconstruct those delivery advances.

## Out-of-order sync requests can discard newer delivery cursors

medium · accepted · C-524ea40d71e5

Coalescing keeps the last arriving MessageID, not necessarily the furthest delivery cursor. An older sync page arriving from another device or overlapping request can overwrite a newer pending cursor before a worker takes it. Only the replacement reaches storage; even a monotonic ApplyDeliveries implementation cannot recover the discarded newer candidate.

## Generic FCM 404 responses are classified as expired subscriptions

medium · accepted · C-59ae722ec939

Every HTTP 404 becomes a permanent subscription failure, even without an FCM UNREGISTERED detail. Request-level failures such as an unavailable or nonexistent configured project can also produce NOT_FOUND responses without establishing that the device token is invalid. The contract test explicitly accepts an empty 404 response as subscription expiration.

## APNs key curve is not validated; a non-P-256 EC key panics in fillInt on the first send

medium · accepted · C-7e75c9e174b4

NewAPNsProvider accepts any *ecdsa.PrivateKey from PKCS #8 or SEC 1 without checking that the curve is P-256. signECDSAJWT always allocates a 64-byte signature and copies r and s into 32-byte halves through fillInt. For P-384 or P-521 keys, r and s are up to 48 or 66 bytes, so `target[len(target)-len(bytes):]` gets a negative start index and causes a runtime panic. A P-224 key does not panic, but it produces a token labelled ES256 that APNs rejects.

## APNs BadDeviceToken is treated as a permanently gone subscription, though it is also returned for a sandbox/production environment mismatch

medium · accepted · C-c8d377ad176a

APNsProvider picks a single APNs environment from the process-wide Sandbox flag. It then maps any response body containing the substring "BadDeviceToken" to ErrSubscriptionGone. Apple returns BadDeviceToken (HTTP 400) for malformed tokens and also when a valid token is sent to the wrong environment. A development-build token sent to production, or a production token sent to sandbox, is therefore reported as permanently invalid. The match is a raw substring search, not an exact parse of the JSON `reason` field.

## Public-only push dialer permits shared-address-space destinations

medium · accepted · C-e7f3a9f46453

Go's IsPrivate does not classify RFC 6598 shared address space, 100.64.0.0/10, as private. These addresses pass every check and are dialed, including destinations used by private overlay networks.

## Realtime per-IP cap of 20 is keyed on the raw remote address string

medium · accepted · C-a910d4025940

The hub limits sockets per exact remoteIP string to 20, across all accounts. For IPv4 behind carrier-grade or corporate NAT, many legitimate users share one address and exhaust the cap. For IPv6, a single client controls a /64 or larger prefix and can rotate addresses to bypass the per-IP limit entirely.

## Keepalive gives a ping round trip only about 6s, less than the 10s one write may take, so slow but healthy peers are disconnected

medium · accepted · C-308049c62401

The reader sets the read deadline to now+pongWait (60s) and extends it only when a complete inbound frame arrives. The socket is push-only, so on an otherwise quiet inbound side the only extension is the pong answering the server's own ping. That ping is sent every pingPeriod (54s). The time left for writing the ping, delivering it behind queued outbound data, and receiving the pong is therefore pongWait - pingPeriod, about 6s. The same single-writer loop lets each outbound write block for up to writeWait (10s). A ticker tick that fires during an outbound write is handled only after that write finishes. The ping then sits behind whatever is already in the kernel send buffer. Successful outbound writes never extend the read deadline. A client that is correctly but slowly receiving pushes can therefore hit the read timeout. The reader then returns closeReply{} and the connection is dropped without a close frame.

## Account export silently truncates categories because rows.Err() is never checked

medium · accepted · C-d037f4777035

exportAssociatedData runs each category query and loops on rows.Next(), but after the loop it checks only rows.Close(). It never checks rows.Err(). In database/sql, when Next returns false because the driver reported a step error or the context was cancelled, Next closes the Rows internally and records the error, which is visible only through Rows.Err(). The caller's later Close returns nil because the Rows are already closed. The loop therefore exits early with a prefix of the rows, and that partial slice is stored as the complete category with a nil error. Several queries call SQLite json() on stored columns (crypto_metadata_json, key_derivation_metadata_json, metadata_json, muted), and json() raises a runtime error on a malformed value. That error surfaces through Next in exactly this way.

## Row iteration failures can silently truncate exports and blob cleanup

medium · accepted · C-b0af1c4a0530

Both loops check Close but never Rows.Err. Next can return false because iteration failed, and Close does not substitute for checking that failure. exportAssociatedData can therefore return a successful, incomplete category. DeleteAccountData can proceed with an incomplete storage-key list if an iteration error leaves the transaction usable.

## DeleteAccountData leaves exported account-owned data (key packages, blocks, mute preferences, call metadata) in place

medium · accepted · C-49fdf403b175

The function documents that it scrubs account-controlled metadata and keeps only pseudonymous IDs. The export enumerates the account-owned categories, but the deletion transaction does not touch four of them:
- call_sessions created by the account, including metadata_json and invited_account_id
- device_key_packages uploaded by the account's devices (only devices.key_package is blanked)
- account_blocks where the account is the blocker
- conversation_notification_preferences
The accounts and devices rows are updated rather than deleted, so an ON DELETE CASCADE from those tables cannot remove the dependent rows. conversation_notification_preferences might cascade from memberships only if the schema defines such a foreign key, which is not visible in scope.

## Every export page re-reads and buffers all associated-data categories without bounds

medium · accepted · C-39d2e9f1a550

Only messages are paginated: the limit is capped at 5000 and continuation uses BeforeID. Every ExportAccount call still runs all 13 category queries with no LIMIT and buffers every row in memory, whichever page is requested. Categories such as delivery_receipts, read_receipts and reactions grow with message history. Paging through a full export therefore repeats the entire category scan once per message page.

## Blob deletion queue has no backoff or attempt cap, so keys that keep failing can starve every newer deletion

medium · accepted · C-988ea6a2ad52

PendingBlobDeletions always returns the oldest rows, ordered by created_at and storage_key and capped by LIMIT. It never looks at attempts or last_attempt_at. RecordBlobDeletionFailure increments attempts and stamps last_attempt_at, but nothing in this store reads those columns. There is also no maximum-attempt or dead-letter state. A failed key keeps its place at the head of the ordering. Once the head batch (default 100, effective maximum 500) consists entirely of keys whose deletion fails every time, each later sweep returns the same keys and newer entries are never attempted. Separately, a requested limit above 500 silently falls back to 100 instead of being clamped to 500.

## Generic member management lacks explicit community-channel membership enforcement

high · accepted · C-931ea205ba7e

ManageConversationMember permits community_channel conversations but does not explicitly require the target to belong to the associated community. In contrast, CreateConversation explicitly enforces that requirement for initial channel members. Unless checkNewConversationMember or database constraints enforce it, a channel manager can add an active outsider directly to a community channel.

## Membership propagation can commit after an incomplete query iteration

medium · accepted · C-e30875c04847

Both loops omit rows.Err(). Rows.Next returning false can indicate an iteration failure rather than successful completion, and Close does not reliably expose that recorded error. If subsequent transaction operations succeed, CreateChannelWithConversation can commit only a subset of community members, while ManageCommunityMember can propagate a role change to only a subset of channels.

## Row iteration failures can commit incomplete cryptographic work

medium · accepted · C-09163ad33b3e

Both loops proceed after Rows.Next returns false without checking Rows.Err. Rows.Close does not reliably return an iteration error, particularly after Next has already closed the result set. A query failure can therefore be mistaken for successful exhaustion, allowing subsequent processing and transaction commit with an incomplete target list.

## Channel membership paths add accounts to conversations without the per-account conversation admission check

medium · accepted · C-6af93e28f80c

CreateConversation applies checkOtherConversations to every added member, but the channel paths do not. CreateChannelWithConversation adds every community member to a new conversation and checks only the creator's own quota. Its comment says one creator bounds the growth, but several managers (owner plus admins) can each create channels up to their own limits. ManageCommunityMember adds the target to every existing channel conversation and calls only checkNewCommunityMember, with no check of the target's conversation count.

## ManageCommunityMember adds an account to a community and all its channel conversations without checking account blocks

medium · accepted · C-de35edbff191

ManageCommunityMember checks the actor's role, that the target is active, the rank ordering, and capacity through checkNewCommunityMember. It never queries account_blocks between actor and target. The function then upserts the target into the community and into every community_channel conversation of that community. Comparable paths do enforce blocks in both directions: ManageConversationMember (lines 978-984) and CreateConversation (lines 804-809). RemoveConversationMember only allows kind 'group', so the target cannot leave the channel conversations through that path.

## Unread counts exclude unread messages sharing the receipt timestamp

medium · accepted · C-77e18c6718c8

The unread boundary compares only timestamps despite the receipt identifying a specific message. When distinct messages share created_at, every message at the receipt's timestamp is excluded, including messages ordered after the acknowledged message. Timestamp ties can therefore suppress legitimate unread counts.

## Conversation pagination recalculates its boundary from mutable activity

medium · accepted · C-577cce04adc2

The cursor contains only a conversation ID, so each request recomputes the cursor's activity timestamp. A new message can move that boundary upward and repeat previously returned conversations; message expiry or deletion can move it downward and skip conversations. If the cursor conversation disappears from the requester's memberships, the scalar subquery returns no row and the next page becomes empty even when other conversations remain.

## Device is created at approval, but the session can only be consumed before the original link expiry, which can orphan the device

medium · accepted · C-5be3e65b2883

approveDeviceLink inserts the device row and its initial key package and announces the device, as long as the link has not expired. ConsumeApprovedDeviceLink requires the same, unextended expires_at to still be in the future before it issues a session. If approval happens close to expiry, the device is active and published but the claimant can never obtain a session through the link. The device still counts against checkDevices limits.

## Push subscriptions without a device are never deduplicated or retired because the NULL device_id never matches

medium · accepted · C-5bf95ef6f32a

CreatePushSubscription inserts device_id as nullableEmptyString(deviceID) but looks up the existing active row, and retires other providers, with `device_id = ?` bound to the raw string. With an empty deviceID neither statement ever matches the stored NULL rows. Every call therefore inserts a new active subscription, the one-provider-per-device rule (I41) is never applied, and ListDevicePushSubscriptions(..., "") never lists these rows.

## A stale delivery failure can disable a refreshed push registration

medium · accepted · C-2702f5e8f817

Refreshing a subscription replaces its endpoint and credentials while preserving its ID. DisablePushTarget subsequently disables solely by that ID, without checking the endpoint or registration generation that failed. A delivery attempt using an old target can therefore invalidate a newer, healthy registration.

## Deviceless backups skip state_counter monotonicity and prior-capability revocation because NULL device_id is compared with '='

medium · accepted · C-71dde504bd05

CreateBackupBlobWithChunkDigests stores device_id as nullableEmptyString(deviceID), so an empty device ID becomes NULL. The MAX(state_counter) lookup and the UPDATE that clears earlier recovery tokens both filter with `device_id = ?` bound to the raw string. When deviceID is "", `device_id = ''` never matches the NULL rows, so previousCounter is always NULL and earlier recovery capabilities are never cleared. BeginRecoveryTransfer scans device_id into a NullString and maps it with stringPtr, which confirms that NULL-device backups are an expected state.

## Expired ringing calls can still be accepted before pruning

medium · accepted · C-df97174bd537

transitionCallSession checks membership, role, version and allowed states but never checks ExpiresAt. An expired ringing row that has not yet been pruned can therefore be accepted, become active and receive a fresh four-hour expiry. Expiration is enforced only by physical deletion, making behavior depend on cleanup timing.

## Slow recovery transfers lose completion rights while still running

medium · accepted · C-520296fa9ca5

Completion requires an unexpired lease, even when the same lease still owns the row. Consequently, a transfer lasting more than two minutes cannot record progress or consume its capability. Capping the lease at capability expiry also prevents completion after that deadline, contrary to the stated allowance for already-leased transfers. No renewal operation appears in the supplied transfer implementation.

## Recovery lease expires after 2 minutes with no renewal, so a long transfer can neither record progress nor consume the single-use capability

medium · accepted · C-747f977b631f

BeginRecoveryTransfer leases a transfer for at most RecoveryLeaseLifetime (2 minutes) and caps the lease at the capability deadline. CompleteRecoveryTransfer accepts the lease only while recovery_lease_expires_at is still in the future, and nothing in this file renews a lease. Two kinds of transfer therefore get ErrRecoveryBusy at completion: one that streams longer than 2 minutes, and one leased shortly before recovery_expires_at that finishes after it. In both cases the offset does not advance, and a complete final range does not clear recovery_token_hash. This contradicts the documented contract at lines 19-21, which says a transfer leased before expiry may finish after the deadline. Also, once a lease lapses mid-stream, the UPDATE at lines 911-913 lets a second BeginRecoveryTransfer take a new lease while the first stream is still sending. That defeats the stated guarantee that racing an active transfer is rejected.

## Sync block filter fails open for message events once the envelope row is hard-deleted

medium · accepted · C-4dcb70d589aa

For message.* events, syncEventBlockedFor finds the sender by looking up message_envelopes with the payload's message_id. If that row no longer exists, the subquery returns NULL. The comparison b.blocked_account_id = NULL is never true, so EXISTS is false and the event counts as not blocked. Two code paths hard-delete envelope rows while leaving their sync events and full payloads in place: PruneExpiredContent, and the idempotency cleanup in saveMessageEnvelope. The block filter therefore fails open exactly for removed messages. Those events become visible, with payload, to accounts that blocked the sender.

## Disappearing-message ciphertext outlives expiry in sync_events and is replayed by ListSyncEvents

high · accepted · C-94ce536ed04c

Every message sync event (created, edited, deleted) stores the full envelope in payload_json through messageSyncEventPayload, and that envelope includes the ciphertext. PruneExpiredContent deletes only message_envelopes, message_attachments and attachment_envelopes rows. It never deletes or redacts the sync_events rows that hold copies of the expired envelopes. listSyncEventsQuery has no expiry predicate and returns se.payload_json for every visible row. As a result, an expired envelope stays on the server until PruneSyncEvents removes it under its own, unrelated age cutoff. Until then it is served to any device that syncs from a cursor older than the event. This contradicts two stated contracts: PruneExpiredMessages says expired envelopes are deleted, and the I33 comment in MessageForAccount says they are never returned. The push-wake path in the same function does cap its TTL at the message expiry, which shows that expiry is meant to bound derived data.

## ListSyncEvents re-scans the entire run of hidden trailing events on every poll

medium · accepted · C-552cb88054f4

ListSyncEvents reads candidates until it has collected limit visible events or the stream ends. It returns only the visible events and does not report how far it scanned. Some events after the last visible one may all be hidden: events from a blocked sender, pre-join encrypted events, or call events for a device that has not joined. In that case every request walks the whole hidden tail, evaluating the block and MLS predicates (json_extract plus correlated subqueries) on each row, and returns an empty or short page. The client cannot move its cursor past hidden events, because SyncBounds' latest value is also visible-only. Every subsequent poll repeats the full scan.

## Realtime recipient snapshot ignores account blocks that every read path applies

medium · accepted · C-5d54a035cb1c

SaveMessageEnvelopeWithSyncEventAndRecipients is documented as returning the authorized recipient snapshot for realtime fanout. Its query, however, returns every member of the conversation. It omits the account_blocks predicate that ListMessages, MessageForAccount and ListSyncEvents all apply. Unless the realtime layer re-applies blocks for each recipient, accounts that blocked the sender receive the new envelope live, even though every read path hides it. enqueuePushWakeJobs receives only the conversation and sender, so this snapshot cannot show whether push wakes honour blocks either.

## Edit and delete authorize on sender only, not current conversation membership

medium · accepted · C-9028e61c103b

saveMessageEnvelope requires membership in the conversation. updateMessageEnvelope and deleteMessageEnvelope authorize only on sender_account_id. An account that has left or been removed from a conversation can therefore still rewrite or tombstone its earlier messages there. Each such mutation inserts a conversation-scoped sync event that is delivered to the remaining members.

## Deleting a message leaves its attachment links, refs and encrypted blobs in place

medium · accepted · C-8b904dad6c84

deleteMessageEnvelope replaces ciphertext, crypto_protocol and crypto_metadata_json, but leaves attachment_refs_json and the message_attachments rows unchanged. This has three consequences: (1) the tombstone keeps advertising the attachment ids; (2) the remaining links stop the attachment_envelopes rows from ever qualifying for the orphan reaper, which requires NOT EXISTS message_attachments; (3) no blob deletion is enqueued. Encrypted attachment blobs of deleted messages are retained until the message expires, and permanently if it has no expiry.

## Coordinator-only revocations complete without a completion event

medium · accepted · C-ac2748087b88

Commit submission confirms the coordinator and invokes a helper that can immediately complete the revocation, but that path does not emit mls.revocation.completed. Event emission exists separately in ConfirmMLSRevocation. When the coordinator is the only required device, its later confirmation takes the already-confirmed branch and returns without emitting the missing event.

## Removing a revoked device through an ordinary bundle leaves its revocation permanently pending

medium · accepted · C-52e914ad6b08

A revoked device stays active in the roster until its revocation commit is accepted. Any group device can name that device in Removed without setting RevocationDeviceID. The same happens when the device is an extra Removed entry beside another revocation, since a bundle carries only one RevocationDeviceID. In these cases mls_revocations is never updated. When the coordinator later submits the real revocation commit, the Removed check fails because the device is no longer active, and the server returns ErrForbidden. The revocation can then never reach commit_submitted or completed.

## A global LIMIT 2000 across all groups' pending adds and removes silently drops removals

medium · accepted · C-6227eb5372f9

One LIMIT 2000 applies to the UNION ALL of every add row and every remove row across all of the requester's groups. There is no ORDER BY and no truncation indicator. The add branch is evaluated first. Add rows for devices with no key packages stay pending indefinitely, because such devices are skipped. Once the requester's add backlog reaches 2000 rows, remove rows and whole conversations disappear from the result, and the response still looks complete.

## Unclaimable devices can starve truncated MLS pending changes

medium · accepted · C-89bafb1a58b3

Pending additions are clipped to 256 per conversation, and the combined query is clipped to 2000 rows without a continuation cursor. Devices lacking usable key packages remain pending because claiming simply skips them. If those devices occupy the selected prefix, repeated calls can return the same unprocessable subset indefinitely, never exposing later claimable additions. The global additions-first limit can similarly hide pending removals.

## Any conversation member can exhaust every other device's MLS key packages, blocking group operations

medium · accepted · C-9ab5d538013e

ClaimConversationKeyPackages checks only that the requester's account is a member of the conversation. Each call then permanently claims, and commits, one unclaimed package from every other non-revoked device of every member, including other accounts' devices. Nothing in the store limits this: there is no per-requester or per-conversation rate limit, no reuse of a recent claim that was never committed, and no non-consumable last-resort package. PublishDeviceKeyPackages caps a device at 50 available packages, so about 50 calls drain every device in a shared conversation. Packages belong to a device, not to a conversation, so the drain affects every conversation those devices are in. A single target device with no package makes the whole claim fail with ErrKeyPackageUnavailable, so one drained device blocks the operation for everyone. A device that stays offline past the 30-day expiry of its initial package causes the same failure.

## Push-wake jobs that become ineligible are never dropped, which distorts backlog and abandonment metrics and can fire stale wakes

medium · accepted · C-670ec7de38de

ClaimPushWakeJobs skips a job in its WHERE clause when any of these is true: the recipient is no longer a member, the subscribed device is revoked, the recipient blocked the sender, or the recipient muted the conversation. Nothing in this file deletes those rows. A caller can only call DropPushWakeJob on a job it has claimed, and these jobs can never be claimed, so they stay in the table until expires_at. PushWakeBacklog filters only on expiry and disabled subscriptions, so it counts these rows, and OldestCreatedAt keeps aging toward the TTL. When the rows expire, the claim transaction deletes them and reports them as provider-level 'abandoned'. If the mute, block or membership change is reversed before expiry, the old job becomes claimable again and wakes the recipient for an outdated event.

## Retention backlog omits documented attachment and sync-event pruning

medium · accepted · C-c9a44674ee9d

The backlog query list contains neither attachment_envelopes nor sync_events, although the supplied retention tests document both as pruning surfaces. Consequently, eligible rows in those tables cannot contribute to Rows or OldestAgeSecond. The metric can report zero while those documented retention queues remain uncleared. The actual pruning implementation is unavailable, so its precise eligibility predicates require verification.

## Backup validation and blob inventory never check rows.Err(), so iteration errors are silently dropped

medium · accepted · C-ab537b600472

ValidateDatabaseFile (quick_check loop) and ListDatabaseBlobReferences (both result loops) treat the error from rows.Close() as the iteration error. In database/sql, when Rows.Next() returns false it closes the Rows itself and keeps the step error in Rows.Err() only. A later rows.Close() then returns nil. An error raised partway through iteration is therefore dropped. In ValidateDatabaseFile the quick_check loop can end with zero rows and no error, so the "ok" check never runs and validation continues. In ListDatabaseBlobReferences a partial attachment/backup blob list, or a partial migration list, is returned as if it were complete. ensureMigrationChecksumColumn in the same file does check rows.Err(), which suggests the other loops are oversights.

## Interrupted first-run checksum backfill leaves the database unable to start

medium · accepted · C-e841f864f79f

On a legacy database, ensureMigrationChecksumColumn runs ALTER TABLE ... ADD COLUMN in its own autocommit statement and returns true only for that one call. The per-migration backfill UPDATEs then run one at a time, interleaved with applying new migrations. If Migrate fails or the process stops after the ALTER but before every legacy row is backfilled, the next start sees the column already present, so checksumColumnAdded is false. Every row that was not backfilled then hits the "has no stored checksum" error. The state is persistent, so the server cannot migrate or start until someone repairs it by hand. Sorted order also means a newly added migration can sort before an applied legacy one. If that new migration fails, the legacy row is never backfilled.

## ProbeDatabaseExclusive cannot detect a running server on a WAL database

medium · accepted · C-b28542c1fb14

Open sets journal_mode=WAL, and that setting is stored in the database file. In WAL mode, BEGIN EXCLUSIVE behaves like BEGIN IMMEDIATE. It takes only the write lock and does not exclude other connections that are open but idle or reading. Even outside WAL, BEGIN EXCLUSIVE succeeds whenever no other connection is holding a lock at that moment. A live server process that is idle between writes therefore does not cause the probe to fail. The name suggests the probe is meant to confirm exclusive ownership, for example before a restore or offline maintenance, and it cannot guarantee that. The probe also opens the path with the default read-write-create mode, so probing a path that does not exist creates an empty database file.

## Plaintext-at-rest assertion is vacuous because the sentinel is generated after all writes and never stored

medium · accepted · C-f92091a14bda

TestInviteDeviceAndEncryptedEnvelopeFlow ends by generating a fresh runtime sentinel and asserting that the database file does not contain it. The sentinel is created only after every store call in the test. It is never passed to any store API: registration, envelopes, sync events, push subscriptions and wake jobs never see it. The database cannot contain it except by random coincidence, so the assertion can never fail. It gives false assurance that no plaintext reaches disk. The test also reads only the main database file. The store has a separate reader pool (store.db.reader), which suggests WAL mode. In WAL mode, recently committed pages live in the -wal file, which this check never scans, so even a correctly injected sentinel could be missed.

## TestExpiredInviteCannotRegister skips the reservation step and accepts any error, so invite-expiry enforcement is effectively untested

medium · accepted · C-8a974e336f7b

Every other registration in this file first calls ReserveRegistrationEnrollment and passes the resulting EnrollmentReservationID to RegisterWithInvite. This test omits both steps and checks only that err is non-nil. RegisterWithInvite will most likely fail because the reservation ID is empty or unknown, whether or not the invite has expired. The test therefore passes even if the expiry predicate is removed. The expiry check most plausibly lives in ReserveRegistrationEnrollment, and this test never calls it with an expired invite. The test also discards the HashPassword error, so an empty hash could add another unrelated failure cause.

## Recovery-capability rotation assertion is vacuous because the old token was already consumed

medium · accepted · C-d48b80dec930

At line 256 the test completes the final transfer of the 6-byte blob, and at lines 259-261 it asserts that firstToken now returns ErrNotFound, so the capability is consumed. It then creates a rotated backup with secondToken and asserts again that firstToken returns ErrNotFound. Because firstToken was already consumed, that second assertion succeeds whether or not CreateBackupBlob revokes the previous capability. The property under test is never exercised: creating a new backup should invalidate an outstanding, unconsumed recovery capability.

## Blob deletion returns success without making the unlink durable

medium · accepted · C-ec51bf5cf384

Delete acknowledges removal without synchronizing the containing directory. On filesystems requiring directory fsync for crash-durable unlink, a successful return does not guarantee the deletion survives power loss. PutEncryptedBlob already applies a directory synchronization after its rename, but the deletion path has no corresponding durability barrier.

## CleanupTemporaryFiles aborts the whole sweep when a listed .tmp file disappears before entry.Info()

medium · accepted · C-f02a9c75917e

CleanupTemporaryFiles reads the blob directory once with os.ReadDir. It then calls entry.Info() for each .tmp entry. On Unix, DirEntry.Info() runs an lstat at call time. A temp file can vanish between the listing and the Info call in three ways: a concurrent PutEncryptedBlob finishes and renames tmp to its final path, a failed upload removes its tmp, or another sweep removes it. In each case Info returns a not-exist error, and the function returns immediately, leaving every remaining entry unswept. The Remove step treats not-exist as success but still increments the removed counter, so the reported count can be too high.

## Message deletion repeatedly scans unindexed reply and thread references

medium · accepted · C-a9a13651877b

Neither child column has an index in the supplied migrations. With SQLite foreign-key enforcement enabled, deleting each envelope requires whole-table scans to locate replies and thread references for SET NULL. A bounded deletion batch can therefore perform work proportional to the batch size multiplied by the entire message history.
