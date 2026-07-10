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
    expect(source, contains('final peerId = session.remotePeerId'));
    expect(
      source,
      contains('_heartBeat(peerId: peerId, sink: channelSink)'),
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

  test('media accept binds one token to authenticated directional keys', () {
    expect(source, contains('_sessionUpgradeTokens.issue('));
    expect(source, contains('mediaMacKey: mediaReceiveKey'));
    expect(source, contains('mediaSendKey: session.mediaSendKey'));
    expect(source, contains("route: '/audio'"));
    expect(source, contains("route: '/input'"));
    expect(source, contains('withTransportToken('));
    expect(source, contains('claimValidator: _isExpectedMediaPeerClaim'));
    expect(source, contains('constantTimeBytesEqual(mediaReceiveKey'));
  });

  test('terminal controls and lifecycle cleanup release media claims', () {
    expect(source, contains('_sessionUpgradeTokens.revoke('));
    expect(source, contains('_sessionUpgradeTokens.clearPeer(peerId)'));
    expect(source, contains('_sessionUpgradeTokens.clearAll()'));
    expect(source, contains('_wireControlSessions.forget('));
    expect(source, contains('_audioManager.closePeerChannels(peerId)'));
    expect(source, contains('_remoteInputManager.closePeerChannels(peerId)'));
    expect(source, contains('namespace: namespace'));
  });

  test('new peer generation revokes only superseded media keys', () {
    expect(source, contains('await _closeSupersededMediaChannels(session);'));
    expect(
      source,
      contains('_audioManager.closeSupersededPeerChannels('),
    );
    expect(
      source,
      contains('_remoteInputManager.closeSupersededPeerChannels('),
    );
    expect(source, contains('mediaMacKey: mediaReceiveKey'));
  });

  test('outgoing stale control binding returns false instead of throwing', () {
    final start = source.indexOf('bool _validateOutgoingControlSession(');
    final end = source.indexOf('String? _issueSessionUpgradeToken(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final validation = source.substring(start, end);

    expect(validation, contains('return result.isAccepted;'));
    expect(validation, isNot(contains('.requireAccepted()')));
  });

  test('audio group token issuance binds the accepted group and stream', () {
    final start = source.indexOf('Future<bool> sendAudioGroupControlTo(');
    final end = source.indexOf('Future<bool> sendRemoteInputControl(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final sendGroup = source.substring(start, end);

    expect(
      sendGroup,
      contains('acceptedGroup?.groupId != control.groupId'),
    );
    expect(
      sendGroup,
      contains('acceptedGroup?.streamId != control.streamId'),
    );
  });
}
