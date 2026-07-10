import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/deviceList.dart';

DeviceData _device({
  required String uid,
  required String name,
  required String host,
  required bool around,
  bool auth = false,
}) {
  return DeviceData(
    id: 1,
    uid: uid,
    name: name,
    host: host,
    port: 10002,
    password: 'stored-password',
    platform: 'macos',
    isServer: false,
    online: false,
    clipboard: true,
    auth: auth,
    lastTime: 1,
    around: around,
  );
}

void main() {
  test('discovered devices persist fresh network addresses', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final resolvedService = source.indexOf('final svr = service;');
    final discovery = source.substring(
      resolvedService,
      source.indexOf(
        'case BonsoirDiscoveryEventType.discoveryStarted ||',
        resolvedService,
      ),
    );

    expect(source, contains('_mergeStoredDeviceWithDiscovery'));
    expect(discovery, contains('final visibleDevice'));
    expect(discovery, contains('await db.upsertDevice(visibleDevice)'));
    expect(discovery, contains('if (!isLost)'));
    expect(discovery, contains('host: host'));
    expect(discovery, contains('port: port'));
  });

  test('connected nearby devices keep fresh discovery host over stored host',
      () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final refresh = source.substring(
      source.indexOf('Future<void> _refreshDevice'),
      source.indexOf('ChatSessionPreviewStrings _sessionPreviewStrings'),
    );
    final merge = source.substring(
      source.indexOf('DeviceData _mergeStoredDeviceWithDiscovery'),
      source.indexOf('Future<void> _refreshDevice'),
    );

    expect(
      refresh,
      contains(
        '_mergeStoredDeviceWithDiscovery(storedDevicesByUid[item.uid], item)',
      ),
    );
    expect(refresh, isNot(contains('storedDevicesByUid[item.uid] ?? item')));
    expect(merge, contains('host: discovered.host.isNotEmpty'));
    expect(merge, contains('port: discovered.port'));
    expect(merge, contains('auth: stored.auth'));
    expect(merge, contains('clipboard: stored.clipboard'));
  });

  test('lost discovery keeps the merged visible snapshot marked not nearby',
      () {
    final stored = _device(
      uid: 'peer',
      name: 'Stored name',
      host: '192.168.1.10',
      around: true,
      auth: true,
    );
    final visibleLost = _device(
      uid: 'peer',
      name: 'Current name',
      host: '192.168.1.30',
      around: false,
      auth: true,
    );

    final reconciled = reconcileDiscoveryDeviceList(
      currentDevices: <DeviceData>[
        _device(
          uid: 'peer',
          name: 'Nearby name',
          host: '192.168.1.20',
          around: true,
        ),
      ],
      peerId: 'peer',
      isLost: true,
      storedDevice: stored,
      visibleDevice: visibleLost,
    );

    expect(reconciled, hasLength(1));
    expect(reconciled.single.name, 'Current name');
    expect(reconciled.single.host, '192.168.1.30');
    expect(reconciled.single.around, isFalse);
    expect(reconciled.single.auth, isTrue);
  });

  test('lost unpersisted discovery candidate is removed instead of retained',
      () {
    final visibleLost = _device(
      uid: 'ephemeral',
      name: 'Ephemeral',
      host: '192.168.1.40',
      around: false,
    );

    final reconciled = reconcileDiscoveryDeviceList(
      currentDevices: <DeviceData>[
        _device(
          uid: 'ephemeral',
          name: 'Ephemeral',
          host: '192.168.1.40',
          around: true,
        ),
      ],
      peerId: 'ephemeral',
      isLost: true,
      storedDevice: null,
      visibleDevice: visibleLost,
    );

    expect(reconciled, isEmpty);
  });
}
