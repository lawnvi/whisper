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
  static const VerificationMeta _passwordMeta =
      const VerificationMeta('password');
  @override
  late final GeneratedColumn<String> password = GeneratedColumn<String>(
      'password', aliasedName, true,
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
        password,
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
    if (data.containsKey('password')) {
      context.handle(_passwordMeta,
          password.isAcceptableOrUnknown(data['password']!, _passwordMeta));
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
      password: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}password']),
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
  final String? password;
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
      this.password,
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
    if (!nullToAbsent || password != null) {
      map['password'] = Variable<String>(password);
    }
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
      password: password == null && nullToAbsent
          ? const Value.absent()
          : Value(password),
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
      password: serializer.fromJson<String?>(json['password']),
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
      'password': serializer.toJson<String?>(password),
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
          Value<String?> password = const Value.absent(),
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
        password: password.present ? password.value : this.password,
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
          ..write('password: $password, ')
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
  int get hashCode => Object.hash(id, uid, name, host, port, password, platform,
      isServer, online, clipboard, auth, lastTime);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceData &&
          other.id == this.id &&
          other.uid == this.uid &&
          other.name == this.name &&
          other.host == this.host &&
          other.port == this.port &&
          other.password == this.password &&
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
  final Value<String?> password;
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
    this.password = const Value.absent(),
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
    this.password = const Value.absent(),
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
    Expression<String>? password,
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
      if (password != null) 'password': password,
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
      Value<String?>? password,
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
      password: password ?? this.password,
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
    if (password.present) {
      map['password'] = Variable<String>(password.value);
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
          ..write('password: $password, ')
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
  static const VerificationMeta _contentMeta =
      const VerificationMeta('content');
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
      'content', aliasedName, true,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _messageMeta =
      const VerificationMeta('message');
  @override
  late final GeneratedColumn<String> message = GeneratedColumn<String>(
      'message', aliasedName, true,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _timestampMeta =
      const VerificationMeta('timestamp');
  @override
  late final GeneratedColumn<int> timestamp = GeneratedColumn<int>(
      'timestamp', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _ackedMeta = const VerificationMeta('acked');
  @override
  late final GeneratedColumn<bool> acked = GeneratedColumn<bool>(
      'acked', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("acked" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
      'path', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  static const VerificationMeta _md5Meta = const VerificationMeta('md5');
  @override
  late final GeneratedColumn<String> md5 = GeneratedColumn<String>(
      'md5', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(""));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        deviceId,
        sender,
        receiver,
        name,
        clipboard,
        size,
        type,
        content,
        message,
        timestamp,
        uuid,
        acked,
        path,
        md5
      ];
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
    if (data.containsKey('clipboard')) {
      context.handle(_clipboardMeta,
          clipboard.isAcceptableOrUnknown(data['clipboard']!, _clipboardMeta));
    }
    if (data.containsKey('size')) {
      context.handle(
          _sizeMeta, size.isAcceptableOrUnknown(data['size']!, _sizeMeta));
    }
    context.handle(_typeMeta, const VerificationResult.success());
    if (data.containsKey('content')) {
      context.handle(_contentMeta,
          content.isAcceptableOrUnknown(data['content']!, _contentMeta));
    }
    if (data.containsKey('message')) {
      context.handle(_messageMeta,
          message.isAcceptableOrUnknown(data['message']!, _messageMeta));
    }
    if (data.containsKey('timestamp')) {
      context.handle(_timestampMeta,
          timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta));
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    }
    if (data.containsKey('acked')) {
      context.handle(
          _ackedMeta, acked.isAcceptableOrUnknown(data['acked']!, _ackedMeta));
    }
    if (data.containsKey('path')) {
      context.handle(
          _pathMeta, path.isAcceptableOrUnknown(data['path']!, _pathMeta));
    }
    if (data.containsKey('md5')) {
      context.handle(
          _md5Meta, md5.isAcceptableOrUnknown(data['md5']!, _md5Meta));
    }
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
      clipboard: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}clipboard'])!,
      size: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}size'])!,
      type: $MessageTable.$convertertype.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}type'])!),
      content: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}content']),
      message: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}message']),
      timestamp: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}timestamp'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      acked: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}acked'])!,
      path: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path'])!,
      md5: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}md5'])!,
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
  final bool clipboard;
  final int size;
  final MessageEnum type;
  final String? content;
  final String? message;
  final int timestamp;
  final String uuid;
  final bool acked;
  final String path;
  final String md5;
  const MessageData(
      {required this.id,
      this.deviceId,
      required this.sender,
      required this.receiver,
      required this.name,
      required this.clipboard,
      required this.size,
      required this.type,
      this.content,
      this.message,
      required this.timestamp,
      required this.uuid,
      required this.acked,
      required this.path,
      required this.md5});
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
    map['clipboard'] = Variable<bool>(clipboard);
    map['size'] = Variable<int>(size);
    {
      map['type'] = Variable<int>($MessageTable.$convertertype.toSql(type));
    }
    if (!nullToAbsent || content != null) {
      map['content'] = Variable<String>(content);
    }
    if (!nullToAbsent || message != null) {
      map['message'] = Variable<String>(message);
    }
    map['timestamp'] = Variable<int>(timestamp);
    map['uuid'] = Variable<String>(uuid);
    map['acked'] = Variable<bool>(acked);
    map['path'] = Variable<String>(path);
    map['md5'] = Variable<String>(md5);
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
      clipboard: Value(clipboard),
      size: Value(size),
      type: Value(type),
      content: content == null && nullToAbsent
          ? const Value.absent()
          : Value(content),
      message: message == null && nullToAbsent
          ? const Value.absent()
          : Value(message),
      timestamp: Value(timestamp),
      uuid: Value(uuid),
      acked: Value(acked),
      path: Value(path),
      md5: Value(md5),
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
      clipboard: serializer.fromJson<bool>(json['clipboard']),
      size: serializer.fromJson<int>(json['size']),
      type: $MessageTable.$convertertype
          .fromJson(serializer.fromJson<int>(json['type'])),
      content: serializer.fromJson<String?>(json['content']),
      message: serializer.fromJson<String?>(json['message']),
      timestamp: serializer.fromJson<int>(json['timestamp']),
      uuid: serializer.fromJson<String>(json['uuid']),
      acked: serializer.fromJson<bool>(json['acked']),
      path: serializer.fromJson<String>(json['path']),
      md5: serializer.fromJson<String>(json['md5']),
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
      'clipboard': serializer.toJson<bool>(clipboard),
      'size': serializer.toJson<int>(size),
      'type': serializer.toJson<int>($MessageTable.$convertertype.toJson(type)),
      'content': serializer.toJson<String?>(content),
      'message': serializer.toJson<String?>(message),
      'timestamp': serializer.toJson<int>(timestamp),
      'uuid': serializer.toJson<String>(uuid),
      'acked': serializer.toJson<bool>(acked),
      'path': serializer.toJson<String>(path),
      'md5': serializer.toJson<String>(md5),
    };
  }

  MessageData copyWith(
          {int? id,
          Value<int?> deviceId = const Value.absent(),
          String? sender,
          String? receiver,
          String? name,
          bool? clipboard,
          int? size,
          MessageEnum? type,
          Value<String?> content = const Value.absent(),
          Value<String?> message = const Value.absent(),
          int? timestamp,
          String? uuid,
          bool? acked,
          String? path,
          String? md5}) =>
      MessageData(
        id: id ?? this.id,
        deviceId: deviceId.present ? deviceId.value : this.deviceId,
        sender: sender ?? this.sender,
        receiver: receiver ?? this.receiver,
        name: name ?? this.name,
        clipboard: clipboard ?? this.clipboard,
        size: size ?? this.size,
        type: type ?? this.type,
        content: content.present ? content.value : this.content,
        message: message.present ? message.value : this.message,
        timestamp: timestamp ?? this.timestamp,
        uuid: uuid ?? this.uuid,
        acked: acked ?? this.acked,
        path: path ?? this.path,
        md5: md5 ?? this.md5,
      );
  @override
  String toString() {
    return (StringBuffer('MessageData(')
          ..write('id: $id, ')
          ..write('deviceId: $deviceId, ')
          ..write('sender: $sender, ')
          ..write('receiver: $receiver, ')
          ..write('name: $name, ')
          ..write('clipboard: $clipboard, ')
          ..write('size: $size, ')
          ..write('type: $type, ')
          ..write('content: $content, ')
          ..write('message: $message, ')
          ..write('timestamp: $timestamp, ')
          ..write('uuid: $uuid, ')
          ..write('acked: $acked, ')
          ..write('path: $path, ')
          ..write('md5: $md5')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      deviceId,
      sender,
      receiver,
      name,
      clipboard,
      size,
      type,
      content,
      message,
      timestamp,
      uuid,
      acked,
      path,
      md5);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageData &&
          other.id == this.id &&
          other.deviceId == this.deviceId &&
          other.sender == this.sender &&
          other.receiver == this.receiver &&
          other.name == this.name &&
          other.clipboard == this.clipboard &&
          other.size == this.size &&
          other.type == this.type &&
          other.content == this.content &&
          other.message == this.message &&
          other.timestamp == this.timestamp &&
          other.uuid == this.uuid &&
          other.acked == this.acked &&
          other.path == this.path &&
          other.md5 == this.md5);
}

