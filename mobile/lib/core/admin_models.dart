/// Rows of the instance-admin API (`/api/v1/admin/...`). Counts and sizes only:
/// the server holds no plaintext, so nothing here can carry message content.
class AdminAccount {
  AdminAccount({
    required this.id,
    required this.username,
    required this.role,
    required this.status,
    this.createdAt,
    this.deviceCount = 0,
    this.storageBytes = 0,
  });

  final String id;
  final String username;
  final String role;
  final String status;
  final DateTime? createdAt;
  final int deviceCount;
  final int storageBytes;

  bool get suspended => status == 'suspended';

  factory AdminAccount.fromJson(Map<String, Object?> json) {
    return AdminAccount(
      id: json['id'] as String,
      username: json['username'] as String? ?? '',
      role: json['role'] as String? ?? 'member',
      status: json['status'] as String? ?? 'active',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      deviceCount: (json['device_count'] as num?)?.toInt() ?? 0,
      storageBytes: (json['storage_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class AdminAuditEvent {
  AdminAuditEvent({
    required this.id,
    required this.eventType,
    this.actorAccountId,
    this.metadata = const <String, String>{},
    this.createdAt,
  });

  final int id;
  final String eventType;
  final String? actorAccountId;
  final Map<String, String> metadata;
  final DateTime? createdAt;

  factory AdminAuditEvent.fromJson(Map<String, Object?> json) {
    final raw = json['metadata'];
    return AdminAuditEvent(
      id: (json['id'] as num).toInt(),
      eventType: json['event_type'] as String? ?? '',
      actorAccountId: json['actor_account_id'] as String?,
      metadata: raw is Map
          ? <String, String>{
              for (final entry in raw.entries)
                entry.key.toString(): entry.value.toString(),
            }
          : const <String, String>{},
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
    );
  }
}

/// One page of an admin listing plus the cursor for the next, if any.
class AdminPage<T> {
  const AdminPage(this.rows, this.nextAfter);

  final List<T> rows;
  final String? nextAfter;
}
