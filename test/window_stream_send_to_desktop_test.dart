import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "送到 ‹设备›" works towards any Whisper peer, and a desktop shows what it
/// is sent.
void main() {
  test('any Whisper peer can be sent a window, not only an adb phone', () {
    final page = File(
      'lib/page/window_stream/flow_space_page.dart',
    ).readAsStringSync();
    final send = page.substring(page.indexOf('String? _sendPeerOf('));
    expect(
      send.substring(0, send.indexOf('\n  }\n')),
      allOf(
        contains('supportsWindowStreamSource()'),
        contains('if (source is RemotePeerSource) {'),
        contains('return source.peerId;'),
        contains('_coordinator.peerIdFor(source)'),
      ),
    );
  });

  test('a desktop opens windows sent to it in windows of their own', () {
    final main = File('lib/main.dart').readAsStringSync();
    final desktop = main.substring(main.indexOf('if (isDesktop()) {'));
    expect(
      desktop.substring(0, desktop.indexOf('\n  }\n')),
      contains('DesktopOfferOpener.shared.start();'),
    );
    final opener = File(
      'lib/page/window_stream/flow_desktop_offers.dart',
    ).readAsStringSync();
    expect(opener, contains('viewer.settleOffer(offer);'));
    expect(opener, contains('openFlowWindow('));
    // Sent again while open: the open window comes forward.
    expect(opener, contains('_streams.focus(session);'));
  });
}
