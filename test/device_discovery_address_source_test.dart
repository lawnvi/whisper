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
    expect(discovery, contains('svr is ResolvedBonsoirService'));
    expect(discovery, contains('await resolveDiscoveryEndpointHost('));
    expect(discovery, contains('resolvedHost: resolvedHost'));
    expect(discovery, contains('advertisedHost: host'));
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

  test('deleted nearby peers stay hidden until their service is lost', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains('socketManager.shouldSuppressDiscoveredPeer(uid)'));
    expect(
      source,
      contains('socketManager.releaseDeletedPeerDiscoverySuppression(uid)'),
    );
    expect(source, contains('devices.removeWhere((item) => item.uid == uid)'));
  });

  test('conversation settings reports deletion back to the device list', () {
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    expect(deviceList, contains('onDeviceDeleted: _removeDevice'));
    expect(conversation, contains('deleteDevice: widget.onDeviceDeleted'));
    expect(
      deviceList,
      contains('if (!socketManager.isConnectedTo(deviceItem.uid))'),
    );
  });
}
