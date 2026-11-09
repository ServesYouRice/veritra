part of 'encrypted_database.dart';

extension InviteAnchorSql on EncryptedLocalDatabase {
  Future<void> _createInviteAnchors() =>
      customStatement('''CREATE TABLE IF NOT EXISTS local_invite_anchors (
    conversation_id TEXT PRIMARY KEY NOT NULL,
    account_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    signing_key BLOB NOT NULL CHECK(length(signing_key) = 32)
  )''');

  Future<void> writeInviteAnchor(InviteAnchor anchor) => customStatement(
          'INSERT INTO local_invite_anchors VALUES (?, ?, ?, ?) '
          'ON CONFLICT(conversation_id) DO UPDATE SET account_id=excluded.account_id, '
          'device_id=excluded.device_id, signing_key=excluded.signing_key',
          [
            anchor.conversationId,
            anchor.accountId,
            anchor.deviceId,
            Uint8List.fromList(anchor.signingKey)
          ]);

  Future<InviteAnchor?> readInviteAnchor(String conversationId) async {
    final row = await customSelect(
        'SELECT * FROM local_invite_anchors WHERE conversation_id = ?',
        variables: [Variable.withString(conversationId)]).getSingleOrNull();
    if (row == null) return null;
    return InviteAnchor(
        conversationId: conversationId,
        accountId: row.read<String>('account_id'),
        deviceId: row.read<String>('device_id'),
        signingKey: row.read<Uint8List>('signing_key'));
  }

  Future<void> _clearInviteAnchors() =>
      customStatement('DELETE FROM local_invite_anchors');
}
