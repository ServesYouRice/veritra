import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto/app_payload.dart';
import '../crypto/profile_key_payload.dart';
import '../crypto/profile_record_codec.dart';
import '../storage/local_store.dart';
import 'api_errors.dart';
import 'profile_models.dart';

/// W11 encrypted profiles (docs/designs/W11-profiles.md): fetching and
/// opening the records, publishing this account's and a group's record,
/// handing the key to the people who need it, and rotating it.
///
/// The server stores ciphertext only. Keys travel in MLS messages, so only
/// people who share a conversation with the subject ever hold one. Nothing in
/// here is logged: no name, photo, key or key id.

/// What a screen shows for a subject: a name and a photo, either may be
/// missing. A null name means "show the username".
class ProfileView {
  const ProfileView({this.name, this.photoPng});
  final String? name;
  final Uint8List? photoPng;
}

/// The server calls the service makes, with the session token already bound.
abstract interface class ProfileApi {
  Future<ProfileFetch> fetch(String kind, String subjectId,
      {int? ifNoneMatchVersion});
  Future<int> put(String kind, String subjectId, Uint8List blob,
      {required String keyId, int? ifMatchVersion});
  Future<List<ProfileVersion>> versions(
      {List<String> accountIds, List<String> conversationIds});
}

/// Sends a hidden key message into one conversation. True once it is queued.
typedef ProfileKeySender = Future<bool> Function(
    String conversationId, AppPayloadType type, Map<String, Object?> body);

/// Another device of this account wrote the record under a key this device
/// does not hold yet. The edit is not applied; try again once the key
/// arrives over MLS.
class ProfileConflictException implements Exception {
  const ProfileConflictException();
  @override
  String toString() => 'ProfileConflictException';
}

