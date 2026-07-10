import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_packet_transport.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/audio/audio_share_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const format = AudioStreamFormat(
    codec: AudioCodecKind.pcmS16le,
    sampleRate: 48000,
    channels: 2,
    frameDurationMs: 20,
    bitRate: 128000,
  );
  final mediaKey = Uint8List.fromList(List<int>.generate(32, (index) => index));

  group('AudioShareCoordinator', () {
    late MethodChannel channel;
    late List<MethodCall> calls;
    late AudioPlatform platform;

    setUp(() {
      channel = const MethodChannel('test_audio_share_coordinator');
      calls = <MethodCall>[];
      platform = AudioPlatform(channel: channel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('source starts capture and sends packets after an offer is accepted',
        () async {
      final transport = _FakeAudioTransport();
      final sentControls = <AudioControlMessage>[];
      final manager = AudioShareManager();
      final coordinator = AudioShareCoordinator(
        manager: manager,
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (uri) async {
          expect(uri.path, '/audio');
          expect(uri.queryParameters['session'], isNotEmpty);
          expect(uri.queryParameters['token'], 'audio-token');
          return transport;
        },
      );

      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: 'pc',
        sinkPeerId: 'phone',
        sinkHost: 'phone.local',
        sinkPort: 10002,
        sendControl: sentControls.add,
        format: format,
      );

      final offer = sentControls.single;
      expect(offer.action, AudioControlAction.offer);

      await coordinator.handleControlMessage(
        AudioControlMessage(
          action: AudioControlAction.accept,
          sessionId: offer.sessionId,
          sourcePeerId: 'pc',
          sinkPeerId: 'phone',
          format: format,
          path: '/audio',
          transportToken: 'audio-token',
        ),
        localPeerId: 'pc',
        remoteHost: 'phone.local',
        remotePort: 10002,
        mediaSendKey: mediaKey,
        sendControl: sentControls.add,
      );

      expect(calls.map((call) => call.method), contains('startCapture'));

      await platform.handleNativeMethodCall(
        MethodCall('onCapturePcm', <String, dynamic>{
          'sessionId': offer.sessionId,
          'sequence': 7,
          'captureTimeMicros': 1234,
          'pcm': Uint8List(format.frameSize * format.channels * 2),
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(transport.sentPackets, hasLength(1));
      expect(transport.sentPackets.single.sessionId, offer.sessionId);
      expect(transport.sentPackets.single.sequence, 0);
    });

    test('source reports an audio control error when capture is denied',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'startCapture') {
          throw PlatformException(
            code: 'audio-capture-permission-denied',
            message: 'Screen recording permission denied',
          );
        }
        return null;
      });

      final transport = _FakeAudioTransport();
      final sentControls = <AudioControlMessage>[];
      final manager = AudioShareManager();
      final coordinator = AudioShareCoordinator(
        manager: manager,
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (_) async => transport,
      );

      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: 'pc',
        sinkPeerId: 'phone',
        sinkHost: 'phone.local',
        sinkPort: 10002,
        sendControl: sentControls.add,
        format: format,
      );

      final offer = sentControls.single;
      await coordinator.handleControlMessage(
        AudioControlMessage(
          action: AudioControlAction.accept,
          sessionId: offer.sessionId,
          sourcePeerId: 'pc',
          sinkPeerId: 'phone',
          format: format,
          path: '/audio',
        ),
        localPeerId: 'pc',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: sentControls.add,
      );

      expect(sentControls.last.action, AudioControlAction.error);
      expect(sentControls.last.errorMessage, contains('Screen recording'));
      expect(coordinator.state.status, AudioShareRuntimeStatus.failed);
      expect(transport.closed, isTrue);
    });

    test('sink auto-accepts offers and writes received packets to playback',
        () async {
      final sentControls = <AudioControlMessage>[];
      final manager = AudioShareManager();
      final coordinator = AudioShareCoordinator(
        manager: manager,
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (_) async => _FakeAudioTransport(),
        playbackGainProvider: () async => 2.0,
      );

      final offer = AudioControlMessage(
        action: AudioControlAction.offer,
        sessionId: 'audio-1',
        sourcePeerId: 'pc',
        sinkPeerId: 'phone',
        format: format,
        path: '/audio',
      );

      await coordinator.handleControlMessage(
        offer,
        localPeerId: 'phone',
        remoteHost: 'pc.local',
        remotePort: 10002,
        sendControl: sentControls.add,
      );

      expect(sentControls.single.action, AudioControlAction.accept);
      expect(calls.map((call) => call.method), contains('startPlayback'));

      manager.handlePacketBytes(
        AudioPacketFrame(
          sessionId: 'audio-1',
          sequence: 1,
          captureTimeMicros: 99,
          payload: Uint8List.fromList(<int>[1, 0, 2, 0]),
        ).encode(),
      );
      await Future<void>.delayed(Duration.zero);

      expect(calls.map((call) => call.method), contains('writePcm'));
      final writeCall = calls.singleWhere((call) => call.method == 'writePcm');
      final arguments = writeCall.arguments as Map<Object?, Object?>;
      expect(arguments['pcm'], Uint8List.fromList(<int>[2, 0, 4, 0]));
    });

    test('sink rolls back playback when sending the accept fails', () async {
      final sentControls = <AudioControlMessage>[];
      final manager = AudioShareManager();
      final coordinator = AudioShareCoordinator(
        manager: manager,
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (_) async => _FakeAudioTransport(),
        playbackGainProvider: () async => 1.0,
      );
      void sendControl(AudioControlMessage control) {
        sentControls.add(control);
        if (control.action == AudioControlAction.accept) {
          throw StateError('upgrade token registry is full');
        }
      }

      await coordinator.handleControlMessage(
        const AudioControlMessage(
          action: AudioControlAction.offer,
          sessionId: 'audio-send-failure',
          sourcePeerId: 'pc',
          sinkPeerId: 'phone',
          format: format,
          path: '/audio',
        ),
        localPeerId: 'phone',
        remoteHost: 'pc.local',
        remotePort: 10002,
        sendControl: sendControl,
      );

      expect(sentControls.map((message) => message.action), <Object>[
        AudioControlAction.accept,
        AudioControlAction.error,
      ]);
      expect(coordinator.state.status, AudioShareRuntimeStatus.failed);
      expect(calls.map((call) => call.method), contains('stopPlayback'));
    });

    test('rejects a competing offer while an audio session is live', () async {
      final sentControls = <AudioControlMessage>[];
      final manager = AudioShareManager();
      final coordinator = AudioShareCoordinator(
        manager: manager,
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (_) async => _FakeAudioTransport(),
        playbackGainProvider: () async => 1.0,
      );

      await coordinator.handleControlMessage(
        const AudioControlMessage(
          action: AudioControlAction.offer,
          sessionId: 'audio-1',
          sourcePeerId: 'pc-a',
          sinkPeerId: 'phone',
          format: format,
          path: '/audio',
        ),
        localPeerId: 'phone',
        remoteHost: 'pc-a.local',
        remotePort: 10002,
        sendControl: sentControls.add,
      );

      await coordinator.handleControlMessage(
        const AudioControlMessage(
          action: AudioControlAction.offer,
          sessionId: 'audio-2',
          sourcePeerId: 'pc-b',
          sinkPeerId: 'phone',
          format: format,
          path: '/audio',
        ),
        localPeerId: 'phone',
        remoteHost: 'pc-b.local',
        remotePort: 10002,
        sendControl: sentControls.add,
      );

      expect(sentControls.first.action, AudioControlAction.accept);
      expect(sentControls.last.action, AudioControlAction.reject);
      expect(sentControls.last.sessionId, 'audio-2');
      expect(coordinator.state.sessionId, 'audio-1');
      expect(coordinator.state.status, AudioShareRuntimeStatus.active);
    });

    test('does not start a second local audio sharing session', () async {
      final transport = _FakeAudioTransport();
      final sentControls = <AudioControlMessage>[];
      final manager = AudioShareManager();
      final coordinator = AudioShareCoordinator(
        manager: manager,
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (_) async => transport,
      );

      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: 'pc',
        sinkPeerId: 'phone-a',
        sinkHost: 'phone-a.local',
        sinkPort: 10002,
        sendControl: sentControls.add,
        format: format,
      );
      final offer = sentControls.single;
      await coordinator.handleControlMessage(
        AudioControlMessage(
          action: AudioControlAction.accept,
          sessionId: offer.sessionId,
          sourcePeerId: 'pc',
          sinkPeerId: 'phone-a',
          format: format,
          path: '/audio',
        ),
        localPeerId: 'pc',
        remoteHost: 'phone-a.local',
        remotePort: 10002,
        sendControl: sentControls.add,
      );

      await expectLater(
        coordinator.startSharingToConnectedPeer(
          sourcePeerId: 'pc',
          sinkPeerId: 'phone-b',
          sinkHost: 'phone-b.local',
          sinkPort: 10002,
          sendControl: sentControls.add,
          format: format,
        ),
        throwsA(isA<StateError>()),
      );
      expect(coordinator.state.sessionId, offer.sessionId);
      expect(coordinator.state.peerId, 'phone-a');
      expect(sentControls, hasLength(1));
    });
  });
}

Future<AudioCodec> _pcmCodec(AudioStreamFormat format) async {
  return PcmPassthroughAudioCodec(
    AudioCodecConfig.fromStreamFormat(format),
  );
}

class _FakeAudioTransport implements AudioPacketTransport {
  final sentPackets = <AudioPacketFrame>[];
  bool closed = false;

  @override
  void send(AudioPacketFrame packet) {
    if (!closed) {
      sentPackets.add(packet);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
