import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/call_service.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/device_link_v3_models.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/sealed_sender.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/sha256.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'api_bounded_decoding.dart';

void main() {
  group('bounded API decoding (T44A)', boundedDecodingTests);

  test('CallSession model parsing requires version and invited_account_id', () {
    final now = DateTime.now().toUtc();
    final json = <String, Object?>{
      'id': 'call_123',
      'conversation_id': 'conv_456',
      'created_by': 'acc_owner',
      'invited_account_id': 'acc_member',
      'state': 'ringing',
      'version': 3,
      'metadata': {'test': 'data'},
      'created_at': now.toIso8601String(),
      'ended_at': now.add(const Duration(minutes: 5)).toIso8601String(),
      'expires_at': now.add(const Duration(minutes: 10)).toIso8601String(),
    };
    final session = CallSession.fromJson(json);
    expect(session.id, 'call_123');
    expect(session.conversationId, 'conv_456');
    expect(session.createdBy, 'acc_owner');
    expect(session.invitedAccountId, 'acc_member');
    expect(session.state, 'ringing');
    expect(session.version, 3);
    expect(session.metadata, {'test': 'data'});
    expect(session.endedAt, isNotNull);
    expect(session.expiresAt, isNotNull);

    final minimalJson = <String, Object?>{
      'id': 'call_minimal',
      'conversation_id': 'conv_minimal',
      'created_by': 'acc_owner',
      'invited_account_id': '',
      'state': 'ringing',
      'version': 1,
      'metadata': <String, Object?>{},
      'created_at': now.toIso8601String(),
    };
    final minimalSession = CallSession.fromJson(minimalJson);
    expect(minimalSession.invitedAccountId, isEmpty);
    expect(minimalSession.version, 1);
    expect(minimalSession.endedAt, isNull);
    expect(minimalSession.expiresAt, isNull);

    // `version` is an optimistic-concurrency token and `invited_account_id`
    // gates transition authorization: a payload missing either is a contract
    // break and must fail loudly rather than default to a plausible value.
    for (final missing in <String>['version', 'invited_account_id']) {
      final broken = Map<String, Object?>.from(minimalJson)..remove(missing);
      expect(() => CallSession.fromJson(broken), throwsA(isA<TypeError>()),
          reason: 'missing $missing must not be silently defaulted');
    }
  });

  test('reauthentication asks for token rotation and returns the new token',
      () async {
    final harness = await _RequestHarness.start();
    addTearDown(harness.close);
    final client = ApiClient(baseUrl: harness.baseUrl);
    addTearDown(client.close);

    final rotatingRequest = harness.nextRequest;
    final rotating =
        client.reauthenticate('token_old', 'owner-password-123', 'secret_1');
    final rotate = await rotatingRequest;
    expect(rotate.method, 'POST');
    expect(rotate.uri.path, '/api/v1/auth/reauth');
    expect(rotate.headers.value(HttpHeaders.authorizationHeader),
        'Bearer token_old');
    expect(rotate.headers.value(ApiClient.sessionRotationHeader), '1');
    expect(await _requestJson(rotate), <String, Object?>{
      'password': 'owner-password-123',
      'device_secret': 'secret_1',
    });
    rotate.response.headers.contentType = ContentType.json;
    rotate.response.write(jsonEncode(<String, Object?>{'token': 'token_new'}));
    await rotate.response.close();
    expect(await rotating, 'token_new');

    // An older server answers 204 and the caller keeps its token.
    final legacyRequest = harness.nextRequest;
    final legacy =
        client.reauthenticate('token_old', 'owner-password-123', 'secret_1');
    final noRotation = await legacyRequest;
    await utf8.decodeStream(noRotation);
    noRotation.response.statusCode = HttpStatus.noContent;
    await noRotation.response.close();
    expect(await legacy, isNull);

    // A malformed token is a contract break, never a silent keep.
    final badRequest = harness.nextRequest;
    final bad =
        client.reauthenticate('token_old', 'owner-password-123', 'secret_1');
    final refused = expectLater(bad, throwsA(isA<ApiResponseException>()));
    final malformed = await badRequest;
    await utf8.decodeStream(malformed);
    malformed.response.headers.contentType = ContentType.json;
    malformed.response.write(jsonEncode(<String, Object?>{'token': 7}));
    await malformed.response.close();
    await refused;
  });

  test('call API sends exact create and transition JSON', () async {
    final harness = await _RequestHarness.start();
    addTearDown(harness.close);
    final client = ApiClient(baseUrl: harness.baseUrl);
    addTearDown(client.close);

    final createRequest = harness.nextRequest;
    final createFuture = client.createCall(
      'token_create',
      'conversation_1',
      const <String, Object?>{'ciphertext': 'AQID', 'version': 1},
    );
    final create = await createRequest;
    expect(create.method, 'POST');
    expect(create.uri.path, '/api/v1/calls');
    expect(create.headers.value(HttpHeaders.authorizationHeader),
        'Bearer token_create');
    expect(await _requestJson(create), <String, Object?>{
      'conversation_id': 'conversation_1',
      'metadata': <String, Object?>{'ciphertext': 'AQID', 'version': 1},
    });
    await _respondWithCall(create, version: 1, state: 'ringing');
    expect((await createFuture).version, 1);

    final transitionRequest = harness.nextRequest;
    final transitionFuture = client.transitionCall(
      'token_transition',
      'call_1',
      'active',
      expectedVersion: 7,
      encryptedMetadata: const <String, Object?>{
        'ciphertext': 'BAUG',
        'version': 1,
      },
    );
    final transition = await transitionRequest;
    expect(transition.method, 'POST');
    expect(transition.uri.path, '/api/v1/calls/call_1/state');
    expect(transition.headers.value(HttpHeaders.authorizationHeader),
        'Bearer token_transition');
    expect(await _requestJson(transition), <String, Object?>{
      'state': 'active',
      'expected_version': 7,
      'metadata': <String, Object?>{'ciphertext': 'BAUG', 'version': 1},
    });
    await _respondWithCall(transition, version: 8, state: 'active');
    expect((await transitionFuture).version, 8);
  });

  test('NativeCallService rejects with the latest pending session version',
      () async {
    final harness = await _RequestHarness.start();
    addTearDown(harness.close);
    final client = ApiClient(baseUrl: harness.baseUrl);
    addTearDown(client.close);
    final incoming = StreamController<IncomingCallSignal>();
    addTearDown(incoming.close);
    final service = NativeCallService(
      api: client,
      token: 'call_token',
      crypto: _UnusedMlsCrypto(),
      incoming: incoming.stream,
    );
    addTearDown(service.dispose);

    final first = _callSession(version: 1);
    final firstOffer = service.incomingOffers.first;
    incoming.add(IncomingCallSignal(first, const <String, Object?>{
      'kind': 'offer',
      'sdp': 'first',
      'sdp_type': 'offer',
    }));
    await firstOffer;

    final latest = _callSession(version: 2);
    final latestOffer = service.incomingOffers.first;
    incoming.add(IncomingCallSignal(latest, const <String, Object?>{
      'kind': 'offer',
      'sdp': 'latest',
      'sdp_type': 'offer',
    }));
    await latestOffer;

    final requestFuture = harness.nextRequest;
    final rejectFuture = service.reject(first);
    final request = await requestFuture;
    expect(await _requestJson(request), <String, Object?>{
      'state': 'rejected',
      'expected_version': 2,
    });
    await _respondWithCall(request, version: 3, state: 'rejected');
    await rejectFuture;
  });

  final baseUrl = Platform.environment['VERITRA_CONTRACT_BASE_URL'];
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];

  test('live server matches every Flutter-used route and model', () async {
    final client = ApiClient(baseUrl: baseUrl!);
    final bindings = NativeCryptoBindings.open(libraryPath!);
    addTearDown(client.close);

    expect((await client.setupStatus())['setup_required'], isTrue);
    final ownerReservation = await client.reserveOwnerEnrollment(
      setupToken: 'contract-setup-token',
    );
    final ownerNative = bindings.createDevice(
      ownerReservation.accountId,
      ownerReservation.deviceId,
    );
    addTearDown(ownerNative.close);
    final owner = await client.createOwner(
      username: 'contract-owner',
      password: 'owner-password-123',
      deviceName: 'contract owner device',
      enrollment: ownerReservation,
      credential: ownerNative.createEnrollmentCredential(
        ownerReservation.challenge,
      ),
      setupToken: 'contract-setup-token',
      instanceName: 'Contract Instance',
    );
    expect(owner.accountId, ownerReservation.accountId);
    expect(owner.deviceId, ownerReservation.deviceId);
    expect(owner.deviceSecret, isNotEmpty);

    final registrationInvite = await client.createInvite(
      owner.token,
      maxUses: 2,
    );
    expect((await client.listInvites(owner.token)).single.id,
        registrationInvite.id);
    final memberReservation = await client.reserveRegistrationEnrollment(
      registrationInvite.code,
    );
    final memberNative = bindings.createDevice(
      memberReservation.accountId,
      memberReservation.deviceId,
    );
    addTearDown(memberNative.close);
    final member = await client.register(
      inviteCode: registrationInvite.code,
      username: 'contract-member',
      password: 'member-password-123',
      deviceName: 'contract member device',
      enrollment: memberReservation,
      credential: memberNative.createEnrollmentCredential(
        memberReservation.challenge,
      ),
    );
    expect(member.accountId, memberReservation.accountId);

    final outsiderReservation = await client.reserveRegistrationEnrollment(
      registrationInvite.code,
    );
    final outsiderNative = bindings.createDevice(
      outsiderReservation.accountId,
      outsiderReservation.deviceId,
    );
    addTearDown(outsiderNative.close);
    final outsider = await client.register(
      inviteCode: registrationInvite.code,
      username: 'contract-outsider',
      password: 'outsider-password-123',
      deviceName: 'contract outsider device',
      enrollment: outsiderReservation,
      credential: outsiderNative.createEnrollmentCredential(
        outsiderReservation.challenge,
      ),
    );

    final revokedInvite = await client.createInvite(owner.token);
    await client.revokeInvite(owner.token, revokedInvite.id);
    expect(
      (await client.listInvites(owner.token))
          .where((invite) => invite.id == revokedInvite.id),
      isEmpty,
    );

    final basicGroup = await client.createConversation(owner.token, 'group');
    final group = await client.createConversationDetailed(
      owner.token,
      kind: 'group',
      title: 'Contract Group',
      memberAccountIds: [member.accountId!],
      retentionSeconds: 3600,
    );
    await client.addConversationMember(
      owner.token,
      basicGroup.id,
      member.accountId!,
    );
    expect(
      (await client.updateRetention(owner.token, group.id, 7200))
          .retentionSeconds,
      7200,
    );

    final community =
        await client.createCommunity(owner.token, 'Contract Community');
    expect((await client.listCommunities(owner.token)).single.id, community.id);
    final channel = await client.createChannel(
      owner.token,
      community.id,
      'Contract Channel',
    );
    expect(channel.conversation.communityId, community.id);
    expect((await client.listChannels(owner.token, community.id)).single.id,
        channel.channel.id);

    final envelope = MessageEnvelope(
      conversationId: group.id,
      idempotencyKey: 'contract-envelope-1',
      ciphertext: List<int>.generate(48, (index) => 128 + index),
      cryptoProtocol: 'mls10-openmls-v1',
      cryptoMetadata: const {'format': 'contract-v1'},
    );
    await client.sendEnvelope(owner.token, envelope);
    final messages = await client.listMessages(owner.token, group.id, limit: 1);
    expect(messages, hasLength(1));
    expect((await client.message(owner.token, messages.single.id)).ciphertext,
        envelope.ciphertext);
    await client.sendReaction(
      member.token,
      messages.single.id,
      List<int>.filled(16, 0x91),
    );
    await client.markRead(member.token, group.id, messages.single.id);
    expect(
        await client.syncEvents(member.token, after: 0, limit: 20), isNotEmpty);
    expect(await client.searchMetadata(owner.token, 'contract-member'),
        isNotEmpty);

    // The contract server has no VAPID, FCM or APNs settings, so it offers
    // only UnifiedPush (which needs none, server/internal/app/app.go) and
    // refuses registrations it could not deliver through (card I41).
    final pushConfig = await client.pushConfig(owner.token);
    expect(pushConfig['enabled'], isTrue);
    expect(pushConfig['providers'], ['unifiedpush']);
    expect(pushConfig.containsKey('vapid_public_key'), isFalse);
    Matcher refusedWith(int status, String code) => isA<ApiException>()
        .having((error) => error.statusCode, 'statusCode', status)
        .having((error) => error.serverCode, 'serverCode', code);
    await expectLater(
      client.registerWebPush(
        owner.token,
        endpoint: 'https://push.example.test/contract',
        publicKey: _p256PublicKey,
        authSecret: _base64UrlNoPadding(List<int>.filled(16, 7)),
      ),
      throwsA(refusedWith(400, 'push_provider_unavailable')),
    );
    await expectLater(client.sendTestPush(owner.token),
        throwsA(refusedWith(404, 'no_push_subscription')));
    await expectLater(client.disablePush(owner.token, 'push_missing'),
        throwsA(refusedWith(404, 'not_found')));

    final accountExport = await client.exportAccountPage(owner.token);
    expect(accountExport['manifest_version'], 'v2');
    expect(accountExport['messages'], isA<List<Object?>>());
    // Smoke check only: this server refuses push registration above, so the
    // export holds no subscription that could carry a secret. The guarantee
    // is TestAccountExportOmitsPushSubscriptionAuthSecret in
    // server/internal/httpapi/export_push_secret_test.go, which seeds one.
    expect(jsonEncode(accountExport), isNot(contains('auth_secret')));

    // The device link (L1-3) has its own live test on a second server:
    // it needs six credential-budget requests, and this test already
    // spends the ten an address gets per minute.
    expect(await client.devices(owner.token), hasLength(1));

    final conversationPage1 = await _getJson(
      '$baseUrl/api/v1/conversations?limit=1',
      owner.token,
    );
    final firstConversation = Conversation.fromJson(Map<String, Object?>.from(
      (conversationPage1['conversations'] as List).single as Map,
    ));
    final conversationPage2 = await _getJson(
      '$baseUrl/api/v1/conversations?limit=1&before=${firstConversation.id}',
      owner.token,
    );
    expect((conversationPage2['conversations'] as List), isNotEmpty);
    expect(await client.conversations(owner.token), isNotEmpty);

    final login = await client.login(
      username: 'contract-owner',
      password: 'owner-password-123',
      deviceId: owner.deviceId!,
      deviceSecret: owner.deviceSecret!,
    );
    // Reauthentication rotates the session token (card T37C). The old token
    // keeps working for in-flight requests during a short grace, but it can
    // no longer use recent authentication.
    final rotated = await client.reauthenticate(
      owner.token,
      'owner-password-123',
      owner.deviceSecret!,
    );
    expect(rotated, isNotNull);
    var ownerToken = rotated!;
    expect(ownerToken, isNot(owner.token));
    expect(await client.devices(owner.token), isNotEmpty);
    await expectLater(
      client.logoutAll(owner.token),
      throwsA(isA<ApiException>().having(
        (error) => error.serverCode,
        'serverCode',
        'recent_auth_required',
      )),
    );
    await client.logoutAll(ownerToken);
    await expectLater(
      client.devices(owner.token),
      throwsA(isA<ApiException>().having(
        (error) => error.serverCode,
        'serverCode',
        'unauthorized',
      )),
    );
    await expectLater(
      client.conversations(login.token),
      throwsA(isA<ApiException>().having(
        (error) => error.serverCode,
        'serverCode',
        'unauthorized',
      )),
    );
    await client.changePassword(ownerToken, 'owner-password-456');
    final relogin = await client.login(
      username: 'contract-owner',
      password: 'owner-password-456',
      deviceId: owner.deviceId!,
      deviceSecret: owner.deviceSecret!,
    );
    await client.logout(relogin.token);

    final rotatedAgain = await client.reauthenticate(
      ownerToken,
      'owner-password-456',
      owner.deviceSecret!,
    );
    expect(rotatedAgain, isNotNull);
    ownerToken = rotatedAgain!;
    await expectLater(
      client.message(ownerToken, 'msg_missing'),
      throwsA(isA<ApiException>()
          .having((error) => error.statusCode, 'status', 404)
          .having((error) => error.serverCode, 'serverCode', 'not_found')),
    );
    // A dm names its peer at creation: the store requires exactly one member
    // account id and rejects anything else with invalid_input. Calls then
    // require that conversation to hold exactly two members, so the peer
    // cannot be added afterwards either.
    final dm = await client.createConversationDetailed(
      ownerToken,
      kind: 'dm',
      memberAccountIds: <String>[member.accountId!],
    );

    final iceServers = await client.callIceServers(ownerToken);
    expect(iceServers, isA<List<Map<String, Object?>>>());

    final createCallMetadata = <String, Object?>{
      'version': 1,
      'ciphertext': base64Encode([1, 2, 3, 4]),
      'protocol': 'mls10-openmls-v1',
      'sender_device_id': owner.deviceId!,
      'action_id': 'action_call_create_1',
    };
    final createdCall = await client.createCall(
      ownerToken,
      dm.id,
      createCallMetadata,
    );
    expect(createdCall.conversationId, dm.id);
    expect(createdCall.createdBy, owner.accountId);
    expect(createdCall.invitedAccountId, member.accountId);
    // The server creates sessions already ringing; there is no 'created' state.
    expect(createdCall.state, 'ringing');
    expect(createdCall.version, 1);
    final retriedCreate =
        await client.createCall(ownerToken, dm.id, createCallMetadata);
    expect(retriedCreate.id, createdCall.id);
    expect(retriedCreate.version, createdCall.version);

    final callList = await client.calls(ownerToken, dm.id);
    expect(callList, isNotEmpty);
    expect(callList.first.id, createdCall.id);

    await expectLater(
      client.transitionCall(
        member.token,
        createdCall.id,
        'active',
        expectedVersion: 999,
      ),
      throwsA(isA<ApiException>()),
    );

    await expectLater(
      client.transitionCall(
        outsider.token,
        createdCall.id,
        'ended',
        expectedVersion: createdCall.version,
      ),
      throwsA(isA<ApiException>().having(
        (error) => error.serverCode,
        'serverCode',
        'forbidden',
      )),
    );

    // A same-state transition carrying no metadata is a no-op: the server
    // short-circuits it and leaves the concurrency token untouched.
    final noopCall = await client.transitionCall(
      member.token,
      createdCall.id,
      'ringing',
      expectedVersion: createdCall.version,
    );
    expect(noopCall.state, 'ringing');
    expect(noopCall.version, createdCall.version);

    final answerMetadata = <String, Object?>{
      'version': 1,
      'ciphertext': base64Encode([5, 6, 7, 8]),
      'protocol': 'mls10-openmls-v1',
      'sender_device_id': member.deviceId!,
      'action_id': 'action_call_answer_1',
    };
    final activeCall = await client.transitionCall(
      member.token,
      createdCall.id,
      'active',
      expectedVersion: noopCall.version,
      encryptedMetadata: answerMetadata,
    );
    expect(activeCall.state, 'active');
    expect(activeCall.version, createdCall.version + 1);
    final retriedAnswer = await client.transitionCall(
      member.token,
      createdCall.id,
      'active',
      expectedVersion: noopCall.version,
      encryptedMetadata: answerMetadata,
    );
    expect(retriedAnswer.id, activeCall.id);
    expect(retriedAnswer.version, activeCall.version);

    final endedCall = await client.transitionCall(
      ownerToken,
      createdCall.id,
      'ended',
      expectedVersion: activeCall.version,
    );
    expect(endedCall.state, 'ended');
    expect(endedCall.endedAt, isNotNull);

    final finalCall = (await client.calls(ownerToken, dm.id))
        .singleWhere((call) => call.id == createdCall.id);
    expect(finalCall.state, 'ended');
    expect(finalCall.version, endedCall.version);
    expect(finalCall.invitedAccountId, member.accountId);

    await client.deleteAccount(outsider.token);
    await client.deleteAccount(member.token);
  },
      skip: baseUrl == null || libraryPath == null
          ? 'live contract server or native library not configured'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));

  final linkBaseUrl = Platform.environment['VERITRA_CONTRACT_LINK_BASE_URL'];

  test('live server links a device with commit-then-reveal (L1-3)', () async {
    final client = ApiClient(baseUrl: linkBaseUrl!);
    final bindings = NativeCryptoBindings.open(libraryPath!);
    addTearDown(client.close);
    final ownerReservation = await client.reserveOwnerEnrollment(
      setupToken: 'contract-setup-token',
    );
    final ownerNative = bindings.createDevice(
      ownerReservation.accountId,
      ownerReservation.deviceId,
    );
    addTearDown(ownerNative.close);
    final owner = await client.createOwner(
      username: 'contract-link-owner',
      password: 'owner-password-123',
      deviceName: 'contract owner device',
      enrollment: ownerReservation,
      credential: ownerNative.createEnrollmentCredential(
        ownerReservation.challenge,
      ),
      setupToken: 'contract-setup-token',
      instanceName: 'Contract Link Instance',
    );
    final baseUrl = linkBaseUrl;

    // Device link (protocol v4, L1-3) end to end against the real server:
    // the existing device commits, the new device claims with its random,
    // the existing device accepts natively and only then reveals, and the
    // new device's code from the reveal is the one the existing device
    // confirms. The contract server is loopback HTTP, which only the demo
    // transport policy allows for these routes.
    final linkClient =
        ApiClient(baseUrl: client.baseUrl, transport: TransportPolicy.demo);
    addTearDown(linkClient.close);
    final linkOrigin = linkClient.baseUrl;
    final linkSecret = List<int>.filled(16, 0x55);
    final sourceRandom = List<int>.filled(32, 0x66);
    final locator = bindings.deviceLinkLocator(linkSecret);
    final link = await linkClient.createDeviceLinkV3(owner, locator,
        ownerNative.k2SourceCommitment(linkOrigin, sourceRandom));
    expect(link.state, 'pending');
    final requestId = List.filled(64, '1').join();
    final linkReservation =
        await linkClient.reserveDeviceLinkV3(locator, requestId);
    final reserved = linkReservation.fields;
    final linkedDeviceId = reserved['device_id'] as String;
    final linkedNative =
        bindings.createDevice(reserved['account_id'] as String, linkedDeviceId);
    addTearDown(linkedNative.close);
    final challenge = base64Decode(reserved['challenge'] as String);
    final linkedCredential = linkedNative.createEnrollmentCredential(challenge);
    final linkId = K2TransferId(linkOrigin, link.id);
    final linkExpiry =
        DateTime.parse(reserved['expires_at'] as String).millisecondsSinceEpoch;
    int nowMs() => DateTime.now().millisecondsSinceEpoch;
    K2LinkContext linkContext(
            List<int> transferKey, List<int> recipientRandom) =>
        K2LinkContext(
          id: linkId,
          accountId: reserved['account_id'] as String,
          nonce: base64Decode(reserved['link_nonce'] as String),
          sourceDeviceId: reserved['existing_device_id'] as String,
          sourceSigningKey:
              base64Decode(reserved['existing_signing_key'] as String),
          recipientDeviceId: linkedDeviceId,
          recipientSigningKey: linkedCredential.signingKey,
          transferPublicKey: transferKey,
          sourceCommitment:
              base64Decode(reserved['source_commitment'] as String),
          recipientRandom: recipientRandom,
        );
    final received = linkedNative.k2ReceiveBegin(
        linkContext(List<int>.filled(32, 0), List<int>.filled(32, 0)),
        linkSecret,
        originalExpiresAt: linkExpiry,
        now: nowMs());
    String token(int fill) =>
        base64Url.encode(List<int>.filled(32, fill)).replaceAll('=', '');
    final claimToken = token(21);
    final linkedDeviceSecret = token(22);
    final initialSessionToken = token(23);
    List<int> tokenHash(String value) => sha256(utf8.encode(value));
    final proof = linkedNative.k2EnrollmentProof(linkId,
        now: nowMs(),
        locator: locator,
        reservationRequestId: List<int>.filled(32, 0x11),
        deviceName: 'contract linked device',
        challenge: challenge,
        keyPackage: linkedCredential.deviceKeyPackage,
        claimTokenHash: tokenHash(claimToken),
        deviceSecretHash: tokenHash(linkedDeviceSecret),
        initialSessionHash: tokenHash(initialSessionToken));
    final claimed = await linkClient.submitDeviceLinkV3Claim(
        FrozenDeviceLinkV3Claim.fromJson(<String, Object?>{
          'code': locator,
          'protocol_version': deviceLinkV3Protocol,
          'server_origin': linkOrigin,
          'reservation_request_id': requestId,
          'enrollment_reservation_id': link.id,
          'device_name': 'contract linked device',
          'device_key_package': base64Encode(linkedCredential.deviceKeyPackage),
          'signing_key': base64Encode(linkedCredential.signingKey),
          'transfer_public_key': base64Encode(received.transferPublicKey),
          'recipient_random': base64Encode(received.recipientRandom),
          'transcript_hash': base64Encode(received.transcriptHash),
          'claim_tag': base64Encode(received.claimTag),
          'claim_token_hash': hexOf(tokenHash(claimToken)),
          'device_secret_hash': hexOf(tokenHash(linkedDeviceSecret)),
          'initial_session_token_hash': hexOf(tokenHash(initialSessionToken)),
          'challenge_signature': base64Encode(proof.signature),
        },
            requestHash: hexOf(proof.requestHash),
            transport: TransportPolicy.demo),
        linkReservation);
    // Before the reveal the server refuses an approval.
    await expectLater(
        linkClient.approveDeviceLinkV3(owner, claimed, List<int>.filled(32, 9)),
        throwsA(isA<ApiException>().having(
            (error) => error.serverCode, 'serverCode', 'reveal_required')));
    // The existing device reads the claim only through the server.
    final seen = await linkClient.deviceLinkV3(owner, link.id);
    expect(seen.state, 'claimed');
    final accepted = ownerNative.k2SourceAccept(
        linkContext(
            seen.bytes('transfer_public_key'), seen.bytes('recipient_random')),
        linkSecret,
        originalExpiresAt: linkExpiry,
        now: nowMs(),
        transcriptHash: seen.bytes('transcript_hash'),
        claimTag: seen.bytes('claim_tag'),
        sourceRandom: sourceRandom);
    final revealed =
        await linkClient.revealDeviceLinkV3(owner, seen, sourceRandom);
    final waiting =
        await linkClient.deviceLinkV3ClaimStatus(claimed, claimToken);
    expect(
        linkedNative.k2RevealSas(linkId, waiting.bytes('source_random'),
            now: nowMs()),
        accepted.sas);
    ownerNative.k2SourceConfirm(linkId, accepted.sas, now: nowMs());
    final approval = ownerNative.k2SourceApprovalRequest(linkId, now: nowMs());
    final approved = await linkClient.approveDeviceLinkV3(
        owner, revealed, approval.approvalTag);
    final completion = await linkClient.completeDeviceLinkV3(
        approved, claimToken, hexOf(tokenHash(initialSessionToken)));
    expect(completion.fields['device_id'], linkedDeviceId);

    final devicePage1 = await _getJson(
      '$baseUrl/api/v1/devices/me?limit=1',
      owner.token,
    );
    final firstDevice = Device.fromJson(
      Map<String, Object?>.from((devicePage1['devices'] as List).single as Map),
    );
    final devicePage2 = await _getJson(
      '$baseUrl/api/v1/devices/me?limit=1&after=${firstDevice.id}',
      owner.token,
    );
    expect((devicePage2['devices'] as List), isNotEmpty);
    expect(await client.devices(owner.token), hasLength(2));
    // The owner's session is recent, so it may revoke the new device.
    await client.revokeDevice(owner.token, linkedDeviceId);
  },
      skip: linkBaseUrl == null || libraryPath == null
          ? 'live link contract server or native library not configured'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));

  // L2-3 sealed sender against a real server with the switch on: the Go
  // POPRF issuer and the Rust client agree, the issuance gate waits for
  // every member device to read sealed events, the post carries no session,
  // a retry of a stored post answers 200, and sync shows the sealed event
  // with no sender only to reads that ask for it.
  final sealedBaseUrl =
      Platform.environment['VERITRA_CONTRACT_SEALED_BASE_URL'];
  test('live server issues and redeems sealed sender tokens (L2-3)', () async {
    final legacy = ApiClient(baseUrl: sealedBaseUrl!);
    final reader = ApiClient(baseUrl: sealedBaseUrl)..readsSealedEvents = true;
    final bindings = NativeCryptoBindings.open(libraryPath!);
    addTearDown(legacy.close);
    addTearDown(reader.close);
    final ownerReservation = await legacy.reserveOwnerEnrollment(
      setupToken: 'contract-setup-token',
    );
    final ownerNative = bindings.createDevice(
      ownerReservation.accountId,
      ownerReservation.deviceId,
    );
    addTearDown(ownerNative.close);
    final owner = await legacy.createOwner(
      username: 'contract-sealed-owner',
      password: 'owner-password-123',
      deviceName: 'contract owner device',
      enrollment: ownerReservation,
      credential: ownerNative.createEnrollmentCredential(
        ownerReservation.challenge,
      ),
      setupToken: 'contract-setup-token',
      instanceName: 'Contract Sealed Instance',
    );
    final invite = await legacy.createInvite(owner.token);
    final memberReservation =
        await legacy.reserveRegistrationEnrollment(invite.code);
    final memberNative = bindings.createDevice(
      memberReservation.accountId,
      memberReservation.deviceId,
    );
    addTearDown(memberNative.close);
    final member = await legacy.register(
      inviteCode: invite.code,
      username: 'contract-sealed-member',
      password: 'member-password-123',
      deviceName: 'contract member device',
      enrollment: memberReservation,
      credential: memberNative.createEnrollmentCredential(
        memberReservation.challenge,
      ),
    );
    expect((await legacy.setupStatus())['sealed_sender'], isTrue);

    final dm = await legacy.createConversationDetailed(
      owner.token,
      kind: 'dm',
      memberAccountIds: <String>[member.accountId!],
    );
    final key = await legacy.sealedKey();
    expect(key.keyId, hasLength(32));
    expect(key.publicKey, hasLength(32));

    // The issuance gate: no tokens until every member device has read sync
    // with the opt-in.
    expect((await legacy.sealedConversation(owner.token, dm.id)).eligible,
        isFalse);
    await reader.syncEvents(owner.token);
    expect((await legacy.sealedConversation(owner.token, dm.id)).eligible,
        isFalse);
    await reader.syncEvents(member.token);
    final state = await legacy.sealedConversation(owner.token, dm.id);
    expect(state.eligible, isTrue);
    expect(state.key.sameAs(key.keyId, key.publicKey), isTrue);

    // The app's token pass, with the real native client against the Go
    // issuer: today's and tomorrow's tokens, the key pinned on first use.
    final store = MemoryLocalStore();
    final tokens = SealedSender(
      origin: sealedBaseUrl,
      localStore: store,
      crypto: NativeCryptoService(bindings: bindings, localStore: store),
      // L2-3: without a franking context no token is handed out.
      loadFrankContext: () async => SealedFrankContext(
          listedKey: List<int>.filled(32, 9), ownerKeys: const <List<int>>[]),
    )..enabled = true;
    await tokens.refresh(reader, owner.token, <Conversation>[dm]);
    final pin = (await store.loadSealedKeyPin(tokens.origin))!;
    expect(pin.changed, isFalse);
    expect(key.sameAs(pin.keyId, pin.publicKey), isTrue);
    final first = (await tokens.takeFor(dm.id))!;
    expect(first.keyId, key.keyId);

    // The metadata a sealed post may carry (the app's own, with no
    // channel or leave mark). Idempotency keys need 22 or more characters.
    final sealedMetadata = <String, Object?>{
      'protocol_version': 1,
      'group_id': dm.id,
      'content_type': 'application',
      'payload_version': 1,
      'mls_epoch': 0,
    };
    final envelope = MessageEnvelope(
      conversationId: dm.id,
      idempotencyKey: 'contract-sealed-post-0001',
      ciphertext: List<int>.generate(64, (index) => 200 - index),
      cryptoProtocol: 'mls10-openmls-v1',
      cryptoMetadata: sealedMetadata,
      frankCommit: List<int>.filled(32, 0x5a),
    ).withSealedToken(first);
    // The session client refuses a sealed envelope outright.
    await expectLater(
        legacy.sendEnvelope(owner.token, envelope), throwsStateError);
    final poster = SealedPostClient(baseUrl: sealedBaseUrl);
    addTearDown(poster.close);
    await poster.post(envelope);

    // A lost answer: the same post again, with a new token, is a 200 that
    // stores nothing new and spends nothing.
    final second = (await tokens.takeFor(dm.id))!;
    await poster.post(envelope.withSealedToken(second));
    // A spent token on another post is refused as one to replace, and the
    // app's retry posts the same message with a fresh token.
    final other = MessageEnvelope(
      conversationId: dm.id,
      idempotencyKey: 'contract-sealed-post-0002',
      ciphertext: List<int>.generate(64, (index) => index),
      cryptoProtocol: 'mls10-openmls-v1',
      cryptoMetadata: sealedMetadata,
    ).withSealedToken(first);
    await expectLater(
        poster.post(other),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.serverCode, 'serverCode', 'sealed_token_spent')
            .having((e) => sealedPostOutcome(e), 'outcome',
                SealedPostOutcome.replaceToken)));
    MessageEnvelope? rewritten;
    await postSealedMessage(
      poster: poster,
      envelope: other,
      tokens: tokens,
      rewrite: (next) async {
        rewritten = next;
        return true;
      },
    );
    expect(rewritten!.idempotencyKey, 'contract-sealed-post-0002');
    expect(rewritten!.sealedToken!.nonce, isNot(first.nonce));

    // The server refuses a sealed post that carries a session.
    final raw = HttpClient();
    addTearDown(() => raw.close(force: true));
    final withSession = await raw
        .postUrl(Uri.parse(sealedBaseUrl).resolve('/api/v1/sealed/messages'));
    withSession.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${owner.token}');
    withSession.add(utf8.encode(jsonEncode(envelope
        .withSealedToken((await tokens.takeFor(dm.id))!)
        .toSealedPostJson())));
    final refused = await withSession.close();
    expect(refused.statusCode, 400);
    expect(await utf8.decodeStream(refused),
        contains('sealed_request_authenticated'));

    // Sync: the member's opted-in read shows two sealed posts, inline and
    // with no sender; a read without the opt-in shows none.
    final events = (await reader.syncEvents(member.token))
        .where((event) => event.type == sealedMessageEventType)
        .toList();
    expect(events, hasLength(2));
    final payload = Map<String, Object?>.from(events.first.payload! as Map);
    expect(payload['sealed'], isTrue);
    final inline = Map<String, Object?>.from(payload['envelope']! as Map);
    expect(inline.keys.where((name) => name.startsWith('sender')), isEmpty);
    final received = ReceivedMessageEnvelope.fromJson(inline);
    expect(received.sealed, isTrue);
    expect(received.ciphertext, envelope.ciphertext);
    expect(received.conversationId, dm.id);
    expect(
        (await legacy.syncEvents(member.token))
            .where((event) => event.type == sealedMessageEventType),
        isEmpty);
  },
      skip: sealedBaseUrl == null || libraryPath == null
          ? 'live sealed contract server or native library not configured'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));
}

