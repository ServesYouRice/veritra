part of 'encrypted_database.dart';

// Local schema 27 (C6, docs/designs/C6-reports-franking.md): which messages
// this account already reported on a server, so a retry or a second tap files
// nothing twice (the server cannot tell: since D95 it never sees the message).
// One new table by raw SQL, like the other later tables. It holds ids only,
// never text or keys, and never goes into a backup, a snapshot, a K2 transfer
// or a log. It is cleared with the pinned report keys on a full local wipe.

extension FiledReportSql on EncryptedLocalDatabase {
  Future<void> _createFiledReports() async {
    await customStatement('CREATE TABLE IF NOT EXISTS local_filed_reports ('
        'origin TEXT NOT NULL CHECK(length(origin) BETWEEN 1 AND 256), '
        'account_id TEXT NOT NULL CHECK(length(account_id) BETWEEN 1 AND 128), '
        'message_key TEXT NOT NULL CHECK(length(message_key) BETWEEN 1 AND 260), '
        'filed_at INTEGER NOT NULL, '
        'PRIMARY KEY(origin, account_id, message_key))');
  }

  Future<bool> readReportFiled(
      String origin, String accountId, String messageKey) async {
    final row = await customSelect(
        'SELECT 1 AS found FROM local_filed_reports '
        'WHERE origin = ? AND account_id = ? AND message_key = ?',
        variables: [
          Variable.withString(origin),
          Variable.withString(accountId),
          Variable.withString(messageKey),
        ]).getSingleOrNull();
    return row != null;
  }

  Future<void> writeReportFiled(
      String origin, String accountId, String messageKey, int filedAt) {
    if (origin.isEmpty || accountId.isEmpty || messageKey.isEmpty) {
      throw const FormatException('invalid filed report');
    }
    return customStatement(
        'INSERT OR IGNORE INTO local_filed_reports '
        '(origin, account_id, message_key, filed_at) VALUES (?, ?, ?, ?)',
        <Object?>[origin, accountId, messageKey, filedAt]);
  }

  Future<void> _clearFiledReports() =>
      customStatement('DELETE FROM local_filed_reports');
}