class MessageCompanion extends UpdateCompanion<MessageData> {
  final Value<int> id;
  final Value<int?> deviceId;
  final Value<String> sender;
  final Value<String> receiver;
  final Value<String> name;
  final Value<bool> clipboard;
  final Value<int> size;
  final Value<MessageEnum> type;
  final Value<String?> content;
  final Value<String?> message;
  final Value<int> timestamp;
  final Value<String> uuid;
  final Value<bool> acked;
  final Value<String> path;
  final Value<String> md5;
  const MessageCompanion({
    this.id = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.sender = const Value.absent(),
    this.receiver = const Value.absent(),
    this.name = const Value.absent(),
    this.clipboard = const Value.absent(),
    this.size = const Value.absent(),
    this.type = const Value.absent(),
    this.content = const Value.absent(),
    this.message = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.uuid = const Value.absent(),
    this.acked = const Value.absent(),
    this.path = const Value.absent(),
    this.md5 = const Value.absent(),
  });
  MessageCompanion.insert({
    this.id = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.sender = const Value.absent(),
    this.receiver = const Value.absent(),
    this.name = const Value.absent(),
    this.clipboard = const Value.absent(),
    this.size = const Value.absent(),
    this.type = const Value.absent(),
    this.content = const Value.absent(),
    this.message = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.uuid = const Value.absent(),
    this.acked = const Value.absent(),
    this.path = const Value.absent(),
    this.md5 = const Value.absent(),
  });
  static Insertable<MessageData> custom({
    Expression<int>? id,
    Expression<int>? deviceId,
    Expression<String>? sender,
    Expression<String>? receiver,
    Expression<String>? name,
    Expression<bool>? clipboard,
    Expression<int>? size,
    Expression<int>? type,
    Expression<String>? content,
    Expression<String>? message,
    Expression<int>? timestamp,
    Expression<String>? uuid,
    Expression<bool>? acked,
    Expression<String>? path,
    Expression<String>? md5,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (deviceId != null) 'device_id': deviceId,
      if (sender != null) 'sender': sender,
      if (receiver != null) 'receiver': receiver,
      if (name != null) 'name': name,
      if (clipboard != null) 'clipboard': clipboard,
      if (size != null) 'size': size,
      if (type != null) 'type': type,
      if (content != null) 'content': content,
      if (message != null) 'message': message,
      if (timestamp != null) 'timestamp': timestamp,
      if (uuid != null) 'uuid': uuid,
      if (acked != null) 'acked': acked,
      if (path != null) 'path': path,
      if (md5 != null) 'md5': md5,
    });
  }

  MessageCompanion copyWith(
      {Value<int>? id,
      Value<int?>? deviceId,
      Value<String>? sender,
      Value<String>? receiver,
      Value<String>? name,
      Value<bool>? clipboard,
      Value<int>? size,
      Value<MessageEnum>? type,
      Value<String?>? content,
      Value<String?>? message,
      Value<int>? timestamp,
      Value<String>? uuid,
      Value<bool>? acked,
      Value<String>? path,
      Value<String>? md5}) {
    return MessageCompanion(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      sender: sender ?? this.sender,
      receiver: receiver ?? this.receiver,
      name: name ?? this.name,
      clipboard: clipboard ?? this.clipboard,
      size: size ?? this.size,
      type: type ?? this.type,
      content: content ?? this.content,
      message: message ?? this.message,
      timestamp: timestamp ?? this.timestamp,
      uuid: uuid ?? this.uuid,
      acked: acked ?? this.acked,
      path: path ?? this.path,
      md5: md5 ?? this.md5,
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
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (message.present) {
      map['message'] = Variable<String>(message.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<int>(timestamp.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (acked.present) {
      map['acked'] = Variable<bool>(acked.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (md5.present) {
      map['md5'] = Variable<String>(md5.value);
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
          ..write('clipboard: $clipboard, ')
          ..write('size: $size, ')
          ..write('type: $type, ')
          ..write('content: $content, ')
          ..write('message: $message, ')
          ..write('timestamp: $timestamp, ')
          ..write('uuid: $uuid, ')
          ..write('acked: $acked, ')
          ..write('path: $path, ')
          ..write('md5: $md5')
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
