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
  /// loaded, or everyone else left or blocked) it stays at sent. A member
  /// who joined after the message was sent is not asked.
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
  // A member who joined after the message was not among its recipients.
  receipts = receipts
      .where((r) => r.memberSince == null || !r.memberSince!.isAfter(createdAt))
      .toList(growable: false);
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
  /// The saved choice, or null when none was ever saved. Throws when the
  /// store cannot be read, so a failure is never mistaken for the default.
  Future<bool?> load();

  /// Throws when the choice could not be saved.
  Future<void> save(bool sendReadReceipts);
}

/// Keeps the switch in the platform keystore the app already uses. Keystore
/// errors are thrown to [ReceiptPreferences], which keeps read state private
/// until the choice is known; a preference must never block startup.
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
  Future<bool?> load() async => switch (await _storage.read(key: key)) {
        'on' => true,
        'off' => false,
        _ => null,
      };

  @override
  Future<void> save(bool sendReadReceipts) =>
      _storage.write(key: key, value: sendReadReceipts ? 'on' : 'off');
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
  bool _known = false;
  bool _saveFailed = false;
  Future<void>? _loaded;

  /// The switch as shown. Before the saved choice is known this is the
  /// default (on), but [shareReadReceipts] stays false.
  bool get sendReadReceipts => _sendReadReceipts;

  /// Whether a read receipt may be shared now: only once the choice is known
  /// (read from the store, or made in this run) and it is on. While a
  /// keystore error hides a saved "off", read state stays private.
  bool get shareReadReceipts => _known && _sendReadReceipts;

  /// The last choice could not be saved on this device, so a later launch
  /// may not see it until the account's setting is read from the server.
  bool get saveFailed => _saveFailed;

  /// Completes once the saved choice has been read, or the read has failed;
  /// it never throws. A read receipt waits for it so a stored "off" is never
  /// missed at startup. A failed read is tried again on the next wait.
  Future<void> get loaded => _loaded ??= _load().then((read) {
        if (!read) _loaded = null;
      });

  Future<bool> _load() async {
    final bool? saved;
    try {
      saved = await _store.load();
    } catch (_) {
      return false;
    }
    if (_changed) return true;
    _known = true;
    if (saved != null) _sendReadReceipts = saved;
    // Knowing the choice changes [shareReadReceipts] even when the switch
    // keeps its default, and ticks follow it.
    notifyListeners();
    return true;
  }

  /// Applies [value] at once and saves it. False when it could not be saved
  /// ([saveFailed]); the choice still applies for this run.
  Future<bool> setSendReadReceipts(bool value) async {
    _changed = true;
    final wasKnown = _known;
    _known = true;
    if (value != _sendReadReceipts || !wasKnown) {
      _sendReadReceipts = value;
      notifyListeners();
    }
    var saved = true;
    try {
      await _store.save(value);
    } catch (_) {
      saved = false;
    }
    if (_saveFailed != !saved) {
      _saveFailed = !saved;
      notifyListeners();
    }
    return saved;
  }
}