class _RequestHarness {
  _RequestHarness(this.server, this.requests, this.subscription);

  final HttpServer server;
  final StreamController<HttpRequest> requests;
  final StreamSubscription<HttpRequest> subscription;

  String get baseUrl => 'http://${server.address.address}:${server.port}';
  Future<HttpRequest> get nextRequest => requests.stream.first;

  static Future<_RequestHarness> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = StreamController<HttpRequest>.broadcast();
    final subscription = server.listen(requests.add);
    return _RequestHarness(server, requests, subscription);
  }

  Future<void> close() async {
    await subscription.cancel();
    await server.close(force: true);
    await requests.close();
  }
}

Future<Map<String, Object?>> _requestJson(HttpRequest request) async =>
    Map<String, Object?>.from(
      jsonDecode(await utf8.decodeStream(request)) as Map,
    );

Future<void> _respondWithCall(
  HttpRequest request, {
  required int version,
  required String state,
}) async {
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(<String, Object?>{
    'id': 'call_1',
    'conversation_id': 'conversation_1',
    'created_by': 'account_owner',
    'invited_account_id': 'account_member',
    'state': state,
    'version': version,
    'metadata': <String, Object?>{},
    'created_at': '2026-08-30T00:00:00Z',
    'ended_at':
        state == 'ringing' || state == 'active' ? null : '2026-08-30T00:01:00Z',
    'expires_at': '2026-08-30T00:10:00Z',
  }));
  await request.response.close();
}

CallSession _callSession({required int version}) => CallSession(
      id: 'call_1',
      conversationId: 'conversation_1',
      createdBy: 'account_owner',
      invitedAccountId: 'account_member',
      state: 'ringing',
      version: version,
      metadata: const <String, Object?>{},
      createdAt: DateTime.utc(2026, 8, 30),
    );

class _UnusedMlsCrypto implements MlsConversationCryptoService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Map<String, Object?>> _getJson(String url, String token) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    expect(response.statusCode, 200);
    return Map<String, Object?>.from(
      jsonDecode(await utf8.decodeStream(response)) as Map,
    );
  } finally {
    client.close(force: true);
  }
}

String _base64UrlNoPadding(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

final _p256PublicKey = _base64UrlNoPadding([
  0x04,
  ..._hex('6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296'),
  ..._hex('4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5'),
]);

List<int> _hex(String value) => [
      for (var index = 0; index < value.length; index += 2)
        int.parse(value.substring(index, index + 2), radix: 16),
    ];