class ProfileService extends ChangeNotifier {
  ProfileService({
    required this.store,
    required this.codec,
    required this.api,
    required this.accountId,
    required this.sendKey,
    required this.postableConversationIds,
    required this.coMemberAccountIds,
    this.knownConversationIds = _unknownConversations,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalStore store;
  final ProfileRecordCodec codec;
  final ProfileApi api;

  /// This account.
  final String accountId;
  final ProfileKeySender sendKey;

  /// Conversations where this account may post a key now. Announcement-only
  /// ones are left out, since the server would refuse the message (S14).
  final List<String> Function() postableConversationIds;

  /// Every other account this account currently shares a conversation with,
  /// or null when the rosters are not all known yet (no rotation is judged
  /// from a partial picture).
  final Set<String>? Function() coMemberAccountIds;

  /// Every conversation this account is in, once the list has come from the
  /// server this session; null before. A queued key is dropped only when
  /// this is known and the conversation is not in it.
  final Set<String>? Function() knownConversationIds;
  static Set<String>? _unknownConversations() => null;
  final DateTime Function() _clock;

  static const _ownKeyId = 'own.key_id';
  static const _ownDue = 'own.due';
  static const _ownAudience = 'own.audience';
  static const _groupKeyIdPrefix = 'group.key_id.';
  static const _groupDuePrefix = 'group.due.';
  static const _deliverPrefix = 'deliver.';
  static const _sidecarPrefix = 'sidecar.group.';
  static const _seenPrefix = 'seen.';

  final Map<String, StoredProfile> _profiles = <String, StoredProfile>{};
  final Set<String> _attempted = <String>{};
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;

  static String _id(String kind, String subjectId) => '$kind\u0000$subjectId';

  static String _deliverName(bool group, String conversationId) =>
      '${_deliverPrefix}${group ? 'group' : 'account'}.$conversationId';

  int get _now => _clock().toUtc().millisecondsSinceEpoch;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  int _revision = 0;

  /// Moves on every change a screen could show; a list that rebuilds only on
  /// selected values reads this.
  int get revision => _revision;

  void _changed() {
    if (_disposed) return;
    _revision++;
    notifyListeners();
  }

  // ---- reading ----------------------------------------------------------

  /// Loads the cached records. Call once before the screens read.
  Future<void> load() async {
    _profiles.clear();
    for (final kind in [profileSubjectAccount, profileSubjectConversation]) {
      for (final profile in await store.loadProfiles(kind)) {
        _profiles[_id(kind, profile.subjectId)] = profile;
      }
    }
    _changed();
  }

  ProfileView? _view(String kind, String id) {
    final profile = _profiles[_id(kind, id)];
    if (profile == null || profile.isPlaceholder) return null;
    if (profile.name == null && profile.photoPng == null) return null;
    return ProfileView(name: profile.name, photoPng: profile.photoPng);
  }

  /// The display name and photo of [accountId], or null to show the username.
  ProfileView? account(String accountId) =>
      _view(profileSubjectAccount, accountId);

  /// The name and photo of a group, or null to show the legacy title.
  ProfileView? conversation(String conversationId) =>
      _view(profileSubjectConversation, conversationId);

  ProfileView? get own => account(accountId);

  /// The server version this device last accepted for a subject (0: none).
  int versionOf(String kind, String subjectId) {
    final profile = _profiles[_id(kind, subjectId)];
    return profile == null || profile.isPlaceholder ? 0 : profile.serverVersion;
  }

  // ---- fetching ---------------------------------------------------------

  /// Fetches one record and keeps it only when every check of the design's
  /// "Receiving and caching" list passes. A failure, a 404 or a record this
  /// device holds no key for keeps what is cached (S9).
  Future<void> refresh(String kind, String subjectId,
          {bool keyArrived = false}) =>
      _serial(() => _refresh(kind, subjectId, keyArrived: keyArrived));

  Future<void> _refresh(String kind, String subjectId,
      {required bool keyArrived}) async {
    final cached = await store.loadProfile(kind, subjectId);
    final haveRecord = cached != null && !cached.isPlaceholder;
    final ProfileFetch served;
    try {
      served = await api.fetch(kind, subjectId,
          ifNoneMatchVersion: haveRecord ? cached.serverVersion : null);
    } on ApiException {
      return;
    } on Object {
      return;
    }
    final keys = await store.loadProfileKeys(kind, subjectId);
    if (served.notModified || served.blob == null) {
      // Nothing new on the server, so a group key that just arrived does not
      // open the record it serves: junk from a member, dropped at once.
      if (served.notModified &&
          keyArrived &&
          haveRecord &&
          kind == profileSubjectConversation) {
        await _dropOtherGroupKeys(subjectId, keys, cached.keyId, cached.keyId);
      }
      return;
    }
    final key = keys.where((k) => k.keyId == served.keyId).firstOrNull;
    if (key == null) {
      // A group key that does not match the served record cannot open it:
      // drop what arrived since, so junk cannot crowd out the real key.
      if (keyArrived && kind == profileSubjectConversation) {
        await _dropOtherGroupKeys(subjectId, keys, null, cached?.keyId);
      }
      return;
    }
    final ProfileRecord record;
    try {
      record = codec.open(
        key: key.key,
        servedKeyId: served.keyId,
        servedVersion: served.version,
        kind: kind,
        subjectId: subjectId,
        blob: served.blob!,
        cachedRevision: haveRecord ? cached.revision : 0,
        versionFloor: cached?.versionFloor ?? 0,
      );
    } on ProfileRecordException {
      // A held key whose id is the served id is the real key (ids are
      // derived), so a failure means the blob is bad. Never delete it: a
      // member or the server could otherwise make everyone drop the key.
      return;
    }
    final saved = await store.saveProfile(StoredProfile(
      kind: kind,
      subjectId: subjectId,
      serverVersion: served.version,
      keyId: served.keyId,
      revision: record.revision,
      name: record.name,
      photoPng: record.photo?.png,
      fetchedAt: _now,
      versionFloor: cached?.versionFloor ?? 0,
    ));
    if (!saved) return;
    if (kind == profileSubjectConversation && keyArrived) {
      await _dropOtherGroupKeys(subjectId, keys, served.keyId, served.keyId);
    }
    _profiles[_id(kind, subjectId)] =
        (await store.loadProfile(kind, subjectId))!;
    _changed();
  }

  Future<void> _dropOtherGroupKeys(
      String conversationId,
      List<StoredProfileKey> keys,
      String? servedKeyId,
      String? cachedKeyId) async {
    for (final key in keys) {
      if (key.keyId != servedKeyId && key.keyId != cachedKeyId) {
        await store.deleteProfileKey(
            profileSubjectConversation, conversationId, key.keyId);
      }
    }
  }

  /// A `profile.updated` sync event: IDs and a version, never content.
  Future<void> onProfileUpdated(Object? payload) async {
    if (payload is! Map) return;
    final kind = payload['subject_kind'];
    final id = payload['subject_id'];
    final version = payload['version'];
    if (kind is! String ||
        id is! String ||
        version is! int ||
        (kind != profileSubjectAccount && kind != profileSubjectConversation) ||
        id.isEmpty ||
        id.length > 128) {
      return;
    }
    if (version <= versionOf(kind, id)) return;
    await refresh(kind, id);
  }

  /// Fetches the records of keys that arrived since this device last tried:
  /// a key whose id differs from the cached record's, tried once per run.
  Future<void> onKeysMayHaveArrived() async {
    final subjects = <String, (String, String)>{};
    for (final kind in [profileSubjectAccount, profileSubjectConversation]) {
      // Group keys are scanned per group, account keys per profile row and
      // per held key.
      for (final key in await store.loadAllProfileKeys(kind)) {
        final cached = _profiles[_id(kind, key.subjectId)];
        if (cached != null && cached.keyId == key.keyId) continue;
        final attempt = '$kind\u0000${key.subjectId}\u0000${key.keyId}';
        if (!_attempted.add(attempt)) continue;
        subjects[_id(kind, key.subjectId)] = (kind, key.subjectId);
      }
    }
    for (final (kind, id) in subjects.values) {
      await refresh(kind, id, keyArrived: true);
    }
  }

  /// The periodic check, at start and every 24 hours: one batch version
  /// request per 200 subjects, then a fetch only for what changed.
  Future<void> checkVersions({
    required Iterable<String> accountIds,
    required Iterable<String> conversationIds,
  }) async {
    final accounts = accountIds.toSet().toList();
    final groups = conversationIds.toSet().toList();
    for (var i = 0; i < accounts.length || i < groups.length; i += 200) {
      final List<ProfileVersion> versions;
      try {
        versions = await api.versions(
          accountIds: accounts.skip(i).take(200).toList(),
          conversationIds: groups.skip(i).take(200).toList(),
        );
      } on Object {
        return;
      }
      for (final v in versions) {
        if ((v.kind == profileSubjectAccount ||
                v.kind == profileSubjectConversation) &&
            v.version > versionOf(v.kind, v.id)) {
          await refresh(v.kind, v.id);
        }
      }
    }
  }

  // ---- publishing -------------------------------------------------------

  /// Sets this account's display name and photo (null clears each).
  Future<void> saveOwnProfile({String? name, ProfilePhoto? photo}) =>
      _serial(() => _publish(profileSubjectAccount, accountId, name, photo));

  /// Sets a group's name and photo (null clears each).
  Future<void> saveGroupProfile(String conversationId,
          {String? name, ProfilePhoto? photo}) =>
      _serial(() =>
          _publish(profileSubjectConversation, conversationId, name, photo));

  String _keyStateName(String kind, String subjectId) =>
      kind == profileSubjectAccount
          ? _ownKeyId
          : '$_groupKeyIdPrefix$subjectId';

  String _dueName(String kind, String subjectId) =>
      kind == profileSubjectAccount ? _ownDue : '$_groupDuePrefix$subjectId';

  /// The key writes use: the one that opens the cached record, else the one
  /// last recorded as current. Null when this device holds neither.
  Future<StoredProfileKey?> _currentKey(String kind, String subjectId) async {
    final keys = await store.loadProfileKeys(kind, subjectId);
    final cached = await store.loadProfile(kind, subjectId);
    if (cached != null && !cached.isPlaceholder) {
      final match = keys.where((k) => k.keyId == cached.keyId).firstOrNull;
      if (match != null) return match;
    }
    final recorded =
        await store.loadProfileState(_keyStateName(kind, subjectId));
    return keys.where((k) => k.keyId == recorded).firstOrNull;
  }

  /// The id of the key this account's profile is under, as far as this
  /// device knows: the key that opens the cached record, else the one last
  /// published from here. Null before any key exists. A second device that
  /// only received the key counts too.
  Future<String?> _ownKeyIdNow() async =>
      (await _currentKey(profileSubjectAccount, accountId))?.keyId;

  Future<void> _publish(
      String kind, String subjectId, String? name, ProfilePhoto? photo) async {
    final trimmed = name?.trim();
    if (trimmed != null &&
        trimmed.isNotEmpty &&
        !ProfileRecordCodec.validName(trimmed, kind: kind)) {
      throw const ProfileRecordException(ProfileRecordFailure.badName);
    }
    final cleanName = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final due = await store.loadProfileState(_dueName(kind, subjectId)) == '1';
    final cached = await store.loadProfile(kind, subjectId);
    var version =
        cached == null || cached.isPlaceholder ? 0 : cached.serverVersion;
    var existing = await _currentKey(kind, subjectId);
    for (var attempt = 0;; attempt++) {
      final StoredProfileKey key;
      final bool rotated;
      if (existing == null || due) {
        // The first save, or the first write after a rotation became due.
        final fresh = codec.newKey();
        final id = ProfileRecordCodec.keyId(fresh);
        key = StoredProfileKey(
            kind: kind,
            subjectId: subjectId,
            keyId: id,
            key: fresh,
            receivedAt: _now);
        rotated = true;
      } else {
        key = existing;
        rotated = false;
      }
      final blob = codec.seal(
        key: key.key,
        record: ProfileRecord(
          kind: kind,
          subjectId: subjectId,
          revision: version + 1,
          name: cleanName,
          photo: photo,
        ),
      );
      // The key is stored before the upload, so a crash after the server
      // accepts the record cannot lose the only copy.
      if (rotated) {
        await store.saveProfileKey(ProfileKeyEffect(
            kind: kind,
            subjectId: subjectId,
            key: key.key,
            keyId: key.keyId,
            version: 0,
            receivedAt: key.receivedAt));
      }
      // Written before the upload: if the answer is lost or the app stops, the
      // key is still announced by the write that finds it in place.
      final marker = 'pending.$kind.$subjectId.${key.keyId}';
      if (rotated) await store.saveProfileState(marker, '1');
      final int stored;
      try {
        stored = await api.put(kind, subjectId, blob,
            keyId: key.keyId, ifMatchVersion: version == 0 ? null : version);
      } on ApiException catch (error) {
        if (error.kind != ApiErrorKind.conflict) rethrow;
        // Another device won the race. Read what it wrote; retry once only
        // if this device can read it.
        await _refresh(kind, subjectId, keyArrived: false);
        final now = await store.loadProfile(kind, subjectId);
        if (attempt >= 1 ||
            now == null ||
            now.isPlaceholder ||
            now.serverVersion <= version) {
          throw const ProfileConflictException();
        }
        version = now.serverVersion;
        existing = await _currentKey(kind, subjectId);
        if (existing == null || existing.keyId != now.keyId) {
          throw const ProfileConflictException();
        }
        continue;
      }
      final profile = StoredProfile(
        kind: kind,
        subjectId: subjectId,
        serverVersion: stored,
        keyId: key.keyId,
        revision: stored,
        name: cleanName,
        photoPng: photo?.png,
        fetchedAt: _now,
        versionFloor: cached?.versionFloor ?? 0,
      );
      await store.saveProfile(profile);
      _profiles[_id(kind, subjectId)] =
          (await store.loadProfile(kind, subjectId))!;
      await store.saveProfileState(_keyStateName(kind, subjectId), key.keyId);
      final announce = rotated || await store.loadProfileState(marker) != null;
      if (announce) {
        await store.saveProfileState(marker, null);
        await store.saveProfileState(_dueName(kind, subjectId), null);
        if (kind == profileSubjectAccount) {
          await _resetAudience();
          await _queueAccountKey(key.keyId);
        } else {
          await store.saveProfileState(
              _deliverName(true, subjectId), key.keyId);
        }
      }
      _changed();
      unawaited(_deliver().catchError((Object _) {}));
      return;
    }
  }

  // ---- delivery ---------------------------------------------------------

  Future<void> _queueAccountKey(String keyId) async {
    for (final id in postableConversationIds()) {
      await store.saveProfileState(_deliverName(false, id), keyId);
    }
  }

  /// A key to give to a conversation that is new to this device (created or
  /// joined): the account key goes in once, if this account has one.
  Future<void> onConversationAvailable(String conversationId) =>
      _serial(() async {
        final keyId = await _ownKeyIdNow();
        if (keyId == null) return;
        await store.saveProfileState(
            _deliverName(false, conversationId), keyId);
        unawaited(_deliver().catchError((Object _) {}));
      });

  /// Conversations this device has not handed the account key to yet get it
  /// once. A conversation seen before is left alone (the sidecar on posts
  /// covers a member who joined since).
  Future<void> noteConversations(Iterable<String> ids) => _serial(() async {
        final keyId = await _ownKeyIdNow();
        var queued = false;
        for (final id in ids) {
          final seen = '$_seenPrefix$id';
          if (await store.loadProfileState(seen) != null) continue;
          await store.saveProfileState(seen, '1');
          if (keyId != null) {
            await store.saveProfileState(_deliverName(false, id), keyId);
            queued = true;
          }
        }
        if (queued) unawaited(_deliver().catchError((Object _) {}));
      });

  /// Sends every queued key message. A message that cannot be queued now
  /// stays for the next call.
  Future<void> retryDeliveries() => _deliver();

  bool _delivering = false;

  Future<void>? _running;

  /// Completes when queued key messages have been tried (tests await it).
  Future<void> get deliveriesIdle => _running ?? Future<void>.value();

  Future<void> _deliver() {
    final run = _deliverOnce();
    _running = run;
    return run;
  }

  Future<void> _deliverOnce() async {
    // Key messages go through the app's send queue, which can be waiting on
    // a write that is waiting on this service: never hold [_serial] here.
    if (_delivering) return;
    _delivering = true;
    try {
      final queued = await store.loadProfileStatePrefix(_deliverPrefix);
      final postable = postableConversationIds().toSet();
      final known = knownConversationIds();
      for (final entry in queued.entries) {
        final rest = entry.key.substring(_deliverPrefix.length);
        final dot = rest.indexOf('.');
        if (dot < 0) continue;
        final isGroup = rest.substring(0, dot) == 'group';
        final conversationId = rest.substring(dot + 1);
        if (!postable.contains(conversationId)) {
          // Gone for sure: drop. Otherwise (blocks or the list not loaded,
          // a removal hold, an announcement chat) keep it for later.
          if (known != null && !known.contains(conversationId)) {
            await _dropIfUnchanged(entry.key, entry.value);
          }
          continue;
        }
        final kind =
            isGroup ? profileSubjectConversation : profileSubjectAccount;
        final subject = isGroup ? conversationId : accountId;
        final key = (await store.loadProfileKeys(kind, subject))
            .where((k) => k.keyId == entry.value)
            .firstOrNull;
        if (key == null) {
          await _dropIfUnchanged(entry.key, entry.value);
          continue;
        }
        final body = profileKeyBody(
            key: key.key,
            keyId: key.keyId,
            version: isGroup ? 0 : versionOf(profileSubjectAccount, accountId));
        bool sent;
        try {
          sent = await sendKey(
              conversationId,
              isGroup
                  ? AppPayloadType.groupProfileKey
                  : AppPayloadType.profileKey,
              body);
        } on Object {
          sent = false;
        }
        if (sent) await _dropIfUnchanged(entry.key, entry.value);
      }
    } finally {
      _delivering = false;
    }
  }

  Future<void> _dropIfUnchanged(String name, String value) => _serial(() async {
        if (await store.loadProfileState(name) == value) {
          await store.saveProfileState(name, null);
        }
      });

  /// Members of a group that is not yet known to hold the key learn it from
  /// the next post: set when a commit added devices to [conversationId].
  Future<void> markGroupKeyForSidecar(String conversationId) async {
    if (await _currentKey(profileSubjectConversation, conversationId) == null) {
      return;
    }
    await store.saveProfileState('$_sidecarPrefix$conversationId', '1');
  }

  /// The key sidecars for the next post into [conversationId] (S13): this
  /// account's key whenever it has one, and the group's key when a commit
  /// added devices since this device last posted there.
  Future<Map<String, Object?>> sidecars(String conversationId) async {
    final out = <String, Object?>{};
    final ownKeyId = await _ownKeyIdNow();
    final own = ownKeyId == null
        ? null
        : (await store.loadProfileKeys(profileSubjectAccount, accountId))
            .where((k) => k.keyId == ownKeyId)
            .firstOrNull;
    if (own != null) {
      out[profileKeyBodyName] = profileKeyBody(
          key: own.key,
          keyId: own.keyId,
          version: versionOf(profileSubjectAccount, accountId));
    }
    if (await store.loadProfileState('$_sidecarPrefix$conversationId') == '1') {
      final group =
          await _currentKey(profileSubjectConversation, conversationId);
      if (group != null) {
        out[groupProfileKeyBodyName] =
            profileKeyBody(key: group.key, keyId: group.keyId, version: 0);
      }
    }
    return out;
  }

  /// Call after a post carrying [sidecars] was queued.
  Future<void> sidecarsSent(String conversationId) =>
      store.saveProfileState('$_sidecarPrefix$conversationId', null);

  // ---- rotation and cleanup --------------------------------------------

  /// Blocking someone makes the next write use a new key (B1).
  Future<void> markOwnRotationDue() => _serial(() async {
        if (await _ownKeyIdNow() == null) return;
        await store.saveProfileState(_ownDue, '1');
      });

  /// A commit that removes a device from [conversationId] makes the next
  /// group-profile write use a new key.
  Future<void> markGroupRotationDue(String conversationId) => _serial(() async {
        if (await _currentKey(profileSubjectConversation, conversationId) ==
            null) {
          return;
        }
        await store.saveProfileState('$_groupDuePrefix$conversationId', '1');
      });

  Future<bool> ownRotationDue() async =>
      await store.loadProfileState(_ownDue) == '1';

  Future<bool> groupRotationDue(String conversationId) async =>
      await store.loadProfileState('$_groupDuePrefix$conversationId') == '1';

  Future<void> _resetAudience() async {
    final current = coMemberAccountIds();
    // Not known: start the audience again from the next full picture.
    await store.saveProfileState(_ownAudience,
        current == null ? null : jsonEncode(current.toList()..sort()));
  }

  /// The audience is every account that shared a conversation with this one
  /// while the current key was in use. When one of them no longer shares any
  /// conversation, a rotation is due. [current] must be the complete set of
  /// co-members; a partial picture would mark a rotation for nothing.
  Future<void> noteCoMembers(Set<String> current) => _serial(() async {
        if (await _ownKeyIdNow() == null) return;
        final raw = await store.loadProfileState(_ownAudience);
        final audience = <String>{};
        if (raw != null) {
          try {
            audience.addAll((jsonDecode(raw) as List).cast<String>());
          } on Object {
            // An unreadable audience restarts from the present.
          }
        }
        final left = audience.difference(current);
        if (left.isNotEmpty) await store.saveProfileState(_ownDue, '1');
        final next = audience.union(current);
        if (next.length != audience.length || raw == null) {
          await store.saveProfileState(
              _ownAudience, jsonEncode(next.toList()..sort()));
        }
      });

  /// Drops an account's cached profile and keys: it was blocked, or no
  /// conversation is shared with it any more.
  Future<void> forgetAccount(String id) => _serial(() async {
        await store.deleteProfileSubject(profileSubjectAccount, id);
        if (_profiles.remove(_id(profileSubjectAccount, id)) != null) {
          _changed();
        }
      });

  /// Data minimisation: when no conversation is shared with an account any
  /// more, its cached profile and keys go. [shared] must be the complete set
  /// of accounts this one shares a conversation with.
  Future<void> pruneUnshared(Set<String> shared) => _serial(() async {
        final known = <String>{
          for (final p in _profiles.values)
            if (p.kind == profileSubjectAccount) p.subjectId,
          for (final k in await store.loadAllProfileKeys(profileSubjectAccount))
            k.subjectId,
        };
        for (final id in known) {
          if (id == accountId || shared.contains(id)) continue;
          await store.deleteProfileSubject(profileSubjectAccount, id);
          _profiles.remove(_id(profileSubjectAccount, id));
          _changed();
        }
      });

  /// Drops a group's cached profile and keys (this account left it).
  Future<void> forgetConversation(String id) => _serial(() async {
        await store.deleteProfileSubject(profileSubjectConversation, id);
        for (final name in [
          '$_groupKeyIdPrefix$id',
          '$_groupDuePrefix$id',
          '$_sidecarPrefix$id',
          '$_seenPrefix$id',
          _deliverName(true, id),
          _deliverName(false, id),
        ]) {
          await store.saveProfileState(name, null);
        }
        if (_profiles.remove(_id(profileSubjectConversation, id)) != null) {
          _changed();
        }
      });
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
