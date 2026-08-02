import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

void main() {
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

    final pushId = await client.registerWebPush(
      owner.token,
      endpoint: 'https://push.example.test/contract',
      publicKey: _p256PublicKey,
      authSecret: _base64UrlNoPadding(List<int>.filled(16, 7)),
    );
    expect((await client.pushConfig(owner.token))['enabled'], isFalse);
    await client.disablePush(owner.token, pushId);

    final link = await client.createDeviceLink(owner.token);
    final fetchedLink = await client.deviceLink(owner.token, link.id);
    expect(fetchedLink.id, link.id);
    expect(fetchedLink.verificationCode, link.verificationCode);
    expect(fetchedLink.state, link.state);
    final linkReservation =
        await client.reserveDeviceLinkEnrollment(link.code!);
    final linkedNative = bindings.createDevice(
      linkReservation.accountId,
      linkReservation.deviceId,
    );
    addTearDown(linkedNative.close);
    final claim = await client.claimDeviceLink(
      code: link.code!,
      deviceName: 'contract linked device',
      enrollment: linkReservation,
      credential: linkedNative.createEnrollmentCredential(
        linkReservation.challenge,
      ),
      verification: linkedNative.deriveDeviceLinkVerification(
        protocolVersion: linkReservation.protocolVersion!,
        peerDeviceId: linkReservation.existingDeviceId!,
        peerSigningKey: linkReservation.existingSigningKey!,
        linkNonce: linkReservation.linkNonce!,
        localIsExistingDevice: false,
      ),
    );
    final linkedVerification = linkedNative.deriveDeviceLinkVerification(
      protocolVersion: linkReservation.protocolVersion!,
      peerDeviceId: linkReservation.existingDeviceId!,
      peerSigningKey: linkReservation.existingSigningKey!,
      linkNonce: linkReservation.linkNonce!,
      localIsExistingDevice: false,
    );
    expect(
        await client.completeDeviceLinkClaim(
            link.id, claim.claimToken, linkedVerification.transcriptHash),
        isNull);
    final ownerVerification = ownerNative.deriveDeviceLinkVerification(
      protocolVersion: linkReservation.protocolVersion!,
      peerDeviceId: linkReservation.deviceId,
      peerSigningKey: linkedNative.signingPublicKey(),
      linkNonce: linkReservation.linkNonce!,
      localIsExistingDevice: true,
    );
    expect(ownerVerification.sas, linkedVerification.sas);
    await client.approveDeviceLink(
      owner.token,
      link.id,
      ownerVerification.transcriptHash,
    );
    final linkedSession = await client.completeDeviceLinkClaim(
        link.id, claim.claimToken, linkedVerification.transcriptHash);
    expect(linkedSession?.deviceId, linkReservation.deviceId);

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
    await client.reauthenticate(
      owner.token,
      'owner-password-123',
      owner.deviceSecret!,
    );
    await client.logoutAll(owner.token);
    await expectLater(
      client.conversations(login.token),
      throwsA(isA<ApiException>().having(
        (error) => error.serverCode,
        'serverCode',
        'unauthorized',
      )),
    );
    await client.changePassword(owner.token, 'owner-password-456');
    final relogin = await client.login(
      username: 'contract-owner',
      password: 'owner-password-456',
      deviceId: owner.deviceId!,
      deviceSecret: owner.deviceSecret!,
    );
    await client.logout(relogin.token);

    await client.reauthenticate(
      owner.token,
      'owner-password-456',
      owner.deviceSecret!,
    );
    await client.revokeDevice(owner.token, linkReservation.deviceId);
    await expectLater(
      client.message(owner.token, 'msg_missing'),
      throwsA(isA<ApiException>()
          .having((error) => error.statusCode, 'status', 404)
          .having((error) => error.serverCode, 'serverCode', 'not_found')),
    );
    await client.deleteAccount(member.token);
  },
      skip: baseUrl == null || libraryPath == null
          ? 'live contract server or native library not configured'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));
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
