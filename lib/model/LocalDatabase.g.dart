// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'LocalDatabase.dart';

// ignore_for_file: type=lint
class $DeviceTable extends Device with TableInfo<$DeviceTable, DeviceData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeviceTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
      'uid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _hostMeta = const VerificationMeta('host');
  @override
  late final GeneratedColumn<String> host = GeneratedColumn<String>(
      'host', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
      'port', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _platformMeta =
      const VerificationMeta('platform');
  @override
  late final GeneratedColumn<String> platform = GeneratedColumn<String>(
      'platform', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _isServerMeta =
      const VerificationMeta('isServer');
  @override
  late final GeneratedColumn<bool> isServer = GeneratedColumn<bool>(
      'is_server', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_server" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _onlineMeta = const VerificationMeta('online');
  @override
  late final GeneratedColumn<bool> online = GeneratedColumn<bool>(
      'online', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("online" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _clipboardMeta =
      const VerificationMeta('clipboard');
  @override
  late final GeneratedColumn<bool> clipboard = GeneratedColumn<bool>(
      'clipboard', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("clipboard" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _authMeta = const VerificationMeta('auth');
  @override
  late final GeneratedColumn<bool> auth = GeneratedColumn<bool>(
      'auth', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("auth" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _lastTimeMeta =
      const VerificationMeta('lastTime');
  @override
  late final GeneratedColumn<int> lastTime = GeneratedColumn<int>(
      'last_time', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        uid,
        name,
        host,
        port,
        platform,
        isServer,
        online,
        clipboard,
        auth,
        lastTime
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'device';
  @override
  VerificationContext validateIntegrity(Insertable<DeviceData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uid')) {
      context.handle(
          _uidMeta, uid.isAcceptableOrUnknown(data['uid']!, _uidMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    }
    if (data.containsKey('host')) {
      context.handle(
          _hostMeta, host.isAcceptableOrUnknown(data['host']!, _hostMeta));
    } else if (isInserting) {
      context.missing(_hostMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
          _portMeta, port.isAcceptableOrUnknown(data['port']!, _portMeta));
    } else if (isInserting) {
      context.missing(_portMeta);
    }
    if (data.containsKey('platform')) {
      context.handle(_platformMeta,
          platform.isAcceptableOrUnknown(data['platform']!, _platformMeta));
    }
    if (data.containsKey('is_server')) {
      context.handle(_isServerMeta,
          isServer.isAcceptableOrUnknown(data['is_server']!, _isServerMeta));
    }
    if (data.containsKey('online')) {
      context.handle(_onlineMeta,
          online.isAcceptableOrUnknown(data['online']!, _onlineMeta));
    }
    if (data.containsKey('clipboard')) {
      context.handle(_clipboardMeta,
          clipboard.isAcceptableOrUnknown(data['clipboard']!, _clipboardMeta));
    }
    if (data.containsKey('auth')) {
      context.handle(
          _authMeta, auth.isAcceptableOrUnknown(data['auth']!, _authMeta));
    }
    if (data.containsKey('last_time')) {
      context.handle(_lastTimeMeta,
          lastTime.isAcceptableOrUnknown(data['last_time']!, _lastTimeMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DeviceData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeviceData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uid'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      host: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}host'])!,
      port: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}port'])!,
      platform: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}platform'])!,
      isServer: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_server'])!,
      online: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}online'])!,
      clipboard: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}clipboard'])!,
      auth: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}auth'])!,
      lastTime: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_time'])!,
    );
  }

  @override
  $DeviceTable createAlias(String alias) {
    return $DeviceTable(attachedDatabase, alias);
  }
}

class DeviceData extends DataClass implements Insertable<DeviceData> {
  final int id;
  final String uid;
  final String name;
  final String host;
  final int port;
  final String platform;
  final bool isServer;
  final bool online;
  final bool clipboard;
  final bool auth;
  final int lastTime;
  const DeviceData(
      {required this.id,
      required this.uid,
      required this.name,
      required this.host,
      required this.port,
      required this.platform,
      required this.isServer,
      required this.online,
      required this.clipboard,
      required this.auth,
      required this.lastTime});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uid'] = Variable<String>(uid);
    map['name'] = Variable<String>(name);
    map['host'] = Variable<String>(host);
    map['port'] = Variable<int>(port);
    map['platform'] = Variable<String>(platform);
    map['is_server'] = Variable<bool>(isServer);
    map['online'] = Variable<bool>(online);
    map['clipboard'] = Variable<bool>(clipboard);
    map['auth'] = Variable<bool>(auth);
    map['last_time'] = Variable<int>(lastTime);
    return map;
  }

  DeviceCompanion toCompanion(bool nullToAbsent) {
    return DeviceCompanion(
      id: Value(id),
      uid: Value(uid),
      name: Value(name),
      host: Value(host),
      port: Value(port),
      platform: Value(platform),
      isServer: Value(isServer),
      online: Value(online),
      clipboard: Value(clipboard),
      auth: Value(auth),
      lastTime: Value(lastTime),
    );
  }

  factory DeviceData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceData(
      id: serializer.fromJson<int>(json['id']),
      uid: serializer.fromJson<String>(json['uid']),
      name: serializer.fromJson<String>(json['name']),
      host: serializer.fromJson<String>(json['host']),
      port: serializer.fromJson<int>(json['port']),
      platform: serializer.fromJson<String>(json['platform']),
      isServer: serializer.fromJson<bool>(json['isServer']),
      online: serializer.fromJson<bool>(json['online']),
      clipboard: serializer.fromJson<bool>(json['clipboard']),
      auth: serializer.fromJson<bool>(json['auth']),
      lastTime: serializer.fromJson<int>(json['lastTime']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uid': serializer.toJson<String>(uid),
      'name': serializer.toJson<String>(name),
      'host': serializer.toJson<String>(host),
      'port': serializer.toJson<int>(port),
      'platform': serializer.toJson<String>(platform),
      'isServer': serializer.toJson<bool>(isServer),
      'online': serializer.toJson<bool>(online),
      'clipboard': serializer.toJson<bool>(clipboard),
      'auth': serializer.toJson<bool>(auth),
      'lastTime': serializer.toJson<int>(lastTime),
    };
  }

  DeviceData copyWith(
          {int? id,
          String? uid,
          String? name,
          String? host,
          int? port,
          String? platform,
          bool? isServer,
          bool? online,
          bool? clipboard,
          bool? auth,
          int? lastTime}) =>
      DeviceData(
        id: id ?? this.id,
        uid: uid ?? this.uid,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        platform: platform ?? this.platform,
        isServer: isServer ?? this.isServer,
        online: online ?? this.online,
        clipboard: clipboard ?? this.clipboard,
        auth: auth ?? this.auth,
        lastTime: lastTime ?? this.lastTime,
      );
  @override
  String toString() {
    return (StringBuffer('DeviceData(')
          ..write('id: $id, ')
          ..write('uid: $uid, ')
          ..write('name: $name, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('platform: $platform, ')
          ..write('isServer: $isServer, ')
          ..write('online: $online, ')
          ..write('clipboard: $clipboard, ')
          ..write('auth: $auth, ')
          ..write('lastTime: $lastTime')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, uid, name, host, port, platform, isServer,
      online, clipboard, auth, lastTime);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceData &&
          other.id == this.id &&
          other.uid == this.uid &&
          other.name == this.name &&
          other.host == this.host &&
          other.port == this.port &&
          other.platform == this.platform &&
          other.isServer == this.isServer &&
          other.online == this.online &&
          other.clipboard == this.clipboard &&
          other.auth == this.auth &&
          other.lastTime == this.lastTime);
}

class DeviceCompanion extends UpdateCompanion<DeviceData> {
  final Value<int> id;
  final Value<String> uid;
  final Value<String> name;
  final Value<String> host;
  final Value<int> port;
  final Value<String> platform;
  final Value<bool> isServer;
  final Value<bool> online;
  final Value<bool> clipboard;
  final Value<bool> auth;
  final Value<int> lastTime;
  const DeviceCompanion({
    this.id = const Value.absent(),
    this.uid = const Value.absent(),
    this.name = const Value.absent(),
    this.host = const Value.absent(),
    this.port = const Value.absent(),
    this.platform = const Value.absent(),
    this.isServer = const Value.absent(),
    this.online = const Value.absent(),
    this.clipboard = const Value.absent(),
    this.auth = const Value.absent(),
    this.lastTime = const Value.absent(),
  });
  DeviceCompanion.insert({
    this.id = const Value.absent(),
    this.uid = const Value.absent(),
    this.name = const Value.absent(),
    required String host,
    required int port,
    this.platform = const Value.absent(),
    this.isServer = const Value.absent(),
    this.online = const Value.absent(),
    this.clipboard = const Value.absent(),
    this.auth = const Value.absent(),
    this.lastTime = const Value.absent(),
  })  : host = Value(host),
        port = Value(port);
  static Insertable<DeviceData> custom({
    Expression<int>? id,
    Expression<String>? uid,
    Expression<String>? name,
    Expression<String>? host,
    Expression<int>? port,
    Expression<String>? platform,
    Expression<bool>? isServer,
    Expression<bool>? online,
    Expression<bool>? clipboard,
    Expression<bool>? auth,
    Expression<int>? lastTime,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uid != null) 'uid': uid,
      if (name != null) 'name': name,
      if (host != null) 'host': host,
      if (port != null) 'port': port,
      if (platform != null) 'platform': platform,
      if (isServer != null) 'is_server': isServer,
      if (online != null) 'online': online,
      if (clipboard != null) 'clipboard': clipboard,
      if (auth != null) 'auth': auth,
      if (lastTime != null) 'last_time': lastTime,
    });
  }

  DeviceCompanion copyWith(
      {Value<int>? id,
      Value<String>? uid,
      Value<String>? name,
      Value<String>? host,
      Value<int>? port,
      Value<String>? platform,
      Value<bool>? isServer,
      Value<bool>? online,
      Value<bool>? clipboard,
      Value<bool>? auth,
      Value<int>? lastTime}) {
    return DeviceCompanion(
      id: id ?? this.id,
      uid: uid ?? this.uid,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      platform: platform ?? this.platform,
      isServer: isServer ?? this.isServer,
      online: online ?? this.online,
      clipboard: clipboard ?? this.clipboard,
      auth: auth ?? this.auth,
      lastTime: lastTime ?? this.lastTime,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (host.present) {
      map['host'] = Variable<String>(host.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (platform.present) {
      map['platform'] = Variable<String>(platform.value);
    }
    if (isServer.present) {
      map['is_server'] = Variable<bool>(isServer.value);
    }
    if (online.present) {
      map['online'] = Variable<bool>(online.value);
    }
    if (clipboard.present) {
      map['clipboard'] = Variable<bool>(clipboard.value);
    }
    if (auth.present) {
      map['auth'] = Variable<bool>(auth.value);
    }
    if (lastTime.present) {
      map['last_time'] = Variable<int>(lastTime.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeviceCompanion(')
          ..write('id: $id, ')
          ..write('uid: $uid, ')
          ..write('name: $name, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('platform: $platform, ')
          ..write('isServer: $isServer, ')
          ..write('online: $online, ')
          ..write('clipboard: $clipboard, ')
          ..write('auth: $auth, ')
          ..write('lastTime: $lastTime')
          ..write(')'))
        .toString();
  }
}

class $MessageTable extends Message with TableInfo<$MessageTable, MessageData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _deviceIdMeta =
      const VerificationMeta('deviceId');
  @override
  late final GeneratedColumn<int> deviceId = GeneratedColumn<int>(
      'device_id', aliasedName, true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES device (id)'));
  static const VerificationMeta _senderMeta = const VerificationMeta('sender');
  @override
  late final GeneratedColumn<String> sender = GeneratedColumn<String>(
      'sender', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _receiverMeta =
      const VerificationMeta('receiver');
  @override
  late final GeneratedColumn<String> receiver = GeneratedColumn<String>(
      'receiver', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _platformMeta =
      const VerificationMeta('platform');
  @override
  late final GeneratedColumn<String> platform = GeneratedColumn<String>(
      'platform', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _clipboardMeta =
      const VerificationMeta('clipboard');
  @override
  late final GeneratedColumn<bool> clipboard = GeneratedColumn<bool>(
      'clipboard', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("clipboard" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
      'size', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumnWithTypeConverter<MessageEnum, int> type =
      GeneratedColumn<int>('type', aliasedName, false,
              type: DriftSqlType.int,
              requiredDuringInsert: false,
              defaultValue: const Constant(0))
          .withConverter<MessageEnum>($MessageTable.$convertertype);
  @override
  List<GeneratedColumn> get $columns =>
      [id, deviceId, sender, receiver, name, platform, clipboard, size, type];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message';
  @override
  VerificationContext validateIntegrity(Insertable<MessageData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('device_id')) {
      context.handle(_deviceIdMeta,
          deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta));
    }
    if (data.containsKey('sender')) {
      context.handle(_senderMeta,
          sender.isAcceptableOrUnknown(data['sender']!, _senderMeta));
    }
    if (data.containsKey('receiver')) {
      context.handle(_receiverMeta,
          receiver.isAcceptableOrUnknown(data['receiver']!, _receiverMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    }
    if (data.containsKey('platform')) {
      context.handle(_platformMeta,
          platform.isAcceptableOrUnknown(data['platform']!, _platformMeta));
    }
    if (data.containsKey('clipboard')) {
      context.handle(_clipboardMeta,
          clipboard.isAcceptableOrUnknown(data['clipboard']!, _clipboardMeta));
    }
    if (data.containsKey('size')) {
      context.handle(
          _sizeMeta, size.isAcceptableOrUnknown(data['size']!, _sizeMeta));
    }
    context.handle(_typeMeta, const VerificationResult.success());
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      deviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}device_id']),
      sender: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sender'])!,
      receiver: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}receiver'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      platform: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}platform'])!,
      clipboard: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}clipboard'])!,
      size: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}size'])!,
      type: $MessageTable.$convertertype.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}type'])!),
    );
  }

  @override
  $MessageTable createAlias(String alias) {
    return $MessageTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<MessageEnum, int, int> $convertertype =
      const EnumIndexConverter<MessageEnum>(MessageEnum.values);
}

class MessageData extends DataClass implements Insertable<MessageData> {
  final int id;
  final int? deviceId;
  final String sender;
  final String receiver;
  final String name;
  final String platform;
  final bool clipboard;
  final int size;
  final MessageEnum type;
  const MessageData(
      {required this.id,
      this.deviceId,
      required this.sender,
      required this.receiver,
      required this.name,
      required this.platform,
      required this.clipboard,
      required this.size,
      required this.type});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || deviceId != null) {
      map['device_id'] = Variable<int>(deviceId);
    }
    map['sender'] = Variable<String>(sender);
    map['receiver'] = Variable<String>(receiver);
    map['name'] = Variable<String>(name);
    map['platform'] = Variable<String>(platform);
    map['clipboard'] = Variable<bool>(clipboard);
    map['size'] = Variable<int>(size);
    {
      map['type'] = Variable<int>($MessageTable.$convertertype.toSql(type));
    }
    return map;
  }

  MessageCompanion toCompanion(bool nullToAbsent) {
    return MessageCompanion(
      id: Value(id),
      deviceId: deviceId == null && nullToAbsent
          ? const Value.absent()
          : Value(deviceId),
      sender: Value(sender),
      receiver: Value(receiver),
      name: Value(name),
      platform: Value(platform),
      clipboard: Value(clipboard),
      size: Value(size),
      type: Value(type),
    );
  }

  factory MessageData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageData(
      id: serializer.fromJson<int>(json['id']),
      deviceId: serializer.fromJson<int?>(json['deviceId']),
      sender: serializer.fromJson<String>(json['sender']),
      receiver: serializer.fromJson<String>(json['receiver']),
      name: serializer.fromJson<String>(json['name']),
      platform: serializer.fromJson<String>(json['platform']),
      clipboard: serializer.fromJson<bool>(json['clipboard']),
      size: serializer.fromJson<int>(json['size']),
      type: $MessageTable.$convertertype
          .fromJson(serializer.fromJson<int>(json['type'])),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'deviceId': serializer.toJson<int?>(deviceId),
      'sender': serializer.toJson<String>(sender),
      'receiver': serializer.toJson<String>(receiver),
      'name': serializer.toJson<String>(name),
      'platform': serializer.toJson<String>(platform),
      'clipboard': serializer.toJson<bool>(clipboard),
      'size': serializer.toJson<int>(size),
      'type': serializer.toJson<int>($MessageTable.$convertertype.toJson(type)),
    };
  }

  MessageData copyWith(
          {int? id,
          Value<int?> deviceId = const Value.absent(),
          String? sender,
          String? receiver,
          String? name,
          String? platform,
          bool? clipboard,
          int? size,
          MessageEnum? type}) =>
      MessageData(
        id: id ?? this.id,
        deviceId: deviceId.present ? deviceId.value : this.deviceId,
        sender: sender ?? this.sender,
        receiver: receiver ?? this.receiver,
        name: name ?? this.name,
        platform: platform ?? this.platform,
        clipboard: clipboard ?? this.clipboard,
        size: size ?? this.size,
        type: type ?? this.type,
      );
  @override
  String toString() {
    return (StringBuffer('MessageData(')
          ..write('id: $id, ')
          ..write('deviceId: $deviceId, ')
          ..write('sender: $sender, ')
          ..write('receiver: $receiver, ')
          ..write('name: $name, ')
          ..write('platform: $platform, ')
          ..write('clipboard: $clipboard, ')
          ..write('size: $size, ')
          ..write('type: $type')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, deviceId, sender, receiver, name, platform, clipboard, size, type);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageData &&
          other.id == this.id &&
          other.deviceId == this.deviceId &&
          other.sender == this.sender &&
          other.receiver == this.receiver &&
          other.name == this.name &&
          other.platform == this.platform &&
          other.clipboard == this.clipboard &&
          other.size == this.size &&
          other.type == this.type);
}

class MessageCompanion extends UpdateCompanion<MessageData> {
  final Value<int> id;
  final Value<int?> deviceId;
  final Value<String> sender;
  final Value<String> receiver;
  final Value<String> name;
  final Value<String> platform;
  final Value<bool> clipboard;
  final Value<int> size;
  final Value<MessageEnum> type;
  const MessageCompanion({
    this.id = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.sender = const Value.absent(),
    this.receiver = const Value.absent(),
    this.name = const Value.absent(),
    this.platform = const Value.absent(),
    this.clipboard = const Value.absent(),
    this.size = const Value.absent(),
    this.type = const Value.absent(),
  });
  MessageCompanion.insert({
    this.id = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.sender = const Value.absent(),
    this.receiver = const Value.absent(),
    this.name = const Value.absent(),
    this.platform = const Value.absent(),
    this.clipboard = const Value.absent(),
    this.size = const Value.absent(),
    this.type = const Value.absent(),
  });
  static Insertable<MessageData> custom({
    Expression<int>? id,
    Expression<int>? deviceId,
    Expression<String>? sender,
    Expression<String>? receiver,
    Expression<String>? name,
    Expression<String>? platform,
    Expression<bool>? clipboard,
    Expression<int>? size,
    Expression<int>? type,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (deviceId != null) 'device_id': deviceId,
      if (sender != null) 'sender': sender,
      if (receiver != null) 'receiver': receiver,
      if (name != null) 'name': name,
      if (platform != null) 'platform': platform,
      if (clipboard != null) 'clipboard': clipboard,
      if (size != null) 'size': size,
      if (type != null) 'type': type,
    });
  }

  MessageCompanion copyWith(
      {Value<int>? id,
      Value<int?>? deviceId,
      Value<String>? sender,
      Value<String>? receiver,
      Value<String>? name,
      Value<String>? platform,
      Value<bool>? clipboard,
      Value<int>? size,
      Value<MessageEnum>? type}) {
    return MessageCompanion(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      sender: sender ?? this.sender,
      receiver: receiver ?? this.receiver,
      name: name ?? this.name,
      platform: platform ?? this.platform,
      clipboard: clipboard ?? this.clipboard,
      size: size ?? this.size,
      type: type ?? this.type,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<int>(deviceId.value);
    }
    if (sender.present) {
      map['sender'] = Variable<String>(sender.value);
    }
    if (receiver.present) {
      map['receiver'] = Variable<String>(receiver.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (platform.present) {
      map['platform'] = Variable<String>(platform.value);
    }
    if (clipboard.present) {
      map['clipboard'] = Variable<bool>(clipboard.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (type.present) {
      map['type'] =
          Variable<int>($MessageTable.$convertertype.toSql(type.value));
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessageCompanion(')
          ..write('id: $id, ')
          ..write('deviceId: $deviceId, ')
          ..write('sender: $sender, ')
          ..write('receiver: $receiver, ')
          ..write('name: $name, ')
          ..write('platform: $platform, ')
          ..write('clipboard: $clipboard, ')
          ..write('size: $size, ')
          ..write('type: $type')
          ..write(')'))
        .toString();
  }
}

abstract class _$LocalDatabase extends GeneratedDatabase {
  _$LocalDatabase(QueryExecutor e) : super(e);
  late final $DeviceTable device = $DeviceTable(this);
  late final $MessageTable message = $MessageTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [device, message];
}
