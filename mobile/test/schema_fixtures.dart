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
    'sender_hidden'
  ]) {
    if (columns.contains(column))
      await database
          .customStatement('ALTER TABLE local_messages DROP COLUMN $column');
  }
}

/// Remove schema15's private device-only outbox from a historical fixture.
Future<void> stripNoticeSchema(EncryptedLocalDatabase database) async {
  for (final table in [
    'local_notice_references',
    'local_notice_decisions',
    'local_notice_usage'
  ]) {
    await database.customStatement('DROP TABLE IF EXISTS $table');
  }
}
