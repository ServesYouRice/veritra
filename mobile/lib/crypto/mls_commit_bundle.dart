import 'dart:collection';
import 'dart:convert';

/// One device in a group membership change (card I51).
typedef MlsDeviceRef = ({String accountId, String deviceId});

/// A staged MLS commit with its Welcome and roster change, queued in the MLS
/// outbox as one item of kind `bundle`. The server accepts it only on
/// [epoch]; this device merges the commit only after that.
class MlsCommitBundle {
  const MlsCommitBundle({
    required this.epoch,
    this.commit = const <int>[],
    this.welcome = const <int>[],
    this.added = const <MlsDeviceRef>[],
    this.removed = const <MlsDeviceRef>[],
    this.revocationDeviceId,
  });

  static const kind = 'bundle';

  final int epoch;

  /// Empty only for a new group with nobody else to add yet.
  final List<int> commit;
  final List<int> welcome;
  final List<MlsDeviceRef> added;
  final List<MlsDeviceRef> removed;
  final String? revocationDeviceId;

  bool get hasCommit => commit.isNotEmpty;

  /// A commit that adds and removes no one: a periodic self-update.
  bool get isUpdateOnly =>
      hasCommit &&
      added.isEmpty &&
      removed.isEmpty &&
      welcome.isEmpty &&
      revocationDeviceId == null;

  Map<String, Object?> toRequestJson(String idempotencyKey) =>
      <String, Object?>{
        'epoch': epoch,
        'idempotency_key': idempotencyKey,
        if (commit.isNotEmpty) 'commit': base64Encode(commit),
        if (welcome.isNotEmpty) 'welcome': base64Encode(welcome),
        if (added.isNotEmpty) 'added': added.map(_refJson).toList(),
        if (removed.isNotEmpty) 'removed': removed.map(_refJson).toList(),
        if (revocationDeviceId != null)
          'revocation_device_id': revocationDeviceId,
      };

  List<int> encode() => utf8.encode(jsonEncode(<String, Object?>{
        'version': 1,
        ...toRequestJson(''),
      }..remove('idempotency_key')));

  static MlsCommitBundle decode(List<int> bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map || json['version'] != 1 || json['epoch'] is! int) {
      throw const FormatException('invalid MLS commit bundle');
    }
    List<MlsDeviceRef> refs(Object? value) => value == null
        ? const <MlsDeviceRef>[]
        : (value as List).map((item) {
            final map = item as Map;
            return (
              accountId: map['account_id'] as String,
              deviceId: map['device_id'] as String,
            );
          }).toList(growable: false);
    final commit = json['commit'];
    final welcome = json['welcome'];
    return MlsCommitBundle(
      epoch: json['epoch'] as int,
      commit: commit is String ? base64Decode(commit) : const <int>[],
      welcome: welcome is String ? base64Decode(welcome) : const <int>[],
      added: refs(json['added']),
      removed: refs(json['removed']),
      revocationDeviceId: json['revocation_device_id'] as String?,
    );
  }

  static Map<String, String> _refJson(MlsDeviceRef ref) =>
      <String, String>{'account_id': ref.accountId, 'device_id': ref.deviceId};
}

/// One `GET /api/v1/mls/pending-changes` read, with the response-level flag
/// that says whether the server cut the whole read at its overall cap (so
/// conversations may be missing). [cut] is null when the server did not say
/// (an older server); one item's own [MlsPendingChange.truncated] alone may
/// come from that conversation's own cap and does not mean the read was cut.
class MlsPendingChanges extends ListBase<MlsPendingChange> {
  MlsPendingChanges(List<MlsPendingChange> items, {this.cut})
      : _items = List<MlsPendingChange>.unmodifiable(items);

  final List<MlsPendingChange> _items;
  final bool? cut;

  @override
  int get length => _items.length;

  @override
  set length(int value) => throw UnsupportedError('unmodifiable');

  @override
  MlsPendingChange operator [](int index) => _items[index];

  @override
  void operator []=(int index, MlsPendingChange value) =>
      throw UnsupportedError('unmodifiable');
}

/// What one group should change, from `GET /api/v1/mls/pending-changes`.
class MlsPendingChange {
  const MlsPendingChange({
    required this.conversationId,
    required this.epoch,
    required this.add,
    required this.remove,
    this.coordinatorDeviceId,
    this.truncated = false,
  });

  final String conversationId;
  final int epoch;
  final List<MlsDeviceRef> add;
  final List<MlsDeviceRef> remove;
  final String? coordinatorDeviceId;

  /// The server cut its lists at a cap: more may be pending than listed.
  /// When the whole read was cut, every item says so and conversations may
  /// be missing from it.
  final bool truncated;

  factory MlsPendingChange.fromJson(Map<String, Object?> json) {
    List<MlsDeviceRef> refs(Object? value) =>
        (value as List? ?? const <Object?>[]).map((item) {
          final map = item as Map;
          return (
            accountId: map['account_id'] as String,
            deviceId: map['device_id'] as String,
          );
        }).toList(growable: false);
    return MlsPendingChange(
      conversationId: json['conversation_id'] as String,
      epoch: (json['epoch'] as num).toInt(),
      add: refs(json['add']),
      remove: refs(json['remove']),
      coordinatorDeviceId: json['coordinator_device_id'] as String?,
      truncated: json['truncated'] == true,
    );
  }
}
