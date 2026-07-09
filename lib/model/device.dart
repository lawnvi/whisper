import 'package:drift/drift.dart';

@UseRowClass(DeviceData)
class Device extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uid => text().unique().withDefault(const Constant(""))();
  TextColumn get identityPublicKey =>
      text().named('identity_public_key').withDefault(const Constant(""))();
  TextColumn get name => text().withDefault(const Constant(""))();
  TextColumn get host => text()();
  IntColumn get port => integer()();
  TextColumn get password =>
      text().nullable().withDefault(const Constant(""))();
  TextColumn get platform => text().withDefault(const Constant(""))();
  BoolColumn get isServer => boolean().withDefault(const Constant(false))();
  BoolColumn get online => boolean().withDefault(const Constant(false))();
  BoolColumn get clipboard => boolean().withDefault(const Constant(false))();
  BoolColumn get auth => boolean().withDefault(const Constant(false))();
  IntColumn get lastTime => integer().withDefault(const Constant(0))();
  BoolColumn get around =>
      boolean().nullable().withDefault(const Constant(false))();
}

final class DeviceData {
  const DeviceData({
    required this.id,
    required this.uid,
    this.identityPublicKey = '',
    required this.name,
    required this.host,
    required this.port,
    this.password,
    required this.platform,
    required this.isServer,
    required this.online,
    required this.clipboard,
    required this.auth,
    required this.lastTime,
    this.around,
  });

  final int id;
  final String uid;
  final String identityPublicKey;
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
  final bool? around;

  factory DeviceData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceData(
      id: serializer.fromJson<int>(json['id']),
      uid: serializer.fromJson<String>(json['uid']),
      identityPublicKey: json.containsKey('identityPublicKey')
          ? serializer.fromJson<String>(json['identityPublicKey'])
          : '',
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
      around: serializer.fromJson<bool?>(json['around']),
    );
  }

  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uid': serializer.toJson<String>(uid),
      'identityPublicKey': serializer.toJson<String>(identityPublicKey),
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
      'around': serializer.toJson<bool?>(around),
    };
  }

  DeviceData copyWith({
    int? id,
    String? uid,
    String? identityPublicKey,
    String? name,
    String? host,
    int? port,
    Value<String?> password = const Value.absent(),
    String? platform,
    bool? isServer,
    bool? online,
    bool? clipboard,
    bool? auth,
    int? lastTime,
    Value<bool?> around = const Value.absent(),
  }) {
    return DeviceData(
      id: id ?? this.id,
      uid: uid ?? this.uid,
      identityPublicKey: identityPublicKey ?? this.identityPublicKey,
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
      around: around.present ? around.value : this.around,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DeviceData &&
        other.id == id &&
        other.uid == uid &&
        other.identityPublicKey == identityPublicKey &&
        other.name == name &&
        other.host == host &&
        other.port == port &&
        other.password == password &&
        other.platform == platform &&
        other.isServer == isServer &&
        other.online == online &&
        other.clipboard == clipboard &&
        other.auth == auth &&
        other.lastTime == lastTime &&
        other.around == around;
  }

  @override
  int get hashCode => Object.hash(
        id,
        uid,
        identityPublicKey,
        name,
        host,
        port,
        password,
        platform,
        isServer,
        online,
        clipboard,
        auth,
        lastTime,
        around,
      );

  @override
  String toString() =>
      'DeviceData(id: $id, uid: $uid, name: $name, platform: $platform)';
}
