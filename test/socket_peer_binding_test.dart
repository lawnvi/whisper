import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/wire_input_policy.dart';

void main() {
  final source = File('lib/socket/svrmanager.dart').readAsStringSync();

  test('authenticated business input requires the current peer generation', () {
    expect(source, contains('_requireCurrentBusinessSession('));
    expect(source, contains('_sessionsByPeerId[peerId]'));
    expect(source, contains('_peerConnections.isCurrent('));
    expect(source, contains('WireInputPolicy.validateMessage('));
  });

  test('file frames carry the authenticated session peer into the engine', () {
    expect(
      source,
      contains('requireCurrent: () => _requireCurrentBusinessSession('),
    );
  });

  test('client heartbeat timer captures its authenticated peer', () {
    expect(
      source,
      contains('_heartBeat(peerId: session.remotePeerId, sink: channelSink)'),
    );
    expect(source, isNot(contains('_heartBeat(sink: channelSink)')));
  });

  test('ACK construction swaps sender and receiver', () {
    final start = source.indexOf('Future<void> _ackMessage(');
    final end = source.indexOf('Future<void> _heartBeat(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final ack = source.substring(start, end);
    expect(ack, contains('json["sender"] = data.receiver'));
    expect(ack, contains('json["receiver"] = data.sender'));
  });

  test('session binding rejects a socket replaced by a newer generation', () {
    expect(
      WireInputPolicy.validateSessionBinding(
        isAuthenticated: true,
        sessionPeerId: 'peer-a',
        sinkPeerId: 'peer-a',
        sessionGeneration: 7,
        isCurrentSession: true,
        isCurrentConnection: true,
      ).isAccepted,
      isTrue,
    );
    expect(
      WireInputPolicy.validateSessionBinding(
        isAuthenticated: true,
        sessionPeerId: 'peer-a',
        sinkPeerId: 'peer-a',
        sessionGeneration: 7,
        isCurrentSession: false,
        isCurrentConnection: false,
      ).reason,
      WireInputReason.sessionNotCurrent,
    );
  });

  test(
      'authenticated control routing never falls back to another selected peer',
      () {
    final start = source.indexOf('Future<void> _listen(');
    final end = source.indexOf('MessageData _buildMessage(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final listen = source.substring(start, end);

    expect(listen, isNot(contains('?? _selectedRemoteProfile')));
    expect(listen, contains('_requireRemoteProfileForSession('));
  });

  test('control session ids are bound before coordinator side effects', () {
    expect(source, contains('WireControlSessionRegistry'));
    expect(source, contains("namespace: 'audio'"));
    expect(source, contains("namespace: 'audio-group'"));
    expect(source, contains("namespace: 'remote-input'"));
    expect(source, contains('isInitialOffer:'));
    expect(source, contains('isIncoming: true'));
    expect(source, contains('isIncoming: false'));
  });

  test('peer cleanup retains active audio control continuations', () {
    expect(source, contains('_preservedControlSessionsForPeer('));
    expect(source, contains('AudioShareCoordinator.shared.state'));
    expect(source, contains('AudioGroupCoordinator.shared.session'));
    expect(source, contains('AudioGroupCoordinator.shared.rejoinSessionId'));
    expect(source, contains('preservedSessions:'));
  });
}
