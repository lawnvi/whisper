import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_reading.dart';

void main() {
  test('discovered devices persist fresh network addresses', () {
    final source = deviceListSource();
    final discovery = source.substring(
      source.indexOf('case BonsoirDiscoveryServiceResolvedEvent() ||'),
      source.indexOf('case BonsoirDiscoveryServiceResolveFailedEvent():'),
    );

    expect(source, contains('mergeStoredDeviceWithDiscovery'));
    expect(discovery, contains('final visibleDevice'));
    expect(discovery, contains('await db.upsertDevice(visibleDevice)'));
    expect(discovery, contains('if (!isLost)'));
    expect(discovery, contains('BonsoirDiscoveryServiceUpdatedEvent() ||'));
    expect(discovery, contains('await resolveDiscoveryEndpointHost('));
    expect(discovery, contains('resolvedHost: svr.hostname'));
    expect(discovery, contains('resolvedAddresses: svr.hostAddresses'));
    expect(discovery, contains('advertisedHost: host'));
    expect(discovery, contains('port: port'));
  });

  test(
    'connected nearby devices keep fresh discovery host over stored host',
    () {
      final source = deviceListSource();
      final refresh = memberSource(source, 'Future<void> _refreshDevice');

      // What the merge itself does is in device_list_rules_test.dart.
      expect(
        refresh,
        contains(
          'mergeStoredDeviceWithDiscovery(storedDevicesByUid[item.uid], item)',
        ),
      );
      expect(refresh, isNot(contains('storedDevicesByUid[item.uid] ?? item')));
    },
  );

  test('lost services clear persisted nearby state without TXT attributes', () {
    final source = deviceListSource();
    final discovery = source.substring(
      source.indexOf('case BonsoirDiscoveryServiceResolvedEvent() ||'),
      source.indexOf('case BonsoirDiscoveryServiceResolveFailedEvent():'),
    );
    final refresh = memberSource(source, 'Future<void> _refreshDevice');

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
    final source = deviceListSource();

    expect(source, contains('socketManager.shouldSuppressDiscoveredPeer(uid)'));
    expect(
      source,
      contains('socketManager.releaseDeletedPeerDiscoverySuppression(uid)'),
    );
    expect(source, contains('devices.removeWhere((item) => item.uid == uid)'));
  });

  test('conversation settings reports deletion back to the device list', () {
    final deviceList = deviceListSource();
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    expect(deviceList, contains('onDeviceDeleted: _removeDevice'));
    expect(conversation, contains('deleteDevice: widget.onDeviceDeleted'));
  });
}
