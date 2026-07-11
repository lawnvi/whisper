import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('discovered devices persist fresh network addresses', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final discovery = source.substring(
      source.indexOf(
        'case BonsoirDiscoveryEventType.discoveryServiceResolved',
      ),
      source.indexOf(
          'case BonsoirDiscoveryEventType.discoveryServiceResolveFailed'),
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

  test('lost services clear persisted nearby state without TXT attributes', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final discovery = source.substring(
      source.indexOf(
        'case BonsoirDiscoveryEventType.discoveryServiceResolved',
      ),
      source.indexOf(
        'case BonsoirDiscoveryEventType.discoveryServiceResolveFailed',
      ),
    );
    final refresh = source.substring(
      source.indexOf('Future<void> _refreshDevice'),
      source.indexOf('ChatSessionPreviewStrings _sessionPreviewStrings'),
    );

    expect(discovery, contains('_discoveryPresence.lost('));
    expect(discovery, contains('peerIdHint: advertisedUid'));
    expect(
      discovery,
      contains('await db.setDeviceDiscoveryPresence(uid, !isLost)'),
    );
    expect(discovery, isNot(contains('devices.insert(index, temp)')));
    expect(refresh, contains('await db.clearDeviceDiscoveryPresence()'));
  });
}
