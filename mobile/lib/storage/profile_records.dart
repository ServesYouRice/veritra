import 'dart:typed_data';

/// W11 local profile records (docs/designs/W11-profiles.md, "Receiving and
/// caching"). Plain values shared by the memory and the encrypted store.

const String profileSubjectAccount = 'account';
const String profileSubjectConversation = 'conversation';

/// Most keys a device keeps for one subject, keyed by key id.
const int profileKeysPerSubject = 4;

/// One profile key a device holds for a subject: an account's own key, a
/// co-member's key, or a group's key.
class StoredProfileKey {
  const StoredProfileKey({
    required this.kind,
    required this.subjectId,
    required this.keyId,
    required this.key,
    required this.receivedAt,
  });

  final String kind;
  final String subjectId;
  final String keyId;
  final Uint8List key;
  final int receivedAt;
}

/// A profile record this device accepted. `revision` 0 with an empty
/// `keyId` is a placeholder that only holds a version floor, never a
/// profile. A removed profile has a null name and no photo.
class StoredProfile {
  const StoredProfile({
    required this.kind,
    required this.subjectId,
    required this.serverVersion,
    required this.keyId,
    required this.revision,
    this.name,
    this.photoPng,
    required this.fetchedAt,
    this.versionFloor = 0,
  });

  final String kind;
  final String subjectId;
  final int serverVersion;
  final String keyId;
  final int revision;
  final String? name;
  final Uint8List? photoPng;
  final int fetchedAt;

  /// The highest `version` hint an account sent with its own key
  /// (authenticated by MLS). A fetched account record below it is a rollback.
  final int versionFloor;

  bool get isPlaceholder => revision == 0;

  StoredProfile copyWith({int? versionFloor}) => StoredProfile(
        kind: kind,
        subjectId: subjectId,
        serverVersion: serverVersion,
        keyId: keyId,
        revision: revision,
        name: name,
        photoPng: photoPng,
        fetchedAt: fetchedAt,
        versionFloor: versionFloor ?? this.versionFloor,
      );
}

/// Which keys of a subject to drop so at most [profileKeysPerSubject] stay.
/// The oldest go first; the key that opens the cached record
/// ([protectedKeyId]) and the one just received ([newestKeyId]) never go.
List<String> profileKeysToEvict(
  List<StoredProfileKey> keys, {
  String? protectedKeyId,
  String? newestKeyId,
}) {
  if (keys.length <= profileKeysPerSubject) return const <String>[];
  final candidates = keys
      .where((k) => k.keyId != protectedKeyId && k.keyId != newestKeyId)
      .toList()
    ..sort((a, b) {
      final byTime = a.receivedAt.compareTo(b.receivedAt);
      return byTime != 0 ? byTime : a.keyId.compareTo(b.keyId);
    });
  final excess = keys.length - profileKeysPerSubject;
  return candidates.take(excess).map((k) => k.keyId).toList();
}
