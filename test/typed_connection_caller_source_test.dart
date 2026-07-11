import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _section(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'missing $start');
  final endIndex = source.indexOf(end, startIndex);
  expect(endIndex, greaterThan(startIndex), reason: 'missing $end');
  return source.substring(startIndex, endIndex);
}

void main() {
  test('device list applies typed results only through its current generation',
      () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final connect = _section(
      source,
      'Future<void> _connectServerInternal(',
      'Future<void> _attemptAutoConnect()',
    );
    final dispose = _section(source, 'void dispose()', 'Future<void> _stopClipboardWatcher');

    expect(source, contains('final ConnectionAttemptTracker _connectionAttempts'));
    expect(connect, contains('ConnectionAttemptRequest('));
    expect(connect, contains('_connectionAttempts.isCurrent('));
    expect(connect, contains('finally {'));
    expect(
      connect.indexOf('_connectionAttempts.isCurrent('),
      lessThan(connect.indexOf('socketManager.selectPeer(')),
    );
    expect(dispose, contains('_connectionAttempts.cancelAll()'));
  });

  test('conversation awaits auth directly without callback or polling', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final connect = _section(
      source,
      'Future<bool> _connectServer(',
      'Future<bool> _restoreConnectionIfNeeded()',
    );
    final restore = _section(
      source,
      'Future<bool> _restoreConnectionIfNeeded()',
      'Future<void> _toggleAudioShare()',
    );

    expect(connect, contains('await socketManager.connectToServer('));
    expect(connect, contains('_connectionAttempts.isCurrent('));
    expect(connect, contains('finally {'));
    expect(connect, isNot(contains('Completer<bool>')));
    expect(restore, isNot(contains('Future.delayed')));
    expect(restore, isNot(contains('for (var i = 0; i < 20')));
  });

  test('connection callers show a dedicated peer rejection message', () {
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    final deviceConnect = _section(
      deviceList,
      'Future<void> _connectServerInternal(',
      'Future<void> _attemptAutoConnect()',
    );
    final conversationConnect = _section(
      conversation,
      'Future<bool> _connectServer(',
      'Future<bool> _restoreConnectionIfNeeded()',
    );

    for (final connect in <String>[deviceConnect, conversationConnect]) {
      expect(
        connect,
        contains('ConnectionAttemptReason.peerRejected'),
      );
      expect(connect, contains('pairingRejectedByPeer'));
    }
  });

  test('peer rejection message is localized in every supported language', () {
    const expected = <String, String>{
      'zh': '对方拒绝了连接请求',
      'en': 'The other device declined the connection request',
      'es': 'El otro dispositivo rechazó la solicitud de conexión',
    };

    for (final entry in expected.entries) {
      final arb = jsonDecode(
        File('lib/l10n/app_${entry.key}.arb').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(arb['pairingRejectedByPeer'], entry.value);
    }
  });

  test('settings policy mutations pass through the socket manager', () {
    final source = File('lib/page/settings.dart').readAsStringSync();

    expect(source, contains('setAutoConnectPolicy(value)'));
    expect(source, contains('setPeerTrust(device.uid, value)'));
    expect(source, contains('deletePeer(device.uid)'));
    expect(
      source,
      isNot(contains('LocalSetting().setAutoConnectEnabled(value)')),
    );
  });

  test('client registration cannot select a peer before the caller guard', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final register = _section(
      source,
      'Future<void> _registerPeerConnection(',
      'Future<void> _handlePeerSocketDoneQueued(',
    );

    expect(register, contains('session.role == PeerSocketRole.server'));
    expect(register, isNot(contains('session.role == PeerSocketRole.client &&')));

    final reconnectRecord = _section(
      source,
      'void _recordAuthenticatedReconnect(',
      'void _invalidatePeerPolicy(',
    );
    expect(reconnectRecord, contains('request.endpoint'));
    expect(reconnectRecord, isNot(contains('device.host')));
  });
}
