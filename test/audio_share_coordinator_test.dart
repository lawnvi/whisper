import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_packet_transport.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

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

    test(
      'source starts capture and sends packets after an offer is accepted',
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
      },
    );

    test('duplicate accepts share one direct capture startup', () async {
      final connectStarted = Completer<void>();
      final releaseConnect = Completer<void>();
      var transportCalls = 0;
      final sentControls = <AudioControlMessage>[];
      final coordinator = AudioShareCoordinator(
        manager: AudioShareManager(),
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (_) async {
          transportCalls += 1;
          if (!connectStarted.isCompleted) {
            connectStarted.complete();
          }
          await releaseConnect.future;
          return _FakeAudioTransport();
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
      final accept = AudioControlMessage(
        action: AudioControlAction.accept,
        sessionId: offer.sessionId,
        sourcePeerId: 'pc',
        sinkPeerId: 'phone',
        format: format,
        path: '/audio',
      );

      final first = coordinator.handleControlMessage(
        accept,
        localPeerId: 'pc',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: sentControls.add,
      );
      await connectStarted.future;
      final duplicate = coordinator.handleControlMessage(
        accept,
        localPeerId: 'pc',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: sentControls.add,
      );
      await Future<void>.delayed(Duration.zero);

      expect(transportCalls, 1);
      releaseConnect.complete();
      await Future.wait(<Future<void>>[first, duplicate]);
      expect(
        calls.where((call) => call.method == 'startCapture'),
        hasLength(1),
      );
    });

    test(
      'unexpected source transport failure stops capture exactly once',
      () async {
        final transport = _ObservableFakeAudioTransport();
        final sentControls = <AudioControlMessage>[];
        final manager = AudioShareManager();
        final coordinator = AudioShareCoordinator(
          manager: manager,
          platform: platform,
          codecFactory: _pcmCodec,
          transportFactory: (_) async => transport,
        );
        var failedNotifications = 0;
        coordinator.addListener(() {
          if (coordinator.state.status == AudioShareRuntimeStatus.failed) {
            failedNotifications += 1;
          }
        });

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

        transport.fail(
          PacketTransportTermination(
            PacketTransportTerminationReason.writerFailure,
            error: StateError('write failed'),
          ),
        );
        await _waitUntil(
          () => coordinator.state.status == AudioShareRuntimeStatus.failed,
        );

        expect(coordinator.state.role, AudioShareRuntimeRole.source);
        expect(coordinator.state.errorMessage, 'transport');
        expect(
          manager.session(offer.sessionId)?.state,
          AudioShareSessionState.failed,
        );
        expect(
          calls.where((call) => call.method == 'stopCapture'),
          hasLength(1),
        );
        expect(transport.closeCount, 1);
        expect(failedNotifications, 1);

        await coordinator.stopLocal();
        await Future<void>.delayed(Duration.zero);
        expect(coordinator.state.status, AudioShareRuntimeStatus.idle);
        expect(
          calls.where((call) => call.method == 'stopCapture'),
          hasLength(1),
        );
        expect(transport.closeCount, 1);
        expect(failedNotifications, 1);
      },
    );

    test(
      'transport failure becomes stable before blocked cleanup finishes',
      () async {
        final releaseStopCapture = Completer<void>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if (call.method == 'stopCapture') {
                await releaseStopCapture.future;
              }
              return null;
            });
        final transport = _ObservableFakeAudioTransport();
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

        transport.fail(
          const PacketTransportTermination(
            PacketTransportTerminationReason.remoteClosed,
          ),
        );
        await _waitUntil(
          () => calls.any((call) => call.method == 'stopCapture'),
        );

        expect(coordinator.state.status, AudioShareRuntimeStatus.failed);
        expect(coordinator.state.errorMessage, 'transport');
        expect(
          manager.session(offer.sessionId)?.state,
          AudioShareSessionState.failed,
        );
        expect(releaseStopCapture.isCompleted, isFalse);

        final restartedControls = <AudioControlMessage>[];
        final restarting = coordinator.startSharingToConnectedPeer(
          sourcePeerId: 'pc',
          sinkPeerId: 'tablet',
          sinkHost: 'tablet.local',
          sinkPort: 10002,
          sendControl: restartedControls.add,
          format: format,
        );
        await Future<void>.delayed(Duration.zero);
        expect(restartedControls, isEmpty);

        releaseStopCapture.complete();
        await _waitUntil(() => transport.closeCount == 1);
        await restarting;
        expect(restartedControls, hasLength(1));
      },
    );

    test(
      'intentional source stop does not become a transport failure',
      () async {
        final transport = _ObservableFakeAudioTransport();
        final sentControls = <AudioControlMessage>[];
        final coordinator = AudioShareCoordinator(
          manager: AudioShareManager(),
          platform: platform,
          codecFactory: _pcmCodec,
          transportFactory: (_) async => transport,
        );
        var failedNotifications = 0;
        coordinator.addListener(() {
          if (coordinator.state.status == AudioShareRuntimeStatus.failed) {
            failedNotifications += 1;
          }
        });

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

        await coordinator.stopLocal();
        await Future<void>.delayed(Duration.zero);

        expect(coordinator.state.status, AudioShareRuntimeStatus.idle);
        expect(failedNotifications, 0);
        expect(transport.closeCount, 1);
        expect(
          calls.where((call) => call.method == 'stopCapture'),
          hasLength(1),
        );
      },
    );

    test(
      'direct stop waits for pending native capture start then stops it',
      () async {
        final startEntered = Completer<void>();
        final releaseStart = Completer<void>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if (call.method == 'startCapture') {
                startEntered.complete();
                await releaseStart.future;
              }
              return null;
            });
        final transport = _FakeAudioTransport();
        final sentControls = <AudioControlMessage>[];
        final coordinator = AudioShareCoordinator(
          manager: AudioShareManager(),
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
        final accepting = coordinator.handleControlMessage(
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
        await startEntered.future;

        var stopCompleted = false;
        final stopping = coordinator.stopLocal().whenComplete(() {
          stopCompleted = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(stopCompleted, isFalse);
        expect(calls.where((call) => call.method == 'stopCapture'), isEmpty);

        releaseStart.complete();
        await Future.wait(<Future<void>>[accepting, stopping]);
        expect(
          calls.where((call) => call.method == 'stopCapture'),
          hasLength(1),
        );
        expect(transport.closed, isTrue);
        expect(coordinator.state.status, AudioShareRuntimeStatus.idle);
      },
    );

    test(
      'source reports an audio control error when capture is denied',
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
        expect(sentControls.last.errorMessage, 'permission');
        expect(coordinator.state.status, AudioShareRuntimeStatus.failed);
        expect(coordinator.state.errorMessage, 'permission');
        expect(transport.closed, isTrue);
      },
    );

    test('remote audio errors are reduced to a stable local reason', () async {
      final sentControls = <AudioControlMessage>[];
      final manager = AudioShareManager();
      final coordinator = AudioShareCoordinator(
        manager: manager,
        platform: platform,
        codecFactory: _pcmCodec,
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
      const remoteText =
          'remote token=never-store-this /Users/alice/private.wav';

      await coordinator.handleControlMessage(
        AudioControlMessage(
          action: AudioControlAction.error,
          sessionId: offer.sessionId,
          sourcePeerId: 'pc',
          sinkPeerId: 'phone',
          errorMessage: remoteText,
        ),
        localPeerId: 'pc',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: sentControls.add,
      );

      expect(coordinator.state.status, AudioShareRuntimeStatus.failed);
      expect(coordinator.state.errorMessage, 'remoteFailure');
      expect(coordinator.state.errorMessage, isNot(contains(remoteText)));
    });

    test('remote audio errors preserve an allowlisted wire reason', () async {
      final sentControls = <AudioControlMessage>[];
      final coordinator = AudioShareCoordinator(
        manager: AudioShareManager(),
        platform: platform,
        codecFactory: _pcmCodec,
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
          action: AudioControlAction.error,
          sessionId: offer.sessionId,
          sourcePeerId: 'pc',
          sinkPeerId: 'phone',
          errorMessage: 'unsupported',
        ),
        localPeerId: 'pc',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: sentControls.add,
      );

      expect(coordinator.state.errorMessage, 'unsupported');
    });

    test(
      'sink auto-accepts offers and writes received packets to playback',
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
        final writeCall = calls.singleWhere(
          (call) => call.method == 'writePcm',
        );
        final arguments = writeCall.arguments as Map<Object?, Object?>;
        expect(arguments['pcm'], Uint8List.fromList(<int>[2, 0, 4, 0]));
      },
    );

    test(
      'unexpected receiver channel close stops playback and fails session',
      () async {
        final sentControls = <AudioControlMessage>[];
        final manager = AudioShareManager();
        final coordinator = AudioShareCoordinator(
          manager: manager,
          platform: platform,
          codecFactory: _pcmCodec,
          playbackGainProvider: () async => 1.0,
        );
        await coordinator.handleControlMessage(
          const AudioControlMessage(
            action: AudioControlAction.offer,
            sessionId: 'audio-receiver-close',
            sourcePeerId: 'pc',
            sinkPeerId: 'phone',
            format: format,
            path: '/audio',
          ),
          localPeerId: 'phone',
          remoteHost: 'pc.local',
          remotePort: 10002,
          sendControl: sentControls.add,
        );
        final channel = _RemoteCloseChannel();
        expect(
          manager.attachChannel(
            channel,
            claim: SessionUpgradeClaim(
              route: '/audio',
              namespace: 'audio',
              sessionId: 'audio-receiver-close',
              peerId: 'pc',
              mediaMacKey: Uint8List(32),
              channelBinding: Uint8List(32),
            ),
          ),
          isTrue,
        );

        await channel.closeRemote();
        await _waitUntil(
          () => coordinator.state.status == AudioShareRuntimeStatus.failed,
        );

        expect(coordinator.state.role, AudioShareRuntimeRole.sink);
        expect(coordinator.state.errorMessage, 'transport');
        expect(
          manager.session('audio-receiver-close')?.state,
          AudioShareSessionState.failed,
        );
        expect(manager.activeChannelCount, 0);
        expect(
          calls.where((call) => call.method == 'stopPlayback'),
          hasLength(1),
        );

        await coordinator.stopLocal();
        expect(
          calls.where((call) => call.method == 'stopPlayback'),
          hasLength(1),
        );
      },
    );

    test('native playback write failure fails the direct sink once', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'writePcm') {
              throw PlatformException(code: 'audio-playback-write-failed');
            }
            return null;
          });
      final manager = AudioShareManager();
      final coordinator = AudioShareCoordinator(
        manager: manager,
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await coordinator.handleControlMessage(
        const AudioControlMessage(
          action: AudioControlAction.offer,
          sessionId: 'audio-native-write-failure',
          sourcePeerId: 'pc',
          sinkPeerId: 'phone',
          format: format,
          path: '/audio',
        ),
        localPeerId: 'phone',
        remoteHost: 'pc.local',
        remotePort: 10002,
        sendControl: (_) {},
      );

      manager.handlePacketBytes(
        AudioPacketFrame(
          sessionId: 'audio-native-write-failure',
          sequence: 1,
          captureTimeMicros: 0,
          payload: Uint8List.fromList(<int>[1, 0, 2, 0]),
        ).encode(),
      );
      await _waitUntil(
        () => coordinator.state.status == AudioShareRuntimeStatus.failed,
      );

      expect(coordinator.state.errorMessage, 'playbackIo');
      expect(
        calls.where((call) => call.method == 'stopPlayback'),
        hasLength(1),
      );
      expect(
        manager.session('audio-native-write-failure')?.state,
        AudioShareSessionState.failed,
      );
    });

    test('receiver close crossing an intentional stop does not fail', () async {
      final releaseStopPlayback = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'stopPlayback') {
              await releaseStopPlayback.future;
            }
            return null;
          });
      final manager = AudioShareManager();
      final coordinator = AudioShareCoordinator(
        manager: manager,
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      var failedNotifications = 0;
      coordinator.addListener(() {
        if (coordinator.state.status == AudioShareRuntimeStatus.failed) {
          failedNotifications += 1;
        }
      });
      await coordinator.handleControlMessage(
        const AudioControlMessage(
          action: AudioControlAction.offer,
          sessionId: 'audio-intentional-crossing',
          sourcePeerId: 'pc',
          sinkPeerId: 'phone',
          format: format,
          path: '/audio',
        ),
        localPeerId: 'phone',
        remoteHost: 'pc.local',
        remotePort: 10002,
        sendControl: (_) {},
      );
      final mediaChannel = _RemoteCloseChannel();
      expect(
        manager.attachChannel(
          mediaChannel,
          claim: SessionUpgradeClaim(
            route: '/audio',
            namespace: 'audio',
            sessionId: 'audio-intentional-crossing',
            peerId: 'pc',
            mediaMacKey: Uint8List(32),
            channelBinding: Uint8List(32),
          ),
        ),
        isTrue,
      );

      final stopping = coordinator.stopLocal();
      await _waitUntil(
        () => calls.any((call) => call.method == 'stopPlayback'),
      );
      await mediaChannel.closeRemote();
      await _waitUntil(() => manager.activeChannelCount == 0);

      expect(failedNotifications, 0);
      expect(coordinator.state.status, AudioShareRuntimeStatus.active);
      releaseStopPlayback.complete();
      await stopping;
      expect(coordinator.state.status, AudioShareRuntimeStatus.idle);
      expect(failedNotifications, 0);
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

    test('cancelled sink startup never sends a stale accept', () async {
      final codecRequested = Completer<void>();
      final releaseCodec = Completer<void>();
      final sentControls = <AudioControlMessage>[];
      final coordinator = AudioShareCoordinator(
        manager: AudioShareManager(),
        platform: platform,
        codecFactory: (format) async {
          codecRequested.complete();
          await releaseCodec.future;
          return _pcmCodec(format);
        },
        playbackGainProvider: () async => 1.0,
      );

      final handling = coordinator.handleControlMessage(
        const AudioControlMessage(
          action: AudioControlAction.offer,
          sessionId: 'audio-cancelled-start',
          sourcePeerId: 'pc',
          sinkPeerId: 'phone',
          format: format,
          path: '/audio',
        ),
        localPeerId: 'phone',
        remoteHost: 'pc.local',
        remotePort: 10002,
        sendControl: sentControls.add,
      );
      await codecRequested.future;

      await coordinator.stopLocal();
      releaseCodec.complete();
      await handling;

      expect(sentControls, isEmpty);
      expect(coordinator.state.status, AudioShareRuntimeStatus.idle);
      expect(
        calls.map((call) => call.method),
        isNot(contains('startPlayback')),
      );
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
  return PcmPassthroughAudioCodec(AudioCodecConfig.fromStreamFormat(format));
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

class _ObservableFakeAudioTransport implements AudioObservablePacketTransport {
  final Completer<PacketTransportTermination> _done =
      Completer<PacketTransportTermination>();
  final sentPackets = <AudioPacketFrame>[];
  int closeCount = 0;

  @override
  Future<PacketTransportTermination> get done => _done.future;

  void fail(PacketTransportTermination termination) {
    if (!_done.isCompleted) {
      _done.complete(termination);
    }
  }

  @override
  void send(AudioPacketFrame packet) {
    sentPackets.add(packet);
  }

  @override
  Future<void> close() async {
    closeCount += 1;
    if (!_done.isCompleted) {
      _done.complete(
        const PacketTransportTermination(
          PacketTransportTerminationReason.localClosed,
        ),
      );
    }
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 50 && !condition(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

final class _RemoteCloseChannel implements WebSocketChannel {
  _RemoteCloseChannel() {
    _sink = _ImmediateWebSocketSink(_controller.close);
  }

  final StreamController<dynamic> _controller = StreamController<dynamic>();
  late final _ImmediateWebSocketSink _sink;

  Future<void> closeRemote() => _controller.close();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ImmediateWebSocketSink implements WebSocketSink {
  _ImmediateWebSocketSink(this._closeStream);

  final Future<void> Function() _closeStream;
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  void add(dynamic data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.drain<void>();

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await _closeStream();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}
