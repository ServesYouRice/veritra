import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../features/chat/chat_list_screen.dart' show conversationTitle;
import '../l10n/app_localizations.dart';
import '../storage/encrypted_database.dart' show LocalMessageKind;
import '../ui/about.dart';
import 'desktop_shell.dart';

/// Where the notification choice is kept. A device preference like the
/// appearance: it survives sign-out and holds no message content.
abstract class NotificationSettingsStore {
  Future<bool?> loadHidePreview();
  Future<void> saveHidePreview(bool value);
}

class SecureNotificationSettingsStore implements NotificationSettingsStore {
  SecureNotificationSettingsStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  static const key = 'veritra.notifications.hide_preview.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<bool?> loadHidePreview() async {
    try {
      final value = await _storage.read(key: key);
      return value == null ? null : value == 'true';
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveHidePreview(bool value) async {
    try {
      await _storage.write(key: key, value: value.toString());
    } catch (_) {
      // The choice still applies for this run.
    }
  }
}

class MemoryNotificationSettingsStore implements NotificationSettingsStore {
  MemoryNotificationSettingsStore([this.hidePreview]);

  bool? hidePreview;

  @override
  Future<bool?> loadHidePreview() async => hidePreview;

  @override
  Future<void> saveHidePreview(bool value) async => hidePreview = value;
}

/// Whether a notification may show message text. The preview is shown until
/// the person hides it.
class NotificationSettings extends ChangeNotifier {
  NotificationSettings(this._store);

  final NotificationSettingsStore _store;
  bool _hidePreview = false;
  bool _changed = false;

  bool get hidePreview => _hidePreview;

  /// Reads the saved choice. A choice made before the read finishes wins.
  Future<void> load() async {
    final saved = await _store.loadHidePreview();
    if (saved == null || _changed || saved == _hidePreview) return;
    _hidePreview = saved;
    notifyListeners();
  }

  Future<void> setHidePreview(bool value) async {
    _changed = true;
    if (value != _hidePreview) {
      _hidePreview = value;
      notifyListeners();
    }
    await _store.saveHidePreview(value);
  }
}

/// Makes the notification settings reachable from the settings screen.
class NotificationSettingsScope
    extends InheritedNotifier<NotificationSettings> {
  const NotificationSettingsScope({
    required NotificationSettings settings,
    required super.child,
    super.key,
  }) : super(notifier: settings);

  static NotificationSettings? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<NotificationSettingsScope>()
      ?.notifier;
}

/// Raises a desktop notification for a message that was decrypted and stored
/// on this device while the window is not in front. The text is built here,
/// from the local record; nothing is sent to the server for it.
class MessageNotifier {
  MessageNotifier({
    required this.state,
    required this.shell,
    required this.notifier,
    required this.settings,
    required this.l10n,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppState state;
  final DesktopShell shell;
  final DesktopNotifier notifier;
  final NotificationSettings settings;

  /// The strings for the device language, read when a notification is built.
  final AppLocalizations Function() l10n;
  final DateTime Function() _now;

  /// Older messages come from catching up after being offline, not from a
  /// message arriving now.
  static const freshness = Duration(minutes: 10);
  static const _maxPerBatch = 3;
  static const _previewLimit = 140;

  final Set<String> _announced = <String>{};

  void attach() => state.onMessagesPublished = _onPublished;

  void detach() {
    if (state.onMessagesPublished == _onPublished) {
      state.onMessagesPublished = null;
    }
  }

  void _onPublished(List<ReceivedMessageEnvelope> envelopes) {
    unawaited(handle(envelopes).catchError((Object _) {}));
  }

  Future<void> handle(List<ReceivedMessageEnvelope> envelopes) async {
    final session = state.session;
    if (session == null) return;
    final candidates =
        <String, ({ReceivedMessageEnvelope envelope, String text})>{};
    for (final envelope in envelopes) {
      if (envelope.editedAt != null || envelope.deletedAt != null) continue;
      if (envelope.senderAccountId == session.accountId ||
          envelope.senderDeviceId == session.deviceId) {
        continue;
      }
      if (state.isBlocked(envelope.senderAccountId)) continue;
      if (_now().difference(envelope.createdAt) > freshness) continue;
      final local = state.historyFor(envelope.conversationId).forEnvelope(
            envelope,
          );
      if (local == null || local.kind != LocalMessageKind.text) continue;
      if (local.deletedAt != null) continue;
      if (!_announced.add(envelope.id)) continue;
      // One notification per conversation: the newest message.
      final previous = candidates[envelope.conversationId];
      if (previous == null ||
          envelope.createdAt.isAfter(previous.envelope.createdAt)) {
        candidates[envelope.conversationId] =
            (envelope: envelope, text: local.body ?? '');
      }
    }
    if (candidates.isEmpty) return;
    if (await shell.isWindowActive()) return;

    var shown = 0;
    for (final entry in candidates.entries) {
      if (shown >= _maxPerBatch) break;
      // The mute flag lives on the server and is read per conversation. If it
      // cannot be read, stay quiet rather than notify for a muted chat.
      if (!await state.loadConversationMuted(entry.key)) continue;
      if (state.isMuted(entry.key)) continue;
      final strings = l10n();
      if (settings.hidePreview) {
        await notifier.show(
          title: veritraProductName,
          body: strings.notificationNewMessage,
        );
      } else {
        final conversation = state.conversations
            .where((item) => item.id == entry.key)
            .firstOrNull;
        await notifier.show(
          title: conversation == null
              ? veritraProductName
              : conversationTitle(strings, conversation),
          body: _preview(entry.value.text),
        );
      }
      shown++;
    }
  }

  static String _preview(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.runes.length <= _previewLimit) return flat;
    return '${String.fromCharCodes(flat.runes.take(_previewLimit))}…';
  }
}
