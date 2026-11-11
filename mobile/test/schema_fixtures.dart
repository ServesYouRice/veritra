import 'package:private_messenger/storage/encrypted_database.dart';

/// Current databases are used to construct historical migration fixtures.
/// Remove W8's additions before claiming such a fixture is schema 12 or older.
Future<void> stripW8Schema(EncryptedLocalDatabase database) async {
  await stripNoticeSchema(database);
  for (final table in [
    ...EncryptedLocalDatabase.historyTables,
    'local_pins',
    'local_pending_pins',
    'local_starred',
    'local_conversation_prefs'
  ]) {
    await database.customStatement('DROP TABLE IF EXISTS $table');
  }
  final columns =
      (await database.customSelect('PRAGMA table_info(local_messages)').get())
          .map((r) => r.read<String>('name'))
          .toSet();
  for (final column in [
    'hidden_at',
    'format_json',
    'forward_hops',
    'channel_id',
    'sender_hidden',
    'sender_removed'
  ]) {
    if (columns.contains(column))
      await database
          .customStatement('ALTER TABLE local_messages DROP COLUMN $column');
  }
}

/// Remove schema15's private device-only outbox from a historical fixture.
Future<void> stripNoticeSchema(EncryptedLocalDatabase database) async {
  await stripCryptoRecordsSchema(database);
  for (final table in [
    'local_notice_references',
    'local_notice_decisions',
    'local_notice_usage'
  ]) {
    await database.customStatement('DROP TABLE IF EXISTS $table');
  }
}

/// Remove schema16's per-record sealed MLS state (D70) from a historical
/// fixture.
Future<void> stripCryptoRecordsSchema(EncryptedLocalDatabase database) async {
  await stripPendingEnrollmentSchema(database);
  await database.customStatement('DROP TABLE IF EXISTS local_crypto_records');
}

/// Remove schema17's pending device enrollment (K2/K0) from a historical
/// fixture.
Future<void> stripPendingEnrollmentSchema(
    EncryptedLocalDatabase database) async {
  await stripK2TransferSchema(database);
  for (final table in PendingEnrollmentSql.tables) {
    await database.customStatement('DROP TABLE IF EXISTS $table');
  }
}

/// Remove schema19's franking reveals and pinned report keys (C6, D95) from a
/// historical fixture. The trigger goes first: it names the table.
Future<void> stripFrankRevealSchema(EncryptedLocalDatabase database) async {
  await stripCommunityInfoSchema(database);
  await database
      .customStatement('DROP TRIGGER IF EXISTS local_frank_reveals_tombstone');
  for (final table in FrankRevealSql.tables) {
    await database.customStatement('DROP TABLE IF EXISTS $table');
  }
}

/// Remove schema18's promotion ledger and history transfer progress (K2)
/// from a historical fixture.
Future<void> stripK2TransferSchema(EncryptedLocalDatabase database) async {
  await stripFrankRevealSchema(database);
  for (final table in K2TransferSql.tables) {
    await database.customStatement('DROP TABLE IF EXISTS $table');
  }
}

/// Remove schema31's community info tables (C3) from a fixture.
Future<void> stripCommunityInfoSchema(EncryptedLocalDatabase database) async {
  await database
      .customStatement('DROP INDEX IF EXISTS local_info_events_subject');
  for (final table in CommunityInfoSql.tables) {
    await database.customStatement('DROP TABLE IF EXISTS $table');
  }
}
