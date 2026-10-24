import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

/// Largest conversation that shows ticks (W5); the server stops keeping
/// delivery cursors past the same number, and channels never show them.
const int tickMaxMembers = 20;

/// How far a message you sent has got (W5).
enum MessageTick {
  /// The server accepted it.
  sent,

  /// Every other member's device has fetched it.
  delivered,

  /// Every other member has read it.
  read,
}

/// The other members' delivery and read cursors, per conversation, as the
/// server last said. Held in memory only: the server is the record, and a
/// conversation reads them again when it opens and when a receipt event
/// arrives.
class ReceiptsState extends ChangeNotifier {
  final Map<String, List<MemberReceipt>> _byConversation =
      <String, List<MemberReceipt>>{};

  List<MemberReceipt> receiptsFor(String conversationId) =>
      _byConversation[conversationId] ?? const <MemberReceipt>[];

  void set(String conversationId, List<MemberReceipt> receipts) {
    _byConversation[conversationId] =
        List<MemberReceipt>.unmodifiable(receipts);
    notifyListeners();
  }

  void clear() {
    if (_byConversation.isEmpty) return;
    _byConversation.clear();
    notifyListeners();
  }

  /// The tick for a message created at [createdAt].
  ///
  /// Group rule: a message is delivered when every other member has a
  /// delivery cursor that reaches it, and read when every other member has
  /// read it. One member who has not is enough to hold it back, so a tick
  /// never promises more than "everyone". With nobody else to ask (nothing
  /// loaded, or everyone else left or blocked) it stays at sent.
  ///
  /// [showRead] is false when the reader keeps their own read receipts off:
  /// like WhatsApp, they then see no read state either, only delivery. A
  /// member who keeps theirs off has no read cursor and holds a group's read
  /// tick back the same way.
  MessageTick tickFor(
    String conversationId,
    DateTime createdAt, {
    required bool showRead,
  }) =>
      tickForReceipts(receiptsFor(conversationId), createdAt,
          showRead: showRead);
}

/// [ReceiptsState.tickFor] over an explicit list.
MessageTick tickForReceipts(
  List<MemberReceipt> receipts,
  DateTime createdAt, {
  required bool showRead,
}) {
  if (receipts.isEmpty) return MessageTick.sent;
  bool covers(DateTime? through) =>
      through != null && !through.isBefore(createdAt);
  if (showRead && receipts.every((r) => covers(r.readThrough))) {
    return MessageTick.read;
  }
  if (receipts.every((r) => covers(r.deliveredThrough))) {
    return MessageTick.delivered;
  }
  return MessageTick.sent;
}

/// Where the read-receipts switch is kept. A device preference, not account
/// data, and it holds no message content.
abstract class ReceiptPreferenceStore {
  Future<bool?> load();
  Future<void> save(bool sendReadReceipts);
}

/// Keeps the switch in the platform keystore the app already uses. A keystore
/// failure falls back to the default (on); a preference must never block
/// startup.
class SecureReceiptPreferenceStore implements ReceiptPreferenceStore {
  SecureReceiptPreferenceStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: false),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  static const key = 'veritra.read_receipts.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<bool?> load() async {
    try {
      return switch (await _storage.read(key: key)) {
        'on' => true,
        'off' => false,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(bool sendReadReceipts) async {
    try {
      await _storage.write(key: key, value: sendReadReceipts ? 'on' : 'off');
    } catch (_) {
      // The choice still applies for this run.
    }
  }
}

class MemoryReceiptPreferenceStore implements ReceiptPreferenceStore {
  MemoryReceiptPreferenceStore([this.value]);

  bool? value;

  @override
  Future<bool?> load() async => value;

  @override
  Future<void> save(bool sendReadReceipts) async => value = sendReadReceipts;
}

/// The "send read receipts" switch (W5). On by default. Off means this device
/// shares no read state (the server keeps a private cursor for the unread
/// count only) and shows none of other people's read state.
class ReceiptPreferences extends ChangeNotifier {
  ReceiptPreferences(this._store);

  final ReceiptPreferenceStore _store;
  bool _sendReadReceipts = true;
  bool _changed = false;
  Future<void>? _loaded;

  bool get sendReadReceipts => _sendReadReceipts;

  /// Completes once the saved choice has been read; a read receipt waits for
  /// it so a stored "off" is never missed at startup.
  Future<void> get loaded => _loaded ??= _load();

  Future<void> _load() async {
    final saved = await _store.load();
    if (saved != null && !_changed && saved != _sendReadReceipts) {
      _sendReadReceipts = saved;
      notifyListeners();
    }
  }

  Future<void> setSendReadReceipts(bool value) async {
    _changed = true;
    if (value != _sendReadReceipts) {
      _sendReadReceipts = value;
      notifyListeners();
    }
    await _store.save(value);
  }
}
