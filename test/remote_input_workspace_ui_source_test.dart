import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_reading.dart';

void main() {
  // The sidebar's entry, and when it lights up, are in
  // device_list_behavior_test.dart and device_list_rules_test.dart.

  test(
    'embedded conversation no longer exposes the single peer remote input action',
    () {
      final source = File('lib/page/conversation.dart').readAsStringSync();
      final shouldShowRemoteInputAction = RegExp(
        r'bool get _shouldShowRemoteInputAction \{[\s\S]*?\n  \}',
      ).firstMatch(source)!.group(0)!;

      expect(shouldShowRemoteInputAction, contains('!widget.embedded'));
    },
  );

  test('socket disconnect clears remote input workspace state', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('Future<void> _handlePeerDisconnected('));
    expect(source, contains('await _handlePeerDisconnected('));
    expect(
      source,
      contains('RemoteInputWorkspaceCoordinator.shared.handlePeerDisconnected'),
    );
    expect(
      source,
      contains('RemoteInputCoordinator.shared.state.isForPeer(peerId)'),
    );
    expect(source, contains('RemoteInputCoordinator.shared.stopLocal()'));
  });
}
