import 'dart:convert';
import 'dart:typed_data';

import '../../core/api_client.dart';
import 'room_ports.dart';

/// [RoomApi] over the server's `/api/v1/rooms` routes.
class ApiClientRoomApi implements RoomApi {
  ApiClientRoomApi(this.client, this.token);
  final ApiClient client;

  /// The session token, read fresh for each call.
  final String Function() token;

  Uint8List _bytes(Object? value) =>
      value is String ? Uint8List.fromList(base64Decode(value)) : Uint8List(0);

  Uint8List? _optionalBytes(Object? value) =>
      value is String && value.isNotEmpty ? _bytes(value) : null;

  List<RoomSeat> _seats(Object? rows) => [
        for (final row in (rows as List? ?? const []).cast<Map>())
          RoomSeat(
            deviceId: row['device_id'] as String,
            accountId: row['account_id'] as String,
            inGroup: row['in_group'] == true,
            offerKeyPackage: _optionalBytes(row['offer_key_package']),
            offerSignature: _optionalBytes(row['offer_signature']),
            offerNonce: row['offer_nonce'] as String?,
            offerExpiresAt: (row['offer_expires_at'] as num?)?.toInt(),
          ),
      ];

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ApiException catch (error) {
      switch (error.serverCode) {
        case 'room_epoch_conflict':
          throw const RoomEpochConflict();
        case 'room_ended':
        case 'not_in_room':
          throw const RoomGone();
      }
      rethrow;
    }
  }

  @override
  Future<RoomJoinInfo> join(String conversationId) => _guard(() async {
        final json = await client.joinRoom(token(), conversationId);
        return RoomJoinInfo(
          callId: json['call_id'] as String,
          groupId: _bytes(json['group_id']),
          epoch: (json['epoch'] as num).toInt(),
          created: json['created'] == true,
          seats: _seats(json['participants']),
          sfuUrl: json['sfu_url'] as String,
          sfuToken: json['sfu_token'] as String,
          nonce: json['nonce'] as String,
          maxDevices: (json['max_devices'] as num?)?.toInt() ?? 50,
        );
      });

  @override
  Future<RoomState> state(String callId) => _guard(() async {
        final json = await client.roomState(token(), callId);
        return RoomState(
          callId: callId,
          groupId: _bytes(json['group_id']),
          epoch: (json['epoch'] as num).toInt(),
          seats: _seats(json['participants']),
        );
      });

  @override
  Future<List<RoomCommitRecord>> commits(String callId, {required int after}) =>
      _guard(() async {
        final json = await client.roomCommits(token(), callId, after: after);
        return [
          for (final row in (json['commits'] as List? ?? const []).cast<Map>())
            RoomCommitRecord(
              epoch: (row['epoch'] as num).toInt(),
              committerDeviceId: row['committer_device_id'] as String,
              commit: _bytes(row['commit']),
              welcome: _optionalBytes(row['welcome']),
            ),
        ];
      });

  @override
  Future<int> sendCommit(
    String callId, {
    required int expectedEpoch,
    required Uint8List commit,
    Uint8List? welcome,
    List<String> addedDeviceIds = const [],
  }) =>
      _guard(() async {
        final json = await client.sendRoomCommit(token(), callId, {
          'expected_epoch': expectedEpoch,
          'commit': base64Encode(commit),
          if (welcome != null) 'welcome': base64Encode(welcome),
          if (addedDeviceIds.isNotEmpty) 'added_device_ids': addedDeviceIds,
        });
        return (json['epoch'] as num).toInt();
      });

  @override
  Future<void> sendOffer(
    String callId, {
    required String nonce,
    required Uint8List keyPackage,
    required Uint8List signature,
    required int expiresAt,
  }) =>
      _guard(() => client.sendRoomOffer(token(), callId, {
            'nonce': nonce,
            'key_package': base64Encode(keyPackage),
            'signature': base64Encode(signature),
            'expires_at': expiresAt,
          }));

  @override
  Future<void> leave(String callId) =>
      _guard(() => client.leaveRoom(token(), callId));
}
