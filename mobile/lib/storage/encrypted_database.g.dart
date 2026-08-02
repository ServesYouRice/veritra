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
  @override
  List<GeneratedColumn> get $columns =>
      [id, conversationId, position, payloadJson];
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
  const LocalCiphertextEnvelope(
      {required this.id,
      required this.conversationId,
      required this.position,
      required this.payloadJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['position'] = Variable<int>(position);
    map['payload_json'] = Variable<String>(payloadJson);
    return map;
  }

  LocalCiphertextEnvelopesCompanion toCompanion(bool nullToAbsent) {
    return LocalCiphertextEnvelopesCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      position: Value(position),
      payloadJson: Value(payloadJson),
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
    };
  }

  LocalCiphertextEnvelope copyWith(
          {String? id,
          String? conversationId,
          int? position,
          String? payloadJson}) =>
      LocalCiphertextEnvelope(
        id: id ?? this.id,
        conversationId: conversationId ?? this.conversationId,
        position: position ?? this.position,
        payloadJson: payloadJson ?? this.payloadJson,
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
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalCiphertextEnvelope(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('position: $position, ')
          ..write('payloadJson: $payloadJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, conversationId, position, payloadJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalCiphertextEnvelope &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.position == this.position &&
          other.payloadJson == this.payloadJson);
}

class LocalCiphertextEnvelopesCompanion
    extends UpdateCompanion<LocalCiphertextEnvelope> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<int> position;
  final Value<String> payloadJson;
  final Value<int> rowid;
  const LocalCiphertextEnvelopesCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.position = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalCiphertextEnvelopesCompanion.insert({
    required String id,
    required String conversationId,
    required int position,
    required String payloadJson,
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
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (position != null) 'position': position,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalCiphertextEnvelopesCompanion copyWith(
      {Value<String>? id,
      Value<String>? conversationId,
      Value<int>? position,
      Value<String>? payloadJson,
      Value<int>? rowid}) {
    return LocalCiphertextEnvelopesCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
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
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
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
    return (StringBuffer('LocalCiphertextEnvelopesCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('position: $position, ')
          ..write('payloadJson: $payloadJson, ')
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
  @override
  List<GeneratedColumn> get $columns => [
        idempotencyKey,
        conversationId,
        kind,
        recipientDeviceId,
        revocationDeviceId,
        payload,
        stateCounter,
        queuedAt
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
  const LocalMlsOutboxEntry(
      {required this.idempotencyKey,
      required this.conversationId,
      required this.kind,
      this.recipientDeviceId,
      this.revocationDeviceId,
      required this.payload,
      required this.stateCounter,
      required this.queuedAt});
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
          int? queuedAt}) =>
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
          ..write('queuedAt: $queuedAt')
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
      queuedAt);
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
          other.queuedAt == this.queuedAt);
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
  late final $LocalMetadataTable localMetadata = $LocalMetadataTable(this);
  late final $LocalMlsTransitionsTable localMlsTransitions =
      $LocalMlsTransitionsTable(this);
  late final $LocalMlsOutboxEntriesTable localMlsOutboxEntries =
      $LocalMlsOutboxEntriesTable(this);
  late final $LocalPeerVerificationsTable localPeerVerifications =
      $LocalPeerVerificationsTable(this);
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
        localMetadata,
        localMlsTransitions,
        localMlsOutboxEntries,
        localPeerVerifications
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
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
  Value<int> rowid,
});
typedef $$LocalCiphertextEnvelopesTableUpdateCompanionBuilder
    = LocalCiphertextEnvelopesCompanion Function({
  Value<String> id,
  Value<String> conversationId,
  Value<int> position,
  Value<String> payloadJson,
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
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalCiphertextEnvelopesCompanion(
            id: id,
            conversationId: conversationId,
            position: position,
            payloadJson: payloadJson,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String conversationId,
            required int position,
            required String payloadJson,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalCiphertextEnvelopesCompanion.insert(
            id: id,
            conversationId: conversationId,
            position: position,
            payloadJson: payloadJson,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
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
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
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
  $$LocalMetadataTableTableManager get localMetadata =>
      $$LocalMetadataTableTableManager(_db, _db.localMetadata);
  $$LocalMlsTransitionsTableTableManager get localMlsTransitions =>
      $$LocalMlsTransitionsTableTableManager(_db, _db.localMlsTransitions);
  $$LocalMlsOutboxEntriesTableTableManager get localMlsOutboxEntries =>
      $$LocalMlsOutboxEntriesTableTableManager(_db, _db.localMlsOutboxEntries);
  $$LocalPeerVerificationsTableTableManager get localPeerVerifications =>
      $$LocalPeerVerificationsTableTableManager(
          _db, _db.localPeerVerifications);
}
