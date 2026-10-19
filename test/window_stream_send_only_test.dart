import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/page/window_stream/flow_space_controller.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/window_stream_coordinator.dart';

/// A device that only shows windows sent to it (an iPad) is in Flow on a
/// desktop too, with "送到" and nothing else; an adb phone is in Flow only
/// while its Whisper is connected, like every other device.
void main() {
  final viewer = WindowStreamViewer.shared;
  const ipad = WindowStreamPeer(
    peerId: 'ipad',
    name: 'iPad',
    platform: WindowStreamPlatform.ios,
    takesWindows: true,
  );

  tearDown(() {
    viewer.peerDisconnected('ipad');
    viewer.peerDisconnected('mac');
  });

  test('connected peers that take windows are targets', () {
    var changes = 0;
    void listener() => changes++;
    viewer.addListener(listener);
    addTearDown(() => viewer.removeListener(listener));
    viewer.peerConnected(ipad);
    expect(viewer.isConnected('ipad'), isTrue);
    expect(viewer.targets.map((peer) => peer.peerId), ['ipad']);
    expect(changes, 1);
    // The same profile again changes nothing.
    viewer.peerConnected(ipad);
    expect(changes, 1);
    viewer.peerConnected(
      const WindowStreamPeer(
        peerId: 'old',
        name: 'Old',
        platform: WindowStreamPlatform.macos,
        takesWindows: false,
      ),
    );
    expect(viewer.targets.map((peer) => peer.peerId), ['ipad']);
    viewer.peerDisconnected('old');
    viewer.peerDisconnected('ipad');
    expect(viewer.isConnected('ipad'), isFalse);
    expect(viewer.targets, isEmpty);
  });

  test('a send-only device is chosen with "送到", sources still first', () {
    final controller = FlowSpaceController(
      coordinator: WindowStreamCoordinator.shared,
    );
    addTearDown(controller.dispose);
    viewer.peerConnected(ipad);
    expect(controller.sendOnly.map((peer) => peer.peerId), ['ipad']);
    // Nothing else there: the iPad is shown.
    expect(controller.selectedTarget?.peerId, 'ipad');
    expect(controller.selected, isNull);

    // A Mac that shows its windows comes: it is the one shown, the iPad
    // waits on the shelf until chosen.
    viewer.peerConnected(
      const WindowStreamPeer(
        peerId: 'mac',
        name: 'Mac',
        platform: WindowStreamPlatform.macos,
        takesWindows: true,
      ),
    );
    viewer.peerAvailable(
      peerId: 'mac',
      name: 'Mac',
      platform: WindowStreamPlatform.macos,
      host: '127.0.0.1',
      port: 1,
    );
    expect(controller.sendOnly.map((peer) => peer.peerId), ['ipad']);
    expect(controller.selectedTarget, isNull);
    expect(controller.selected?.info.name, 'Mac');
    controller.selectTarget(ipad);
    expect(controller.selectedTarget?.peerId, 'ipad');
    expect(controller.selected, isNull);
    viewer.peerDisconnected('ipad');
    expect(controller.selectedTarget, isNull);
    expect(controller.selected?.info.name, 'Mac');
  });

  test('the shelf lists send-only devices and sends to them', () {
    final page = File(
      'lib/page/window_stream/flow_space_page.dart',
    ).readAsStringSync();
    expect(page, contains('for (final peer in _controller.sendOnly)'));
    expect(page, contains('subtitle: l10n.windowStreamReceiveOnly'));
    expect(page, contains('onTap: () => _controller.selectTarget(peer)'));
    expect(page, contains("key: ValueKey('send:\${target.peerId}')"));
  });

  test('an adb phone is a source only while its Whisper is connected', () {
    final coordinator = File(
      'lib/window_stream/window_stream_coordinator.dart',
    ).readAsStringSync();
    final sources = coordinator.substring(
      coordinator.indexOf('List<WindowSource> get sources {'),
      coordinator.indexOf('bool isAdbPhoneConnected('),
    );
    expect(sources, contains('isAdbPhoneConnected(device)'));
    expect(coordinator, contains('WindowStreamViewer.shared.isConnected'));
    final page = File(
      'lib/page/window_stream/flow_space_page.dart',
    ).readAsStringSync();
    expect(page, contains('!_coordinator.isAdbPhoneConnected(device)'));
    expect(page, contains('l10n.windowStreamConnectFirst'));
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    expect(
      manager,
      contains('WindowStreamViewer.shared.peerDisconnected(peerId);'),
    );
    expect(manager, contains('WindowStreamViewer.shared.peerConnected('));
  });
}
