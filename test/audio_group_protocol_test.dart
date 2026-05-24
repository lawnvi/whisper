import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  const format = AudioStreamFormat(
    codec: AudioCodecKind.opus,
    sampleRate: 48000,
    channels: 2,
    frameDurationMs: 20,
    bitRate: 128000,
  );

  test('AudioGroupControlMessage round-trips group offer fields', () {
    const message = AudioGroupControlMessage(
      action: AudioGroupControlAction.groupOffer,
      groupId: 'group-1',
      streamId: 'stream-1',
      sessionId: 'session-1',
      sourcePeerId: 'mac',
      sinkPeerId: 'phone-left',
      sinkPeerIds: <String>['phone-left', 'phone-right'],
      format: format,
      transport: AudioTransport.websocket,
      path: '/audio',
      channelRole: AudioChannelRole.left,
      targetLatencyMs: 160,
      sentAtMicros: 100,
      receivedAtMicros: 120,
      sinkClockMicros: 140,
      playbackCursorMicros: 160,
      clockOffsetMicros: 180,
      rttMicros: 200,
      jitterMicros: 20,
      bufferDepthMicros: 42000,
      latePacketCount: 3,
      syncErrorMicros: 7000,
    );

    final json = message.toJson();
    expect(json, isNot(containsPair('enqueueLatePacketCount', anything)));
    expect(json, isNot(containsPair('pumpLatePacketCount', anything)));
    expect(json, isNot(containsPair('minArrivalLeadMicros', anything)));
    expect(json, isNot(containsPair('minPumpLeadMicros', anything)));

    final decoded = AudioGroupControlMessage.fromJson(json);

    expect(decoded.action, AudioGroupControlAction.groupOffer);
    expect(decoded.groupId, 'group-1');
    expect(decoded.streamId, 'stream-1');
    expect(decoded.sessionId, 'session-1');
    expect(decoded.sourcePeerId, 'mac');
    expect(decoded.sinkPeerId, 'phone-left');
    expect(decoded.sinkPeerIds, <String>['phone-left', 'phone-right']);
    expect(decoded.channelRole, AudioChannelRole.left);
    expect(decoded.targetLatencyMs, 160);
    expect(decoded.sentAtMicros, 100);
    expect(decoded.receivedAtMicros, 120);
    expect(decoded.sinkClockMicros, 140);
    expect(decoded.playbackCursorMicros, 160);
    expect(decoded.clockOffsetMicros, 180);
    expect(decoded.rttMicros, 200);
    expect(decoded.jitterMicros, 20);
    expect(decoded.bufferDepthMicros, 42000);
    expect(decoded.latePacketCount, 3);
    expect(decoded.syncErrorMicros, 7000);
    expect(decoded.format, format);
  });

  test('AudioGroupPacketFrame encodes synchronized stream metadata', () {
    final packet = AudioGroupPacketFrame(
      groupId: 'group-1',
      streamId: 'stream-1',
      sessionId: 'session-1',
      sourcePeerId: 'mac',
      sequence: 42,
      captureTimeMicros: 1000,
      targetPlaybackTimeMicros: 1200,
      durationMicros: 20000,
      channelMask: AudioChannelMask.stereo,
      payload: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );

    final decoded = AudioGroupPacketFrame.decode(packet.encode());

    expect(decoded.groupId, 'group-1');
    expect(decoded.streamId, 'stream-1');
    expect(decoded.sessionId, 'session-1');
    expect(decoded.sourcePeerId, 'mac');
    expect(decoded.sequence, 42);
    expect(decoded.captureTimeMicros, 1000);
    expect(decoded.targetPlaybackTimeMicros, 1200);
    expect(decoded.durationMicros, 20000);
    expect(decoded.channelMask, AudioChannelMask.stereo);
    expect(decoded.payload, <int>[1, 2, 3, 4]);
  });

  test('AudioGroupPacketFrame rejects legacy audio packet magic', () {
    final legacy = AudioPacketFrame(
      sessionId: 'audio-1',
      sequence: 1,
      captureTimeMicros: 10,
      payload: Uint8List.fromList(<int>[1]),
    ).encode();

    expect(
      () => AudioGroupPacketFrame.decode(legacy),
      throwsA(isA<FormatException>()),
    );
  });

  test('PeerCapabilities round-trips audio group flags', () {
    final profile = PeerProfile(
      device: DeviceData(
        id: 1,
        uid: 'peer-a',
        name: 'Peer A',
        host: '127.0.0.1',
        port: 9000,
        password: '',
        platform: 'macos',
        isServer: true,
        online: true,
        clipboard: true,
        auth: true,
        lastTime: 1,
        around: true,
      ),
      trustedPeerIds: const <String>['peer-b'],
      autoApproveNewDevices: false,
      autoConnectEnabled: true,
      protocolVersion: 5,
      capabilities: const PeerCapabilities(
        audioGroupSourceV1: true,
        audioGroupSinkV1: true,
        audioSyncClockV1: true,
        audioChannelRoleV1: true,
      ),
    );

    final decoded = PeerProfile.fromJson(profile.toJson());

    expect(decoded.capabilities.audioGroupSourceV1, isTrue);
    expect(decoded.capabilities.audioGroupSinkV1, isTrue);
    expect(decoded.capabilities.audioSyncClockV1, isTrue);
    expect(decoded.capabilities.audioChannelRoleV1, isTrue);
  });

  test('legacy capabilities default audio group flags to false', () {
    final capabilities = PeerCapabilities.fromJson(const <String, dynamic>{});

    expect(capabilities.audioGroupSourceV1, isFalse);
    expect(capabilities.audioGroupSinkV1, isFalse);
    expect(capabilities.audioSyncClockV1, isFalse);
    expect(capabilities.audioChannelRoleV1, isFalse);
  });

  test('AudioGroupControl is appended after remote input control', () {
    expect(
      MessageEnum.AudioGroupControl.index,
      MessageEnum.RemoteInputControl.index + 1,
    );
  });
}
