// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'encrypted_database.dart';

// ignore_for_file: type=lint
class $LocalAccountsTable extends LocalAccounts
    with TableInfo<$LocalAccountsTable, LocalAccount> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalAccountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _singletonMeta =
      const VerificationMeta('singleton');
  @override
  late final GeneratedColumn<int> singleton = GeneratedColumn<int>(
      'singleton', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _sessionJsonMeta =
      const VerificationMeta('sessionJson');
  @override
  late final GeneratedColumn<String> sessionJson = GeneratedColumn<String>(
      'session_json', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [singleton, sessionJson];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_accounts';
  @override
  VerificationContext validateIntegrity(Insertable<LocalAccount> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('singleton')) {
      context.handle(_singletonMeta,
          singleton.isAcceptableOrUnknown(data['singleton']!, _singletonMeta));
    }
    if (data.containsKey('session_json')) {
      context.handle(
          _sessionJsonMeta,
          sessionJson.isAcceptableOrUnknown(
              data['session_json']!, _sessionJsonMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {singleton};
  @override
  LocalAccount map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalAccount(
      singleton: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}singleton'])!,
      sessionJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}session_json']),
    );
  }

  @override
  $LocalAccountsTable createAlias(String alias) {
    return $LocalAccountsTable(attachedDatabase, alias);
  }
}

class LocalAccount extends DataClass implements Insertable<LocalAccount> {
  final int singleton;
  final String? sessionJson;
  const LocalAccount({required this.singleton, this.sessionJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['singleton'] = Variable<int>(singleton);
    if (!nullToAbsent || sessionJson != null) {
      map['session_json'] = Variable<String>(sessionJson);
    }
    return map;
  }

  LocalAccountsCompanion toCompanion(bool nullToAbsent) {
    return LocalAccountsCompanion(
      singleton: Value(singleton),
      sessionJson: sessionJson == null && nullToAbsent
          ? const Value.absent()
          : Value(sessionJson),
    );
  }

  factory LocalAccount.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalAccount(
      singleton: serializer.fromJson<int>(json['singleton']),
      sessionJson: serializer.fromJson<String?>(json['sessionJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'singleton': serializer.toJson<int>(singleton),
      'sessionJson': serializer.toJson<String?>(sessionJson),
    };
  }

  LocalAccount copyWith(
          {int? singleton,
          Value<String?> sessionJson = const Value.absent()}) =>
      LocalAccount(
        singleton: singleton ?? this.singleton,
        sessionJson: sessionJson.present ? sessionJson.value : this.sessionJson,
      );
  LocalAccount copyWithCompanion(LocalAccountsCompanion data) {
    return LocalAccount(
      singleton: data.singleton.present ? data.singleton.value : this.singleton,
      sessionJson:
          data.sessionJson.present ? data.sessionJson.value : this.sessionJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalAccount(')
          ..write('singleton: $singleton, ')
          ..write('sessionJson: $sessionJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(singleton, sessionJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalAccount &&
          other.singleton == this.singleton &&
          other.sessionJson == this.sessionJson);
}

class LocalAccountsCompanion extends UpdateCompanion<LocalAccount> {
  final Value<int> singleton;
  final Value<String?> sessionJson;
  const LocalAccountsCompanion({
    this.singleton = const Value.absent(),
    this.sessionJson = const Value.absent(),
  });
  LocalAccountsCompanion.insert({
    this.singleton = const Value.absent(),
    this.sessionJson = const Value.absent(),
  });
  static Insertable<LocalAccount> custom({
    Expression<int>? singleton,
    Expression<String>? sessionJson,
  }) {
    return RawValuesInsertable({
      if (singleton != null) 'singleton': singleton,
      if (sessionJson != null) 'session_json': sessionJson,
    });
  }

  LocalAccountsCompanion copyWith(
      {Value<int>? singleton, Value<String?>? sessionJson}) {
    return LocalAccountsCompanion(
      singleton: singleton ?? this.singleton,
      sessionJson: sessionJson ?? this.sessionJson,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (singleton.present) {
      map['singleton'] = Variable<int>(singleton.value);
    }
    if (sessionJson.present) {
      map['session_json'] = Variable<String>(sessionJson.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalAccountsCompanion(')
          ..write('singleton: $singleton, ')
          ..write('sessionJson: $sessionJson')
          ..write(')'))
        .toString();
  }
}

class $LocalConversationsTable extends LocalConversations
    with TableInfo<$LocalConversationsTable, LocalConversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _payloadJsonMeta =
      const VerificationMeta('payloadJson');
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
      'payload_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, position, payloadJson];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_conversations';
  @override
  VerificationContext validateIntegrity(Insertable<LocalConversation> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
          _payloadJsonMeta,
          payloadJson.isAcceptableOrUnknown(
              data['payload_json']!, _payloadJsonMeta));
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LocalConversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalConversation(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position'])!,
      payloadJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_json'])!,
    );
  }

  @override
  $LocalConversationsTable createAlias(String alias) {
    return $LocalConversationsTable(attachedDatabase, alias);
  }
}

class LocalConversation extends DataClass
    implements Insertable<LocalConversation> {
  final String id;
  final int position;
  final String payloadJson;
  const LocalConversation(
      {required this.id, required this.position, required this.payloadJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['position'] = Variable<int>(position);
    map['payload_json'] = Variable<String>(payloadJson);
    return map;
  }

  LocalConversationsCompanion toCompanion(bool nullToAbsent) {
    return LocalConversationsCompanion(
      id: Value(id),
      position: Value(position),
      payloadJson: Value(payloadJson),
    );
  }

  factory LocalConversation.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalConversation(
      id: serializer.fromJson<String>(json['id']),
      position: serializer.fromJson<int>(json['position']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'position': serializer.toJson<int>(position),
      'payloadJson': serializer.toJson<String>(payloadJson),
    };
  }

  LocalConversation copyWith(
          {String? id, int? position, String? payloadJson}) =>
      LocalConversation(
        id: id ?? this.id,
        position: position ?? this.position,
        payloadJson: payloadJson ?? this.payloadJson,
      );
  LocalConversation copyWithCompanion(LocalConversationsCompanion data) {
    return LocalConversation(
      id: data.id.present ? data.id.value : this.id,
      position: data.position.present ? data.position.value : this.position,
      payloadJson:
          data.payloadJson.present ? data.payloadJson.value : this.payloadJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalConversation(')
          ..write('id: $id, ')
          ..write('position: $position, ')
          ..write('payloadJson: $payloadJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, position, payloadJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalConversation &&
          other.id == this.id &&
          other.position == this.position &&
          other.payloadJson == this.payloadJson);
}

class LocalConversationsCompanion extends UpdateCompanion<LocalConversation> {
  final Value<String> id;
  final Value<int> position;
  final Value<String> payloadJson;
  final Value<int> rowid;
  const LocalConversationsCompanion({
    this.id = const Value.absent(),
    this.position = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalConversationsCompanion.insert({
    required String id,
    required int position,
    required String payloadJson,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        position = Value(position),
        payloadJson = Value(payloadJson);
  static Insertable<LocalConversation> custom({
    Expression<String>? id,
    Expression<int>? position,
    Expression<String>? payloadJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (position != null) 'position': position,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalConversationsCompanion copyWith(
      {Value<String>? id,
      Value<int>? position,
      Value<String>? payloadJson,
      Value<int>? rowid}) {
    return LocalConversationsCompanion(
      id: id ?? this.id,
      position: position ?? this.position,
      payloadJson: payloadJson ?? this.payloadJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalConversationsCompanion(')
          ..write('id: $id, ')
          ..write('position: $position, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalCiphertextEnvelopesTable extends LocalCiphertextEnvelopes
    with TableInfo<$LocalCiphertextEnvelopesTable, LocalCiphertextEnvelope> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalCiphertextEnvelopesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _payloadJsonMeta =
      const VerificationMeta('payloadJson');
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
      'payload_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _expiresAtMeta =
      const VerificationMeta('expiresAt');
  @override
  late final GeneratedColumn<int> expiresAt = GeneratedColumn<int>(
      'expires_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, conversationId, position, payloadJson, expiresAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_ciphertext_envelopes';
  @override
  VerificationContext validateIntegrity(
      Insertable<LocalCiphertextEnvelope> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
          _payloadJsonMeta,
          payloadJson.isAcceptableOrUnknown(
              data['payload_json']!, _payloadJsonMeta));
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(_expiresAtMeta,
          expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LocalCiphertextEnvelope map(Map<String, dynamic> data,
      {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalCiphertextEnvelope(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position'])!,
      payloadJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_json'])!,
      expiresAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}expires_at']),
    );
  }

  @override
  $LocalCiphertextEnvelopesTable createAlias(String alias) {
    return $LocalCiphertextEnvelopesTable(attachedDatabase, alias);
  }
}

class LocalCiphertextEnvelope extends DataClass
    implements Insertable<LocalCiphertextEnvelope> {
  final String id;
  final String conversationId;
  final int position;
  final String payloadJson;
  final int? expiresAt;
  const LocalCiphertextEnvelope(
      {required this.id,
      required this.conversationId,
      required this.position,
      required this.payloadJson,
      this.expiresAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['position'] = Variable<int>(position);
    map['payload_json'] = Variable<String>(payloadJson);
    if (!nullToAbsent || expiresAt != null) {
      map['expires_at'] = Variable<int>(expiresAt);
    }
    return map;
  }

  LocalCiphertextEnvelopesCompanion toCompanion(bool nullToAbsent) {
    return LocalCiphertextEnvelopesCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      position: Value(position),
      payloadJson: Value(payloadJson),
      expiresAt: expiresAt == null && nullToAbsent
          ? const Value.absent()
          : Value(expiresAt),
    );
  }

  factory LocalCiphertextEnvelope.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalCiphertextEnvelope(
      id: serializer.fromJson<String>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      position: serializer.fromJson<int>(json['position']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      expiresAt: serializer.fromJson<int?>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'position': serializer.toJson<int>(position),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'expiresAt': serializer.toJson<int?>(expiresAt),
    };
  }

  LocalCiphertextEnvelope copyWith(
          {String? id,
          String? conversationId,
          int? position,
          String? payloadJson,
          Value<int?> expiresAt = const Value.absent()}) =>
      LocalCiphertextEnvelope(
        id: id ?? this.id,
        conversationId: conversationId ?? this.conversationId,
        position: position ?? this.position,
        payloadJson: payloadJson ?? this.payloadJson,
        expiresAt: expiresAt.present ? expiresAt.value : this.expiresAt,
      );
  LocalCiphertextEnvelope copyWithCompanion(
      LocalCiphertextEnvelopesCompanion data) {
    return LocalCiphertextEnvelope(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      position: data.position.present ? data.position.value : this.position,
      payloadJson:
          data.payloadJson.present ? data.payloadJson.value : this.payloadJson,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalCiphertextEnvelope(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('position: $position, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, conversationId, position, payloadJson, expiresAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalCiphertextEnvelope &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.position == this.position &&
          other.payloadJson == this.payloadJson &&
          other.expiresAt == this.expiresAt);
}

class LocalCiphertextEnvelopesCompanion
    extends UpdateCompanion<LocalCiphertextEnvelope> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<int> position;
  final Value<String> payloadJson;
  final Value<int?> expiresAt;
  final Value<int> rowid;
  const LocalCiphertextEnvelopesCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.position = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalCiphertextEnvelopesCompanion.insert({
    required String id,
    required String conversationId,
    required int position,
    required String payloadJson,
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        conversationId = Value(conversationId),
        position = Value(position),
        payloadJson = Value(payloadJson);
  static Insertable<LocalCiphertextEnvelope> custom({
    Expression<String>? id,
    Expression<String>? conversationId,
    Expression<int>? position,
    Expression<String>? payloadJson,
    Expression<int>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (position != null) 'position': position,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalCiphertextEnvelopesCompanion copyWith(
      {Value<String>? id,
      Value<String>? conversationId,
      Value<int>? position,
      Value<String>? payloadJson,
      Value<int?>? expiresAt,
      Value<int>? rowid}) {
    return LocalCiphertextEnvelopesCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      position: position ?? this.position,
      payloadJson: payloadJson ?? this.payloadJson,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<int>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalCiphertextEnvelopesCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('position: $position, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalSyncStatesTable extends LocalSyncStates
    with TableInfo<$LocalSyncStatesTable, LocalSyncState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalSyncStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _singletonMeta =
      const VerificationMeta('singleton');
  @override
  late final GeneratedColumn<int> singleton = GeneratedColumn<int>(
      'singleton', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _cursorMeta = const VerificationMeta('cursor');
  @override
  late final GeneratedColumn<int> cursor = GeneratedColumn<int>(
      'cursor', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [singleton, cursor];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_sync_states';
  @override
  VerificationContext validateIntegrity(Insertable<LocalSyncState> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('singleton')) {
      context.handle(_singletonMeta,
          singleton.isAcceptableOrUnknown(data['singleton']!, _singletonMeta));
    }
    if (data.containsKey('cursor')) {
      context.handle(_cursorMeta,
          cursor.isAcceptableOrUnknown(data['cursor']!, _cursorMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {singleton};
  @override
  LocalSyncState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalSyncState(
      singleton: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}singleton'])!,
      cursor: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}cursor'])!,
    );
  }

  @override
  $LocalSyncStatesTable createAlias(String alias) {
    return $LocalSyncStatesTable(attachedDatabase, alias);
  }
}

class LocalSyncState extends DataClass implements Insertable<LocalSyncState> {
  final int singleton;
  final int cursor;
  const LocalSyncState({required this.singleton, required this.cursor});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['singleton'] = Variable<int>(singleton);
    map['cursor'] = Variable<int>(cursor);
    return map;
  }

  LocalSyncStatesCompanion toCompanion(bool nullToAbsent) {
    return LocalSyncStatesCompanion(
      singleton: Value(singleton),
      cursor: Value(cursor),
    );
  }

  factory LocalSyncState.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalSyncState(
      singleton: serializer.fromJson<int>(json['singleton']),
      cursor: serializer.fromJson<int>(json['cursor']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'singleton': serializer.toJson<int>(singleton),
      'cursor': serializer.toJson<int>(cursor),
    };
  }

  LocalSyncState copyWith({int? singleton, int? cursor}) => LocalSyncState(
        singleton: singleton ?? this.singleton,
        cursor: cursor ?? this.cursor,
      );
  LocalSyncState copyWithCompanion(LocalSyncStatesCompanion data) {
    return LocalSyncState(
      singleton: data.singleton.present ? data.singleton.value : this.singleton,
      cursor: data.cursor.present ? data.cursor.value : this.cursor,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalSyncState(')
          ..write('singleton: $singleton, ')
          ..write('cursor: $cursor')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(singleton, cursor);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalSyncState &&
          other.singleton == this.singleton &&
          other.cursor == this.cursor);
}

class LocalSyncStatesCompanion extends UpdateCompanion<LocalSyncState> {
  final Value<int> singleton;
  final Value<int> cursor;
  const LocalSyncStatesCompanion({
    this.singleton = const Value.absent(),
    this.cursor = const Value.absent(),
  });
  LocalSyncStatesCompanion.insert({
    this.singleton = const Value.absent(),
    this.cursor = const Value.absent(),
  });
  static Insertable<LocalSyncState> custom({
    Expression<int>? singleton,
    Expression<int>? cursor,
  }) {
    return RawValuesInsertable({
      if (singleton != null) 'singleton': singleton,
      if (cursor != null) 'cursor': cursor,
    });
  }

  LocalSyncStatesCompanion copyWith(
      {Value<int>? singleton, Value<int>? cursor}) {
    return LocalSyncStatesCompanion(
      singleton: singleton ?? this.singleton,
      cursor: cursor ?? this.cursor,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (singleton.present) {
      map['singleton'] = Variable<int>(singleton.value);
    }
    if (cursor.present) {
      map['cursor'] = Variable<int>(cursor.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalSyncStatesCompanion(')
          ..write('singleton: $singleton, ')
          ..write('cursor: $cursor')
          ..write(')'))
        .toString();
  }
}

class $LocalOutboxEntriesTable extends LocalOutboxEntries
    with TableInfo<$LocalOutboxEntriesTable, LocalOutboxEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalOutboxEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idempotencyKeyMeta =
      const VerificationMeta('idempotencyKey');
  @override
  late final GeneratedColumn<String> idempotencyKey = GeneratedColumn<String>(
      'idempotency_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _queuedAtMeta =
      const VerificationMeta('queuedAt');
  @override
  late final GeneratedColumn<int> queuedAt = GeneratedColumn<int>(
      'queued_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _payloadJsonMeta =
      const VerificationMeta('payloadJson');
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
      'payload_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _attemptCountMeta =
      const VerificationMeta('attemptCount');
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
      'attempt_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _nextAttemptAtMeta =
      const VerificationMeta('nextAttemptAt');
  @override
  late final GeneratedColumn<int> nextAttemptAt = GeneratedColumn<int>(
      'next_attempt_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _failureClassMeta =
      const VerificationMeta('failureClass');
  @override
  late final GeneratedColumn<String> failureClass = GeneratedColumn<String>(
      'failure_class', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _terminalMeta =
      const VerificationMeta('terminal');
  @override
  late final GeneratedColumn<bool> terminal = GeneratedColumn<bool>(
      'terminal', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("terminal" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns => [
        idempotencyKey,
        conversationId,
        queuedAt,
        payloadJson,
        attemptCount,
        nextAttemptAt,
        failureClass,
        terminal
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_outbox_entries';
  @override
  VerificationContext validateIntegrity(Insertable<LocalOutboxEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('idempotency_key')) {
      context.handle(
          _idempotencyKeyMeta,
          idempotencyKey.isAcceptableOrUnknown(
              data['idempotency_key']!, _idempotencyKeyMeta));
    } else if (isInserting) {
      context.missing(_idempotencyKeyMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('queued_at')) {
      context.handle(_queuedAtMeta,
          queuedAt.isAcceptableOrUnknown(data['queued_at']!, _queuedAtMeta));
    } else if (isInserting) {
      context.missing(_queuedAtMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
          _payloadJsonMeta,
          payloadJson.isAcceptableOrUnknown(
              data['payload_json']!, _payloadJsonMeta));
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
          _attemptCountMeta,
          attemptCount.isAcceptableOrUnknown(
              data['attempt_count']!, _attemptCountMeta));
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
          _nextAttemptAtMeta,
          nextAttemptAt.isAcceptableOrUnknown(
              data['next_attempt_at']!, _nextAttemptAtMeta));
    }
    if (data.containsKey('failure_class')) {
      context.handle(
          _failureClassMeta,
          failureClass.isAcceptableOrUnknown(
              data['failure_class']!, _failureClassMeta));
    }
    if (data.containsKey('terminal')) {
      context.handle(_terminalMeta,
          terminal.isAcceptableOrUnknown(data['terminal']!, _terminalMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {idempotencyKey};
  @override
  LocalOutboxEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalOutboxEntry(
      idempotencyKey: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}idempotency_key'])!,
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      queuedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}queued_at'])!,
      payloadJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_json'])!,
      attemptCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}attempt_count'])!,
      nextAttemptAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}next_attempt_at']),
      failureClass: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}failure_class']),
      terminal: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}terminal'])!,
    );
  }

  @override
  $LocalOutboxEntriesTable createAlias(String alias) {
    return $LocalOutboxEntriesTable(attachedDatabase, alias);
  }
}

class LocalOutboxEntry extends DataClass
    implements Insertable<LocalOutboxEntry> {
  final String idempotencyKey;
  final String conversationId;
  final int queuedAt;
  final String payloadJson;
  final int attemptCount;
  final int? nextAttemptAt;
  final String? failureClass;
  final bool terminal;
  const LocalOutboxEntry(
      {required this.idempotencyKey,
      required this.conversationId,
      required this.queuedAt,
      required this.payloadJson,
      required this.attemptCount,
      this.nextAttemptAt,
      this.failureClass,
      required this.terminal});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['idempotency_key'] = Variable<String>(idempotencyKey);
    map['conversation_id'] = Variable<String>(conversationId);
    map['queued_at'] = Variable<int>(queuedAt);
    map['payload_json'] = Variable<String>(payloadJson);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || nextAttemptAt != null) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt);
    }
    if (!nullToAbsent || failureClass != null) {
      map['failure_class'] = Variable<String>(failureClass);
    }
    map['terminal'] = Variable<bool>(terminal);
    return map;
  }

  LocalOutboxEntriesCompanion toCompanion(bool nullToAbsent) {
    return LocalOutboxEntriesCompanion(
      idempotencyKey: Value(idempotencyKey),
      conversationId: Value(conversationId),
      queuedAt: Value(queuedAt),
      payloadJson: Value(payloadJson),
      attemptCount: Value(attemptCount),
      nextAttemptAt: nextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAt),
      failureClass: failureClass == null && nullToAbsent
          ? const Value.absent()
          : Value(failureClass),
      terminal: Value(terminal),
    );
  }

  factory LocalOutboxEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalOutboxEntry(
      idempotencyKey: serializer.fromJson<String>(json['idempotencyKey']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      queuedAt: serializer.fromJson<int>(json['queuedAt']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      nextAttemptAt: serializer.fromJson<int?>(json['nextAttemptAt']),
      failureClass: serializer.fromJson<String?>(json['failureClass']),
      terminal: serializer.fromJson<bool>(json['terminal']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'idempotencyKey': serializer.toJson<String>(idempotencyKey),
      'conversationId': serializer.toJson<String>(conversationId),
      'queuedAt': serializer.toJson<int>(queuedAt),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'nextAttemptAt': serializer.toJson<int?>(nextAttemptAt),
      'failureClass': serializer.toJson<String?>(failureClass),
      'terminal': serializer.toJson<bool>(terminal),
    };
  }

  LocalOutboxEntry copyWith(
          {String? idempotencyKey,
          String? conversationId,
          int? queuedAt,
          String? payloadJson,
          int? attemptCount,
          Value<int?> nextAttemptAt = const Value.absent(),
          Value<String?> failureClass = const Value.absent(),
          bool? terminal}) =>
      LocalOutboxEntry(
        idempotencyKey: idempotencyKey ?? this.idempotencyKey,
        conversationId: conversationId ?? this.conversationId,
        queuedAt: queuedAt ?? this.queuedAt,
        payloadJson: payloadJson ?? this.payloadJson,
        attemptCount: attemptCount ?? this.attemptCount,
        nextAttemptAt:
            nextAttemptAt.present ? nextAttemptAt.value : this.nextAttemptAt,
        failureClass:
            failureClass.present ? failureClass.value : this.failureClass,
        terminal: terminal ?? this.terminal,
      );
  LocalOutboxEntry copyWithCompanion(LocalOutboxEntriesCompanion data) {
    return LocalOutboxEntry(
      idempotencyKey: data.idempotencyKey.present
          ? data.idempotencyKey.value
          : this.idempotencyKey,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      queuedAt: data.queuedAt.present ? data.queuedAt.value : this.queuedAt,
      payloadJson:
          data.payloadJson.present ? data.payloadJson.value : this.payloadJson,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      failureClass: data.failureClass.present
          ? data.failureClass.value
          : this.failureClass,
      terminal: data.terminal.present ? data.terminal.value : this.terminal,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalOutboxEntry(')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('conversationId: $conversationId, ')
          ..write('queuedAt: $queuedAt, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('failureClass: $failureClass, ')
          ..write('terminal: $terminal')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(idempotencyKey, conversationId, queuedAt,
      payloadJson, attemptCount, nextAttemptAt, failureClass, terminal);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalOutboxEntry &&
          other.idempotencyKey == this.idempotencyKey &&
          other.conversationId == this.conversationId &&
          other.queuedAt == this.queuedAt &&
          other.payloadJson == this.payloadJson &&
          other.attemptCount == this.attemptCount &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.failureClass == this.failureClass &&
          other.terminal == this.terminal);
}

class LocalOutboxEntriesCompanion extends UpdateCompanion<LocalOutboxEntry> {
  final Value<String> idempotencyKey;
  final Value<String> conversationId;
  final Value<int> queuedAt;
  final Value<String> payloadJson;
  final Value<int> attemptCount;
  final Value<int?> nextAttemptAt;
  final Value<String?> failureClass;
  final Value<bool> terminal;
  final Value<int> rowid;
  const LocalOutboxEntriesCompanion({
    this.idempotencyKey = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.queuedAt = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.failureClass = const Value.absent(),
    this.terminal = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalOutboxEntriesCompanion.insert({
    required String idempotencyKey,
    required String conversationId,
    required int queuedAt,
    required String payloadJson,
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.failureClass = const Value.absent(),
    this.terminal = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : idempotencyKey = Value(idempotencyKey),
        conversationId = Value(conversationId),
        queuedAt = Value(queuedAt),
        payloadJson = Value(payloadJson);
  static Insertable<LocalOutboxEntry> custom({
    Expression<String>? idempotencyKey,
    Expression<String>? conversationId,
    Expression<int>? queuedAt,
    Expression<String>? payloadJson,
    Expression<int>? attemptCount,
    Expression<int>? nextAttemptAt,
    Expression<String>? failureClass,
    Expression<bool>? terminal,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      if (conversationId != null) 'conversation_id': conversationId,
      if (queuedAt != null) 'queued_at': queuedAt,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (failureClass != null) 'failure_class': failureClass,
      if (terminal != null) 'terminal': terminal,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalOutboxEntriesCompanion copyWith(
      {Value<String>? idempotencyKey,
      Value<String>? conversationId,
      Value<int>? queuedAt,
      Value<String>? payloadJson,
      Value<int>? attemptCount,
      Value<int?>? nextAttemptAt,
      Value<String?>? failureClass,
      Value<bool>? terminal,
      Value<int>? rowid}) {
    return LocalOutboxEntriesCompanion(
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      conversationId: conversationId ?? this.conversationId,
      queuedAt: queuedAt ?? this.queuedAt,
      payloadJson: payloadJson ?? this.payloadJson,
      attemptCount: attemptCount ?? this.attemptCount,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      failureClass: failureClass ?? this.failureClass,
      terminal: terminal ?? this.terminal,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (idempotencyKey.present) {
      map['idempotency_key'] = Variable<String>(idempotencyKey.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (queuedAt.present) {
      map['queued_at'] = Variable<int>(queuedAt.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt.value);
    }
    if (failureClass.present) {
      map['failure_class'] = Variable<String>(failureClass.value);
    }
    if (terminal.present) {
      map['terminal'] = Variable<bool>(terminal.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalOutboxEntriesCompanion(')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('conversationId: $conversationId, ')
          ..write('queuedAt: $queuedAt, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('failureClass: $failureClass, ')
          ..write('terminal: $terminal, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalCryptoStatesTable extends LocalCryptoStates
    with TableInfo<$LocalCryptoStatesTable, LocalCryptoState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalCryptoStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _singletonMeta =
      const VerificationMeta('singleton');
  @override
  late final GeneratedColumn<int> singleton = GeneratedColumn<int>(
      'singleton', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _counterMeta =
      const VerificationMeta('counter');
  @override
  late final GeneratedColumn<int> counter = GeneratedColumn<int>(
      'counter', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _stateKeyMeta =
      const VerificationMeta('stateKey');
  @override
  late final GeneratedColumn<Uint8List> stateKey = GeneratedColumn<Uint8List>(
      'state_key', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _sealedStateMeta =
      const VerificationMeta('sealedState');
  @override
  late final GeneratedColumn<Uint8List> sealedState =
      GeneratedColumn<Uint8List>('sealed_state', aliasedName, false,
          type: DriftSqlType.blob, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [singleton, counter, stateKey, sealedState];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_crypto_states';
  @override
  VerificationContext validateIntegrity(Insertable<LocalCryptoState> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('singleton')) {
      context.handle(_singletonMeta,
          singleton.isAcceptableOrUnknown(data['singleton']!, _singletonMeta));
    }
    if (data.containsKey('counter')) {
      context.handle(_counterMeta,
          counter.isAcceptableOrUnknown(data['counter']!, _counterMeta));
    } else if (isInserting) {
      context.missing(_counterMeta);
    }
    if (data.containsKey('state_key')) {
      context.handle(_stateKeyMeta,
          stateKey.isAcceptableOrUnknown(data['state_key']!, _stateKeyMeta));
    } else if (isInserting) {
      context.missing(_stateKeyMeta);
    }
    if (data.containsKey('sealed_state')) {
      context.handle(
          _sealedStateMeta,
          sealedState.isAcceptableOrUnknown(
              data['sealed_state']!, _sealedStateMeta));
    } else if (isInserting) {
      context.missing(_sealedStateMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {singleton};
  @override
  LocalCryptoState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalCryptoState(
      singleton: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}singleton'])!,
      counter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}counter'])!,
      stateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}state_key'])!,
      sealedState: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}sealed_state'])!,
    );
  }

  @override
  $LocalCryptoStatesTable createAlias(String alias) {
    return $LocalCryptoStatesTable(attachedDatabase, alias);
  }
}

class LocalCryptoState extends DataClass
    implements Insertable<LocalCryptoState> {
  final int singleton;
  final int counter;
  final Uint8List stateKey;
  final Uint8List sealedState;
  const LocalCryptoState(
      {required this.singleton,
      required this.counter,
      required this.stateKey,
      required this.sealedState});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['singleton'] = Variable<int>(singleton);
    map['counter'] = Variable<int>(counter);
    map['state_key'] = Variable<Uint8List>(stateKey);
    map['sealed_state'] = Variable<Uint8List>(sealedState);
    return map;
  }

  LocalCryptoStatesCompanion toCompanion(bool nullToAbsent) {
    return LocalCryptoStatesCompanion(
      singleton: Value(singleton),
      counter: Value(counter),
      stateKey: Value(stateKey),
      sealedState: Value(sealedState),
    );
  }

  factory LocalCryptoState.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalCryptoState(
      singleton: serializer.fromJson<int>(json['singleton']),
      counter: serializer.fromJson<int>(json['counter']),
      stateKey: serializer.fromJson<Uint8List>(json['stateKey']),
      sealedState: serializer.fromJson<Uint8List>(json['sealedState']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'singleton': serializer.toJson<int>(singleton),
      'counter': serializer.toJson<int>(counter),
      'stateKey': serializer.toJson<Uint8List>(stateKey),
      'sealedState': serializer.toJson<Uint8List>(sealedState),
    };
  }

  LocalCryptoState copyWith(
          {int? singleton,
          int? counter,
          Uint8List? stateKey,
          Uint8List? sealedState}) =>
      LocalCryptoState(
        singleton: singleton ?? this.singleton,
        counter: counter ?? this.counter,
        stateKey: stateKey ?? this.stateKey,
        sealedState: sealedState ?? this.sealedState,
      );
  LocalCryptoState copyWithCompanion(LocalCryptoStatesCompanion data) {
    return LocalCryptoState(
      singleton: data.singleton.present ? data.singleton.value : this.singleton,
      counter: data.counter.present ? data.counter.value : this.counter,
      stateKey: data.stateKey.present ? data.stateKey.value : this.stateKey,
      sealedState:
          data.sealedState.present ? data.sealedState.value : this.sealedState,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalCryptoState(')
          ..write('singleton: $singleton, ')
          ..write('counter: $counter, ')
          ..write('stateKey: $stateKey, ')
          ..write('sealedState: $sealedState')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(singleton, counter,
      $driftBlobEquality.hash(stateKey), $driftBlobEquality.hash(sealedState));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalCryptoState &&
          other.singleton == this.singleton &&
          other.counter == this.counter &&
          $driftBlobEquality.equals(other.stateKey, this.stateKey) &&
          $driftBlobEquality.equals(other.sealedState, this.sealedState));
}

class LocalCryptoStatesCompanion extends UpdateCompanion<LocalCryptoState> {
  final Value<int> singleton;
  final Value<int> counter;
  final Value<Uint8List> stateKey;
  final Value<Uint8List> sealedState;
  const LocalCryptoStatesCompanion({
    this.singleton = const Value.absent(),
    this.counter = const Value.absent(),
    this.stateKey = const Value.absent(),
    this.sealedState = const Value.absent(),
  });
  LocalCryptoStatesCompanion.insert({
    this.singleton = const Value.absent(),
    required int counter,
    required Uint8List stateKey,
    required Uint8List sealedState,
  })  : counter = Value(counter),
        stateKey = Value(stateKey),
        sealedState = Value(sealedState);
  static Insertable<LocalCryptoState> custom({
    Expression<int>? singleton,
    Expression<int>? counter,
    Expression<Uint8List>? stateKey,
    Expression<Uint8List>? sealedState,
  }) {
    return RawValuesInsertable({
      if (singleton != null) 'singleton': singleton,
      if (counter != null) 'counter': counter,
      if (stateKey != null) 'state_key': stateKey,
      if (sealedState != null) 'sealed_state': sealedState,
    });
  }

  LocalCryptoStatesCompanion copyWith(
      {Value<int>? singleton,
      Value<int>? counter,
      Value<Uint8List>? stateKey,
      Value<Uint8List>? sealedState}) {
    return LocalCryptoStatesCompanion(
      singleton: singleton ?? this.singleton,
      counter: counter ?? this.counter,
      stateKey: stateKey ?? this.stateKey,
      sealedState: sealedState ?? this.sealedState,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (singleton.present) {
      map['singleton'] = Variable<int>(singleton.value);
    }
    if (counter.present) {
      map['counter'] = Variable<int>(counter.value);
    }
    if (stateKey.present) {
      map['state_key'] = Variable<Uint8List>(stateKey.value);
    }
    if (sealedState.present) {
      map['sealed_state'] = Variable<Uint8List>(sealedState.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalCryptoStatesCompanion(')
          ..write('singleton: $singleton, ')
          ..write('counter: $counter, ')
          ..write('stateKey: $stateKey, ')
          ..write('sealedState: $sealedState')
          ..write(')'))
        .toString();
  }
}

class $LocalCryptoRecordsTable extends LocalCryptoRecords
    with TableInfo<$LocalCryptoRecordsTable, LocalCryptoRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalCryptoRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<int> kind = GeneratedColumn<int>(
      'kind', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _recordIdMeta =
      const VerificationMeta('recordId');
  @override
  late final GeneratedColumn<Uint8List> recordId = GeneratedColumn<Uint8List>(
      'record_id', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _generationMeta =
      const VerificationMeta('generation');
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
      'generation', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _sealedMeta = const VerificationMeta('sealed');
  @override
  late final GeneratedColumn<Uint8List> sealed = GeneratedColumn<Uint8List>(
      'sealed', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [kind, recordId, generation, sealed];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_crypto_records';
  @override
  VerificationContext validateIntegrity(Insertable<LocalCryptoRecord> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(_recordIdMeta,
          recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta));
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('generation')) {
      context.handle(
          _generationMeta,
          generation.isAcceptableOrUnknown(
              data['generation']!, _generationMeta));
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('sealed')) {
      context.handle(_sealedMeta,
          sealed.isAcceptableOrUnknown(data['sealed']!, _sealedMeta));
    } else if (isInserting) {
      context.missing(_sealedMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {kind, recordId};
  @override
  LocalCryptoRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalCryptoRecord(
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}kind'])!,
      recordId: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}record_id'])!,
      generation: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}generation'])!,
      sealed: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}sealed'])!,
    );
  }

  @override
  $LocalCryptoRecordsTable createAlias(String alias) {
    return $LocalCryptoRecordsTable(attachedDatabase, alias);
  }
}

class LocalCryptoRecord extends DataClass
    implements Insertable<LocalCryptoRecord> {
  /// The record kind from the sealed header (1 device, 2 group, 3 kp).
  final int kind;

  /// The raw record id: a group id or key-package hash ref; empty for the
  /// device record.
  final Uint8List recordId;

  /// The generation (root counter) the record was last sealed at.
  final int generation;
  final Uint8List sealed;
  const LocalCryptoRecord(
      {required this.kind,
      required this.recordId,
      required this.generation,
      required this.sealed});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['kind'] = Variable<int>(kind);
    map['record_id'] = Variable<Uint8List>(recordId);
    map['generation'] = Variable<int>(generation);
    map['sealed'] = Variable<Uint8List>(sealed);
    return map;
  }

  LocalCryptoRecordsCompanion toCompanion(bool nullToAbsent) {
    return LocalCryptoRecordsCompanion(
      kind: Value(kind),
      recordId: Value(recordId),
      generation: Value(generation),
      sealed: Value(sealed),
    );
  }

  factory LocalCryptoRecord.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalCryptoRecord(
      kind: serializer.fromJson<int>(json['kind']),
      recordId: serializer.fromJson<Uint8List>(json['recordId']),
      generation: serializer.fromJson<int>(json['generation']),
      sealed: serializer.fromJson<Uint8List>(json['sealed']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'kind': serializer.toJson<int>(kind),
      'recordId': serializer.toJson<Uint8List>(recordId),
      'generation': serializer.toJson<int>(generation),
      'sealed': serializer.toJson<Uint8List>(sealed),
    };
  }

  LocalCryptoRecord copyWith(
          {int? kind,
          Uint8List? recordId,
          int? generation,
          Uint8List? sealed}) =>
      LocalCryptoRecord(
        kind: kind ?? this.kind,
        recordId: recordId ?? this.recordId,
        generation: generation ?? this.generation,
        sealed: sealed ?? this.sealed,
      );
  LocalCryptoRecord copyWithCompanion(LocalCryptoRecordsCompanion data) {
    return LocalCryptoRecord(
      kind: data.kind.present ? data.kind.value : this.kind,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
      generation:
          data.generation.present ? data.generation.value : this.generation,
      sealed: data.sealed.present ? data.sealed.value : this.sealed,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalCryptoRecord(')
          ..write('kind: $kind, ')
          ..write('recordId: $recordId, ')
          ..write('generation: $generation, ')
          ..write('sealed: $sealed')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(kind, $driftBlobEquality.hash(recordId),
      generation, $driftBlobEquality.hash(sealed));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalCryptoRecord &&
          other.kind == this.kind &&
          $driftBlobEquality.equals(other.recordId, this.recordId) &&
          other.generation == this.generation &&
          $driftBlobEquality.equals(other.sealed, this.sealed));
}

class LocalCryptoRecordsCompanion extends UpdateCompanion<LocalCryptoRecord> {
  final Value<int> kind;
  final Value<Uint8List> recordId;
  final Value<int> generation;
  final Value<Uint8List> sealed;
  final Value<int> rowid;
  const LocalCryptoRecordsCompanion({
    this.kind = const Value.absent(),
    this.recordId = const Value.absent(),
    this.generation = const Value.absent(),
    this.sealed = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalCryptoRecordsCompanion.insert({
    required int kind,
    required Uint8List recordId,
    required int generation,
    required Uint8List sealed,
    this.rowid = const Value.absent(),
  })  : kind = Value(kind),
        recordId = Value(recordId),
        generation = Value(generation),
        sealed = Value(sealed);
  static Insertable<LocalCryptoRecord> custom({
    Expression<int>? kind,
    Expression<Uint8List>? recordId,
    Expression<int>? generation,
    Expression<Uint8List>? sealed,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (kind != null) 'kind': kind,
      if (recordId != null) 'record_id': recordId,
      if (generation != null) 'generation': generation,
      if (sealed != null) 'sealed': sealed,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalCryptoRecordsCompanion copyWith(
      {Value<int>? kind,
      Value<Uint8List>? recordId,
      Value<int>? generation,
      Value<Uint8List>? sealed,
      Value<int>? rowid}) {
    return LocalCryptoRecordsCompanion(
      kind: kind ?? this.kind,
      recordId: recordId ?? this.recordId,
      generation: generation ?? this.generation,
      sealed: sealed ?? this.sealed,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (kind.present) {
      map['kind'] = Variable<int>(kind.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<Uint8List>(recordId.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (sealed.present) {
      map['sealed'] = Variable<Uint8List>(sealed.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalCryptoRecordsCompanion(')
          ..write('kind: $kind, ')
          ..write('recordId: $recordId, ')
          ..write('generation: $generation, ')
          ..write('sealed: $sealed, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalMetadataTable extends LocalMetadata
    with TableInfo<$LocalMetadataTable, LocalMetadataData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMetadataTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [name, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_metadata';
  @override
  VerificationContext validateIntegrity(Insertable<LocalMetadataData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {name};
  @override
  LocalMetadataData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalMetadataData(
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $LocalMetadataTable createAlias(String alias) {
    return $LocalMetadataTable(attachedDatabase, alias);
  }
}

class LocalMetadataData extends DataClass
    implements Insertable<LocalMetadataData> {
  final String name;
  final String value;
  const LocalMetadataData({required this.name, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['name'] = Variable<String>(name);
    map['value'] = Variable<String>(value);
    return map;
  }

  LocalMetadataCompanion toCompanion(bool nullToAbsent) {
    return LocalMetadataCompanion(
      name: Value(name),
      value: Value(value),
    );
  }

  factory LocalMetadataData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalMetadataData(
      name: serializer.fromJson<String>(json['name']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'name': serializer.toJson<String>(name),
      'value': serializer.toJson<String>(value),
    };
  }

  LocalMetadataData copyWith({String? name, String? value}) =>
      LocalMetadataData(
        name: name ?? this.name,
        value: value ?? this.value,
      );
  LocalMetadataData copyWithCompanion(LocalMetadataCompanion data) {
    return LocalMetadataData(
      name: data.name.present ? data.name.value : this.name,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalMetadataData(')
          ..write('name: $name, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(name, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalMetadataData &&
          other.name == this.name &&
          other.value == this.value);
}

class LocalMetadataCompanion extends UpdateCompanion<LocalMetadataData> {
  final Value<String> name;
  final Value<String> value;
  final Value<int> rowid;
  const LocalMetadataCompanion({
    this.name = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMetadataCompanion.insert({
    required String name,
    required String value,
    this.rowid = const Value.absent(),
  })  : name = Value(name),
        value = Value(value);
  static Insertable<LocalMetadataData> custom({
    Expression<String>? name,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (name != null) 'name': name,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMetadataCompanion copyWith(
      {Value<String>? name, Value<String>? value, Value<int>? rowid}) {
    return LocalMetadataCompanion(
      name: name ?? this.name,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMetadataCompanion(')
          ..write('name: $name, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalMlsTransitionsTable extends LocalMlsTransitions
    with TableInfo<$LocalMlsTransitionsTable, LocalMlsTransition> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMlsTransitionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _messageIdMeta =
      const VerificationMeta('messageId');
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
      'message_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _cursorMeta = const VerificationMeta('cursor');
  @override
  late final GeneratedColumn<int> cursor = GeneratedColumn<int>(
      'cursor', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _counterMeta =
      const VerificationMeta('counter');
  @override
  late final GeneratedColumn<int> counter = GeneratedColumn<int>(
      'counter', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [messageId, conversationId, cursor, counter];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_mls_transitions';
  @override
  VerificationContext validateIntegrity(Insertable<LocalMlsTransition> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('message_id')) {
      context.handle(_messageIdMeta,
          messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta));
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('cursor')) {
      context.handle(_cursorMeta,
          cursor.isAcceptableOrUnknown(data['cursor']!, _cursorMeta));
    } else if (isInserting) {
      context.missing(_cursorMeta);
    }
    if (data.containsKey('counter')) {
      context.handle(_counterMeta,
          counter.isAcceptableOrUnknown(data['counter']!, _counterMeta));
    } else if (isInserting) {
      context.missing(_counterMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {messageId};
  @override
  LocalMlsTransition map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalMlsTransition(
      messageId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}message_id'])!,
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      cursor: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}cursor'])!,
      counter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}counter'])!,
    );
  }

  @override
  $LocalMlsTransitionsTable createAlias(String alias) {
    return $LocalMlsTransitionsTable(attachedDatabase, alias);
  }
}

class LocalMlsTransition extends DataClass
    implements Insertable<LocalMlsTransition> {
  final String messageId;
  final String conversationId;
  final int cursor;
  final int counter;
  const LocalMlsTransition(
      {required this.messageId,
      required this.conversationId,
      required this.cursor,
      required this.counter});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['message_id'] = Variable<String>(messageId);
    map['conversation_id'] = Variable<String>(conversationId);
    map['cursor'] = Variable<int>(cursor);
    map['counter'] = Variable<int>(counter);
    return map;
  }

  LocalMlsTransitionsCompanion toCompanion(bool nullToAbsent) {
    return LocalMlsTransitionsCompanion(
      messageId: Value(messageId),
      conversationId: Value(conversationId),
      cursor: Value(cursor),
      counter: Value(counter),
    );
  }

  factory LocalMlsTransition.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalMlsTransition(
      messageId: serializer.fromJson<String>(json['messageId']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      cursor: serializer.fromJson<int>(json['cursor']),
      counter: serializer.fromJson<int>(json['counter']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'messageId': serializer.toJson<String>(messageId),
      'conversationId': serializer.toJson<String>(conversationId),
      'cursor': serializer.toJson<int>(cursor),
      'counter': serializer.toJson<int>(counter),
    };
  }

  LocalMlsTransition copyWith(
          {String? messageId,
          String? conversationId,
          int? cursor,
          int? counter}) =>
      LocalMlsTransition(
        messageId: messageId ?? this.messageId,
        conversationId: conversationId ?? this.conversationId,
        cursor: cursor ?? this.cursor,
        counter: counter ?? this.counter,
      );
  LocalMlsTransition copyWithCompanion(LocalMlsTransitionsCompanion data) {
    return LocalMlsTransition(
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      cursor: data.cursor.present ? data.cursor.value : this.cursor,
      counter: data.counter.present ? data.counter.value : this.counter,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalMlsTransition(')
          ..write('messageId: $messageId, ')
          ..write('conversationId: $conversationId, ')
          ..write('cursor: $cursor, ')
          ..write('counter: $counter')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(messageId, conversationId, cursor, counter);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalMlsTransition &&
          other.messageId == this.messageId &&
          other.conversationId == this.conversationId &&
          other.cursor == this.cursor &&
          other.counter == this.counter);
}

class LocalMlsTransitionsCompanion extends UpdateCompanion<LocalMlsTransition> {
  final Value<String> messageId;
  final Value<String> conversationId;
  final Value<int> cursor;
  final Value<int> counter;
  final Value<int> rowid;
  const LocalMlsTransitionsCompanion({
    this.messageId = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.cursor = const Value.absent(),
    this.counter = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMlsTransitionsCompanion.insert({
    required String messageId,
    required String conversationId,
    required int cursor,
    required int counter,
    this.rowid = const Value.absent(),
  })  : messageId = Value(messageId),
        conversationId = Value(conversationId),
        cursor = Value(cursor),
        counter = Value(counter);
  static Insertable<LocalMlsTransition> custom({
    Expression<String>? messageId,
    Expression<String>? conversationId,
    Expression<int>? cursor,
    Expression<int>? counter,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (messageId != null) 'message_id': messageId,
      if (conversationId != null) 'conversation_id': conversationId,
      if (cursor != null) 'cursor': cursor,
      if (counter != null) 'counter': counter,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMlsTransitionsCompanion copyWith(
      {Value<String>? messageId,
      Value<String>? conversationId,
      Value<int>? cursor,
      Value<int>? counter,
      Value<int>? rowid}) {
    return LocalMlsTransitionsCompanion(
      messageId: messageId ?? this.messageId,
      conversationId: conversationId ?? this.conversationId,
      cursor: cursor ?? this.cursor,
      counter: counter ?? this.counter,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (cursor.present) {
      map['cursor'] = Variable<int>(cursor.value);
    }
    if (counter.present) {
      map['counter'] = Variable<int>(counter.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMlsTransitionsCompanion(')
          ..write('messageId: $messageId, ')
          ..write('conversationId: $conversationId, ')
          ..write('cursor: $cursor, ')
          ..write('counter: $counter, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalMlsOutboxEntriesTable extends LocalMlsOutboxEntries
    with TableInfo<$LocalMlsOutboxEntriesTable, LocalMlsOutboxEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMlsOutboxEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idempotencyKeyMeta =
      const VerificationMeta('idempotencyKey');
  @override
  late final GeneratedColumn<String> idempotencyKey = GeneratedColumn<String>(
      'idempotency_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
      'kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _recipientDeviceIdMeta =
      const VerificationMeta('recipientDeviceId');
  @override
  late final GeneratedColumn<String> recipientDeviceId =
      GeneratedColumn<String>('recipient_device_id', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _revocationDeviceIdMeta =
      const VerificationMeta('revocationDeviceId');
  @override
  late final GeneratedColumn<String> revocationDeviceId =
      GeneratedColumn<String>('revocation_device_id', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _payloadMeta =
      const VerificationMeta('payload');
  @override
  late final GeneratedColumn<Uint8List> payload = GeneratedColumn<Uint8List>(
      'payload', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _stateCounterMeta =
      const VerificationMeta('stateCounter');
  @override
  late final GeneratedColumn<int> stateCounter = GeneratedColumn<int>(
      'state_counter', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _queuedAtMeta =
      const VerificationMeta('queuedAt');
  @override
  late final GeneratedColumn<int> queuedAt = GeneratedColumn<int>(
      'queued_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _attemptCountMeta =
      const VerificationMeta('attemptCount');
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
      'attempt_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _nextAttemptAtMeta =
      const VerificationMeta('nextAttemptAt');
  @override
  late final GeneratedColumn<int> nextAttemptAt = GeneratedColumn<int>(
      'next_attempt_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _failureClassMeta =
      const VerificationMeta('failureClass');
  @override
  late final GeneratedColumn<String> failureClass = GeneratedColumn<String>(
      'failure_class', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _terminalMeta =
      const VerificationMeta('terminal');
  @override
  late final GeneratedColumn<bool> terminal = GeneratedColumn<bool>(
      'terminal', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("terminal" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns => [
        idempotencyKey,
        conversationId,
        kind,
        recipientDeviceId,
        revocationDeviceId,
        payload,
        stateCounter,
        queuedAt,
        attemptCount,
        nextAttemptAt,
        failureClass,
        terminal
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_mls_outbox_entries';
  @override
  VerificationContext validateIntegrity(
      Insertable<LocalMlsOutboxEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('idempotency_key')) {
      context.handle(
          _idempotencyKeyMeta,
          idempotencyKey.isAcceptableOrUnknown(
              data['idempotency_key']!, _idempotencyKeyMeta));
    } else if (isInserting) {
      context.missing(_idempotencyKeyMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('recipient_device_id')) {
      context.handle(
          _recipientDeviceIdMeta,
          recipientDeviceId.isAcceptableOrUnknown(
              data['recipient_device_id']!, _recipientDeviceIdMeta));
    }
    if (data.containsKey('revocation_device_id')) {
      context.handle(
          _revocationDeviceIdMeta,
          revocationDeviceId.isAcceptableOrUnknown(
              data['revocation_device_id']!, _revocationDeviceIdMeta));
    }
    if (data.containsKey('payload')) {
      context.handle(_payloadMeta,
          payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta));
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('state_counter')) {
      context.handle(
          _stateCounterMeta,
          stateCounter.isAcceptableOrUnknown(
              data['state_counter']!, _stateCounterMeta));
    } else if (isInserting) {
      context.missing(_stateCounterMeta);
    }
    if (data.containsKey('queued_at')) {
      context.handle(_queuedAtMeta,
          queuedAt.isAcceptableOrUnknown(data['queued_at']!, _queuedAtMeta));
    } else if (isInserting) {
      context.missing(_queuedAtMeta);
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
          _attemptCountMeta,
          attemptCount.isAcceptableOrUnknown(
              data['attempt_count']!, _attemptCountMeta));
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
          _nextAttemptAtMeta,
          nextAttemptAt.isAcceptableOrUnknown(
              data['next_attempt_at']!, _nextAttemptAtMeta));
    }
    if (data.containsKey('failure_class')) {
      context.handle(
          _failureClassMeta,
          failureClass.isAcceptableOrUnknown(
              data['failure_class']!, _failureClassMeta));
    }
    if (data.containsKey('terminal')) {
      context.handle(_terminalMeta,
          terminal.isAcceptableOrUnknown(data['terminal']!, _terminalMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {idempotencyKey};
  @override
  LocalMlsOutboxEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalMlsOutboxEntry(
      idempotencyKey: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}idempotency_key'])!,
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      recipientDeviceId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}recipient_device_id']),
      revocationDeviceId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}revocation_device_id']),
      payload: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}payload'])!,
      stateCounter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}state_counter'])!,
      queuedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}queued_at'])!,
      attemptCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}attempt_count'])!,
      nextAttemptAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}next_attempt_at']),
      failureClass: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}failure_class']),
      terminal: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}terminal'])!,
    );
  }

  @override
  $LocalMlsOutboxEntriesTable createAlias(String alias) {
    return $LocalMlsOutboxEntriesTable(attachedDatabase, alias);
  }
}

class LocalMlsOutboxEntry extends DataClass
    implements Insertable<LocalMlsOutboxEntry> {
  final String idempotencyKey;
  final String conversationId;
  final String kind;
  final String? recipientDeviceId;
  final String? revocationDeviceId;
  final Uint8List payload;
  final int stateCounter;
  final int queuedAt;
  final int attemptCount;
  final int? nextAttemptAt;
  final String? failureClass;
  final bool terminal;
  const LocalMlsOutboxEntry(
      {required this.idempotencyKey,
      required this.conversationId,
      required this.kind,
      this.recipientDeviceId,
      this.revocationDeviceId,
      required this.payload,
      required this.stateCounter,
      required this.queuedAt,
      required this.attemptCount,
      this.nextAttemptAt,
      this.failureClass,
      required this.terminal});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['idempotency_key'] = Variable<String>(idempotencyKey);
    map['conversation_id'] = Variable<String>(conversationId);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || recipientDeviceId != null) {
      map['recipient_device_id'] = Variable<String>(recipientDeviceId);
    }
    if (!nullToAbsent || revocationDeviceId != null) {
      map['revocation_device_id'] = Variable<String>(revocationDeviceId);
    }
    map['payload'] = Variable<Uint8List>(payload);
    map['state_counter'] = Variable<int>(stateCounter);
    map['queued_at'] = Variable<int>(queuedAt);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || nextAttemptAt != null) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt);
    }
    if (!nullToAbsent || failureClass != null) {
      map['failure_class'] = Variable<String>(failureClass);
    }
    map['terminal'] = Variable<bool>(terminal);
    return map;
  }

  LocalMlsOutboxEntriesCompanion toCompanion(bool nullToAbsent) {
    return LocalMlsOutboxEntriesCompanion(
      idempotencyKey: Value(idempotencyKey),
      conversationId: Value(conversationId),
      kind: Value(kind),
      recipientDeviceId: recipientDeviceId == null && nullToAbsent
          ? const Value.absent()
          : Value(recipientDeviceId),
      revocationDeviceId: revocationDeviceId == null && nullToAbsent
          ? const Value.absent()
          : Value(revocationDeviceId),
      payload: Value(payload),
      stateCounter: Value(stateCounter),
      queuedAt: Value(queuedAt),
      attemptCount: Value(attemptCount),
      nextAttemptAt: nextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAt),
      failureClass: failureClass == null && nullToAbsent
          ? const Value.absent()
          : Value(failureClass),
      terminal: Value(terminal),
    );
  }

  factory LocalMlsOutboxEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalMlsOutboxEntry(
      idempotencyKey: serializer.fromJson<String>(json['idempotencyKey']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      kind: serializer.fromJson<String>(json['kind']),
      recipientDeviceId:
          serializer.fromJson<String?>(json['recipientDeviceId']),
      revocationDeviceId:
          serializer.fromJson<String?>(json['revocationDeviceId']),
      payload: serializer.fromJson<Uint8List>(json['payload']),
      stateCounter: serializer.fromJson<int>(json['stateCounter']),
      queuedAt: serializer.fromJson<int>(json['queuedAt']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      nextAttemptAt: serializer.fromJson<int?>(json['nextAttemptAt']),
      failureClass: serializer.fromJson<String?>(json['failureClass']),
      terminal: serializer.fromJson<bool>(json['terminal']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'idempotencyKey': serializer.toJson<String>(idempotencyKey),
      'conversationId': serializer.toJson<String>(conversationId),
      'kind': serializer.toJson<String>(kind),
      'recipientDeviceId': serializer.toJson<String?>(recipientDeviceId),
      'revocationDeviceId': serializer.toJson<String?>(revocationDeviceId),
      'payload': serializer.toJson<Uint8List>(payload),
      'stateCounter': serializer.toJson<int>(stateCounter),
      'queuedAt': serializer.toJson<int>(queuedAt),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'nextAttemptAt': serializer.toJson<int?>(nextAttemptAt),
      'failureClass': serializer.toJson<String?>(failureClass),
      'terminal': serializer.toJson<bool>(terminal),
    };
  }

  LocalMlsOutboxEntry copyWith(
          {String? idempotencyKey,
          String? conversationId,
          String? kind,
          Value<String?> recipientDeviceId = const Value.absent(),
          Value<String?> revocationDeviceId = const Value.absent(),
          Uint8List? payload,
          int? stateCounter,
          int? queuedAt,
          int? attemptCount,
          Value<int?> nextAttemptAt = const Value.absent(),
          Value<String?> failureClass = const Value.absent(),
          bool? terminal}) =>
      LocalMlsOutboxEntry(
        idempotencyKey: idempotencyKey ?? this.idempotencyKey,
        conversationId: conversationId ?? this.conversationId,
        kind: kind ?? this.kind,
        recipientDeviceId: recipientDeviceId.present
            ? recipientDeviceId.value
            : this.recipientDeviceId,
        revocationDeviceId: revocationDeviceId.present
            ? revocationDeviceId.value
            : this.revocationDeviceId,
        payload: payload ?? this.payload,
        stateCounter: stateCounter ?? this.stateCounter,
        queuedAt: queuedAt ?? this.queuedAt,
        attemptCount: attemptCount ?? this.attemptCount,
        nextAttemptAt:
            nextAttemptAt.present ? nextAttemptAt.value : this.nextAttemptAt,
        failureClass:
            failureClass.present ? failureClass.value : this.failureClass,
        terminal: terminal ?? this.terminal,
      );
  LocalMlsOutboxEntry copyWithCompanion(LocalMlsOutboxEntriesCompanion data) {
    return LocalMlsOutboxEntry(
      idempotencyKey: data.idempotencyKey.present
          ? data.idempotencyKey.value
          : this.idempotencyKey,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      kind: data.kind.present ? data.kind.value : this.kind,
      recipientDeviceId: data.recipientDeviceId.present
          ? data.recipientDeviceId.value
          : this.recipientDeviceId,
      revocationDeviceId: data.revocationDeviceId.present
          ? data.revocationDeviceId.value
          : this.revocationDeviceId,
      payload: data.payload.present ? data.payload.value : this.payload,
      stateCounter: data.stateCounter.present
          ? data.stateCounter.value
          : this.stateCounter,
      queuedAt: data.queuedAt.present ? data.queuedAt.value : this.queuedAt,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      failureClass: data.failureClass.present
          ? data.failureClass.value
          : this.failureClass,
      terminal: data.terminal.present ? data.terminal.value : this.terminal,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalMlsOutboxEntry(')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('conversationId: $conversationId, ')
          ..write('kind: $kind, ')
          ..write('recipientDeviceId: $recipientDeviceId, ')
          ..write('revocationDeviceId: $revocationDeviceId, ')
          ..write('payload: $payload, ')
          ..write('stateCounter: $stateCounter, ')
          ..write('queuedAt: $queuedAt, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('failureClass: $failureClass, ')
          ..write('terminal: $terminal')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      idempotencyKey,
      conversationId,
      kind,
      recipientDeviceId,
      revocationDeviceId,
      $driftBlobEquality.hash(payload),
      stateCounter,
      queuedAt,
      attemptCount,
      nextAttemptAt,
      failureClass,
      terminal);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalMlsOutboxEntry &&
          other.idempotencyKey == this.idempotencyKey &&
          other.conversationId == this.conversationId &&
          other.kind == this.kind &&
          other.recipientDeviceId == this.recipientDeviceId &&
          other.revocationDeviceId == this.revocationDeviceId &&
          $driftBlobEquality.equals(other.payload, this.payload) &&
          other.stateCounter == this.stateCounter &&
          other.queuedAt == this.queuedAt &&
          other.attemptCount == this.attemptCount &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.failureClass == this.failureClass &&
          other.terminal == this.terminal);
}

class LocalMlsOutboxEntriesCompanion
    extends UpdateCompanion<LocalMlsOutboxEntry> {
  final Value<String> idempotencyKey;
  final Value<String> conversationId;
  final Value<String> kind;
  final Value<String?> recipientDeviceId;
  final Value<String?> revocationDeviceId;
  final Value<Uint8List> payload;
  final Value<int> stateCounter;
  final Value<int> queuedAt;
  final Value<int> attemptCount;
  final Value<int?> nextAttemptAt;
  final Value<String?> failureClass;
  final Value<bool> terminal;
  final Value<int> rowid;
  const LocalMlsOutboxEntriesCompanion({
    this.idempotencyKey = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.kind = const Value.absent(),
    this.recipientDeviceId = const Value.absent(),
    this.revocationDeviceId = const Value.absent(),
    this.payload = const Value.absent(),
    this.stateCounter = const Value.absent(),
    this.queuedAt = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.failureClass = const Value.absent(),
    this.terminal = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMlsOutboxEntriesCompanion.insert({
    required String idempotencyKey,
    required String conversationId,
    required String kind,
    this.recipientDeviceId = const Value.absent(),
    this.revocationDeviceId = const Value.absent(),
    required Uint8List payload,
    required int stateCounter,
    required int queuedAt,
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.failureClass = const Value.absent(),
    this.terminal = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : idempotencyKey = Value(idempotencyKey),
        conversationId = Value(conversationId),
        kind = Value(kind),
        payload = Value(payload),
        stateCounter = Value(stateCounter),
        queuedAt = Value(queuedAt);
  static Insertable<LocalMlsOutboxEntry> custom({
    Expression<String>? idempotencyKey,
    Expression<String>? conversationId,
    Expression<String>? kind,
    Expression<String>? recipientDeviceId,
    Expression<String>? revocationDeviceId,
    Expression<Uint8List>? payload,
    Expression<int>? stateCounter,
    Expression<int>? queuedAt,
    Expression<int>? attemptCount,
    Expression<int>? nextAttemptAt,
    Expression<String>? failureClass,
    Expression<bool>? terminal,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      if (conversationId != null) 'conversation_id': conversationId,
      if (kind != null) 'kind': kind,
      if (recipientDeviceId != null) 'recipient_device_id': recipientDeviceId,
      if (revocationDeviceId != null)
        'revocation_device_id': revocationDeviceId,
      if (payload != null) 'payload': payload,
      if (stateCounter != null) 'state_counter': stateCounter,
      if (queuedAt != null) 'queued_at': queuedAt,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (failureClass != null) 'failure_class': failureClass,
      if (terminal != null) 'terminal': terminal,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMlsOutboxEntriesCompanion copyWith(
      {Value<String>? idempotencyKey,
      Value<String>? conversationId,
      Value<String>? kind,
      Value<String?>? recipientDeviceId,
      Value<String?>? revocationDeviceId,
      Value<Uint8List>? payload,
      Value<int>? stateCounter,
      Value<int>? queuedAt,
      Value<int>? attemptCount,
      Value<int?>? nextAttemptAt,
      Value<String?>? failureClass,
      Value<bool>? terminal,
      Value<int>? rowid}) {
    return LocalMlsOutboxEntriesCompanion(
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      conversationId: conversationId ?? this.conversationId,
      kind: kind ?? this.kind,
      recipientDeviceId: recipientDeviceId ?? this.recipientDeviceId,
      revocationDeviceId: revocationDeviceId ?? this.revocationDeviceId,
      payload: payload ?? this.payload,
      stateCounter: stateCounter ?? this.stateCounter,
      queuedAt: queuedAt ?? this.queuedAt,
      attemptCount: attemptCount ?? this.attemptCount,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      failureClass: failureClass ?? this.failureClass,
      terminal: terminal ?? this.terminal,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (idempotencyKey.present) {
      map['idempotency_key'] = Variable<String>(idempotencyKey.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (recipientDeviceId.present) {
      map['recipient_device_id'] = Variable<String>(recipientDeviceId.value);
    }
    if (revocationDeviceId.present) {
      map['revocation_device_id'] = Variable<String>(revocationDeviceId.value);
    }
    if (payload.present) {
      map['payload'] = Variable<Uint8List>(payload.value);
    }
    if (stateCounter.present) {
      map['state_counter'] = Variable<int>(stateCounter.value);
    }
    if (queuedAt.present) {
      map['queued_at'] = Variable<int>(queuedAt.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt.value);
    }
    if (failureClass.present) {
      map['failure_class'] = Variable<String>(failureClass.value);
    }
    if (terminal.present) {
      map['terminal'] = Variable<bool>(terminal.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMlsOutboxEntriesCompanion(')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('conversationId: $conversationId, ')
          ..write('kind: $kind, ')
          ..write('recipientDeviceId: $recipientDeviceId, ')
          ..write('revocationDeviceId: $revocationDeviceId, ')
          ..write('payload: $payload, ')
          ..write('stateCounter: $stateCounter, ')
          ..write('queuedAt: $queuedAt, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('failureClass: $failureClass, ')
          ..write('terminal: $terminal, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalPeerVerificationsTable extends LocalPeerVerifications
    with TableInfo<$LocalPeerVerificationsTable, LocalPeerVerification> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalPeerVerificationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _peerAccountIdMeta =
      const VerificationMeta('peerAccountId');
  @override
  late final GeneratedColumn<String> peerAccountId = GeneratedColumn<String>(
      'peer_account_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _transcriptHashMeta =
      const VerificationMeta('transcriptHash');
  @override
  late final GeneratedColumn<Uint8List> transcriptHash =
      GeneratedColumn<Uint8List>('transcript_hash', aliasedName, false,
          type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _verifiedAtMeta =
      const VerificationMeta('verifiedAt');
  @override
  late final GeneratedColumn<int> verifiedAt = GeneratedColumn<int>(
      'verified_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [conversationId, peerAccountId, transcriptHash, verifiedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_peer_verifications';
  @override
  VerificationContext validateIntegrity(
      Insertable<LocalPeerVerification> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('peer_account_id')) {
      context.handle(
          _peerAccountIdMeta,
          peerAccountId.isAcceptableOrUnknown(
              data['peer_account_id']!, _peerAccountIdMeta));
    } else if (isInserting) {
      context.missing(_peerAccountIdMeta);
    }
    if (data.containsKey('transcript_hash')) {
      context.handle(
          _transcriptHashMeta,
          transcriptHash.isAcceptableOrUnknown(
              data['transcript_hash']!, _transcriptHashMeta));
    } else if (isInserting) {
      context.missing(_transcriptHashMeta);
    }
    if (data.containsKey('verified_at')) {
      context.handle(
          _verifiedAtMeta,
          verifiedAt.isAcceptableOrUnknown(
              data['verified_at']!, _verifiedAtMeta));
    } else if (isInserting) {
      context.missing(_verifiedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId, peerAccountId};
  @override
  LocalPeerVerification map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalPeerVerification(
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      peerAccountId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}peer_account_id'])!,
      transcriptHash: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}transcript_hash'])!,
      verifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}verified_at'])!,
    );
  }

  @override
  $LocalPeerVerificationsTable createAlias(String alias) {
    return $LocalPeerVerificationsTable(attachedDatabase, alias);
  }
}

class LocalPeerVerification extends DataClass
    implements Insertable<LocalPeerVerification> {
  final String conversationId;
  final String peerAccountId;
  final Uint8List transcriptHash;
  final int verifiedAt;
  const LocalPeerVerification(
      {required this.conversationId,
      required this.peerAccountId,
      required this.transcriptHash,
      required this.verifiedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['peer_account_id'] = Variable<String>(peerAccountId);
    map['transcript_hash'] = Variable<Uint8List>(transcriptHash);
    map['verified_at'] = Variable<int>(verifiedAt);
    return map;
  }

  LocalPeerVerificationsCompanion toCompanion(bool nullToAbsent) {
    return LocalPeerVerificationsCompanion(
      conversationId: Value(conversationId),
      peerAccountId: Value(peerAccountId),
      transcriptHash: Value(transcriptHash),
      verifiedAt: Value(verifiedAt),
    );
  }

  factory LocalPeerVerification.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalPeerVerification(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      peerAccountId: serializer.fromJson<String>(json['peerAccountId']),
      transcriptHash: serializer.fromJson<Uint8List>(json['transcriptHash']),
      verifiedAt: serializer.fromJson<int>(json['verifiedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'peerAccountId': serializer.toJson<String>(peerAccountId),
      'transcriptHash': serializer.toJson<Uint8List>(transcriptHash),
      'verifiedAt': serializer.toJson<int>(verifiedAt),
    };
  }

  LocalPeerVerification copyWith(
          {String? conversationId,
          String? peerAccountId,
          Uint8List? transcriptHash,
          int? verifiedAt}) =>
      LocalPeerVerification(
        conversationId: conversationId ?? this.conversationId,
        peerAccountId: peerAccountId ?? this.peerAccountId,
        transcriptHash: transcriptHash ?? this.transcriptHash,
        verifiedAt: verifiedAt ?? this.verifiedAt,
      );
  LocalPeerVerification copyWithCompanion(
      LocalPeerVerificationsCompanion data) {
    return LocalPeerVerification(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      peerAccountId: data.peerAccountId.present
          ? data.peerAccountId.value
          : this.peerAccountId,
      transcriptHash: data.transcriptHash.present
          ? data.transcriptHash.value
          : this.transcriptHash,
      verifiedAt:
          data.verifiedAt.present ? data.verifiedAt.value : this.verifiedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalPeerVerification(')
          ..write('conversationId: $conversationId, ')
          ..write('peerAccountId: $peerAccountId, ')
          ..write('transcriptHash: $transcriptHash, ')
          ..write('verifiedAt: $verifiedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(conversationId, peerAccountId,
      $driftBlobEquality.hash(transcriptHash), verifiedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalPeerVerification &&
          other.conversationId == this.conversationId &&
          other.peerAccountId == this.peerAccountId &&
          $driftBlobEquality.equals(
              other.transcriptHash, this.transcriptHash) &&
          other.verifiedAt == this.verifiedAt);
}

class LocalPeerVerificationsCompanion
    extends UpdateCompanion<LocalPeerVerification> {
  final Value<String> conversationId;
  final Value<String> peerAccountId;
  final Value<Uint8List> transcriptHash;
  final Value<int> verifiedAt;
  final Value<int> rowid;
  const LocalPeerVerificationsCompanion({
    this.conversationId = const Value.absent(),
    this.peerAccountId = const Value.absent(),
    this.transcriptHash = const Value.absent(),
    this.verifiedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalPeerVerificationsCompanion.insert({
    required String conversationId,
    required String peerAccountId,
    required Uint8List transcriptHash,
    required int verifiedAt,
    this.rowid = const Value.absent(),
  })  : conversationId = Value(conversationId),
        peerAccountId = Value(peerAccountId),
        transcriptHash = Value(transcriptHash),
        verifiedAt = Value(verifiedAt);
  static Insertable<LocalPeerVerification> custom({
    Expression<String>? conversationId,
    Expression<String>? peerAccountId,
    Expression<Uint8List>? transcriptHash,
    Expression<int>? verifiedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (peerAccountId != null) 'peer_account_id': peerAccountId,
      if (transcriptHash != null) 'transcript_hash': transcriptHash,
      if (verifiedAt != null) 'verified_at': verifiedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalPeerVerificationsCompanion copyWith(
      {Value<String>? conversationId,
      Value<String>? peerAccountId,
      Value<Uint8List>? transcriptHash,
      Value<int>? verifiedAt,
      Value<int>? rowid}) {
    return LocalPeerVerificationsCompanion(
      conversationId: conversationId ?? this.conversationId,
      peerAccountId: peerAccountId ?? this.peerAccountId,
      transcriptHash: transcriptHash ?? this.transcriptHash,
      verifiedAt: verifiedAt ?? this.verifiedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (peerAccountId.present) {
      map['peer_account_id'] = Variable<String>(peerAccountId.value);
    }
    if (transcriptHash.present) {
      map['transcript_hash'] = Variable<Uint8List>(transcriptHash.value);
    }
    if (verifiedAt.present) {
      map['verified_at'] = Variable<int>(verifiedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalPeerVerificationsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('peerAccountId: $peerAccountId, ')
          ..write('transcriptHash: $transcriptHash, ')
          ..write('verifiedAt: $verifiedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalMessagesTable extends LocalMessages
    with TableInfo<$LocalMessagesTable, LocalMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _serverMessageIdMeta =
      const VerificationMeta('serverMessageId');
  @override
  late final GeneratedColumn<String> serverMessageId = GeneratedColumn<String>(
      'server_message_id', aliasedName, true,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _senderAccountIdMeta =
      const VerificationMeta('senderAccountId');
  @override
  late final GeneratedColumn<String> senderAccountId = GeneratedColumn<String>(
      'sender_account_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _senderDeviceIdMeta =
      const VerificationMeta('senderDeviceId');
  @override
  late final GeneratedColumn<String> senderDeviceId = GeneratedColumn<String>(
      'sender_device_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
      'kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
      'body', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _replyToMeta =
      const VerificationMeta('replyTo');
  @override
  late final GeneratedColumn<String> replyTo = GeneratedColumn<String>(
      'reply_to', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _editedAtMeta =
      const VerificationMeta('editedAt');
  @override
  late final GeneratedColumn<int> editedAt = GeneratedColumn<int>(
      'edited_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
      'deleted_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
      'state', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _expiresAtMeta =
      const VerificationMeta('expiresAt');
  @override
  late final GeneratedColumn<int> expiresAt = GeneratedColumn<int>(
      'expires_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _searchIdMeta =
      const VerificationMeta('searchId');
  @override
  late final GeneratedColumn<int> searchId = GeneratedColumn<int>(
      'search_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _hiddenAtMeta =
      const VerificationMeta('hiddenAt');
  @override
  late final GeneratedColumn<int> hiddenAt = GeneratedColumn<int>(
      'hidden_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _formatJsonMeta =
      const VerificationMeta('formatJson');
  @override
  late final GeneratedColumn<String> formatJson = GeneratedColumn<String>(
      'format_json', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _forwardHopsMeta =
      const VerificationMeta('forwardHops');
  @override
  late final GeneratedColumn<int> forwardHops = GeneratedColumn<int>(
      'forward_hops', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _channelIdMeta =
      const VerificationMeta('channelId');
  @override
  late final GeneratedColumn<String> channelId = GeneratedColumn<String>(
      'channel_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _senderHiddenMeta =
      const VerificationMeta('senderHidden');
  @override
  late final GeneratedColumn<bool> senderHidden = GeneratedColumn<bool>(
      'sender_hidden', aliasedName, true,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("sender_hidden" IN (0, 1))'));
  @override
  List<GeneratedColumn> get $columns => [
        key,
        serverMessageId,
        conversationId,
        senderAccountId,
        senderDeviceId,
        kind,
        body,
        replyTo,
        createdAt,
        editedAt,
        deletedAt,
        state,
        expiresAt,
        searchId,
        hiddenAt,
        formatJson,
        forwardHops,
        channelId,
        senderHidden
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_messages';
  @override
  VerificationContext validateIntegrity(Insertable<LocalMessage> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('server_message_id')) {
      context.handle(
          _serverMessageIdMeta,
          serverMessageId.isAcceptableOrUnknown(
              data['server_message_id']!, _serverMessageIdMeta));
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('sender_account_id')) {
      context.handle(
          _senderAccountIdMeta,
          senderAccountId.isAcceptableOrUnknown(
              data['sender_account_id']!, _senderAccountIdMeta));
    } else if (isInserting) {
      context.missing(_senderAccountIdMeta);
    }
    if (data.containsKey('sender_device_id')) {
      context.handle(
          _senderDeviceIdMeta,
          senderDeviceId.isAcceptableOrUnknown(
              data['sender_device_id']!, _senderDeviceIdMeta));
    } else if (isInserting) {
      context.missing(_senderDeviceIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
          _bodyMeta, body.isAcceptableOrUnknown(data['body']!, _bodyMeta));
    }
    if (data.containsKey('reply_to')) {
      context.handle(_replyToMeta,
          replyTo.isAcceptableOrUnknown(data['reply_to']!, _replyToMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('edited_at')) {
      context.handle(_editedAtMeta,
          editedAt.isAcceptableOrUnknown(data['edited_at']!, _editedAtMeta));
    }
    if (data.containsKey('deleted_at')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta));
    }
    if (data.containsKey('state')) {
      context.handle(
          _stateMeta, state.isAcceptableOrUnknown(data['state']!, _stateMeta));
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(_expiresAtMeta,
          expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta));
    }
    if (data.containsKey('search_id')) {
      context.handle(_searchIdMeta,
          searchId.isAcceptableOrUnknown(data['search_id']!, _searchIdMeta));
    }
    if (data.containsKey('hidden_at')) {
      context.handle(_hiddenAtMeta,
          hiddenAt.isAcceptableOrUnknown(data['hidden_at']!, _hiddenAtMeta));
    }
    if (data.containsKey('format_json')) {
      context.handle(
          _formatJsonMeta,
          formatJson.isAcceptableOrUnknown(
              data['format_json']!, _formatJsonMeta));
    }
    if (data.containsKey('forward_hops')) {
      context.handle(
          _forwardHopsMeta,
          forwardHops.isAcceptableOrUnknown(
              data['forward_hops']!, _forwardHopsMeta));
    }
    if (data.containsKey('channel_id')) {
      context.handle(_channelIdMeta,
          channelId.isAcceptableOrUnknown(data['channel_id']!, _channelIdMeta));
    }
    if (data.containsKey('sender_hidden')) {
      context.handle(
          _senderHiddenMeta,
          senderHidden.isAcceptableOrUnknown(
              data['sender_hidden']!, _senderHiddenMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  LocalMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalMessage(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      serverMessageId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}server_message_id']),
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      senderAccountId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}sender_account_id'])!,
      senderDeviceId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}sender_device_id'])!,
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      body: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}body']),
      replyTo: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reply_to']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      editedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}edited_at']),
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}deleted_at']),
      state: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}state'])!,
      expiresAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}expires_at']),
      searchId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}search_id']),
      hiddenAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}hidden_at']),
      formatJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}format_json']),
      forwardHops: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}forward_hops']),
      channelId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}channel_id']),
      senderHidden: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}sender_hidden']),
    );
  }

  @override
  $LocalMessagesTable createAlias(String alias) {
    return $LocalMessagesTable(attachedDatabase, alias);
  }
}

class LocalMessage extends DataClass implements Insertable<LocalMessage> {
  final String key;
  final String? serverMessageId;
  final String conversationId;
  final String senderAccountId;
  final String senderDeviceId;
  final String kind;
  final String? body;
  final String? replyTo;
  final int createdAt;
  final int? editedAt;
  final int? deletedAt;
  final String state;
  final int? expiresAt;

  /// The row's number in the search index (W10, schema 12), set by the
  /// database's triggers for text messages and never by the app. The index
  /// cannot use `rowid`: a table keyed by text may renumber its rows when
  /// vacuumed, which would leave deleted text in the index.
  final int? searchId;
  final int? hiddenAt;
  final String? formatJson;
  final int? forwardHops;
  final String? channelId;
  final bool? senderHidden;
  const LocalMessage(
      {required this.key,
      this.serverMessageId,
      required this.conversationId,
      required this.senderAccountId,
      required this.senderDeviceId,
      required this.kind,
      this.body,
      this.replyTo,
      required this.createdAt,
      this.editedAt,
      this.deletedAt,
      required this.state,
      this.expiresAt,
      this.searchId,
      this.hiddenAt,
      this.formatJson,
      this.forwardHops,
      this.channelId,
      this.senderHidden});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    if (!nullToAbsent || serverMessageId != null) {
      map['server_message_id'] = Variable<String>(serverMessageId);
    }
    map['conversation_id'] = Variable<String>(conversationId);
    map['sender_account_id'] = Variable<String>(senderAccountId);
    map['sender_device_id'] = Variable<String>(senderDeviceId);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || body != null) {
      map['body'] = Variable<String>(body);
    }
    if (!nullToAbsent || replyTo != null) {
      map['reply_to'] = Variable<String>(replyTo);
    }
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || editedAt != null) {
      map['edited_at'] = Variable<int>(editedAt);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || expiresAt != null) {
      map['expires_at'] = Variable<int>(expiresAt);
    }
    if (!nullToAbsent || searchId != null) {
      map['search_id'] = Variable<int>(searchId);
    }
    if (!nullToAbsent || hiddenAt != null) {
      map['hidden_at'] = Variable<int>(hiddenAt);
    }
    if (!nullToAbsent || formatJson != null) {
      map['format_json'] = Variable<String>(formatJson);
    }
    if (!nullToAbsent || forwardHops != null) {
      map['forward_hops'] = Variable<int>(forwardHops);
    }
    if (!nullToAbsent || channelId != null) {
      map['channel_id'] = Variable<String>(channelId);
    }
    if (!nullToAbsent || senderHidden != null) {
      map['sender_hidden'] = Variable<bool>(senderHidden);
    }
    return map;
  }

  LocalMessagesCompanion toCompanion(bool nullToAbsent) {
    return LocalMessagesCompanion(
      key: Value(key),
      serverMessageId: serverMessageId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverMessageId),
      conversationId: Value(conversationId),
      senderAccountId: Value(senderAccountId),
      senderDeviceId: Value(senderDeviceId),
      kind: Value(kind),
      body: body == null && nullToAbsent ? const Value.absent() : Value(body),
      replyTo: replyTo == null && nullToAbsent
          ? const Value.absent()
          : Value(replyTo),
      createdAt: Value(createdAt),
      editedAt: editedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(editedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      state: Value(state),
      expiresAt: expiresAt == null && nullToAbsent
          ? const Value.absent()
          : Value(expiresAt),
      searchId: searchId == null && nullToAbsent
          ? const Value.absent()
          : Value(searchId),
      hiddenAt: hiddenAt == null && nullToAbsent
          ? const Value.absent()
          : Value(hiddenAt),
      formatJson: formatJson == null && nullToAbsent
          ? const Value.absent()
          : Value(formatJson),
      forwardHops: forwardHops == null && nullToAbsent
          ? const Value.absent()
          : Value(forwardHops),
      channelId: channelId == null && nullToAbsent
          ? const Value.absent()
          : Value(channelId),
      senderHidden: senderHidden == null && nullToAbsent
          ? const Value.absent()
          : Value(senderHidden),
    );
  }

  factory LocalMessage.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalMessage(
      key: serializer.fromJson<String>(json['key']),
      serverMessageId: serializer.fromJson<String?>(json['serverMessageId']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      senderAccountId: serializer.fromJson<String>(json['senderAccountId']),
      senderDeviceId: serializer.fromJson<String>(json['senderDeviceId']),
      kind: serializer.fromJson<String>(json['kind']),
      body: serializer.fromJson<String?>(json['body']),
      replyTo: serializer.fromJson<String?>(json['replyTo']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      editedAt: serializer.fromJson<int?>(json['editedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      state: serializer.fromJson<String>(json['state']),
      expiresAt: serializer.fromJson<int?>(json['expiresAt']),
      searchId: serializer.fromJson<int?>(json['searchId']),
      hiddenAt: serializer.fromJson<int?>(json['hiddenAt']),
      formatJson: serializer.fromJson<String?>(json['formatJson']),
      forwardHops: serializer.fromJson<int?>(json['forwardHops']),
      channelId: serializer.fromJson<String?>(json['channelId']),
      senderHidden: serializer.fromJson<bool?>(json['senderHidden']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'serverMessageId': serializer.toJson<String?>(serverMessageId),
      'conversationId': serializer.toJson<String>(conversationId),
      'senderAccountId': serializer.toJson<String>(senderAccountId),
      'senderDeviceId': serializer.toJson<String>(senderDeviceId),
      'kind': serializer.toJson<String>(kind),
      'body': serializer.toJson<String?>(body),
      'replyTo': serializer.toJson<String?>(replyTo),
      'createdAt': serializer.toJson<int>(createdAt),
      'editedAt': serializer.toJson<int?>(editedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'state': serializer.toJson<String>(state),
      'expiresAt': serializer.toJson<int?>(expiresAt),
      'searchId': serializer.toJson<int?>(searchId),
      'hiddenAt': serializer.toJson<int?>(hiddenAt),
      'formatJson': serializer.toJson<String?>(formatJson),
      'forwardHops': serializer.toJson<int?>(forwardHops),
      'channelId': serializer.toJson<String?>(channelId),
      'senderHidden': serializer.toJson<bool?>(senderHidden),
    };
  }

  LocalMessage copyWith(
          {String? key,
          Value<String?> serverMessageId = const Value.absent(),
          String? conversationId,
          String? senderAccountId,
          String? senderDeviceId,
          String? kind,
          Value<String?> body = const Value.absent(),
          Value<String?> replyTo = const Value.absent(),
          int? createdAt,
          Value<int?> editedAt = const Value.absent(),
          Value<int?> deletedAt = const Value.absent(),
          String? state,
          Value<int?> expiresAt = const Value.absent(),
          Value<int?> searchId = const Value.absent(),
          Value<int?> hiddenAt = const Value.absent(),
          Value<String?> formatJson = const Value.absent(),
          Value<int?> forwardHops = const Value.absent(),
          Value<String?> channelId = const Value.absent(),
          Value<bool?> senderHidden = const Value.absent()}) =>
      LocalMessage(
        key: key ?? this.key,
        serverMessageId: serverMessageId.present
            ? serverMessageId.value
            : this.serverMessageId,
        conversationId: conversationId ?? this.conversationId,
        senderAccountId: senderAccountId ?? this.senderAccountId,
        senderDeviceId: senderDeviceId ?? this.senderDeviceId,
        kind: kind ?? this.kind,
        body: body.present ? body.value : this.body,
        replyTo: replyTo.present ? replyTo.value : this.replyTo,
        createdAt: createdAt ?? this.createdAt,
        editedAt: editedAt.present ? editedAt.value : this.editedAt,
        deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
        state: state ?? this.state,
        expiresAt: expiresAt.present ? expiresAt.value : this.expiresAt,
        searchId: searchId.present ? searchId.value : this.searchId,
        hiddenAt: hiddenAt.present ? hiddenAt.value : this.hiddenAt,
        formatJson: formatJson.present ? formatJson.value : this.formatJson,
        forwardHops: forwardHops.present ? forwardHops.value : this.forwardHops,
        channelId: channelId.present ? channelId.value : this.channelId,
        senderHidden:
            senderHidden.present ? senderHidden.value : this.senderHidden,
      );
  LocalMessage copyWithCompanion(LocalMessagesCompanion data) {
    return LocalMessage(
      key: data.key.present ? data.key.value : this.key,
      serverMessageId: data.serverMessageId.present
          ? data.serverMessageId.value
          : this.serverMessageId,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      senderAccountId: data.senderAccountId.present
          ? data.senderAccountId.value
          : this.senderAccountId,
      senderDeviceId: data.senderDeviceId.present
          ? data.senderDeviceId.value
          : this.senderDeviceId,
      kind: data.kind.present ? data.kind.value : this.kind,
      body: data.body.present ? data.body.value : this.body,
      replyTo: data.replyTo.present ? data.replyTo.value : this.replyTo,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      editedAt: data.editedAt.present ? data.editedAt.value : this.editedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      state: data.state.present ? data.state.value : this.state,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
      searchId: data.searchId.present ? data.searchId.value : this.searchId,
      hiddenAt: data.hiddenAt.present ? data.hiddenAt.value : this.hiddenAt,
      formatJson:
          data.formatJson.present ? data.formatJson.value : this.formatJson,
      forwardHops:
          data.forwardHops.present ? data.forwardHops.value : this.forwardHops,
      channelId: data.channelId.present ? data.channelId.value : this.channelId,
      senderHidden: data.senderHidden.present
          ? data.senderHidden.value
          : this.senderHidden,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessage(')
          ..write('key: $key, ')
          ..write('serverMessageId: $serverMessageId, ')
          ..write('conversationId: $conversationId, ')
          ..write('senderAccountId: $senderAccountId, ')
          ..write('senderDeviceId: $senderDeviceId, ')
          ..write('kind: $kind, ')
          ..write('body: $body, ')
          ..write('replyTo: $replyTo, ')
          ..write('createdAt: $createdAt, ')
          ..write('editedAt: $editedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('state: $state, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('searchId: $searchId, ')
          ..write('hiddenAt: $hiddenAt, ')
          ..write('formatJson: $formatJson, ')
          ..write('forwardHops: $forwardHops, ')
          ..write('channelId: $channelId, ')
          ..write('senderHidden: $senderHidden')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      key,
      serverMessageId,
      conversationId,
      senderAccountId,
      senderDeviceId,
      kind,
      body,
      replyTo,
      createdAt,
      editedAt,
      deletedAt,
      state,
      expiresAt,
      searchId,
      hiddenAt,
      formatJson,
      forwardHops,
      channelId,
      senderHidden);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalMessage &&
          other.key == this.key &&
          other.serverMessageId == this.serverMessageId &&
          other.conversationId == this.conversationId &&
          other.senderAccountId == this.senderAccountId &&
          other.senderDeviceId == this.senderDeviceId &&
          other.kind == this.kind &&
          other.body == this.body &&
          other.replyTo == this.replyTo &&
          other.createdAt == this.createdAt &&
          other.editedAt == this.editedAt &&
          other.deletedAt == this.deletedAt &&
          other.state == this.state &&
          other.expiresAt == this.expiresAt &&
          other.searchId == this.searchId &&
          other.hiddenAt == this.hiddenAt &&
          other.formatJson == this.formatJson &&
          other.forwardHops == this.forwardHops &&
          other.channelId == this.channelId &&
          other.senderHidden == this.senderHidden);
}

class LocalMessagesCompanion extends UpdateCompanion<LocalMessage> {
  final Value<String> key;
  final Value<String?> serverMessageId;
  final Value<String> conversationId;
  final Value<String> senderAccountId;
  final Value<String> senderDeviceId;
  final Value<String> kind;
  final Value<String?> body;
  final Value<String?> replyTo;
  final Value<int> createdAt;
  final Value<int?> editedAt;
  final Value<int?> deletedAt;
  final Value<String> state;
  final Value<int?> expiresAt;
  final Value<int?> searchId;
  final Value<int?> hiddenAt;
  final Value<String?> formatJson;
  final Value<int?> forwardHops;
  final Value<String?> channelId;
  final Value<bool?> senderHidden;
  final Value<int> rowid;
  const LocalMessagesCompanion({
    this.key = const Value.absent(),
    this.serverMessageId = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.senderAccountId = const Value.absent(),
    this.senderDeviceId = const Value.absent(),
    this.kind = const Value.absent(),
    this.body = const Value.absent(),
    this.replyTo = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.editedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.state = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.searchId = const Value.absent(),
    this.hiddenAt = const Value.absent(),
    this.formatJson = const Value.absent(),
    this.forwardHops = const Value.absent(),
    this.channelId = const Value.absent(),
    this.senderHidden = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMessagesCompanion.insert({
    required String key,
    this.serverMessageId = const Value.absent(),
    required String conversationId,
    required String senderAccountId,
    required String senderDeviceId,
    required String kind,
    this.body = const Value.absent(),
    this.replyTo = const Value.absent(),
    required int createdAt,
    this.editedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    required String state,
    this.expiresAt = const Value.absent(),
    this.searchId = const Value.absent(),
    this.hiddenAt = const Value.absent(),
    this.formatJson = const Value.absent(),
    this.forwardHops = const Value.absent(),
    this.channelId = const Value.absent(),
    this.senderHidden = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        conversationId = Value(conversationId),
        senderAccountId = Value(senderAccountId),
        senderDeviceId = Value(senderDeviceId),
        kind = Value(kind),
        createdAt = Value(createdAt),
        state = Value(state);
  static Insertable<LocalMessage> custom({
    Expression<String>? key,
    Expression<String>? serverMessageId,
    Expression<String>? conversationId,
    Expression<String>? senderAccountId,
    Expression<String>? senderDeviceId,
    Expression<String>? kind,
    Expression<String>? body,
    Expression<String>? replyTo,
    Expression<int>? createdAt,
    Expression<int>? editedAt,
    Expression<int>? deletedAt,
    Expression<String>? state,
    Expression<int>? expiresAt,
    Expression<int>? searchId,
    Expression<int>? hiddenAt,
    Expression<String>? formatJson,
    Expression<int>? forwardHops,
    Expression<String>? channelId,
    Expression<bool>? senderHidden,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (serverMessageId != null) 'server_message_id': serverMessageId,
      if (conversationId != null) 'conversation_id': conversationId,
      if (senderAccountId != null) 'sender_account_id': senderAccountId,
      if (senderDeviceId != null) 'sender_device_id': senderDeviceId,
      if (kind != null) 'kind': kind,
      if (body != null) 'body': body,
      if (replyTo != null) 'reply_to': replyTo,
      if (createdAt != null) 'created_at': createdAt,
      if (editedAt != null) 'edited_at': editedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (state != null) 'state': state,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (searchId != null) 'search_id': searchId,
      if (hiddenAt != null) 'hidden_at': hiddenAt,
      if (formatJson != null) 'format_json': formatJson,
      if (forwardHops != null) 'forward_hops': forwardHops,
      if (channelId != null) 'channel_id': channelId,
      if (senderHidden != null) 'sender_hidden': senderHidden,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMessagesCompanion copyWith(
      {Value<String>? key,
      Value<String?>? serverMessageId,
      Value<String>? conversationId,
      Value<String>? senderAccountId,
      Value<String>? senderDeviceId,
      Value<String>? kind,
      Value<String?>? body,
      Value<String?>? replyTo,
      Value<int>? createdAt,
      Value<int?>? editedAt,
      Value<int?>? deletedAt,
      Value<String>? state,
      Value<int?>? expiresAt,
      Value<int?>? searchId,
      Value<int?>? hiddenAt,
      Value<String?>? formatJson,
      Value<int?>? forwardHops,
      Value<String?>? channelId,
      Value<bool?>? senderHidden,
      Value<int>? rowid}) {
    return LocalMessagesCompanion(
      key: key ?? this.key,
      serverMessageId: serverMessageId ?? this.serverMessageId,
      conversationId: conversationId ?? this.conversationId,
      senderAccountId: senderAccountId ?? this.senderAccountId,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
      kind: kind ?? this.kind,
      body: body ?? this.body,
      replyTo: replyTo ?? this.replyTo,
      createdAt: createdAt ?? this.createdAt,
      editedAt: editedAt ?? this.editedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      state: state ?? this.state,
      expiresAt: expiresAt ?? this.expiresAt,
      searchId: searchId ?? this.searchId,
      hiddenAt: hiddenAt ?? this.hiddenAt,
      formatJson: formatJson ?? this.formatJson,
      forwardHops: forwardHops ?? this.forwardHops,
      channelId: channelId ?? this.channelId,
      senderHidden: senderHidden ?? this.senderHidden,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (serverMessageId.present) {
      map['server_message_id'] = Variable<String>(serverMessageId.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (senderAccountId.present) {
      map['sender_account_id'] = Variable<String>(senderAccountId.value);
    }
    if (senderDeviceId.present) {
      map['sender_device_id'] = Variable<String>(senderDeviceId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (replyTo.present) {
      map['reply_to'] = Variable<String>(replyTo.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (editedAt.present) {
      map['edited_at'] = Variable<int>(editedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<int>(expiresAt.value);
    }
    if (searchId.present) {
      map['search_id'] = Variable<int>(searchId.value);
    }
    if (hiddenAt.present) {
      map['hidden_at'] = Variable<int>(hiddenAt.value);
    }
    if (formatJson.present) {
      map['format_json'] = Variable<String>(formatJson.value);
    }
    if (forwardHops.present) {
      map['forward_hops'] = Variable<int>(forwardHops.value);
    }
    if (channelId.present) {
      map['channel_id'] = Variable<String>(channelId.value);
    }
    if (senderHidden.present) {
      map['sender_hidden'] = Variable<bool>(senderHidden.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessagesCompanion(')
          ..write('key: $key, ')
          ..write('serverMessageId: $serverMessageId, ')
          ..write('conversationId: $conversationId, ')
          ..write('senderAccountId: $senderAccountId, ')
          ..write('senderDeviceId: $senderDeviceId, ')
          ..write('kind: $kind, ')
          ..write('body: $body, ')
          ..write('replyTo: $replyTo, ')
          ..write('createdAt: $createdAt, ')
          ..write('editedAt: $editedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('state: $state, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('searchId: $searchId, ')
          ..write('hiddenAt: $hiddenAt, ')
          ..write('formatJson: $formatJson, ')
          ..write('forwardHops: $forwardHops, ')
          ..write('channelId: $channelId, ')
          ..write('senderHidden: $senderHidden, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalMessageReactionsTable extends LocalMessageReactions
    with TableInfo<$LocalMessageReactionsTable, LocalMessageReaction> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMessageReactionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _targetKeyMeta =
      const VerificationMeta('targetKey');
  @override
  late final GeneratedColumn<String> targetKey = GeneratedColumn<String>(
      'target_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _reactorAccountIdMeta =
      const VerificationMeta('reactorAccountId');
  @override
  late final GeneratedColumn<String> reactorAccountId = GeneratedColumn<String>(
      'reactor_account_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _reactionMeta =
      const VerificationMeta('reaction');
  @override
  late final GeneratedColumn<String> reaction = GeneratedColumn<String>(
      'reaction', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [targetKey, reactorAccountId, reaction, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_message_reactions';
  @override
  VerificationContext validateIntegrity(
      Insertable<LocalMessageReaction> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('target_key')) {
      context.handle(_targetKeyMeta,
          targetKey.isAcceptableOrUnknown(data['target_key']!, _targetKeyMeta));
    } else if (isInserting) {
      context.missing(_targetKeyMeta);
    }
    if (data.containsKey('reactor_account_id')) {
      context.handle(
          _reactorAccountIdMeta,
          reactorAccountId.isAcceptableOrUnknown(
              data['reactor_account_id']!, _reactorAccountIdMeta));
    } else if (isInserting) {
      context.missing(_reactorAccountIdMeta);
    }
    if (data.containsKey('reaction')) {
      context.handle(_reactionMeta,
          reaction.isAcceptableOrUnknown(data['reaction']!, _reactionMeta));
    } else if (isInserting) {
      context.missing(_reactionMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {targetKey, reactorAccountId};
  @override
  LocalMessageReaction map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalMessageReaction(
      targetKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}target_key'])!,
      reactorAccountId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}reactor_account_id'])!,
      reaction: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reaction'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $LocalMessageReactionsTable createAlias(String alias) {
    return $LocalMessageReactionsTable(attachedDatabase, alias);
  }
}

class LocalMessageReaction extends DataClass
    implements Insertable<LocalMessageReaction> {
  final String targetKey;
  final String reactorAccountId;
  final String reaction;
  final int updatedAt;
  const LocalMessageReaction(
      {required this.targetKey,
      required this.reactorAccountId,
      required this.reaction,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['target_key'] = Variable<String>(targetKey);
    map['reactor_account_id'] = Variable<String>(reactorAccountId);
    map['reaction'] = Variable<String>(reaction);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  LocalMessageReactionsCompanion toCompanion(bool nullToAbsent) {
    return LocalMessageReactionsCompanion(
      targetKey: Value(targetKey),
      reactorAccountId: Value(reactorAccountId),
      reaction: Value(reaction),
      updatedAt: Value(updatedAt),
    );
  }

  factory LocalMessageReaction.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalMessageReaction(
      targetKey: serializer.fromJson<String>(json['targetKey']),
      reactorAccountId: serializer.fromJson<String>(json['reactorAccountId']),
      reaction: serializer.fromJson<String>(json['reaction']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'targetKey': serializer.toJson<String>(targetKey),
      'reactorAccountId': serializer.toJson<String>(reactorAccountId),
      'reaction': serializer.toJson<String>(reaction),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  LocalMessageReaction copyWith(
          {String? targetKey,
          String? reactorAccountId,
          String? reaction,
          int? updatedAt}) =>
      LocalMessageReaction(
        targetKey: targetKey ?? this.targetKey,
        reactorAccountId: reactorAccountId ?? this.reactorAccountId,
        reaction: reaction ?? this.reaction,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  LocalMessageReaction copyWithCompanion(LocalMessageReactionsCompanion data) {
    return LocalMessageReaction(
      targetKey: data.targetKey.present ? data.targetKey.value : this.targetKey,
      reactorAccountId: data.reactorAccountId.present
          ? data.reactorAccountId.value
          : this.reactorAccountId,
      reaction: data.reaction.present ? data.reaction.value : this.reaction,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessageReaction(')
          ..write('targetKey: $targetKey, ')
          ..write('reactorAccountId: $reactorAccountId, ')
          ..write('reaction: $reaction, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(targetKey, reactorAccountId, reaction, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalMessageReaction &&
          other.targetKey == this.targetKey &&
          other.reactorAccountId == this.reactorAccountId &&
          other.reaction == this.reaction &&
          other.updatedAt == this.updatedAt);
}

class LocalMessageReactionsCompanion
    extends UpdateCompanion<LocalMessageReaction> {
  final Value<String> targetKey;
  final Value<String> reactorAccountId;
  final Value<String> reaction;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const LocalMessageReactionsCompanion({
    this.targetKey = const Value.absent(),
    this.reactorAccountId = const Value.absent(),
    this.reaction = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMessageReactionsCompanion.insert({
    required String targetKey,
    required String reactorAccountId,
    required String reaction,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : targetKey = Value(targetKey),
        reactorAccountId = Value(reactorAccountId),
        reaction = Value(reaction),
        updatedAt = Value(updatedAt);
  static Insertable<LocalMessageReaction> custom({
    Expression<String>? targetKey,
    Expression<String>? reactorAccountId,
    Expression<String>? reaction,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (targetKey != null) 'target_key': targetKey,
      if (reactorAccountId != null) 'reactor_account_id': reactorAccountId,
      if (reaction != null) 'reaction': reaction,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMessageReactionsCompanion copyWith(
      {Value<String>? targetKey,
      Value<String>? reactorAccountId,
      Value<String>? reaction,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return LocalMessageReactionsCompanion(
      targetKey: targetKey ?? this.targetKey,
      reactorAccountId: reactorAccountId ?? this.reactorAccountId,
      reaction: reaction ?? this.reaction,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (targetKey.present) {
      map['target_key'] = Variable<String>(targetKey.value);
    }
    if (reactorAccountId.present) {
      map['reactor_account_id'] = Variable<String>(reactorAccountId.value);
    }
    if (reaction.present) {
      map['reaction'] = Variable<String>(reaction.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessageReactionsCompanion(')
          ..write('targetKey: $targetKey, ')
          ..write('reactorAccountId: $reactorAccountId, ')
          ..write('reaction: $reaction, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalDraftsTable extends LocalDrafts
    with TableInfo<$LocalDraftsTable, LocalDraft> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalDraftsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
      'body', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _replyToMeta =
      const VerificationMeta('replyTo');
  @override
  late final GeneratedColumn<String> replyTo = GeneratedColumn<String>(
      'reply_to', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [conversationId, body, replyTo, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_drafts';
  @override
  VerificationContext validateIntegrity(Insertable<LocalDraft> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
          _bodyMeta, body.isAcceptableOrUnknown(data['body']!, _bodyMeta));
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('reply_to')) {
      context.handle(_replyToMeta,
          replyTo.isAcceptableOrUnknown(data['reply_to']!, _replyToMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  LocalDraft map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalDraft(
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      body: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}body'])!,
      replyTo: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reply_to']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $LocalDraftsTable createAlias(String alias) {
    return $LocalDraftsTable(attachedDatabase, alias);
  }
}

class LocalDraft extends DataClass implements Insertable<LocalDraft> {
  final String conversationId;
  final String body;

  /// The local key of the message being replied to, if any.
  final String? replyTo;
  final int updatedAt;
  const LocalDraft(
      {required this.conversationId,
      required this.body,
      this.replyTo,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['body'] = Variable<String>(body);
    if (!nullToAbsent || replyTo != null) {
      map['reply_to'] = Variable<String>(replyTo);
    }
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  LocalDraftsCompanion toCompanion(bool nullToAbsent) {
    return LocalDraftsCompanion(
      conversationId: Value(conversationId),
      body: Value(body),
      replyTo: replyTo == null && nullToAbsent
          ? const Value.absent()
          : Value(replyTo),
      updatedAt: Value(updatedAt),
    );
  }

  factory LocalDraft.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalDraft(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      body: serializer.fromJson<String>(json['body']),
      replyTo: serializer.fromJson<String?>(json['replyTo']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'body': serializer.toJson<String>(body),
      'replyTo': serializer.toJson<String?>(replyTo),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  LocalDraft copyWith(
          {String? conversationId,
          String? body,
          Value<String?> replyTo = const Value.absent(),
          int? updatedAt}) =>
      LocalDraft(
        conversationId: conversationId ?? this.conversationId,
        body: body ?? this.body,
        replyTo: replyTo.present ? replyTo.value : this.replyTo,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  LocalDraft copyWithCompanion(LocalDraftsCompanion data) {
    return LocalDraft(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      body: data.body.present ? data.body.value : this.body,
      replyTo: data.replyTo.present ? data.replyTo.value : this.replyTo,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalDraft(')
          ..write('conversationId: $conversationId, ')
          ..write('body: $body, ')
          ..write('replyTo: $replyTo, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(conversationId, body, replyTo, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalDraft &&
          other.conversationId == this.conversationId &&
          other.body == this.body &&
          other.replyTo == this.replyTo &&
          other.updatedAt == this.updatedAt);
}

class LocalDraftsCompanion extends UpdateCompanion<LocalDraft> {
  final Value<String> conversationId;
  final Value<String> body;
  final Value<String?> replyTo;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const LocalDraftsCompanion({
    this.conversationId = const Value.absent(),
    this.body = const Value.absent(),
    this.replyTo = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalDraftsCompanion.insert({
    required String conversationId,
    required String body,
    this.replyTo = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : conversationId = Value(conversationId),
        body = Value(body),
        updatedAt = Value(updatedAt);
  static Insertable<LocalDraft> custom({
    Expression<String>? conversationId,
    Expression<String>? body,
    Expression<String>? replyTo,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (body != null) 'body': body,
      if (replyTo != null) 'reply_to': replyTo,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalDraftsCompanion copyWith(
      {Value<String>? conversationId,
      Value<String>? body,
      Value<String?>? replyTo,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return LocalDraftsCompanion(
      conversationId: conversationId ?? this.conversationId,
      body: body ?? this.body,
      replyTo: replyTo ?? this.replyTo,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (replyTo.present) {
      map['reply_to'] = Variable<String>(replyTo.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalDraftsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('body: $body, ')
          ..write('replyTo: $replyTo, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalConversationMutesTable extends LocalConversationMutes
    with TableInfo<$LocalConversationMutesTable, LocalConversationMute> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalConversationMutesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _mutedUntilMeta =
      const VerificationMeta('mutedUntil');
  @override
  late final GeneratedColumn<int> mutedUntil = GeneratedColumn<int>(
      'muted_until', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [conversationId, mutedUntil];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_conversation_mutes';
  @override
  VerificationContext validateIntegrity(
      Insertable<LocalConversationMute> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('muted_until')) {
      context.handle(
          _mutedUntilMeta,
          mutedUntil.isAcceptableOrUnknown(
              data['muted_until']!, _mutedUntilMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  LocalConversationMute map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalConversationMute(
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      mutedUntil: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}muted_until']),
    );
  }

  @override
  $LocalConversationMutesTable createAlias(String alias) {
    return $LocalConversationMutesTable(attachedDatabase, alias);
  }
}

class LocalConversationMute extends DataClass
    implements Insertable<LocalConversationMute> {
  final String conversationId;

  /// When the mute ends (epoch milliseconds); null mutes without an end.
  final int? mutedUntil;
  const LocalConversationMute({required this.conversationId, this.mutedUntil});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    if (!nullToAbsent || mutedUntil != null) {
      map['muted_until'] = Variable<int>(mutedUntil);
    }
    return map;
  }

  LocalConversationMutesCompanion toCompanion(bool nullToAbsent) {
    return LocalConversationMutesCompanion(
      conversationId: Value(conversationId),
      mutedUntil: mutedUntil == null && nullToAbsent
          ? const Value.absent()
          : Value(mutedUntil),
    );
  }

  factory LocalConversationMute.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalConversationMute(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      mutedUntil: serializer.fromJson<int?>(json['mutedUntil']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'mutedUntil': serializer.toJson<int?>(mutedUntil),
    };
  }

  LocalConversationMute copyWith(
          {String? conversationId,
          Value<int?> mutedUntil = const Value.absent()}) =>
      LocalConversationMute(
        conversationId: conversationId ?? this.conversationId,
        mutedUntil: mutedUntil.present ? mutedUntil.value : this.mutedUntil,
      );
  LocalConversationMute copyWithCompanion(
      LocalConversationMutesCompanion data) {
    return LocalConversationMute(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      mutedUntil:
          data.mutedUntil.present ? data.mutedUntil.value : this.mutedUntil,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalConversationMute(')
          ..write('conversationId: $conversationId, ')
          ..write('mutedUntil: $mutedUntil')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(conversationId, mutedUntil);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalConversationMute &&
          other.conversationId == this.conversationId &&
          other.mutedUntil == this.mutedUntil);
}

class LocalConversationMutesCompanion
    extends UpdateCompanion<LocalConversationMute> {
  final Value<String> conversationId;
  final Value<int?> mutedUntil;
  final Value<int> rowid;
  const LocalConversationMutesCompanion({
    this.conversationId = const Value.absent(),
    this.mutedUntil = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalConversationMutesCompanion.insert({
    required String conversationId,
    this.mutedUntil = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId);
  static Insertable<LocalConversationMute> custom({
    Expression<String>? conversationId,
    Expression<int>? mutedUntil,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (mutedUntil != null) 'muted_until': mutedUntil,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalConversationMutesCompanion copyWith(
      {Value<String>? conversationId,
      Value<int?>? mutedUntil,
      Value<int>? rowid}) {
    return LocalConversationMutesCompanion(
      conversationId: conversationId ?? this.conversationId,
      mutedUntil: mutedUntil ?? this.mutedUntil,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (mutedUntil.present) {
      map['muted_until'] = Variable<int>(mutedUntil.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalConversationMutesCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('mutedUntil: $mutedUntil, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalPinsTable extends LocalPins
    with TableInfo<$LocalPinsTable, LocalPin> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalPinsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _channelIdMeta =
      const VerificationMeta('channelId');
  @override
  late final GeneratedColumn<String> channelId = GeneratedColumn<String>(
      'channel_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _targetKeyMeta =
      const VerificationMeta('targetKey');
  @override
  late final GeneratedColumn<String> targetKey = GeneratedColumn<String>(
      'target_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pinnedByAccountIdMeta =
      const VerificationMeta('pinnedByAccountId');
  @override
  late final GeneratedColumn<String> pinnedByAccountId =
      GeneratedColumn<String>('pinned_by_account_id', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pinnedAtMeta =
      const VerificationMeta('pinnedAt');
  @override
  late final GeneratedColumn<int> pinnedAt = GeneratedColumn<int>(
      'pinned_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _appliedOrderMeta =
      const VerificationMeta('appliedOrder');
  @override
  late final GeneratedColumn<int> appliedOrder = GeneratedColumn<int>(
      'applied_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _expiresAtMeta =
      const VerificationMeta('expiresAt');
  @override
  late final GeneratedColumn<int> expiresAt = GeneratedColumn<int>(
      'expires_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        conversationId,
        channelId,
        targetKey,
        pinnedByAccountId,
        pinnedAt,
        appliedOrder,
        expiresAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_pins';
  @override
  VerificationContext validateIntegrity(Insertable<LocalPin> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('channel_id')) {
      context.handle(_channelIdMeta,
          channelId.isAcceptableOrUnknown(data['channel_id']!, _channelIdMeta));
    }
    if (data.containsKey('target_key')) {
      context.handle(_targetKeyMeta,
          targetKey.isAcceptableOrUnknown(data['target_key']!, _targetKeyMeta));
    } else if (isInserting) {
      context.missing(_targetKeyMeta);
    }
    if (data.containsKey('pinned_by_account_id')) {
      context.handle(
          _pinnedByAccountIdMeta,
          pinnedByAccountId.isAcceptableOrUnknown(
              data['pinned_by_account_id']!, _pinnedByAccountIdMeta));
    } else if (isInserting) {
      context.missing(_pinnedByAccountIdMeta);
    }
    if (data.containsKey('pinned_at')) {
      context.handle(_pinnedAtMeta,
          pinnedAt.isAcceptableOrUnknown(data['pinned_at']!, _pinnedAtMeta));
    } else if (isInserting) {
      context.missing(_pinnedAtMeta);
    }
    if (data.containsKey('applied_order')) {
      context.handle(
          _appliedOrderMeta,
          appliedOrder.isAcceptableOrUnknown(
              data['applied_order']!, _appliedOrderMeta));
    }
    if (data.containsKey('expires_at')) {
      context.handle(_expiresAtMeta,
          expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta));
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId, targetKey};
  @override
  LocalPin map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalPin(
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      channelId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}channel_id']),
      targetKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}target_key'])!,
      pinnedByAccountId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}pinned_by_account_id'])!,
      pinnedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}pinned_at'])!,
      appliedOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}applied_order'])!,
      expiresAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}expires_at'])!,
    );
  }

  @override
  $LocalPinsTable createAlias(String alias) {
    return $LocalPinsTable(attachedDatabase, alias);
  }
}

class LocalPin extends DataClass implements Insertable<LocalPin> {
  final String conversationId;
  final String? channelId;
  final String targetKey;
  final String pinnedByAccountId;
  final int pinnedAt;
  final int appliedOrder;
  final int expiresAt;
  const LocalPin(
      {required this.conversationId,
      this.channelId,
      required this.targetKey,
      required this.pinnedByAccountId,
      required this.pinnedAt,
      required this.appliedOrder,
      required this.expiresAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    if (!nullToAbsent || channelId != null) {
      map['channel_id'] = Variable<String>(channelId);
    }
    map['target_key'] = Variable<String>(targetKey);
    map['pinned_by_account_id'] = Variable<String>(pinnedByAccountId);
    map['pinned_at'] = Variable<int>(pinnedAt);
    map['applied_order'] = Variable<int>(appliedOrder);
    map['expires_at'] = Variable<int>(expiresAt);
    return map;
  }

  LocalPinsCompanion toCompanion(bool nullToAbsent) {
    return LocalPinsCompanion(
      conversationId: Value(conversationId),
      channelId: channelId == null && nullToAbsent
          ? const Value.absent()
          : Value(channelId),
      targetKey: Value(targetKey),
      pinnedByAccountId: Value(pinnedByAccountId),
      pinnedAt: Value(pinnedAt),
      appliedOrder: Value(appliedOrder),
      expiresAt: Value(expiresAt),
    );
  }

  factory LocalPin.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalPin(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      channelId: serializer.fromJson<String?>(json['channelId']),
      targetKey: serializer.fromJson<String>(json['targetKey']),
      pinnedByAccountId: serializer.fromJson<String>(json['pinnedByAccountId']),
      pinnedAt: serializer.fromJson<int>(json['pinnedAt']),
      appliedOrder: serializer.fromJson<int>(json['appliedOrder']),
      expiresAt: serializer.fromJson<int>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'channelId': serializer.toJson<String?>(channelId),
      'targetKey': serializer.toJson<String>(targetKey),
      'pinnedByAccountId': serializer.toJson<String>(pinnedByAccountId),
      'pinnedAt': serializer.toJson<int>(pinnedAt),
      'appliedOrder': serializer.toJson<int>(appliedOrder),
      'expiresAt': serializer.toJson<int>(expiresAt),
    };
  }

  LocalPin copyWith(
          {String? conversationId,
          Value<String?> channelId = const Value.absent(),
          String? targetKey,
          String? pinnedByAccountId,
          int? pinnedAt,
          int? appliedOrder,
          int? expiresAt}) =>
      LocalPin(
        conversationId: conversationId ?? this.conversationId,
        channelId: channelId.present ? channelId.value : this.channelId,
        targetKey: targetKey ?? this.targetKey,
        pinnedByAccountId: pinnedByAccountId ?? this.pinnedByAccountId,
        pinnedAt: pinnedAt ?? this.pinnedAt,
        appliedOrder: appliedOrder ?? this.appliedOrder,
        expiresAt: expiresAt ?? this.expiresAt,
      );
  LocalPin copyWithCompanion(LocalPinsCompanion data) {
    return LocalPin(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      channelId: data.channelId.present ? data.channelId.value : this.channelId,
      targetKey: data.targetKey.present ? data.targetKey.value : this.targetKey,
      pinnedByAccountId: data.pinnedByAccountId.present
          ? data.pinnedByAccountId.value
          : this.pinnedByAccountId,
      pinnedAt: data.pinnedAt.present ? data.pinnedAt.value : this.pinnedAt,
      appliedOrder: data.appliedOrder.present
          ? data.appliedOrder.value
          : this.appliedOrder,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalPin(')
          ..write('conversationId: $conversationId, ')
          ..write('channelId: $channelId, ')
          ..write('targetKey: $targetKey, ')
          ..write('pinnedByAccountId: $pinnedByAccountId, ')
          ..write('pinnedAt: $pinnedAt, ')
          ..write('appliedOrder: $appliedOrder, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(conversationId, channelId, targetKey,
      pinnedByAccountId, pinnedAt, appliedOrder, expiresAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalPin &&
          other.conversationId == this.conversationId &&
          other.channelId == this.channelId &&
          other.targetKey == this.targetKey &&
          other.pinnedByAccountId == this.pinnedByAccountId &&
          other.pinnedAt == this.pinnedAt &&
          other.appliedOrder == this.appliedOrder &&
          other.expiresAt == this.expiresAt);
}

class LocalPinsCompanion extends UpdateCompanion<LocalPin> {
  final Value<String> conversationId;
  final Value<String?> channelId;
  final Value<String> targetKey;
  final Value<String> pinnedByAccountId;
  final Value<int> pinnedAt;
  final Value<int> appliedOrder;
  final Value<int> expiresAt;
  final Value<int> rowid;
  const LocalPinsCompanion({
    this.conversationId = const Value.absent(),
    this.channelId = const Value.absent(),
    this.targetKey = const Value.absent(),
    this.pinnedByAccountId = const Value.absent(),
    this.pinnedAt = const Value.absent(),
    this.appliedOrder = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalPinsCompanion.insert({
    required String conversationId,
    this.channelId = const Value.absent(),
    required String targetKey,
    required String pinnedByAccountId,
    required int pinnedAt,
    this.appliedOrder = const Value.absent(),
    required int expiresAt,
    this.rowid = const Value.absent(),
  })  : conversationId = Value(conversationId),
        targetKey = Value(targetKey),
        pinnedByAccountId = Value(pinnedByAccountId),
        pinnedAt = Value(pinnedAt),
        expiresAt = Value(expiresAt);
  static Insertable<LocalPin> custom({
    Expression<String>? conversationId,
    Expression<String>? channelId,
    Expression<String>? targetKey,
    Expression<String>? pinnedByAccountId,
    Expression<int>? pinnedAt,
    Expression<int>? appliedOrder,
    Expression<int>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (channelId != null) 'channel_id': channelId,
      if (targetKey != null) 'target_key': targetKey,
      if (pinnedByAccountId != null) 'pinned_by_account_id': pinnedByAccountId,
      if (pinnedAt != null) 'pinned_at': pinnedAt,
      if (appliedOrder != null) 'applied_order': appliedOrder,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalPinsCompanion copyWith(
      {Value<String>? conversationId,
      Value<String?>? channelId,
      Value<String>? targetKey,
      Value<String>? pinnedByAccountId,
      Value<int>? pinnedAt,
      Value<int>? appliedOrder,
      Value<int>? expiresAt,
      Value<int>? rowid}) {
    return LocalPinsCompanion(
      conversationId: conversationId ?? this.conversationId,
      channelId: channelId ?? this.channelId,
      targetKey: targetKey ?? this.targetKey,
      pinnedByAccountId: pinnedByAccountId ?? this.pinnedByAccountId,
      pinnedAt: pinnedAt ?? this.pinnedAt,
      appliedOrder: appliedOrder ?? this.appliedOrder,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (channelId.present) {
      map['channel_id'] = Variable<String>(channelId.value);
    }
    if (targetKey.present) {
      map['target_key'] = Variable<String>(targetKey.value);
    }
    if (pinnedByAccountId.present) {
      map['pinned_by_account_id'] = Variable<String>(pinnedByAccountId.value);
    }
    if (pinnedAt.present) {
      map['pinned_at'] = Variable<int>(pinnedAt.value);
    }
    if (appliedOrder.present) {
      map['applied_order'] = Variable<int>(appliedOrder.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<int>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalPinsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('channelId: $channelId, ')
          ..write('targetKey: $targetKey, ')
          ..write('pinnedByAccountId: $pinnedByAccountId, ')
          ..write('pinnedAt: $pinnedAt, ')
          ..write('appliedOrder: $appliedOrder, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalPendingPinsTable extends LocalPendingPins
    with TableInfo<$LocalPendingPinsTable, LocalPendingPin> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalPendingPinsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _actionKeyMeta =
      const VerificationMeta('actionKey');
  @override
  late final GeneratedColumn<String> actionKey = GeneratedColumn<String>(
      'action_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _channelIdMeta =
      const VerificationMeta('channelId');
  @override
  late final GeneratedColumn<String> channelId = GeneratedColumn<String>(
      'channel_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _targetKeyMeta =
      const VerificationMeta('targetKey');
  @override
  late final GeneratedColumn<String> targetKey = GeneratedColumn<String>(
      'target_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _accountIdMeta =
      const VerificationMeta('accountId');
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
      'account_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  @override
  late final GeneratedColumn<bool> pinned = GeneratedColumn<bool>(
      'pinned', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("pinned" IN (0, 1))'));
  static const VerificationMeta _durationSecondsMeta =
      const VerificationMeta('durationSeconds');
  @override
  late final GeneratedColumn<int> durationSeconds = GeneratedColumn<int>(
      'duration_seconds', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        actionKey,
        conversationId,
        channelId,
        targetKey,
        accountId,
        pinned,
        durationSeconds
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_pending_pins';
  @override
  VerificationContext validateIntegrity(Insertable<LocalPendingPin> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('action_key')) {
      context.handle(_actionKeyMeta,
          actionKey.isAcceptableOrUnknown(data['action_key']!, _actionKeyMeta));
    } else if (isInserting) {
      context.missing(_actionKeyMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('channel_id')) {
      context.handle(_channelIdMeta,
          channelId.isAcceptableOrUnknown(data['channel_id']!, _channelIdMeta));
    }
    if (data.containsKey('target_key')) {
      context.handle(_targetKeyMeta,
          targetKey.isAcceptableOrUnknown(data['target_key']!, _targetKeyMeta));
    } else if (isInserting) {
      context.missing(_targetKeyMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(_accountIdMeta,
          accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta));
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('pinned')) {
      context.handle(_pinnedMeta,
          pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta));
    } else if (isInserting) {
      context.missing(_pinnedMeta);
    }
    if (data.containsKey('duration_seconds')) {
      context.handle(
          _durationSecondsMeta,
          durationSeconds.isAcceptableOrUnknown(
              data['duration_seconds']!, _durationSecondsMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {actionKey};
  @override
  LocalPendingPin map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalPendingPin(
      actionKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}action_key'])!,
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      channelId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}channel_id']),
      targetKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}target_key'])!,
      accountId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}account_id'])!,
      pinned: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}pinned'])!,
      durationSeconds: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}duration_seconds']),
    );
  }

  @override
  $LocalPendingPinsTable createAlias(String alias) {
    return $LocalPendingPinsTable(attachedDatabase, alias);
  }
}

class LocalPendingPin extends DataClass implements Insertable<LocalPendingPin> {
  final String actionKey;
  final String conversationId;
  final String? channelId;
  final String targetKey;
  final String accountId;
  final bool pinned;
  final int? durationSeconds;
  const LocalPendingPin(
      {required this.actionKey,
      required this.conversationId,
      this.channelId,
      required this.targetKey,
      required this.accountId,
      required this.pinned,
      this.durationSeconds});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['action_key'] = Variable<String>(actionKey);
    map['conversation_id'] = Variable<String>(conversationId);
    if (!nullToAbsent || channelId != null) {
      map['channel_id'] = Variable<String>(channelId);
    }
    map['target_key'] = Variable<String>(targetKey);
    map['account_id'] = Variable<String>(accountId);
    map['pinned'] = Variable<bool>(pinned);
    if (!nullToAbsent || durationSeconds != null) {
      map['duration_seconds'] = Variable<int>(durationSeconds);
    }
    return map;
  }

  LocalPendingPinsCompanion toCompanion(bool nullToAbsent) {
    return LocalPendingPinsCompanion(
      actionKey: Value(actionKey),
      conversationId: Value(conversationId),
      channelId: channelId == null && nullToAbsent
          ? const Value.absent()
          : Value(channelId),
      targetKey: Value(targetKey),
      accountId: Value(accountId),
      pinned: Value(pinned),
      durationSeconds: durationSeconds == null && nullToAbsent
          ? const Value.absent()
          : Value(durationSeconds),
    );
  }

  factory LocalPendingPin.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalPendingPin(
      actionKey: serializer.fromJson<String>(json['actionKey']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      channelId: serializer.fromJson<String?>(json['channelId']),
      targetKey: serializer.fromJson<String>(json['targetKey']),
      accountId: serializer.fromJson<String>(json['accountId']),
      pinned: serializer.fromJson<bool>(json['pinned']),
      durationSeconds: serializer.fromJson<int?>(json['durationSeconds']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'actionKey': serializer.toJson<String>(actionKey),
      'conversationId': serializer.toJson<String>(conversationId),
      'channelId': serializer.toJson<String?>(channelId),
      'targetKey': serializer.toJson<String>(targetKey),
      'accountId': serializer.toJson<String>(accountId),
      'pinned': serializer.toJson<bool>(pinned),
      'durationSeconds': serializer.toJson<int?>(durationSeconds),
    };
  }

  LocalPendingPin copyWith(
          {String? actionKey,
          String? conversationId,
          Value<String?> channelId = const Value.absent(),
          String? targetKey,
          String? accountId,
          bool? pinned,
          Value<int?> durationSeconds = const Value.absent()}) =>
      LocalPendingPin(
        actionKey: actionKey ?? this.actionKey,
        conversationId: conversationId ?? this.conversationId,
        channelId: channelId.present ? channelId.value : this.channelId,
        targetKey: targetKey ?? this.targetKey,
        accountId: accountId ?? this.accountId,
        pinned: pinned ?? this.pinned,
        durationSeconds: durationSeconds.present
            ? durationSeconds.value
            : this.durationSeconds,
      );
  LocalPendingPin copyWithCompanion(LocalPendingPinsCompanion data) {
    return LocalPendingPin(
      actionKey: data.actionKey.present ? data.actionKey.value : this.actionKey,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      channelId: data.channelId.present ? data.channelId.value : this.channelId,
      targetKey: data.targetKey.present ? data.targetKey.value : this.targetKey,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
      durationSeconds: data.durationSeconds.present
          ? data.durationSeconds.value
          : this.durationSeconds,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalPendingPin(')
          ..write('actionKey: $actionKey, ')
          ..write('conversationId: $conversationId, ')
          ..write('channelId: $channelId, ')
          ..write('targetKey: $targetKey, ')
          ..write('accountId: $accountId, ')
          ..write('pinned: $pinned, ')
          ..write('durationSeconds: $durationSeconds')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(actionKey, conversationId, channelId,
      targetKey, accountId, pinned, durationSeconds);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalPendingPin &&
          other.actionKey == this.actionKey &&
          other.conversationId == this.conversationId &&
          other.channelId == this.channelId &&
          other.targetKey == this.targetKey &&
          other.accountId == this.accountId &&
          other.pinned == this.pinned &&
          other.durationSeconds == this.durationSeconds);
}

class LocalPendingPinsCompanion extends UpdateCompanion<LocalPendingPin> {
  final Value<String> actionKey;
  final Value<String> conversationId;
  final Value<String?> channelId;
  final Value<String> targetKey;
  final Value<String> accountId;
  final Value<bool> pinned;
  final Value<int?> durationSeconds;
  final Value<int> rowid;
  const LocalPendingPinsCompanion({
    this.actionKey = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.channelId = const Value.absent(),
    this.targetKey = const Value.absent(),
    this.accountId = const Value.absent(),
    this.pinned = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalPendingPinsCompanion.insert({
    required String actionKey,
    required String conversationId,
    this.channelId = const Value.absent(),
    required String targetKey,
    required String accountId,
    required bool pinned,
    this.durationSeconds = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : actionKey = Value(actionKey),
        conversationId = Value(conversationId),
        targetKey = Value(targetKey),
        accountId = Value(accountId),
        pinned = Value(pinned);
  static Insertable<LocalPendingPin> custom({
    Expression<String>? actionKey,
    Expression<String>? conversationId,
    Expression<String>? channelId,
    Expression<String>? targetKey,
    Expression<String>? accountId,
    Expression<bool>? pinned,
    Expression<int>? durationSeconds,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (actionKey != null) 'action_key': actionKey,
      if (conversationId != null) 'conversation_id': conversationId,
      if (channelId != null) 'channel_id': channelId,
      if (targetKey != null) 'target_key': targetKey,
      if (accountId != null) 'account_id': accountId,
      if (pinned != null) 'pinned': pinned,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalPendingPinsCompanion copyWith(
      {Value<String>? actionKey,
      Value<String>? conversationId,
      Value<String?>? channelId,
      Value<String>? targetKey,
      Value<String>? accountId,
      Value<bool>? pinned,
      Value<int?>? durationSeconds,
      Value<int>? rowid}) {
    return LocalPendingPinsCompanion(
      actionKey: actionKey ?? this.actionKey,
      conversationId: conversationId ?? this.conversationId,
      channelId: channelId ?? this.channelId,
      targetKey: targetKey ?? this.targetKey,
      accountId: accountId ?? this.accountId,
      pinned: pinned ?? this.pinned,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (actionKey.present) {
      map['action_key'] = Variable<String>(actionKey.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (channelId.present) {
      map['channel_id'] = Variable<String>(channelId.value);
    }
    if (targetKey.present) {
      map['target_key'] = Variable<String>(targetKey.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (pinned.present) {
      map['pinned'] = Variable<bool>(pinned.value);
    }
    if (durationSeconds.present) {
      map['duration_seconds'] = Variable<int>(durationSeconds.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalPendingPinsCompanion(')
          ..write('actionKey: $actionKey, ')
          ..write('conversationId: $conversationId, ')
          ..write('channelId: $channelId, ')
          ..write('targetKey: $targetKey, ')
          ..write('accountId: $accountId, ')
          ..write('pinned: $pinned, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalStarredTable extends LocalStarred
    with TableInfo<$LocalStarredTable, LocalStarredData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalStarredTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _messageKeyMeta =
      const VerificationMeta('messageKey');
  @override
  late final GeneratedColumn<String> messageKey = GeneratedColumn<String>(
      'message_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _starredAtMeta =
      const VerificationMeta('starredAt');
  @override
  late final GeneratedColumn<int> starredAt = GeneratedColumn<int>(
      'starred_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [messageKey, starredAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_starred';
  @override
  VerificationContext validateIntegrity(Insertable<LocalStarredData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('message_key')) {
      context.handle(
          _messageKeyMeta,
          messageKey.isAcceptableOrUnknown(
              data['message_key']!, _messageKeyMeta));
    } else if (isInserting) {
      context.missing(_messageKeyMeta);
    }
    if (data.containsKey('starred_at')) {
      context.handle(_starredAtMeta,
          starredAt.isAcceptableOrUnknown(data['starred_at']!, _starredAtMeta));
    } else if (isInserting) {
      context.missing(_starredAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {messageKey};
  @override
  LocalStarredData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalStarredData(
      messageKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}message_key'])!,
      starredAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}starred_at'])!,
    );
  }

  @override
  $LocalStarredTable createAlias(String alias) {
    return $LocalStarredTable(attachedDatabase, alias);
  }
}

class LocalStarredData extends DataClass
    implements Insertable<LocalStarredData> {
  final String messageKey;
  final int starredAt;
  const LocalStarredData({required this.messageKey, required this.starredAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['message_key'] = Variable<String>(messageKey);
    map['starred_at'] = Variable<int>(starredAt);
    return map;
  }

  LocalStarredCompanion toCompanion(bool nullToAbsent) {
    return LocalStarredCompanion(
      messageKey: Value(messageKey),
      starredAt: Value(starredAt),
    );
  }

  factory LocalStarredData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalStarredData(
      messageKey: serializer.fromJson<String>(json['messageKey']),
      starredAt: serializer.fromJson<int>(json['starredAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'messageKey': serializer.toJson<String>(messageKey),
      'starredAt': serializer.toJson<int>(starredAt),
    };
  }

  LocalStarredData copyWith({String? messageKey, int? starredAt}) =>
      LocalStarredData(
        messageKey: messageKey ?? this.messageKey,
        starredAt: starredAt ?? this.starredAt,
      );
  LocalStarredData copyWithCompanion(LocalStarredCompanion data) {
    return LocalStarredData(
      messageKey:
          data.messageKey.present ? data.messageKey.value : this.messageKey,
      starredAt: data.starredAt.present ? data.starredAt.value : this.starredAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalStarredData(')
          ..write('messageKey: $messageKey, ')
          ..write('starredAt: $starredAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(messageKey, starredAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalStarredData &&
          other.messageKey == this.messageKey &&
          other.starredAt == this.starredAt);
}

class LocalStarredCompanion extends UpdateCompanion<LocalStarredData> {
  final Value<String> messageKey;
  final Value<int> starredAt;
  final Value<int> rowid;
  const LocalStarredCompanion({
    this.messageKey = const Value.absent(),
    this.starredAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalStarredCompanion.insert({
    required String messageKey,
    required int starredAt,
    this.rowid = const Value.absent(),
  })  : messageKey = Value(messageKey),
        starredAt = Value(starredAt);
  static Insertable<LocalStarredData> custom({
    Expression<String>? messageKey,
    Expression<int>? starredAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (messageKey != null) 'message_key': messageKey,
      if (starredAt != null) 'starred_at': starredAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalStarredCompanion copyWith(
      {Value<String>? messageKey, Value<int>? starredAt, Value<int>? rowid}) {
    return LocalStarredCompanion(
      messageKey: messageKey ?? this.messageKey,
      starredAt: starredAt ?? this.starredAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (messageKey.present) {
      map['message_key'] = Variable<String>(messageKey.value);
    }
    if (starredAt.present) {
      map['starred_at'] = Variable<int>(starredAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalStarredCompanion(')
          ..write('messageKey: $messageKey, ')
          ..write('starredAt: $starredAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalConversationPrefsTable extends LocalConversationPrefs
    with TableInfo<$LocalConversationPrefsTable, LocalConversationPref> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalConversationPrefsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _archivedAtMeta =
      const VerificationMeta('archivedAt');
  @override
  late final GeneratedColumn<int> archivedAt = GeneratedColumn<int>(
      'archived_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _pinnedAtMeta =
      const VerificationMeta('pinnedAt');
  @override
  late final GeneratedColumn<int> pinnedAt = GeneratedColumn<int>(
      'pinned_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [conversationId, archivedAt, pinnedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_conversation_prefs';
  @override
  VerificationContext validateIntegrity(
      Insertable<LocalConversationPref> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('archived_at')) {
      context.handle(
          _archivedAtMeta,
          archivedAt.isAcceptableOrUnknown(
              data['archived_at']!, _archivedAtMeta));
    }
    if (data.containsKey('pinned_at')) {
      context.handle(_pinnedAtMeta,
          pinnedAt.isAcceptableOrUnknown(data['pinned_at']!, _pinnedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  LocalConversationPref map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalConversationPref(
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      archivedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}archived_at']),
      pinnedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}pinned_at']),
    );
  }

  @override
  $LocalConversationPrefsTable createAlias(String alias) {
    return $LocalConversationPrefsTable(attachedDatabase, alias);
  }
}

class LocalConversationPref extends DataClass
    implements Insertable<LocalConversationPref> {
  final String conversationId;
  final int? archivedAt;
  final int? pinnedAt;
  const LocalConversationPref(
      {required this.conversationId, this.archivedAt, this.pinnedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    if (!nullToAbsent || archivedAt != null) {
      map['archived_at'] = Variable<int>(archivedAt);
    }
    if (!nullToAbsent || pinnedAt != null) {
      map['pinned_at'] = Variable<int>(pinnedAt);
    }
    return map;
  }

  LocalConversationPrefsCompanion toCompanion(bool nullToAbsent) {
    return LocalConversationPrefsCompanion(
      conversationId: Value(conversationId),
      archivedAt: archivedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(archivedAt),
      pinnedAt: pinnedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(pinnedAt),
    );
  }

  factory LocalConversationPref.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalConversationPref(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      archivedAt: serializer.fromJson<int?>(json['archivedAt']),
      pinnedAt: serializer.fromJson<int?>(json['pinnedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'archivedAt': serializer.toJson<int?>(archivedAt),
      'pinnedAt': serializer.toJson<int?>(pinnedAt),
    };
  }

  LocalConversationPref copyWith(
          {String? conversationId,
          Value<int?> archivedAt = const Value.absent(),
          Value<int?> pinnedAt = const Value.absent()}) =>
      LocalConversationPref(
        conversationId: conversationId ?? this.conversationId,
        archivedAt: archivedAt.present ? archivedAt.value : this.archivedAt,
        pinnedAt: pinnedAt.present ? pinnedAt.value : this.pinnedAt,
      );
  LocalConversationPref copyWithCompanion(
      LocalConversationPrefsCompanion data) {
    return LocalConversationPref(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      archivedAt:
          data.archivedAt.present ? data.archivedAt.value : this.archivedAt,
      pinnedAt: data.pinnedAt.present ? data.pinnedAt.value : this.pinnedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalConversationPref(')
          ..write('conversationId: $conversationId, ')
          ..write('archivedAt: $archivedAt, ')
          ..write('pinnedAt: $pinnedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(conversationId, archivedAt, pinnedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalConversationPref &&
          other.conversationId == this.conversationId &&
          other.archivedAt == this.archivedAt &&
          other.pinnedAt == this.pinnedAt);
}

class LocalConversationPrefsCompanion
    extends UpdateCompanion<LocalConversationPref> {
  final Value<String> conversationId;
  final Value<int?> archivedAt;
  final Value<int?> pinnedAt;
  final Value<int> rowid;
  const LocalConversationPrefsCompanion({
    this.conversationId = const Value.absent(),
    this.archivedAt = const Value.absent(),
    this.pinnedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalConversationPrefsCompanion.insert({
    required String conversationId,
    this.archivedAt = const Value.absent(),
    this.pinnedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId);
  static Insertable<LocalConversationPref> custom({
    Expression<String>? conversationId,
    Expression<int>? archivedAt,
    Expression<int>? pinnedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (archivedAt != null) 'archived_at': archivedAt,
      if (pinnedAt != null) 'pinned_at': pinnedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalConversationPrefsCompanion copyWith(
      {Value<String>? conversationId,
      Value<int?>? archivedAt,
      Value<int?>? pinnedAt,
      Value<int>? rowid}) {
    return LocalConversationPrefsCompanion(
      conversationId: conversationId ?? this.conversationId,
      archivedAt: archivedAt ?? this.archivedAt,
      pinnedAt: pinnedAt ?? this.pinnedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (archivedAt.present) {
      map['archived_at'] = Variable<int>(archivedAt.value);
    }
    if (pinnedAt.present) {
      map['pinned_at'] = Variable<int>(pinnedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalConversationPrefsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('archivedAt: $archivedAt, ')
          ..write('pinnedAt: $pinnedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$EncryptedLocalDatabase extends GeneratedDatabase {
  _$EncryptedLocalDatabase(QueryExecutor e) : super(e);
  $EncryptedLocalDatabaseManager get managers =>
      $EncryptedLocalDatabaseManager(this);
  late final $LocalAccountsTable localAccounts = $LocalAccountsTable(this);
  late final $LocalConversationsTable localConversations =
      $LocalConversationsTable(this);
  late final $LocalCiphertextEnvelopesTable localCiphertextEnvelopes =
      $LocalCiphertextEnvelopesTable(this);
  late final $LocalSyncStatesTable localSyncStates =
      $LocalSyncStatesTable(this);
  late final $LocalOutboxEntriesTable localOutboxEntries =
      $LocalOutboxEntriesTable(this);
  late final $LocalCryptoStatesTable localCryptoStates =
      $LocalCryptoStatesTable(this);
  late final $LocalCryptoRecordsTable localCryptoRecords =
      $LocalCryptoRecordsTable(this);
  late final $LocalMetadataTable localMetadata = $LocalMetadataTable(this);
  late final $LocalMlsTransitionsTable localMlsTransitions =
      $LocalMlsTransitionsTable(this);
  late final $LocalMlsOutboxEntriesTable localMlsOutboxEntries =
      $LocalMlsOutboxEntriesTable(this);
  late final $LocalPeerVerificationsTable localPeerVerifications =
      $LocalPeerVerificationsTable(this);
  late final $LocalMessagesTable localMessages = $LocalMessagesTable(this);
  late final $LocalMessageReactionsTable localMessageReactions =
      $LocalMessageReactionsTable(this);
  late final $LocalDraftsTable localDrafts = $LocalDraftsTable(this);
  late final $LocalConversationMutesTable localConversationMutes =
      $LocalConversationMutesTable(this);
  late final $LocalPinsTable localPins = $LocalPinsTable(this);
  late final $LocalPendingPinsTable localPendingPins =
      $LocalPendingPinsTable(this);
  late final $LocalStarredTable localStarred = $LocalStarredTable(this);
  late final $LocalConversationPrefsTable localConversationPrefs =
      $LocalConversationPrefsTable(this);
  late final Index localCiphertextEnvelopesConversationPosition = Index(
      'local_ciphertext_envelopes_conversation_position',
      'CREATE INDEX IF NOT EXISTS local_ciphertext_envelopes_conversation_position ON local_ciphertext_envelopes (conversation_id, position)');
  late final Index localCiphertextEnvelopesExpiresAt = Index(
      'local_ciphertext_envelopes_expires_at',
      'CREATE INDEX IF NOT EXISTS local_ciphertext_envelopes_expires_at ON local_ciphertext_envelopes (expires_at) WHERE expires_at IS NOT NULL');
  late final Index localMessagesExpiresAt = Index('local_messages_expires_at',
      'CREATE INDEX IF NOT EXISTS local_messages_expires_at ON local_messages (expires_at) WHERE expires_at IS NOT NULL');
  late final Index localMessagesSearchId = Index('local_messages_search_id',
      'CREATE UNIQUE INDEX IF NOT EXISTS local_messages_search_id ON local_messages (search_id)');
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        localAccounts,
        localConversations,
        localCiphertextEnvelopes,
        localSyncStates,
        localOutboxEntries,
        localCryptoStates,
        localCryptoRecords,
        localMetadata,
        localMlsTransitions,
        localMlsOutboxEntries,
        localPeerVerifications,
        localMessages,
        localMessageReactions,
        localDrafts,
        localConversationMutes,
        localPins,
        localPendingPins,
        localStarred,
        localConversationPrefs,
        localCiphertextEnvelopesConversationPosition,
        localCiphertextEnvelopesExpiresAt,
        localMessagesExpiresAt,
        localMessagesSearchId
      ];
}

typedef $$LocalAccountsTableCreateCompanionBuilder = LocalAccountsCompanion
    Function({
  Value<int> singleton,
  Value<String?> sessionJson,
});
typedef $$LocalAccountsTableUpdateCompanionBuilder = LocalAccountsCompanion
    Function({
  Value<int> singleton,
  Value<String?> sessionJson,
});

class $$LocalAccountsTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalAccountsTable> {
  $$LocalAccountsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get singleton => $composableBuilder(
      column: $table.singleton, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sessionJson => $composableBuilder(
      column: $table.sessionJson, builder: (column) => ColumnFilters(column));
}

class $$LocalAccountsTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalAccountsTable> {
  $$LocalAccountsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get singleton => $composableBuilder(
      column: $table.singleton, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sessionJson => $composableBuilder(
      column: $table.sessionJson, builder: (column) => ColumnOrderings(column));
}

class $$LocalAccountsTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalAccountsTable> {
  $$LocalAccountsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get singleton =>
      $composableBuilder(column: $table.singleton, builder: (column) => column);

  GeneratedColumn<String> get sessionJson => $composableBuilder(
      column: $table.sessionJson, builder: (column) => column);
}

class $$LocalAccountsTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalAccountsTable,
    LocalAccount,
    $$LocalAccountsTableFilterComposer,
    $$LocalAccountsTableOrderingComposer,
    $$LocalAccountsTableAnnotationComposer,
    $$LocalAccountsTableCreateCompanionBuilder,
    $$LocalAccountsTableUpdateCompanionBuilder,
    (
      LocalAccount,
      BaseReferences<_$EncryptedLocalDatabase, $LocalAccountsTable,
          LocalAccount>
    ),
    LocalAccount,
    PrefetchHooks Function()> {
  $$LocalAccountsTableTableManager(
      _$EncryptedLocalDatabase db, $LocalAccountsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalAccountsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalAccountsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalAccountsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> singleton = const Value.absent(),
            Value<String?> sessionJson = const Value.absent(),
          }) =>
              LocalAccountsCompanion(
            singleton: singleton,
            sessionJson: sessionJson,
          ),
          createCompanionCallback: ({
            Value<int> singleton = const Value.absent(),
            Value<String?> sessionJson = const Value.absent(),
          }) =>
              LocalAccountsCompanion.insert(
            singleton: singleton,
            sessionJson: sessionJson,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalAccountsTable, LocalAccount>(table),
                    BaseReferences<_$EncryptedLocalDatabase,
                        $LocalAccountsTable, LocalAccount>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalAccountsTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalAccountsTable,
    LocalAccount,
    $$LocalAccountsTableFilterComposer,
    $$LocalAccountsTableOrderingComposer,
    $$LocalAccountsTableAnnotationComposer,
    $$LocalAccountsTableCreateCompanionBuilder,
    $$LocalAccountsTableUpdateCompanionBuilder,
    (
      LocalAccount,
      BaseReferences<_$EncryptedLocalDatabase, $LocalAccountsTable,
          LocalAccount>
    ),
    LocalAccount,
    PrefetchHooks Function()>;
typedef $$LocalConversationsTableCreateCompanionBuilder
    = LocalConversationsCompanion Function({
  required String id,
  required int position,
  required String payloadJson,
  Value<int> rowid,
});
typedef $$LocalConversationsTableUpdateCompanionBuilder
    = LocalConversationsCompanion Function({
  Value<String> id,
  Value<int> position,
  Value<String> payloadJson,
  Value<int> rowid,
});

class $$LocalConversationsTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalConversationsTable> {
  $$LocalConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnFilters(column));
}

class $$LocalConversationsTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalConversationsTable> {
  $$LocalConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnOrderings(column));
}

class $$LocalConversationsTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalConversationsTable> {
  $$LocalConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => column);
}

class $$LocalConversationsTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalConversationsTable,
    LocalConversation,
    $$LocalConversationsTableFilterComposer,
    $$LocalConversationsTableOrderingComposer,
    $$LocalConversationsTableAnnotationComposer,
    $$LocalConversationsTableCreateCompanionBuilder,
    $$LocalConversationsTableUpdateCompanionBuilder,
    (
      LocalConversation,
      BaseReferences<_$EncryptedLocalDatabase, $LocalConversationsTable,
          LocalConversation>
    ),
    LocalConversation,
    PrefetchHooks Function()> {
  $$LocalConversationsTableTableManager(
      _$EncryptedLocalDatabase db, $LocalConversationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalConversationsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<String> payloadJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalConversationsCompanion(
            id: id,
            position: position,
            payloadJson: payloadJson,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required int position,
            required String payloadJson,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalConversationsCompanion.insert(
            id: id,
            position: position,
            payloadJson: payloadJson,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalConversationsTable, LocalConversation>(
                        table),
                    BaseReferences<
                        _$EncryptedLocalDatabase,
                        $LocalConversationsTable,
                        LocalConversation>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalConversationsTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalConversationsTable,
    LocalConversation,
    $$LocalConversationsTableFilterComposer,
    $$LocalConversationsTableOrderingComposer,
    $$LocalConversationsTableAnnotationComposer,
    $$LocalConversationsTableCreateCompanionBuilder,
    $$LocalConversationsTableUpdateCompanionBuilder,
    (
      LocalConversation,
      BaseReferences<_$EncryptedLocalDatabase, $LocalConversationsTable,
          LocalConversation>
    ),
    LocalConversation,
    PrefetchHooks Function()>;
typedef $$LocalCiphertextEnvelopesTableCreateCompanionBuilder
    = LocalCiphertextEnvelopesCompanion Function({
  required String id,
  required String conversationId,
  required int position,
  required String payloadJson,
  Value<int?> expiresAt,
  Value<int> rowid,
});
typedef $$LocalCiphertextEnvelopesTableUpdateCompanionBuilder
    = LocalCiphertextEnvelopesCompanion Function({
  Value<String> id,
  Value<String> conversationId,
  Value<int> position,
  Value<String> payloadJson,
  Value<int?> expiresAt,
  Value<int> rowid,
});

class $$LocalCiphertextEnvelopesTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalCiphertextEnvelopesTable> {
  $$LocalCiphertextEnvelopesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get expiresAt => $composableBuilder(
      column: $table.expiresAt, builder: (column) => ColumnFilters(column));
}

class $$LocalCiphertextEnvelopesTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalCiphertextEnvelopesTable> {
  $$LocalCiphertextEnvelopesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get expiresAt => $composableBuilder(
      column: $table.expiresAt, builder: (column) => ColumnOrderings(column));
}

class $$LocalCiphertextEnvelopesTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalCiphertextEnvelopesTable> {
  $$LocalCiphertextEnvelopesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => column);

  GeneratedColumn<int> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);
}

class $$LocalCiphertextEnvelopesTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalCiphertextEnvelopesTable,
    LocalCiphertextEnvelope,
    $$LocalCiphertextEnvelopesTableFilterComposer,
    $$LocalCiphertextEnvelopesTableOrderingComposer,
    $$LocalCiphertextEnvelopesTableAnnotationComposer,
    $$LocalCiphertextEnvelopesTableCreateCompanionBuilder,
    $$LocalCiphertextEnvelopesTableUpdateCompanionBuilder,
    (
      LocalCiphertextEnvelope,
      BaseReferences<_$EncryptedLocalDatabase, $LocalCiphertextEnvelopesTable,
          LocalCiphertextEnvelope>
    ),
    LocalCiphertextEnvelope,
    PrefetchHooks Function()> {
  $$LocalCiphertextEnvelopesTableTableManager(
      _$EncryptedLocalDatabase db, $LocalCiphertextEnvelopesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalCiphertextEnvelopesTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalCiphertextEnvelopesTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalCiphertextEnvelopesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<String> payloadJson = const Value.absent(),
            Value<int?> expiresAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalCiphertextEnvelopesCompanion(
            id: id,
            conversationId: conversationId,
            position: position,
            payloadJson: payloadJson,
            expiresAt: expiresAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String conversationId,
            required int position,
            required String payloadJson,
            Value<int?> expiresAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalCiphertextEnvelopesCompanion.insert(
            id: id,
            conversationId: conversationId,
            position: position,
            payloadJson: payloadJson,
            expiresAt: expiresAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalCiphertextEnvelopesTable,
                        LocalCiphertextEnvelope>(table),
                    BaseReferences<
                        _$EncryptedLocalDatabase,
                        $LocalCiphertextEnvelopesTable,
                        LocalCiphertextEnvelope>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalCiphertextEnvelopesTableProcessedTableManager
    = ProcessedTableManager<
        _$EncryptedLocalDatabase,
        $LocalCiphertextEnvelopesTable,
        LocalCiphertextEnvelope,
        $$LocalCiphertextEnvelopesTableFilterComposer,
        $$LocalCiphertextEnvelopesTableOrderingComposer,
        $$LocalCiphertextEnvelopesTableAnnotationComposer,
        $$LocalCiphertextEnvelopesTableCreateCompanionBuilder,
        $$LocalCiphertextEnvelopesTableUpdateCompanionBuilder,
        (
          LocalCiphertextEnvelope,
          BaseReferences<_$EncryptedLocalDatabase,
              $LocalCiphertextEnvelopesTable, LocalCiphertextEnvelope>
        ),
        LocalCiphertextEnvelope,
        PrefetchHooks Function()>;
typedef $$LocalSyncStatesTableCreateCompanionBuilder = LocalSyncStatesCompanion
    Function({
  Value<int> singleton,
  Value<int> cursor,
});
typedef $$LocalSyncStatesTableUpdateCompanionBuilder = LocalSyncStatesCompanion
    Function({
  Value<int> singleton,
  Value<int> cursor,
});

class $$LocalSyncStatesTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalSyncStatesTable> {
  $$LocalSyncStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get singleton => $composableBuilder(
      column: $table.singleton, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get cursor => $composableBuilder(
      column: $table.cursor, builder: (column) => ColumnFilters(column));
}

class $$LocalSyncStatesTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalSyncStatesTable> {
  $$LocalSyncStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get singleton => $composableBuilder(
      column: $table.singleton, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get cursor => $composableBuilder(
      column: $table.cursor, builder: (column) => ColumnOrderings(column));
}

class $$LocalSyncStatesTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalSyncStatesTable> {
  $$LocalSyncStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get singleton =>
      $composableBuilder(column: $table.singleton, builder: (column) => column);

  GeneratedColumn<int> get cursor =>
      $composableBuilder(column: $table.cursor, builder: (column) => column);
}

class $$LocalSyncStatesTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalSyncStatesTable,
    LocalSyncState,
    $$LocalSyncStatesTableFilterComposer,
    $$LocalSyncStatesTableOrderingComposer,
    $$LocalSyncStatesTableAnnotationComposer,
    $$LocalSyncStatesTableCreateCompanionBuilder,
    $$LocalSyncStatesTableUpdateCompanionBuilder,
    (
      LocalSyncState,
      BaseReferences<_$EncryptedLocalDatabase, $LocalSyncStatesTable,
          LocalSyncState>
    ),
    LocalSyncState,
    PrefetchHooks Function()> {
  $$LocalSyncStatesTableTableManager(
      _$EncryptedLocalDatabase db, $LocalSyncStatesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalSyncStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalSyncStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalSyncStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> singleton = const Value.absent(),
            Value<int> cursor = const Value.absent(),
          }) =>
              LocalSyncStatesCompanion(
            singleton: singleton,
            cursor: cursor,
          ),
          createCompanionCallback: ({
            Value<int> singleton = const Value.absent(),
            Value<int> cursor = const Value.absent(),
          }) =>
              LocalSyncStatesCompanion.insert(
            singleton: singleton,
            cursor: cursor,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalSyncStatesTable, LocalSyncState>(table),
                    BaseReferences<_$EncryptedLocalDatabase,
                        $LocalSyncStatesTable, LocalSyncState>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalSyncStatesTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalSyncStatesTable,
    LocalSyncState,
    $$LocalSyncStatesTableFilterComposer,
    $$LocalSyncStatesTableOrderingComposer,
    $$LocalSyncStatesTableAnnotationComposer,
    $$LocalSyncStatesTableCreateCompanionBuilder,
    $$LocalSyncStatesTableUpdateCompanionBuilder,
    (
      LocalSyncState,
      BaseReferences<_$EncryptedLocalDatabase, $LocalSyncStatesTable,
          LocalSyncState>
    ),
    LocalSyncState,
    PrefetchHooks Function()>;
typedef $$LocalOutboxEntriesTableCreateCompanionBuilder
    = LocalOutboxEntriesCompanion Function({
  required String idempotencyKey,
  required String conversationId,
  required int queuedAt,
  required String payloadJson,
  Value<int> attemptCount,
  Value<int?> nextAttemptAt,
  Value<String?> failureClass,
  Value<bool> terminal,
  Value<int> rowid,
});
typedef $$LocalOutboxEntriesTableUpdateCompanionBuilder
    = LocalOutboxEntriesCompanion Function({
  Value<String> idempotencyKey,
  Value<String> conversationId,
  Value<int> queuedAt,
  Value<String> payloadJson,
  Value<int> attemptCount,
  Value<int?> nextAttemptAt,
  Value<String?> failureClass,
  Value<bool> terminal,
  Value<int> rowid,
});

class $$LocalOutboxEntriesTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalOutboxEntriesTable> {
  $$LocalOutboxEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get idempotencyKey => $composableBuilder(
      column: $table.idempotencyKey,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get queuedAt => $composableBuilder(
      column: $table.queuedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get nextAttemptAt => $composableBuilder(
      column: $table.nextAttemptAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get failureClass => $composableBuilder(
      column: $table.failureClass, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get terminal => $composableBuilder(
      column: $table.terminal, builder: (column) => ColumnFilters(column));
}

class $$LocalOutboxEntriesTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalOutboxEntriesTable> {
  $$LocalOutboxEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get idempotencyKey => $composableBuilder(
      column: $table.idempotencyKey,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get queuedAt => $composableBuilder(
      column: $table.queuedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get nextAttemptAt => $composableBuilder(
      column: $table.nextAttemptAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get failureClass => $composableBuilder(
      column: $table.failureClass,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get terminal => $composableBuilder(
      column: $table.terminal, builder: (column) => ColumnOrderings(column));
}

class $$LocalOutboxEntriesTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalOutboxEntriesTable> {
  $$LocalOutboxEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get idempotencyKey => $composableBuilder(
      column: $table.idempotencyKey, builder: (column) => column);

  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<int> get queuedAt =>
      $composableBuilder(column: $table.queuedAt, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount, builder: (column) => column);

  GeneratedColumn<int> get nextAttemptAt => $composableBuilder(
      column: $table.nextAttemptAt, builder: (column) => column);

  GeneratedColumn<String> get failureClass => $composableBuilder(
      column: $table.failureClass, builder: (column) => column);

  GeneratedColumn<bool> get terminal =>
      $composableBuilder(column: $table.terminal, builder: (column) => column);
}

class $$LocalOutboxEntriesTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalOutboxEntriesTable,
    LocalOutboxEntry,
    $$LocalOutboxEntriesTableFilterComposer,
    $$LocalOutboxEntriesTableOrderingComposer,
    $$LocalOutboxEntriesTableAnnotationComposer,
    $$LocalOutboxEntriesTableCreateCompanionBuilder,
    $$LocalOutboxEntriesTableUpdateCompanionBuilder,
    (
      LocalOutboxEntry,
      BaseReferences<_$EncryptedLocalDatabase, $LocalOutboxEntriesTable,
          LocalOutboxEntry>
    ),
    LocalOutboxEntry,
    PrefetchHooks Function()> {
  $$LocalOutboxEntriesTableTableManager(
      _$EncryptedLocalDatabase db, $LocalOutboxEntriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalOutboxEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalOutboxEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalOutboxEntriesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> idempotencyKey = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<int> queuedAt = const Value.absent(),
            Value<String> payloadJson = const Value.absent(),
            Value<int> attemptCount = const Value.absent(),
            Value<int?> nextAttemptAt = const Value.absent(),
            Value<String?> failureClass = const Value.absent(),
            Value<bool> terminal = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalOutboxEntriesCompanion(
            idempotencyKey: idempotencyKey,
            conversationId: conversationId,
            queuedAt: queuedAt,
            payloadJson: payloadJson,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failureClass: failureClass,
            terminal: terminal,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String idempotencyKey,
            required String conversationId,
            required int queuedAt,
            required String payloadJson,
            Value<int> attemptCount = const Value.absent(),
            Value<int?> nextAttemptAt = const Value.absent(),
            Value<String?> failureClass = const Value.absent(),
            Value<bool> terminal = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalOutboxEntriesCompanion.insert(
            idempotencyKey: idempotencyKey,
            conversationId: conversationId,
            queuedAt: queuedAt,
            payloadJson: payloadJson,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failureClass: failureClass,
            terminal: terminal,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalOutboxEntriesTable, LocalOutboxEntry>(
                        table),
                    BaseReferences<
                        _$EncryptedLocalDatabase,
                        $LocalOutboxEntriesTable,
                        LocalOutboxEntry>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalOutboxEntriesTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalOutboxEntriesTable,
    LocalOutboxEntry,
    $$LocalOutboxEntriesTableFilterComposer,
    $$LocalOutboxEntriesTableOrderingComposer,
    $$LocalOutboxEntriesTableAnnotationComposer,
    $$LocalOutboxEntriesTableCreateCompanionBuilder,
    $$LocalOutboxEntriesTableUpdateCompanionBuilder,
    (
      LocalOutboxEntry,
      BaseReferences<_$EncryptedLocalDatabase, $LocalOutboxEntriesTable,
          LocalOutboxEntry>
    ),
    LocalOutboxEntry,
    PrefetchHooks Function()>;
typedef $$LocalCryptoStatesTableCreateCompanionBuilder
    = LocalCryptoStatesCompanion Function({
  Value<int> singleton,
  required int counter,
  required Uint8List stateKey,
  required Uint8List sealedState,
});
typedef $$LocalCryptoStatesTableUpdateCompanionBuilder
    = LocalCryptoStatesCompanion Function({
  Value<int> singleton,
  Value<int> counter,
  Value<Uint8List> stateKey,
  Value<Uint8List> sealedState,
});

class $$LocalCryptoStatesTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalCryptoStatesTable> {
  $$LocalCryptoStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get singleton => $composableBuilder(
      column: $table.singleton, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get counter => $composableBuilder(
      column: $table.counter, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get stateKey => $composableBuilder(
      column: $table.stateKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get sealedState => $composableBuilder(
      column: $table.sealedState, builder: (column) => ColumnFilters(column));
}

class $$LocalCryptoStatesTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalCryptoStatesTable> {
  $$LocalCryptoStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get singleton => $composableBuilder(
      column: $table.singleton, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get counter => $composableBuilder(
      column: $table.counter, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get stateKey => $composableBuilder(
      column: $table.stateKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get sealedState => $composableBuilder(
      column: $table.sealedState, builder: (column) => ColumnOrderings(column));
}

class $$LocalCryptoStatesTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalCryptoStatesTable> {
  $$LocalCryptoStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get singleton =>
      $composableBuilder(column: $table.singleton, builder: (column) => column);

  GeneratedColumn<int> get counter =>
      $composableBuilder(column: $table.counter, builder: (column) => column);

  GeneratedColumn<Uint8List> get stateKey =>
      $composableBuilder(column: $table.stateKey, builder: (column) => column);

  GeneratedColumn<Uint8List> get sealedState => $composableBuilder(
      column: $table.sealedState, builder: (column) => column);
}

class $$LocalCryptoStatesTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalCryptoStatesTable,
    LocalCryptoState,
    $$LocalCryptoStatesTableFilterComposer,
    $$LocalCryptoStatesTableOrderingComposer,
    $$LocalCryptoStatesTableAnnotationComposer,
    $$LocalCryptoStatesTableCreateCompanionBuilder,
    $$LocalCryptoStatesTableUpdateCompanionBuilder,
    (
      LocalCryptoState,
      BaseReferences<_$EncryptedLocalDatabase, $LocalCryptoStatesTable,
          LocalCryptoState>
    ),
    LocalCryptoState,
    PrefetchHooks Function()> {
  $$LocalCryptoStatesTableTableManager(
      _$EncryptedLocalDatabase db, $LocalCryptoStatesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalCryptoStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalCryptoStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalCryptoStatesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> singleton = const Value.absent(),
            Value<int> counter = const Value.absent(),
            Value<Uint8List> stateKey = const Value.absent(),
            Value<Uint8List> sealedState = const Value.absent(),
          }) =>
              LocalCryptoStatesCompanion(
            singleton: singleton,
            counter: counter,
            stateKey: stateKey,
            sealedState: sealedState,
          ),
          createCompanionCallback: ({
            Value<int> singleton = const Value.absent(),
            required int counter,
            required Uint8List stateKey,
            required Uint8List sealedState,
          }) =>
              LocalCryptoStatesCompanion.insert(
            singleton: singleton,
            counter: counter,
            stateKey: stateKey,
            sealedState: sealedState,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalCryptoStatesTable, LocalCryptoState>(
                        table),
                    BaseReferences<_$EncryptedLocalDatabase,
                        $LocalCryptoStatesTable, LocalCryptoState>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalCryptoStatesTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalCryptoStatesTable,
    LocalCryptoState,
    $$LocalCryptoStatesTableFilterComposer,
    $$LocalCryptoStatesTableOrderingComposer,
    $$LocalCryptoStatesTableAnnotationComposer,
    $$LocalCryptoStatesTableCreateCompanionBuilder,
    $$LocalCryptoStatesTableUpdateCompanionBuilder,
    (
      LocalCryptoState,
      BaseReferences<_$EncryptedLocalDatabase, $LocalCryptoStatesTable,
          LocalCryptoState>
    ),
    LocalCryptoState,
    PrefetchHooks Function()>;
typedef $$LocalCryptoRecordsTableCreateCompanionBuilder
    = LocalCryptoRecordsCompanion Function({
  required int kind,
  required Uint8List recordId,
  required int generation,
  required Uint8List sealed,
  Value<int> rowid,
});
typedef $$LocalCryptoRecordsTableUpdateCompanionBuilder
    = LocalCryptoRecordsCompanion Function({
  Value<int> kind,
  Value<Uint8List> recordId,
  Value<int> generation,
  Value<Uint8List> sealed,
  Value<int> rowid,
});

class $$LocalCryptoRecordsTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalCryptoRecordsTable> {
  $$LocalCryptoRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get recordId => $composableBuilder(
      column: $table.recordId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get generation => $composableBuilder(
      column: $table.generation, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get sealed => $composableBuilder(
      column: $table.sealed, builder: (column) => ColumnFilters(column));
}

class $$LocalCryptoRecordsTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalCryptoRecordsTable> {
  $$LocalCryptoRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get recordId => $composableBuilder(
      column: $table.recordId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get generation => $composableBuilder(
      column: $table.generation, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get sealed => $composableBuilder(
      column: $table.sealed, builder: (column) => ColumnOrderings(column));
}

class $$LocalCryptoRecordsTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalCryptoRecordsTable> {
  $$LocalCryptoRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<Uint8List> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);

  GeneratedColumn<int> get generation => $composableBuilder(
      column: $table.generation, builder: (column) => column);

  GeneratedColumn<Uint8List> get sealed =>
      $composableBuilder(column: $table.sealed, builder: (column) => column);
}

class $$LocalCryptoRecordsTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalCryptoRecordsTable,
    LocalCryptoRecord,
    $$LocalCryptoRecordsTableFilterComposer,
    $$LocalCryptoRecordsTableOrderingComposer,
    $$LocalCryptoRecordsTableAnnotationComposer,
    $$LocalCryptoRecordsTableCreateCompanionBuilder,
    $$LocalCryptoRecordsTableUpdateCompanionBuilder,
    (
      LocalCryptoRecord,
      BaseReferences<_$EncryptedLocalDatabase, $LocalCryptoRecordsTable,
          LocalCryptoRecord>
    ),
    LocalCryptoRecord,
    PrefetchHooks Function()> {
  $$LocalCryptoRecordsTableTableManager(
      _$EncryptedLocalDatabase db, $LocalCryptoRecordsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalCryptoRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalCryptoRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalCryptoRecordsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> kind = const Value.absent(),
            Value<Uint8List> recordId = const Value.absent(),
            Value<int> generation = const Value.absent(),
            Value<Uint8List> sealed = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalCryptoRecordsCompanion(
            kind: kind,
            recordId: recordId,
            generation: generation,
            sealed: sealed,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required int kind,
            required Uint8List recordId,
            required int generation,
            required Uint8List sealed,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalCryptoRecordsCompanion.insert(
            kind: kind,
            recordId: recordId,
            generation: generation,
            sealed: sealed,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalCryptoRecordsTable, LocalCryptoRecord>(
                        table),
                    BaseReferences<
                        _$EncryptedLocalDatabase,
                        $LocalCryptoRecordsTable,
                        LocalCryptoRecord>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalCryptoRecordsTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalCryptoRecordsTable,
    LocalCryptoRecord,
    $$LocalCryptoRecordsTableFilterComposer,
    $$LocalCryptoRecordsTableOrderingComposer,
    $$LocalCryptoRecordsTableAnnotationComposer,
    $$LocalCryptoRecordsTableCreateCompanionBuilder,
    $$LocalCryptoRecordsTableUpdateCompanionBuilder,
    (
      LocalCryptoRecord,
      BaseReferences<_$EncryptedLocalDatabase, $LocalCryptoRecordsTable,
          LocalCryptoRecord>
    ),
    LocalCryptoRecord,
    PrefetchHooks Function()>;
typedef $$LocalMetadataTableCreateCompanionBuilder = LocalMetadataCompanion
    Function({
  required String name,
  required String value,
  Value<int> rowid,
});
typedef $$LocalMetadataTableUpdateCompanionBuilder = LocalMetadataCompanion
    Function({
  Value<String> name,
  Value<String> value,
  Value<int> rowid,
});

class $$LocalMetadataTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMetadataTable> {
  $$LocalMetadataTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$LocalMetadataTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMetadataTable> {
  $$LocalMetadataTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$LocalMetadataTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMetadataTable> {
  $$LocalMetadataTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$LocalMetadataTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalMetadataTable,
    LocalMetadataData,
    $$LocalMetadataTableFilterComposer,
    $$LocalMetadataTableOrderingComposer,
    $$LocalMetadataTableAnnotationComposer,
    $$LocalMetadataTableCreateCompanionBuilder,
    $$LocalMetadataTableUpdateCompanionBuilder,
    (
      LocalMetadataData,
      BaseReferences<_$EncryptedLocalDatabase, $LocalMetadataTable,
          LocalMetadataData>
    ),
    LocalMetadataData,
    PrefetchHooks Function()> {
  $$LocalMetadataTableTableManager(
      _$EncryptedLocalDatabase db, $LocalMetadataTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMetadataTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMetadataTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalMetadataTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> name = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMetadataCompanion(
            name: name,
            value: value,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String name,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMetadataCompanion.insert(
            name: name,
            value: value,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalMetadataTable, LocalMetadataData>(table),
                    BaseReferences<_$EncryptedLocalDatabase,
                        $LocalMetadataTable, LocalMetadataData>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalMetadataTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalMetadataTable,
    LocalMetadataData,
    $$LocalMetadataTableFilterComposer,
    $$LocalMetadataTableOrderingComposer,
    $$LocalMetadataTableAnnotationComposer,
    $$LocalMetadataTableCreateCompanionBuilder,
    $$LocalMetadataTableUpdateCompanionBuilder,
    (
      LocalMetadataData,
      BaseReferences<_$EncryptedLocalDatabase, $LocalMetadataTable,
          LocalMetadataData>
    ),
    LocalMetadataData,
    PrefetchHooks Function()>;
typedef $$LocalMlsTransitionsTableCreateCompanionBuilder
    = LocalMlsTransitionsCompanion Function({
  required String messageId,
  required String conversationId,
  required int cursor,
  required int counter,
  Value<int> rowid,
});
typedef $$LocalMlsTransitionsTableUpdateCompanionBuilder
    = LocalMlsTransitionsCompanion Function({
  Value<String> messageId,
  Value<String> conversationId,
  Value<int> cursor,
  Value<int> counter,
  Value<int> rowid,
});

class $$LocalMlsTransitionsTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMlsTransitionsTable> {
  $$LocalMlsTransitionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get messageId => $composableBuilder(
      column: $table.messageId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get cursor => $composableBuilder(
      column: $table.cursor, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get counter => $composableBuilder(
      column: $table.counter, builder: (column) => ColumnFilters(column));
}

class $$LocalMlsTransitionsTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMlsTransitionsTable> {
  $$LocalMlsTransitionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get messageId => $composableBuilder(
      column: $table.messageId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get cursor => $composableBuilder(
      column: $table.cursor, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get counter => $composableBuilder(
      column: $table.counter, builder: (column) => ColumnOrderings(column));
}

class $$LocalMlsTransitionsTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMlsTransitionsTable> {
  $$LocalMlsTransitionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<int> get cursor =>
      $composableBuilder(column: $table.cursor, builder: (column) => column);

  GeneratedColumn<int> get counter =>
      $composableBuilder(column: $table.counter, builder: (column) => column);
}

class $$LocalMlsTransitionsTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalMlsTransitionsTable,
    LocalMlsTransition,
    $$LocalMlsTransitionsTableFilterComposer,
    $$LocalMlsTransitionsTableOrderingComposer,
    $$LocalMlsTransitionsTableAnnotationComposer,
    $$LocalMlsTransitionsTableCreateCompanionBuilder,
    $$LocalMlsTransitionsTableUpdateCompanionBuilder,
    (
      LocalMlsTransition,
      BaseReferences<_$EncryptedLocalDatabase, $LocalMlsTransitionsTable,
          LocalMlsTransition>
    ),
    LocalMlsTransition,
    PrefetchHooks Function()> {
  $$LocalMlsTransitionsTableTableManager(
      _$EncryptedLocalDatabase db, $LocalMlsTransitionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMlsTransitionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMlsTransitionsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalMlsTransitionsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> messageId = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<int> cursor = const Value.absent(),
            Value<int> counter = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMlsTransitionsCompanion(
            messageId: messageId,
            conversationId: conversationId,
            cursor: cursor,
            counter: counter,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String messageId,
            required String conversationId,
            required int cursor,
            required int counter,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMlsTransitionsCompanion.insert(
            messageId: messageId,
            conversationId: conversationId,
            cursor: cursor,
            counter: counter,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalMlsTransitionsTable, LocalMlsTransition>(
                        table),
                    BaseReferences<
                        _$EncryptedLocalDatabase,
                        $LocalMlsTransitionsTable,
                        LocalMlsTransition>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalMlsTransitionsTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalMlsTransitionsTable,
    LocalMlsTransition,
    $$LocalMlsTransitionsTableFilterComposer,
    $$LocalMlsTransitionsTableOrderingComposer,
    $$LocalMlsTransitionsTableAnnotationComposer,
    $$LocalMlsTransitionsTableCreateCompanionBuilder,
    $$LocalMlsTransitionsTableUpdateCompanionBuilder,
    (
      LocalMlsTransition,
      BaseReferences<_$EncryptedLocalDatabase, $LocalMlsTransitionsTable,
          LocalMlsTransition>
    ),
    LocalMlsTransition,
    PrefetchHooks Function()>;
typedef $$LocalMlsOutboxEntriesTableCreateCompanionBuilder
    = LocalMlsOutboxEntriesCompanion Function({
  required String idempotencyKey,
  required String conversationId,
  required String kind,
  Value<String?> recipientDeviceId,
  Value<String?> revocationDeviceId,
  required Uint8List payload,
  required int stateCounter,
  required int queuedAt,
  Value<int> attemptCount,
  Value<int?> nextAttemptAt,
  Value<String?> failureClass,
  Value<bool> terminal,
  Value<int> rowid,
});
typedef $$LocalMlsOutboxEntriesTableUpdateCompanionBuilder
    = LocalMlsOutboxEntriesCompanion Function({
  Value<String> idempotencyKey,
  Value<String> conversationId,
  Value<String> kind,
  Value<String?> recipientDeviceId,
  Value<String?> revocationDeviceId,
  Value<Uint8List> payload,
  Value<int> stateCounter,
  Value<int> queuedAt,
  Value<int> attemptCount,
  Value<int?> nextAttemptAt,
  Value<String?> failureClass,
  Value<bool> terminal,
  Value<int> rowid,
});

class $$LocalMlsOutboxEntriesTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMlsOutboxEntriesTable> {
  $$LocalMlsOutboxEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get idempotencyKey => $composableBuilder(
      column: $table.idempotencyKey,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get recipientDeviceId => $composableBuilder(
      column: $table.recipientDeviceId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get revocationDeviceId => $composableBuilder(
      column: $table.revocationDeviceId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get payload => $composableBuilder(
      column: $table.payload, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get stateCounter => $composableBuilder(
      column: $table.stateCounter, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get queuedAt => $composableBuilder(
      column: $table.queuedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get nextAttemptAt => $composableBuilder(
      column: $table.nextAttemptAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get failureClass => $composableBuilder(
      column: $table.failureClass, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get terminal => $composableBuilder(
      column: $table.terminal, builder: (column) => ColumnFilters(column));
}

class $$LocalMlsOutboxEntriesTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMlsOutboxEntriesTable> {
  $$LocalMlsOutboxEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get idempotencyKey => $composableBuilder(
      column: $table.idempotencyKey,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get recipientDeviceId => $composableBuilder(
      column: $table.recipientDeviceId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get revocationDeviceId => $composableBuilder(
      column: $table.revocationDeviceId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get payload => $composableBuilder(
      column: $table.payload, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get stateCounter => $composableBuilder(
      column: $table.stateCounter,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get queuedAt => $composableBuilder(
      column: $table.queuedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get nextAttemptAt => $composableBuilder(
      column: $table.nextAttemptAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get failureClass => $composableBuilder(
      column: $table.failureClass,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get terminal => $composableBuilder(
      column: $table.terminal, builder: (column) => ColumnOrderings(column));
}

class $$LocalMlsOutboxEntriesTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMlsOutboxEntriesTable> {
  $$LocalMlsOutboxEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get idempotencyKey => $composableBuilder(
      column: $table.idempotencyKey, builder: (column) => column);

  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get recipientDeviceId => $composableBuilder(
      column: $table.recipientDeviceId, builder: (column) => column);

  GeneratedColumn<String> get revocationDeviceId => $composableBuilder(
      column: $table.revocationDeviceId, builder: (column) => column);

  GeneratedColumn<Uint8List> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<int> get stateCounter => $composableBuilder(
      column: $table.stateCounter, builder: (column) => column);

  GeneratedColumn<int> get queuedAt =>
      $composableBuilder(column: $table.queuedAt, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount, builder: (column) => column);

  GeneratedColumn<int> get nextAttemptAt => $composableBuilder(
      column: $table.nextAttemptAt, builder: (column) => column);

  GeneratedColumn<String> get failureClass => $composableBuilder(
      column: $table.failureClass, builder: (column) => column);

  GeneratedColumn<bool> get terminal =>
      $composableBuilder(column: $table.terminal, builder: (column) => column);
}

class $$LocalMlsOutboxEntriesTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalMlsOutboxEntriesTable,
    LocalMlsOutboxEntry,
    $$LocalMlsOutboxEntriesTableFilterComposer,
    $$LocalMlsOutboxEntriesTableOrderingComposer,
    $$LocalMlsOutboxEntriesTableAnnotationComposer,
    $$LocalMlsOutboxEntriesTableCreateCompanionBuilder,
    $$LocalMlsOutboxEntriesTableUpdateCompanionBuilder,
    (
      LocalMlsOutboxEntry,
      BaseReferences<_$EncryptedLocalDatabase, $LocalMlsOutboxEntriesTable,
          LocalMlsOutboxEntry>
    ),
    LocalMlsOutboxEntry,
    PrefetchHooks Function()> {
  $$LocalMlsOutboxEntriesTableTableManager(
      _$EncryptedLocalDatabase db, $LocalMlsOutboxEntriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMlsOutboxEntriesTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMlsOutboxEntriesTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalMlsOutboxEntriesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> idempotencyKey = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<String> kind = const Value.absent(),
            Value<String?> recipientDeviceId = const Value.absent(),
            Value<String?> revocationDeviceId = const Value.absent(),
            Value<Uint8List> payload = const Value.absent(),
            Value<int> stateCounter = const Value.absent(),
            Value<int> queuedAt = const Value.absent(),
            Value<int> attemptCount = const Value.absent(),
            Value<int?> nextAttemptAt = const Value.absent(),
            Value<String?> failureClass = const Value.absent(),
            Value<bool> terminal = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMlsOutboxEntriesCompanion(
            idempotencyKey: idempotencyKey,
            conversationId: conversationId,
            kind: kind,
            recipientDeviceId: recipientDeviceId,
            revocationDeviceId: revocationDeviceId,
            payload: payload,
            stateCounter: stateCounter,
            queuedAt: queuedAt,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failureClass: failureClass,
            terminal: terminal,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String idempotencyKey,
            required String conversationId,
            required String kind,
            Value<String?> recipientDeviceId = const Value.absent(),
            Value<String?> revocationDeviceId = const Value.absent(),
            required Uint8List payload,
            required int stateCounter,
            required int queuedAt,
            Value<int> attemptCount = const Value.absent(),
            Value<int?> nextAttemptAt = const Value.absent(),
            Value<String?> failureClass = const Value.absent(),
            Value<bool> terminal = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMlsOutboxEntriesCompanion.insert(
            idempotencyKey: idempotencyKey,
            conversationId: conversationId,
            kind: kind,
            recipientDeviceId: recipientDeviceId,
            revocationDeviceId: revocationDeviceId,
            payload: payload,
            stateCounter: stateCounter,
            queuedAt: queuedAt,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            failureClass: failureClass,
            terminal: terminal,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalMlsOutboxEntriesTable,
                        LocalMlsOutboxEntry>(table),
                    BaseReferences<
                        _$EncryptedLocalDatabase,
                        $LocalMlsOutboxEntriesTable,
                        LocalMlsOutboxEntry>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalMlsOutboxEntriesTableProcessedTableManager
    = ProcessedTableManager<
        _$EncryptedLocalDatabase,
        $LocalMlsOutboxEntriesTable,
        LocalMlsOutboxEntry,
        $$LocalMlsOutboxEntriesTableFilterComposer,
        $$LocalMlsOutboxEntriesTableOrderingComposer,
        $$LocalMlsOutboxEntriesTableAnnotationComposer,
        $$LocalMlsOutboxEntriesTableCreateCompanionBuilder,
        $$LocalMlsOutboxEntriesTableUpdateCompanionBuilder,
        (
          LocalMlsOutboxEntry,
          BaseReferences<_$EncryptedLocalDatabase, $LocalMlsOutboxEntriesTable,
              LocalMlsOutboxEntry>
        ),
        LocalMlsOutboxEntry,
        PrefetchHooks Function()>;
typedef $$LocalPeerVerificationsTableCreateCompanionBuilder
    = LocalPeerVerificationsCompanion Function({
  required String conversationId,
  required String peerAccountId,
  required Uint8List transcriptHash,
  required int verifiedAt,
  Value<int> rowid,
});
typedef $$LocalPeerVerificationsTableUpdateCompanionBuilder
    = LocalPeerVerificationsCompanion Function({
  Value<String> conversationId,
  Value<String> peerAccountId,
  Value<Uint8List> transcriptHash,
  Value<int> verifiedAt,
  Value<int> rowid,
});

class $$LocalPeerVerificationsTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalPeerVerificationsTable> {
  $$LocalPeerVerificationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get peerAccountId => $composableBuilder(
      column: $table.peerAccountId, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get transcriptHash => $composableBuilder(
      column: $table.transcriptHash,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get verifiedAt => $composableBuilder(
      column: $table.verifiedAt, builder: (column) => ColumnFilters(column));
}

class $$LocalPeerVerificationsTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalPeerVerificationsTable> {
  $$LocalPeerVerificationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get peerAccountId => $composableBuilder(
      column: $table.peerAccountId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get transcriptHash => $composableBuilder(
      column: $table.transcriptHash,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get verifiedAt => $composableBuilder(
      column: $table.verifiedAt, builder: (column) => ColumnOrderings(column));
}

class $$LocalPeerVerificationsTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalPeerVerificationsTable> {
  $$LocalPeerVerificationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<String> get peerAccountId => $composableBuilder(
      column: $table.peerAccountId, builder: (column) => column);

  GeneratedColumn<Uint8List> get transcriptHash => $composableBuilder(
      column: $table.transcriptHash, builder: (column) => column);

  GeneratedColumn<int> get verifiedAt => $composableBuilder(
      column: $table.verifiedAt, builder: (column) => column);
}

class $$LocalPeerVerificationsTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalPeerVerificationsTable,
    LocalPeerVerification,
    $$LocalPeerVerificationsTableFilterComposer,
    $$LocalPeerVerificationsTableOrderingComposer,
    $$LocalPeerVerificationsTableAnnotationComposer,
    $$LocalPeerVerificationsTableCreateCompanionBuilder,
    $$LocalPeerVerificationsTableUpdateCompanionBuilder,
    (
      LocalPeerVerification,
      BaseReferences<_$EncryptedLocalDatabase, $LocalPeerVerificationsTable,
          LocalPeerVerification>
    ),
    LocalPeerVerification,
    PrefetchHooks Function()> {
  $$LocalPeerVerificationsTableTableManager(
      _$EncryptedLocalDatabase db, $LocalPeerVerificationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalPeerVerificationsTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalPeerVerificationsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalPeerVerificationsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> conversationId = const Value.absent(),
            Value<String> peerAccountId = const Value.absent(),
            Value<Uint8List> transcriptHash = const Value.absent(),
            Value<int> verifiedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalPeerVerificationsCompanion(
            conversationId: conversationId,
            peerAccountId: peerAccountId,
            transcriptHash: transcriptHash,
            verifiedAt: verifiedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String conversationId,
            required String peerAccountId,
            required Uint8List transcriptHash,
            required int verifiedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalPeerVerificationsCompanion.insert(
            conversationId: conversationId,
            peerAccountId: peerAccountId,
            transcriptHash: transcriptHash,
            verifiedAt: verifiedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalPeerVerificationsTable,
                        LocalPeerVerification>(table),
                    BaseReferences<
                        _$EncryptedLocalDatabase,
                        $LocalPeerVerificationsTable,
                        LocalPeerVerification>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalPeerVerificationsTableProcessedTableManager
    = ProcessedTableManager<
        _$EncryptedLocalDatabase,
        $LocalPeerVerificationsTable,
        LocalPeerVerification,
        $$LocalPeerVerificationsTableFilterComposer,
        $$LocalPeerVerificationsTableOrderingComposer,
        $$LocalPeerVerificationsTableAnnotationComposer,
        $$LocalPeerVerificationsTableCreateCompanionBuilder,
        $$LocalPeerVerificationsTableUpdateCompanionBuilder,
        (
          LocalPeerVerification,
          BaseReferences<_$EncryptedLocalDatabase, $LocalPeerVerificationsTable,
              LocalPeerVerification>
        ),
        LocalPeerVerification,
        PrefetchHooks Function()>;
typedef $$LocalMessagesTableCreateCompanionBuilder = LocalMessagesCompanion
    Function({
  required String key,
  Value<String?> serverMessageId,
  required String conversationId,
  required String senderAccountId,
  required String senderDeviceId,
  required String kind,
  Value<String?> body,
  Value<String?> replyTo,
  required int createdAt,
  Value<int?> editedAt,
  Value<int?> deletedAt,
  required String state,
  Value<int?> expiresAt,
  Value<int?> searchId,
  Value<int?> hiddenAt,
  Value<String?> formatJson,
  Value<int?> forwardHops,
  Value<String?> channelId,
  Value<bool?> senderHidden,
  Value<int> rowid,
});
typedef $$LocalMessagesTableUpdateCompanionBuilder = LocalMessagesCompanion
    Function({
  Value<String> key,
  Value<String?> serverMessageId,
  Value<String> conversationId,
  Value<String> senderAccountId,
  Value<String> senderDeviceId,
  Value<String> kind,
  Value<String?> body,
  Value<String?> replyTo,
  Value<int> createdAt,
  Value<int?> editedAt,
  Value<int?> deletedAt,
  Value<String> state,
  Value<int?> expiresAt,
  Value<int?> searchId,
  Value<int?> hiddenAt,
  Value<String?> formatJson,
  Value<int?> forwardHops,
  Value<String?> channelId,
  Value<bool?> senderHidden,
  Value<int> rowid,
});

class $$LocalMessagesTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get serverMessageId => $composableBuilder(
      column: $table.serverMessageId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get senderAccountId => $composableBuilder(
      column: $table.senderAccountId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get senderDeviceId => $composableBuilder(
      column: $table.senderDeviceId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get body => $composableBuilder(
      column: $table.body, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get replyTo => $composableBuilder(
      column: $table.replyTo, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get editedAt => $composableBuilder(
      column: $table.editedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get expiresAt => $composableBuilder(
      column: $table.expiresAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get searchId => $composableBuilder(
      column: $table.searchId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get hiddenAt => $composableBuilder(
      column: $table.hiddenAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get formatJson => $composableBuilder(
      column: $table.formatJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get forwardHops => $composableBuilder(
      column: $table.forwardHops, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get channelId => $composableBuilder(
      column: $table.channelId, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get senderHidden => $composableBuilder(
      column: $table.senderHidden, builder: (column) => ColumnFilters(column));
}

class $$LocalMessagesTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get serverMessageId => $composableBuilder(
      column: $table.serverMessageId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get senderAccountId => $composableBuilder(
      column: $table.senderAccountId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get senderDeviceId => $composableBuilder(
      column: $table.senderDeviceId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get body => $composableBuilder(
      column: $table.body, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get replyTo => $composableBuilder(
      column: $table.replyTo, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get editedAt => $composableBuilder(
      column: $table.editedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get expiresAt => $composableBuilder(
      column: $table.expiresAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get searchId => $composableBuilder(
      column: $table.searchId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get hiddenAt => $composableBuilder(
      column: $table.hiddenAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get formatJson => $composableBuilder(
      column: $table.formatJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get forwardHops => $composableBuilder(
      column: $table.forwardHops, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get channelId => $composableBuilder(
      column: $table.channelId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get senderHidden => $composableBuilder(
      column: $table.senderHidden,
      builder: (column) => ColumnOrderings(column));
}

class $$LocalMessagesTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get serverMessageId => $composableBuilder(
      column: $table.serverMessageId, builder: (column) => column);

  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<String> get senderAccountId => $composableBuilder(
      column: $table.senderAccountId, builder: (column) => column);

  GeneratedColumn<String> get senderDeviceId => $composableBuilder(
      column: $table.senderDeviceId, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get replyTo =>
      $composableBuilder(column: $table.replyTo, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get editedAt =>
      $composableBuilder(column: $table.editedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  GeneratedColumn<int> get searchId =>
      $composableBuilder(column: $table.searchId, builder: (column) => column);

  GeneratedColumn<int> get hiddenAt =>
      $composableBuilder(column: $table.hiddenAt, builder: (column) => column);

  GeneratedColumn<String> get formatJson => $composableBuilder(
      column: $table.formatJson, builder: (column) => column);

  GeneratedColumn<int> get forwardHops => $composableBuilder(
      column: $table.forwardHops, builder: (column) => column);

  GeneratedColumn<String> get channelId =>
      $composableBuilder(column: $table.channelId, builder: (column) => column);

  GeneratedColumn<bool> get senderHidden => $composableBuilder(
      column: $table.senderHidden, builder: (column) => column);
}

class $$LocalMessagesTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalMessagesTable,
    LocalMessage,
    $$LocalMessagesTableFilterComposer,
    $$LocalMessagesTableOrderingComposer,
    $$LocalMessagesTableAnnotationComposer,
    $$LocalMessagesTableCreateCompanionBuilder,
    $$LocalMessagesTableUpdateCompanionBuilder,
    (
      LocalMessage,
      BaseReferences<_$EncryptedLocalDatabase, $LocalMessagesTable,
          LocalMessage>
    ),
    LocalMessage,
    PrefetchHooks Function()> {
  $$LocalMessagesTableTableManager(
      _$EncryptedLocalDatabase db, $LocalMessagesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String?> serverMessageId = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<String> senderAccountId = const Value.absent(),
            Value<String> senderDeviceId = const Value.absent(),
            Value<String> kind = const Value.absent(),
            Value<String?> body = const Value.absent(),
            Value<String?> replyTo = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int?> editedAt = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            Value<String> state = const Value.absent(),
            Value<int?> expiresAt = const Value.absent(),
            Value<int?> searchId = const Value.absent(),
            Value<int?> hiddenAt = const Value.absent(),
            Value<String?> formatJson = const Value.absent(),
            Value<int?> forwardHops = const Value.absent(),
            Value<String?> channelId = const Value.absent(),
            Value<bool?> senderHidden = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMessagesCompanion(
            key: key,
            serverMessageId: serverMessageId,
            conversationId: conversationId,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            kind: kind,
            body: body,
            replyTo: replyTo,
            createdAt: createdAt,
            editedAt: editedAt,
            deletedAt: deletedAt,
            state: state,
            expiresAt: expiresAt,
            searchId: searchId,
            hiddenAt: hiddenAt,
            formatJson: formatJson,
            forwardHops: forwardHops,
            channelId: channelId,
            senderHidden: senderHidden,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            Value<String?> serverMessageId = const Value.absent(),
            required String conversationId,
            required String senderAccountId,
            required String senderDeviceId,
            required String kind,
            Value<String?> body = const Value.absent(),
            Value<String?> replyTo = const Value.absent(),
            required int createdAt,
            Value<int?> editedAt = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            required String state,
            Value<int?> expiresAt = const Value.absent(),
            Value<int?> searchId = const Value.absent(),
            Value<int?> hiddenAt = const Value.absent(),
            Value<String?> formatJson = const Value.absent(),
            Value<int?> forwardHops = const Value.absent(),
            Value<String?> channelId = const Value.absent(),
            Value<bool?> senderHidden = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMessagesCompanion.insert(
            key: key,
            serverMessageId: serverMessageId,
            conversationId: conversationId,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            kind: kind,
            body: body,
            replyTo: replyTo,
            createdAt: createdAt,
            editedAt: editedAt,
            deletedAt: deletedAt,
            state: state,
            expiresAt: expiresAt,
            searchId: searchId,
            hiddenAt: hiddenAt,
            formatJson: formatJson,
            forwardHops: forwardHops,
            channelId: channelId,
            senderHidden: senderHidden,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalMessagesTable, LocalMessage>(table),
                    BaseReferences<_$EncryptedLocalDatabase,
                        $LocalMessagesTable, LocalMessage>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalMessagesTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalMessagesTable,
    LocalMessage,
    $$LocalMessagesTableFilterComposer,
    $$LocalMessagesTableOrderingComposer,
    $$LocalMessagesTableAnnotationComposer,
    $$LocalMessagesTableCreateCompanionBuilder,
    $$LocalMessagesTableUpdateCompanionBuilder,
    (
      LocalMessage,
      BaseReferences<_$EncryptedLocalDatabase, $LocalMessagesTable,
          LocalMessage>
    ),
    LocalMessage,
    PrefetchHooks Function()>;
typedef $$LocalMessageReactionsTableCreateCompanionBuilder
    = LocalMessageReactionsCompanion Function({
  required String targetKey,
  required String reactorAccountId,
  required String reaction,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$LocalMessageReactionsTableUpdateCompanionBuilder
    = LocalMessageReactionsCompanion Function({
  Value<String> targetKey,
  Value<String> reactorAccountId,
  Value<String> reaction,
  Value<int> updatedAt,
  Value<int> rowid,
});

class $$LocalMessageReactionsTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMessageReactionsTable> {
  $$LocalMessageReactionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get targetKey => $composableBuilder(
      column: $table.targetKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get reactorAccountId => $composableBuilder(
      column: $table.reactorAccountId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get reaction => $composableBuilder(
      column: $table.reaction, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$LocalMessageReactionsTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMessageReactionsTable> {
  $$LocalMessageReactionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get targetKey => $composableBuilder(
      column: $table.targetKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get reactorAccountId => $composableBuilder(
      column: $table.reactorAccountId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get reaction => $composableBuilder(
      column: $table.reaction, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$LocalMessageReactionsTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalMessageReactionsTable> {
  $$LocalMessageReactionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get targetKey =>
      $composableBuilder(column: $table.targetKey, builder: (column) => column);

  GeneratedColumn<String> get reactorAccountId => $composableBuilder(
      column: $table.reactorAccountId, builder: (column) => column);

  GeneratedColumn<String> get reaction =>
      $composableBuilder(column: $table.reaction, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$LocalMessageReactionsTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalMessageReactionsTable,
    LocalMessageReaction,
    $$LocalMessageReactionsTableFilterComposer,
    $$LocalMessageReactionsTableOrderingComposer,
    $$LocalMessageReactionsTableAnnotationComposer,
    $$LocalMessageReactionsTableCreateCompanionBuilder,
    $$LocalMessageReactionsTableUpdateCompanionBuilder,
    (
      LocalMessageReaction,
      BaseReferences<_$EncryptedLocalDatabase, $LocalMessageReactionsTable,
          LocalMessageReaction>
    ),
    LocalMessageReaction,
    PrefetchHooks Function()> {
  $$LocalMessageReactionsTableTableManager(
      _$EncryptedLocalDatabase db, $LocalMessageReactionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMessageReactionsTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMessageReactionsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalMessageReactionsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> targetKey = const Value.absent(),
            Value<String> reactorAccountId = const Value.absent(),
            Value<String> reaction = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMessageReactionsCompanion(
            targetKey: targetKey,
            reactorAccountId: reactorAccountId,
            reaction: reaction,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String targetKey,
            required String reactorAccountId,
            required String reaction,
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMessageReactionsCompanion.insert(
            targetKey: targetKey,
            reactorAccountId: reactorAccountId,
            reaction: reaction,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalMessageReactionsTable,
                        LocalMessageReaction>(table),
                    BaseReferences<
                        _$EncryptedLocalDatabase,
                        $LocalMessageReactionsTable,
                        LocalMessageReaction>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalMessageReactionsTableProcessedTableManager
    = ProcessedTableManager<
        _$EncryptedLocalDatabase,
        $LocalMessageReactionsTable,
        LocalMessageReaction,
        $$LocalMessageReactionsTableFilterComposer,
        $$LocalMessageReactionsTableOrderingComposer,
        $$LocalMessageReactionsTableAnnotationComposer,
        $$LocalMessageReactionsTableCreateCompanionBuilder,
        $$LocalMessageReactionsTableUpdateCompanionBuilder,
        (
          LocalMessageReaction,
          BaseReferences<_$EncryptedLocalDatabase, $LocalMessageReactionsTable,
              LocalMessageReaction>
        ),
        LocalMessageReaction,
        PrefetchHooks Function()>;
typedef $$LocalDraftsTableCreateCompanionBuilder = LocalDraftsCompanion
    Function({
  required String conversationId,
  required String body,
  Value<String?> replyTo,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$LocalDraftsTableUpdateCompanionBuilder = LocalDraftsCompanion
    Function({
  Value<String> conversationId,
  Value<String> body,
  Value<String?> replyTo,
  Value<int> updatedAt,
  Value<int> rowid,
});

class $$LocalDraftsTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalDraftsTable> {
  $$LocalDraftsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get body => $composableBuilder(
      column: $table.body, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get replyTo => $composableBuilder(
      column: $table.replyTo, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$LocalDraftsTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalDraftsTable> {
  $$LocalDraftsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get body => $composableBuilder(
      column: $table.body, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get replyTo => $composableBuilder(
      column: $table.replyTo, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$LocalDraftsTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalDraftsTable> {
  $$LocalDraftsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get replyTo =>
      $composableBuilder(column: $table.replyTo, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$LocalDraftsTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalDraftsTable,
    LocalDraft,
    $$LocalDraftsTableFilterComposer,
    $$LocalDraftsTableOrderingComposer,
    $$LocalDraftsTableAnnotationComposer,
    $$LocalDraftsTableCreateCompanionBuilder,
    $$LocalDraftsTableUpdateCompanionBuilder,
    (
      LocalDraft,
      BaseReferences<_$EncryptedLocalDatabase, $LocalDraftsTable, LocalDraft>
    ),
    LocalDraft,
    PrefetchHooks Function()> {
  $$LocalDraftsTableTableManager(
      _$EncryptedLocalDatabase db, $LocalDraftsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalDraftsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalDraftsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalDraftsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> conversationId = const Value.absent(),
            Value<String> body = const Value.absent(),
            Value<String?> replyTo = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalDraftsCompanion(
            conversationId: conversationId,
            body: body,
            replyTo: replyTo,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String conversationId,
            required String body,
            Value<String?> replyTo = const Value.absent(),
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalDraftsCompanion.insert(
            conversationId: conversationId,
            body: body,
            replyTo: replyTo,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalDraftsTable, LocalDraft>(table),
                    BaseReferences<_$EncryptedLocalDatabase, $LocalDraftsTable,
                        LocalDraft>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalDraftsTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalDraftsTable,
    LocalDraft,
    $$LocalDraftsTableFilterComposer,
    $$LocalDraftsTableOrderingComposer,
    $$LocalDraftsTableAnnotationComposer,
    $$LocalDraftsTableCreateCompanionBuilder,
    $$LocalDraftsTableUpdateCompanionBuilder,
    (
      LocalDraft,
      BaseReferences<_$EncryptedLocalDatabase, $LocalDraftsTable, LocalDraft>
    ),
    LocalDraft,
    PrefetchHooks Function()>;
typedef $$LocalConversationMutesTableCreateCompanionBuilder
    = LocalConversationMutesCompanion Function({
  required String conversationId,
  Value<int?> mutedUntil,
  Value<int> rowid,
});
typedef $$LocalConversationMutesTableUpdateCompanionBuilder
    = LocalConversationMutesCompanion Function({
  Value<String> conversationId,
  Value<int?> mutedUntil,
  Value<int> rowid,
});

class $$LocalConversationMutesTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalConversationMutesTable> {
  $$LocalConversationMutesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get mutedUntil => $composableBuilder(
      column: $table.mutedUntil, builder: (column) => ColumnFilters(column));
}

class $$LocalConversationMutesTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalConversationMutesTable> {
  $$LocalConversationMutesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get mutedUntil => $composableBuilder(
      column: $table.mutedUntil, builder: (column) => ColumnOrderings(column));
}

class $$LocalConversationMutesTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalConversationMutesTable> {
  $$LocalConversationMutesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<int> get mutedUntil => $composableBuilder(
      column: $table.mutedUntil, builder: (column) => column);
}

class $$LocalConversationMutesTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalConversationMutesTable,
    LocalConversationMute,
    $$LocalConversationMutesTableFilterComposer,
    $$LocalConversationMutesTableOrderingComposer,
    $$LocalConversationMutesTableAnnotationComposer,
    $$LocalConversationMutesTableCreateCompanionBuilder,
    $$LocalConversationMutesTableUpdateCompanionBuilder,
    (
      LocalConversationMute,
      BaseReferences<_$EncryptedLocalDatabase, $LocalConversationMutesTable,
          LocalConversationMute>
    ),
    LocalConversationMute,
    PrefetchHooks Function()> {
  $$LocalConversationMutesTableTableManager(
      _$EncryptedLocalDatabase db, $LocalConversationMutesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalConversationMutesTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalConversationMutesTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalConversationMutesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> conversationId = const Value.absent(),
            Value<int?> mutedUntil = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalConversationMutesCompanion(
            conversationId: conversationId,
            mutedUntil: mutedUntil,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String conversationId,
            Value<int?> mutedUntil = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalConversationMutesCompanion.insert(
            conversationId: conversationId,
            mutedUntil: mutedUntil,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalConversationMutesTable,
                        LocalConversationMute>(table),
                    BaseReferences<
                        _$EncryptedLocalDatabase,
                        $LocalConversationMutesTable,
                        LocalConversationMute>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalConversationMutesTableProcessedTableManager
    = ProcessedTableManager<
        _$EncryptedLocalDatabase,
        $LocalConversationMutesTable,
        LocalConversationMute,
        $$LocalConversationMutesTableFilterComposer,
        $$LocalConversationMutesTableOrderingComposer,
        $$LocalConversationMutesTableAnnotationComposer,
        $$LocalConversationMutesTableCreateCompanionBuilder,
        $$LocalConversationMutesTableUpdateCompanionBuilder,
        (
          LocalConversationMute,
          BaseReferences<_$EncryptedLocalDatabase, $LocalConversationMutesTable,
              LocalConversationMute>
        ),
        LocalConversationMute,
        PrefetchHooks Function()>;
typedef $$LocalPinsTableCreateCompanionBuilder = LocalPinsCompanion Function({
  required String conversationId,
  Value<String?> channelId,
  required String targetKey,
  required String pinnedByAccountId,
  required int pinnedAt,
  Value<int> appliedOrder,
  required int expiresAt,
  Value<int> rowid,
});
typedef $$LocalPinsTableUpdateCompanionBuilder = LocalPinsCompanion Function({
  Value<String> conversationId,
  Value<String?> channelId,
  Value<String> targetKey,
  Value<String> pinnedByAccountId,
  Value<int> pinnedAt,
  Value<int> appliedOrder,
  Value<int> expiresAt,
  Value<int> rowid,
});

class $$LocalPinsTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalPinsTable> {
  $$LocalPinsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get channelId => $composableBuilder(
      column: $table.channelId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get targetKey => $composableBuilder(
      column: $table.targetKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get pinnedByAccountId => $composableBuilder(
      column: $table.pinnedByAccountId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get pinnedAt => $composableBuilder(
      column: $table.pinnedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get appliedOrder => $composableBuilder(
      column: $table.appliedOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get expiresAt => $composableBuilder(
      column: $table.expiresAt, builder: (column) => ColumnFilters(column));
}

class $$LocalPinsTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalPinsTable> {
  $$LocalPinsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get channelId => $composableBuilder(
      column: $table.channelId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get targetKey => $composableBuilder(
      column: $table.targetKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get pinnedByAccountId => $composableBuilder(
      column: $table.pinnedByAccountId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get pinnedAt => $composableBuilder(
      column: $table.pinnedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get appliedOrder => $composableBuilder(
      column: $table.appliedOrder,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get expiresAt => $composableBuilder(
      column: $table.expiresAt, builder: (column) => ColumnOrderings(column));
}

class $$LocalPinsTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalPinsTable> {
  $$LocalPinsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<String> get channelId =>
      $composableBuilder(column: $table.channelId, builder: (column) => column);

  GeneratedColumn<String> get targetKey =>
      $composableBuilder(column: $table.targetKey, builder: (column) => column);

  GeneratedColumn<String> get pinnedByAccountId => $composableBuilder(
      column: $table.pinnedByAccountId, builder: (column) => column);

  GeneratedColumn<int> get pinnedAt =>
      $composableBuilder(column: $table.pinnedAt, builder: (column) => column);

  GeneratedColumn<int> get appliedOrder => $composableBuilder(
      column: $table.appliedOrder, builder: (column) => column);

  GeneratedColumn<int> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);
}

class $$LocalPinsTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalPinsTable,
    LocalPin,
    $$LocalPinsTableFilterComposer,
    $$LocalPinsTableOrderingComposer,
    $$LocalPinsTableAnnotationComposer,
    $$LocalPinsTableCreateCompanionBuilder,
    $$LocalPinsTableUpdateCompanionBuilder,
    (
      LocalPin,
      BaseReferences<_$EncryptedLocalDatabase, $LocalPinsTable, LocalPin>
    ),
    LocalPin,
    PrefetchHooks Function()> {
  $$LocalPinsTableTableManager(
      _$EncryptedLocalDatabase db, $LocalPinsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalPinsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalPinsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalPinsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> conversationId = const Value.absent(),
            Value<String?> channelId = const Value.absent(),
            Value<String> targetKey = const Value.absent(),
            Value<String> pinnedByAccountId = const Value.absent(),
            Value<int> pinnedAt = const Value.absent(),
            Value<int> appliedOrder = const Value.absent(),
            Value<int> expiresAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalPinsCompanion(
            conversationId: conversationId,
            channelId: channelId,
            targetKey: targetKey,
            pinnedByAccountId: pinnedByAccountId,
            pinnedAt: pinnedAt,
            appliedOrder: appliedOrder,
            expiresAt: expiresAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String conversationId,
            Value<String?> channelId = const Value.absent(),
            required String targetKey,
            required String pinnedByAccountId,
            required int pinnedAt,
            Value<int> appliedOrder = const Value.absent(),
            required int expiresAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalPinsCompanion.insert(
            conversationId: conversationId,
            channelId: channelId,
            targetKey: targetKey,
            pinnedByAccountId: pinnedByAccountId,
            pinnedAt: pinnedAt,
            appliedOrder: appliedOrder,
            expiresAt: expiresAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalPinsTable, LocalPin>(table),
                    BaseReferences<_$EncryptedLocalDatabase, $LocalPinsTable,
                        LocalPin>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalPinsTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalPinsTable,
    LocalPin,
    $$LocalPinsTableFilterComposer,
    $$LocalPinsTableOrderingComposer,
    $$LocalPinsTableAnnotationComposer,
    $$LocalPinsTableCreateCompanionBuilder,
    $$LocalPinsTableUpdateCompanionBuilder,
    (
      LocalPin,
      BaseReferences<_$EncryptedLocalDatabase, $LocalPinsTable, LocalPin>
    ),
    LocalPin,
    PrefetchHooks Function()>;
typedef $$LocalPendingPinsTableCreateCompanionBuilder
    = LocalPendingPinsCompanion Function({
  required String actionKey,
  required String conversationId,
  Value<String?> channelId,
  required String targetKey,
  required String accountId,
  required bool pinned,
  Value<int?> durationSeconds,
  Value<int> rowid,
});
typedef $$LocalPendingPinsTableUpdateCompanionBuilder
    = LocalPendingPinsCompanion Function({
  Value<String> actionKey,
  Value<String> conversationId,
  Value<String?> channelId,
  Value<String> targetKey,
  Value<String> accountId,
  Value<bool> pinned,
  Value<int?> durationSeconds,
  Value<int> rowid,
});

class $$LocalPendingPinsTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalPendingPinsTable> {
  $$LocalPendingPinsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get actionKey => $composableBuilder(
      column: $table.actionKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get channelId => $composableBuilder(
      column: $table.channelId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get targetKey => $composableBuilder(
      column: $table.targetKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get accountId => $composableBuilder(
      column: $table.accountId, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get pinned => $composableBuilder(
      column: $table.pinned, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durationSeconds => $composableBuilder(
      column: $table.durationSeconds,
      builder: (column) => ColumnFilters(column));
}

class $$LocalPendingPinsTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalPendingPinsTable> {
  $$LocalPendingPinsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get actionKey => $composableBuilder(
      column: $table.actionKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get channelId => $composableBuilder(
      column: $table.channelId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get targetKey => $composableBuilder(
      column: $table.targetKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get accountId => $composableBuilder(
      column: $table.accountId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get pinned => $composableBuilder(
      column: $table.pinned, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durationSeconds => $composableBuilder(
      column: $table.durationSeconds,
      builder: (column) => ColumnOrderings(column));
}

class $$LocalPendingPinsTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalPendingPinsTable> {
  $$LocalPendingPinsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get actionKey =>
      $composableBuilder(column: $table.actionKey, builder: (column) => column);

  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<String> get channelId =>
      $composableBuilder(column: $table.channelId, builder: (column) => column);

  GeneratedColumn<String> get targetKey =>
      $composableBuilder(column: $table.targetKey, builder: (column) => column);

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<bool> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => column);

  GeneratedColumn<int> get durationSeconds => $composableBuilder(
      column: $table.durationSeconds, builder: (column) => column);
}

class $$LocalPendingPinsTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalPendingPinsTable,
    LocalPendingPin,
    $$LocalPendingPinsTableFilterComposer,
    $$LocalPendingPinsTableOrderingComposer,
    $$LocalPendingPinsTableAnnotationComposer,
    $$LocalPendingPinsTableCreateCompanionBuilder,
    $$LocalPendingPinsTableUpdateCompanionBuilder,
    (
      LocalPendingPin,
      BaseReferences<_$EncryptedLocalDatabase, $LocalPendingPinsTable,
          LocalPendingPin>
    ),
    LocalPendingPin,
    PrefetchHooks Function()> {
  $$LocalPendingPinsTableTableManager(
      _$EncryptedLocalDatabase db, $LocalPendingPinsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalPendingPinsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalPendingPinsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalPendingPinsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> actionKey = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<String?> channelId = const Value.absent(),
            Value<String> targetKey = const Value.absent(),
            Value<String> accountId = const Value.absent(),
            Value<bool> pinned = const Value.absent(),
            Value<int?> durationSeconds = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalPendingPinsCompanion(
            actionKey: actionKey,
            conversationId: conversationId,
            channelId: channelId,
            targetKey: targetKey,
            accountId: accountId,
            pinned: pinned,
            durationSeconds: durationSeconds,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String actionKey,
            required String conversationId,
            Value<String?> channelId = const Value.absent(),
            required String targetKey,
            required String accountId,
            required bool pinned,
            Value<int?> durationSeconds = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalPendingPinsCompanion.insert(
            actionKey: actionKey,
            conversationId: conversationId,
            channelId: channelId,
            targetKey: targetKey,
            accountId: accountId,
            pinned: pinned,
            durationSeconds: durationSeconds,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalPendingPinsTable, LocalPendingPin>(table),
                    BaseReferences<_$EncryptedLocalDatabase,
                        $LocalPendingPinsTable, LocalPendingPin>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalPendingPinsTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalPendingPinsTable,
    LocalPendingPin,
    $$LocalPendingPinsTableFilterComposer,
    $$LocalPendingPinsTableOrderingComposer,
    $$LocalPendingPinsTableAnnotationComposer,
    $$LocalPendingPinsTableCreateCompanionBuilder,
    $$LocalPendingPinsTableUpdateCompanionBuilder,
    (
      LocalPendingPin,
      BaseReferences<_$EncryptedLocalDatabase, $LocalPendingPinsTable,
          LocalPendingPin>
    ),
    LocalPendingPin,
    PrefetchHooks Function()>;
typedef $$LocalStarredTableCreateCompanionBuilder = LocalStarredCompanion
    Function({
  required String messageKey,
  required int starredAt,
  Value<int> rowid,
});
typedef $$LocalStarredTableUpdateCompanionBuilder = LocalStarredCompanion
    Function({
  Value<String> messageKey,
  Value<int> starredAt,
  Value<int> rowid,
});

class $$LocalStarredTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalStarredTable> {
  $$LocalStarredTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get messageKey => $composableBuilder(
      column: $table.messageKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get starredAt => $composableBuilder(
      column: $table.starredAt, builder: (column) => ColumnFilters(column));
}

class $$LocalStarredTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalStarredTable> {
  $$LocalStarredTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get messageKey => $composableBuilder(
      column: $table.messageKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get starredAt => $composableBuilder(
      column: $table.starredAt, builder: (column) => ColumnOrderings(column));
}

class $$LocalStarredTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalStarredTable> {
  $$LocalStarredTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get messageKey => $composableBuilder(
      column: $table.messageKey, builder: (column) => column);

  GeneratedColumn<int> get starredAt =>
      $composableBuilder(column: $table.starredAt, builder: (column) => column);
}

class $$LocalStarredTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalStarredTable,
    LocalStarredData,
    $$LocalStarredTableFilterComposer,
    $$LocalStarredTableOrderingComposer,
    $$LocalStarredTableAnnotationComposer,
    $$LocalStarredTableCreateCompanionBuilder,
    $$LocalStarredTableUpdateCompanionBuilder,
    (
      LocalStarredData,
      BaseReferences<_$EncryptedLocalDatabase, $LocalStarredTable,
          LocalStarredData>
    ),
    LocalStarredData,
    PrefetchHooks Function()> {
  $$LocalStarredTableTableManager(
      _$EncryptedLocalDatabase db, $LocalStarredTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalStarredTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalStarredTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalStarredTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> messageKey = const Value.absent(),
            Value<int> starredAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalStarredCompanion(
            messageKey: messageKey,
            starredAt: starredAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String messageKey,
            required int starredAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalStarredCompanion.insert(
            messageKey: messageKey,
            starredAt: starredAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalStarredTable, LocalStarredData>(table),
                    BaseReferences<_$EncryptedLocalDatabase, $LocalStarredTable,
                        LocalStarredData>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalStarredTableProcessedTableManager = ProcessedTableManager<
    _$EncryptedLocalDatabase,
    $LocalStarredTable,
    LocalStarredData,
    $$LocalStarredTableFilterComposer,
    $$LocalStarredTableOrderingComposer,
    $$LocalStarredTableAnnotationComposer,
    $$LocalStarredTableCreateCompanionBuilder,
    $$LocalStarredTableUpdateCompanionBuilder,
    (
      LocalStarredData,
      BaseReferences<_$EncryptedLocalDatabase, $LocalStarredTable,
          LocalStarredData>
    ),
    LocalStarredData,
    PrefetchHooks Function()>;
typedef $$LocalConversationPrefsTableCreateCompanionBuilder
    = LocalConversationPrefsCompanion Function({
  required String conversationId,
  Value<int?> archivedAt,
  Value<int?> pinnedAt,
  Value<int> rowid,
});
typedef $$LocalConversationPrefsTableUpdateCompanionBuilder
    = LocalConversationPrefsCompanion Function({
  Value<String> conversationId,
  Value<int?> archivedAt,
  Value<int?> pinnedAt,
  Value<int> rowid,
});

class $$LocalConversationPrefsTableFilterComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalConversationPrefsTable> {
  $$LocalConversationPrefsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get archivedAt => $composableBuilder(
      column: $table.archivedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get pinnedAt => $composableBuilder(
      column: $table.pinnedAt, builder: (column) => ColumnFilters(column));
}

class $$LocalConversationPrefsTableOrderingComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalConversationPrefsTable> {
  $$LocalConversationPrefsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get archivedAt => $composableBuilder(
      column: $table.archivedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get pinnedAt => $composableBuilder(
      column: $table.pinnedAt, builder: (column) => ColumnOrderings(column));
}

class $$LocalConversationPrefsTableAnnotationComposer
    extends Composer<_$EncryptedLocalDatabase, $LocalConversationPrefsTable> {
  $$LocalConversationPrefsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<int> get archivedAt => $composableBuilder(
      column: $table.archivedAt, builder: (column) => column);

  GeneratedColumn<int> get pinnedAt =>
      $composableBuilder(column: $table.pinnedAt, builder: (column) => column);
}

class $$LocalConversationPrefsTableTableManager extends RootTableManager<
    _$EncryptedLocalDatabase,
    $LocalConversationPrefsTable,
    LocalConversationPref,
    $$LocalConversationPrefsTableFilterComposer,
    $$LocalConversationPrefsTableOrderingComposer,
    $$LocalConversationPrefsTableAnnotationComposer,
    $$LocalConversationPrefsTableCreateCompanionBuilder,
    $$LocalConversationPrefsTableUpdateCompanionBuilder,
    (
      LocalConversationPref,
      BaseReferences<_$EncryptedLocalDatabase, $LocalConversationPrefsTable,
          LocalConversationPref>
    ),
    LocalConversationPref,
    PrefetchHooks Function()> {
  $$LocalConversationPrefsTableTableManager(
      _$EncryptedLocalDatabase db, $LocalConversationPrefsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalConversationPrefsTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalConversationPrefsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalConversationPrefsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> conversationId = const Value.absent(),
            Value<int?> archivedAt = const Value.absent(),
            Value<int?> pinnedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalConversationPrefsCompanion(
            conversationId: conversationId,
            archivedAt: archivedAt,
            pinnedAt: pinnedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String conversationId,
            Value<int?> archivedAt = const Value.absent(),
            Value<int?> pinnedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalConversationPrefsCompanion.insert(
            conversationId: conversationId,
            archivedAt: archivedAt,
            pinnedAt: pinnedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalConversationPrefsTable,
                        LocalConversationPref>(table),
                    BaseReferences<
                        _$EncryptedLocalDatabase,
                        $LocalConversationPrefsTable,
                        LocalConversationPref>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalConversationPrefsTableProcessedTableManager
    = ProcessedTableManager<
        _$EncryptedLocalDatabase,
        $LocalConversationPrefsTable,
        LocalConversationPref,
        $$LocalConversationPrefsTableFilterComposer,
        $$LocalConversationPrefsTableOrderingComposer,
        $$LocalConversationPrefsTableAnnotationComposer,
        $$LocalConversationPrefsTableCreateCompanionBuilder,
        $$LocalConversationPrefsTableUpdateCompanionBuilder,
        (
          LocalConversationPref,
          BaseReferences<_$EncryptedLocalDatabase, $LocalConversationPrefsTable,
              LocalConversationPref>
        ),
        LocalConversationPref,
        PrefetchHooks Function()>;

class $EncryptedLocalDatabaseManager {
  final _$EncryptedLocalDatabase _db;
  $EncryptedLocalDatabaseManager(this._db);
  $$LocalAccountsTableTableManager get localAccounts =>
      $$LocalAccountsTableTableManager(_db, _db.localAccounts);
  $$LocalConversationsTableTableManager get localConversations =>
      $$LocalConversationsTableTableManager(_db, _db.localConversations);
  $$LocalCiphertextEnvelopesTableTableManager get localCiphertextEnvelopes =>
      $$LocalCiphertextEnvelopesTableTableManager(
          _db, _db.localCiphertextEnvelopes);
  $$LocalSyncStatesTableTableManager get localSyncStates =>
      $$LocalSyncStatesTableTableManager(_db, _db.localSyncStates);
  $$LocalOutboxEntriesTableTableManager get localOutboxEntries =>
      $$LocalOutboxEntriesTableTableManager(_db, _db.localOutboxEntries);
  $$LocalCryptoStatesTableTableManager get localCryptoStates =>
      $$LocalCryptoStatesTableTableManager(_db, _db.localCryptoStates);
  $$LocalCryptoRecordsTableTableManager get localCryptoRecords =>
      $$LocalCryptoRecordsTableTableManager(_db, _db.localCryptoRecords);
  $$LocalMetadataTableTableManager get localMetadata =>
      $$LocalMetadataTableTableManager(_db, _db.localMetadata);
  $$LocalMlsTransitionsTableTableManager get localMlsTransitions =>
      $$LocalMlsTransitionsTableTableManager(_db, _db.localMlsTransitions);
  $$LocalMlsOutboxEntriesTableTableManager get localMlsOutboxEntries =>
      $$LocalMlsOutboxEntriesTableTableManager(_db, _db.localMlsOutboxEntries);
  $$LocalPeerVerificationsTableTableManager get localPeerVerifications =>
      $$LocalPeerVerificationsTableTableManager(
          _db, _db.localPeerVerifications);
  $$LocalMessagesTableTableManager get localMessages =>
      $$LocalMessagesTableTableManager(_db, _db.localMessages);
  $$LocalMessageReactionsTableTableManager get localMessageReactions =>
      $$LocalMessageReactionsTableTableManager(_db, _db.localMessageReactions);
  $$LocalDraftsTableTableManager get localDrafts =>
      $$LocalDraftsTableTableManager(_db, _db.localDrafts);
  $$LocalConversationMutesTableTableManager get localConversationMutes =>
      $$LocalConversationMutesTableTableManager(
          _db, _db.localConversationMutes);
  $$LocalPinsTableTableManager get localPins =>
      $$LocalPinsTableTableManager(_db, _db.localPins);
  $$LocalPendingPinsTableTableManager get localPendingPins =>
      $$LocalPendingPinsTableTableManager(_db, _db.localPendingPins);
  $$LocalStarredTableTableManager get localStarred =>
      $$LocalStarredTableTableManager(_db, _db.localStarred);
  $$LocalConversationPrefsTableTableManager get localConversationPrefs =>
      $$LocalConversationPrefsTableTableManager(
          _db, _db.localConversationPrefs);
}
