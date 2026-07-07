import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  group('PeerProfile audio capabilities', () {
    test('round-trips audio source, speaker sink, and remote input flags', () {
      final profile = PeerProfile(
        device: DeviceData(
          id: 1,
          uid: 'peer-a',
          name: 'Peer A',
          host: '127.0.0.1',
          port: 9000,
          password: '',
          platform: 'windows',
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
        protocolVersion: 3,
        capabilities: const PeerCapabilities(
          systemAudioSourceV1: true,
          speakerSinkV1: true,
          remoteInputSourceV1: true,
          remoteInputSinkV1: true,
        ),
      );

      final decoded = PeerProfile.fromJson(profile.toJson());

      expect(decoded.capabilities.systemAudioSourceV1, isTrue);
      expect(decoded.capabilities.speakerSinkV1, isTrue);
      expect(decoded.capabilities.remoteInputSourceV1, isTrue);
      expect(decoded.capabilities.remoteInputSinkV1, isTrue);
    });

    test('legacy capability payload defaults new realtime flags to false', () {
      final profile = PeerProfile.fromJson(<String, dynamic>{
        'device': <String, dynamic>{
          'id': 1,
          'uid': 'peer-a',
          'name': 'Peer A',
          'host': '127.0.0.1',
          'port': 9000,
          'platform': 'macos',
          'isServer': true,
          'online': true,
          'clipboard': true,
          'auth': true,
          'lastTime': 1,
          'around': true,
        },
        'trustedPeerIds': <String>[],
        'autoApproveNewDevices': false,
        'autoConnectEnabled': true,
        'protocolVersion': 2,
        'capabilities': <String, dynamic>{},
      });

      expect(profile.capabilities.systemAudioSourceV1, isFalse);
      expect(profile.capabilities.speakerSinkV1, isFalse);
      expect(profile.capabilities.remoteInputSourceV1, isFalse);
      expect(profile.capabilities.remoteInputSinkV1, isFalse);
    });
  });

  group('AudioControlMessage', () {
    test('uses an appended message enum value for backward compatibility', () {
      expect(MessageEnum.AudioControl.index,
          MessageEnum.TransferControl.index + 1);
    });

    test('round-trips offer fields and audio format', () {
      const format = AudioStreamFormat(
        codec: AudioCodecKind.opus,
        sampleRate: 48000,
        channels: 2,
        frameDurationMs: 20,
        bitRate: 128000,
      );
      const message = AudioControlMessage(
        action: AudioControlAction.offer,
        sessionId: 'audio-1',
        sourcePeerId: 'peer-a',
        sinkPeerId: 'peer-b',
        format: format,
        transport: AudioTransport.websocket,
        path: '/audio',
      );

      final decoded = AudioControlMessage.fromJson(message.toJson());

      expect(decoded.action, AudioControlAction.offer);
      expect(decoded.sessionId, 'audio-1');
      expect(decoded.sourcePeerId, 'peer-a');
      expect(decoded.sinkPeerId, 'peer-b');
      expect(decoded.format, format);
      expect(decoded.transport, AudioTransport.websocket);
      expect(decoded.path, '/audio');
    });

    test('round-trips error messages without a format', () {
      const message = AudioControlMessage(
        action: AudioControlAction.error,
        sessionId: 'audio-1',
        sourcePeerId: 'peer-a',
        sinkPeerId: 'peer-b',
        errorMessage: 'capture permission denied',
      );

      final decoded = AudioControlMessage.fromJson(message.toJson());

      expect(decoded.action, AudioControlAction.error);
      expect(decoded.format, isNull);
      expect(decoded.errorMessage, 'capture permission denied');
    });
  });

  group('AudioGroupControlMessage', () {
    test('sinkJoinRequest action roundtrips and unknown falls back to error',
        () {
      const msg = AudioGroupControlMessage(
        action: AudioGroupControlAction.sinkJoinRequest,
        groupId: 'g',
        streamId: 's',
        sessionId: 'sess',
        sourcePeerId: 'src',
        sinkPeerId: 'sink',
      );
      final decoded = AudioGroupControlMessage.fromJson(msg.toJson());
      expect(decoded.action, AudioGroupControlAction.sinkJoinRequest);

      final unknown = AudioGroupControlMessage.fromJson(<String, dynamic>{
        ...msg.toJson(),
        'action': 'someFutureAction',
      });
      expect(unknown.action, AudioGroupControlAction.error);
    });
  });

  group('AudioPacketFrame', () {
    test('encodes and decodes Opus packet metadata and payload', () {
      final frame = AudioPacketFrame(
        sessionId: 'audio-1',
        sequence: 42,
        captureTimeMicros: 123456,
        payload: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
      );

      final encoded = frame.encode();
      final decoded = AudioPacketFrame.decode(encoded);

      expect(decoded.sessionId, 'audio-1');
      expect(decoded.sequence, 42);
      expect(decoded.captureTimeMicros, 123456);
      expect(decoded.payload, <int>[1, 2, 3, 4, 5]);
    });

    test('rejects packets without the audio packet magic header', () {
      final badPacket = Uint8List.fromList(<int>[0, 1, 2, 3, 4]);

      expect(
        () => AudioPacketFrame.decode(badPacket),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
