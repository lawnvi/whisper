import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_group_session.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

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

  group('AudioGroupCoordinator', () {
    late MethodChannel channel;
    late List<MethodCall> calls;
    late AudioPlatform platform;

    setUp(() {
      channel = const MethodChannel('test_audio_group_coordinator');
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

    test('source creates one group offer per sink with shared stream', () {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-${sent.length + 1}',
      );

      final session = coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.left,
          'phone-right': AudioChannelRole.right,
        },
        format: format,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      expect(session.groupId, 'group-1');
      expect(session.streamId, 'stream-1');
      expect(sent.map((item) => item.peerId), <String>[
        'phone-left',
        'phone-right',
      ]);
      expect(
        sent.map((item) => item.control.action).toSet(),
        <AudioGroupControlAction>{AudioGroupControlAction.groupOffer},
      );
      expect(
        sent.map((item) => item.control.streamId).toSet(),
        <String>{'stream-1'},
      );
      expect(sent[0].control.channelRole, AudioChannelRole.left);
      expect(sent[1].control.channelRole, AudioChannelRole.right);
      expect(sent[0].control.targetLatencyMs, 55);
      expect(sent[1].control.targetLatencyMs, 55);
    });

    test('source starts capture once and fans packets out to accepted sinks',
        () async {
      final sent = <_SentGroupControl>[];
      final transports = <String, _FakeAudioGroupTransport>{};
      var now = 1000;
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (uri) async {
          expect(uri.queryParameters['session'], isNotEmpty);
          expect(uri.queryParameters['token'], startsWith('group-token-'));
          final transport = _FakeAudioGroupTransport();
          transports[uri.host] = transport;
          return transport;
        },
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-${transports.length + 1}',
        clockMicros: () => now,
      );

      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.left,
          'phone-right': AudioChannelRole.right,
        },
        format: format,
        sendControl: (_, __) {},
      );

      now = 61000;
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-left',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-left',
          channelRole: AudioChannelRole.left,
          path: '/audio',
          transportToken: 'group-token-left',
        ),
        localPeerId: 'mac',
        remoteHost: 'left.local',
        remotePort: 10002,
        mediaSendKey: mediaKey,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );
      now = 62000;
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-right',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-right',
          channelRole: AudioChannelRole.right,
          path: '/audio',
          transportToken: 'group-token-right',
        ),
        localPeerId: 'mac',
        remoteHost: 'right.local',
        remotePort: 10002,
        mediaSendKey: mediaKey,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      expect(
        calls.where((call) => call.method == 'startCapture'),
        isEmpty,
      );
      expect(
        sent.map((item) => item.control.action),
        <AudioGroupControlAction>[
          AudioGroupControlAction.clockProbe,
          AudioGroupControlAction.clockProbe,
        ],
      );

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.clockReport,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-left',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-left',
          sentAtMicros: 1000,
          receivedAtMicros: 51000,
          sinkClockMicros: 52000,
        ),
        localPeerId: 'mac',
        remoteHost: 'left.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );
      expect(
        calls.where((call) => call.method == 'startCapture'),
        isEmpty,
      );

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.clockReport,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-right',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-right',
          sentAtMicros: 1000,
          receivedAtMicros: 51000,
          sinkClockMicros: 52000,
        ),
        localPeerId: 'mac',
        remoteHost: 'right.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );

      expect(
        calls.where((call) => call.method == 'startCapture'),
        hasLength(1),
      );
      await platform.handleNativeMethodCall(
        MethodCall('onCapturePcm', <String, dynamic>{
          'sessionId': 'stream-1',
          'sequence': 7,
          'captureTimeMicros': 1234,
          'pcm': Uint8List(format.frameSize * format.channels * 2),
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(transports['left.local']?.sentPackets, hasLength(1));
      expect(transports['right.local']?.sentPackets, hasLength(1));
      final leftPacket = transports['left.local']!.sentPackets.single;
      final rightPacket = transports['right.local']!.sentPackets.single;
      expect(leftPacket.streamId, 'stream-1');
      expect(rightPacket.streamId, 'stream-1');
      expect(leftPacket.sequence, rightPacket.sequence);
      expect(leftPacket.captureTimeMicros, 1234);
      expect(leftPacket.targetPlaybackTimeMicros, 127000);
    });

    test('source adapts group latency from the slowest synchronized sink',
        () async {
      final transports = <String, _FakeAudioGroupTransport>{};
      var now = 1000;
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (uri) async {
          final transport = _FakeAudioGroupTransport();
          transports[uri.host] = transport;
          return transport;
        },
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-1',
        clockMicros: () => now,
      );

      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone': AudioChannelRole.stereo,
        },
        format: format,
        sendControl: (_, __) {},
      );

      now = 10000;
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.stereo,
          path: '/audio',
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );

      now = 91000;
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.clockReport,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          sentAtMicros: 1000,
          receivedAtMicros: 61000,
          sinkClockMicros: 61000,
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );

      expect(coordinator.session?.targetLatencyMs, 80);

      await platform.handleNativeMethodCall(
        MethodCall('onCapturePcm', <String, dynamic>{
          'sessionId': 'stream-1',
          'sequence': 9,
          'captureTimeMicros': 4321,
          'pcm': Uint8List(format.frameSize * format.channels * 2),
        }),
      );
      await Future<void>.delayed(Duration.zero);

      final packet = transports['phone.local']!.sentPackets.single;
      expect(packet.targetPlaybackTimeMicros, 171000);
    });

    test('accept updates only the matching sink', () async {
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (_) async => _FakeAudioGroupTransport(),
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-1',
      );
      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.left,
          'phone-right': AudioChannelRole.right,
        },
        format: format,
        sendControl: (_, __) {},
      );

      final session = await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-left',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-left',
          channelRole: AudioChannelRole.left,
        ),
        localPeerId: 'mac',
        remoteHost: 'phone-left.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );

      expect(session?.sinks['phone-left']?.state, AudioGroupSinkState.active);
      expect(session?.sinks['phone-left']?.sessionId, 'session-left');
      expect(session?.sinks['phone-right']?.state, AudioGroupSinkState.offered);
      expect(session?.state, AudioGroupState.partial);
    });

    test('rejecting one sink does not fail the whole group', () async {
      final coordinator = AudioGroupCoordinator(
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-1',
      );
      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.left,
          'phone-right': AudioChannelRole.right,
        },
        format: format,
        sendControl: (_, __) {},
      );

      final session = await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupReject,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-left',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-left',
          errorMessage: 'busy',
        ),
        localPeerId: 'mac',
        remoteHost: '',
        remotePort: 0,
        sendControl: (_, __) {},
      );

      expect(session?.sinks['phone-left']?.state, AudioGroupSinkState.failed);
      expect(session?.sinks['phone-left']?.lastError, 'busy');
      expect(session?.sinks['phone-right']?.state, AudioGroupSinkState.offered);
      expect(session?.state, AudioGroupState.connecting);
    });

    test('sink rejects a second group offer while already active', () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
        groupIdFactory: () => 'group-local',
        streamIdFactory: () => 'stream-local',
        sessionIdFactory: () => 'session-local',
        clockMicros: () => 1000,
      );

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupOffer,
          groupId: 'group-a',
          streamId: 'stream-a',
          sessionId: 'session-a',
          sourcePeerId: 'mac-a',
          sinkPeerId: 'phone',
          sinkPeerIds: <String>['phone'],
          format: format,
          path: '/audio',
          channelRole: AudioChannelRole.stereo,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac-a.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupOffer,
          groupId: 'group-b',
          streamId: 'stream-b',
          sessionId: 'session-b',
          sourcePeerId: 'mac-b',
          sinkPeerId: 'phone',
          sinkPeerIds: <String>['phone'],
          format: format,
          path: '/audio',
          channelRole: AudioChannelRole.stereo,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac-b.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      expect(sent.first.control.action, AudioGroupControlAction.groupAccept);
      expect(sent.last.peerId, 'mac-b');
      expect(sent.last.control.action, AudioGroupControlAction.groupReject);
      expect(sent.last.control.errorMessage, contains('already active'));
      expect(coordinator.session?.groupId, 'group-a');
    });

    test('stopGroup sends stop to every sink and clears local session',
        () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-1',
      );
      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.left,
          'phone-right': AudioChannelRole.right,
        },
        format: format,
        sendControl: (_, __) {},
      );

      await coordinator.stopGroup(
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      expect(
        sent.map((item) => item.control.action).toSet(),
        <AudioGroupControlAction>{AudioGroupControlAction.groupStop},
      );
      expect(sent.map((item) => item.peerId), <String>[
        'phone-left',
        'phone-right',
      ]);
      expect(coordinator.session, isNull);
    });

    test('source updates active group without restarting capture', () async {
      final sent = <_SentGroupControl>[];
      final transports = <String, _FakeAudioGroupTransport>{};
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (uri) async {
          final transport = _FakeAudioGroupTransport();
          transports[uri.host] = transport;
          return transport;
        },
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-${sent.length + 1}',
      );
      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.left,
          'phone-right': AudioChannelRole.right,
        },
        format: format,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-left',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-left',
          channelRole: AudioChannelRole.left,
          path: '/audio',
        ),
        localPeerId: 'mac',
        remoteHost: 'phone-left.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-right',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-right',
          channelRole: AudioChannelRole.right,
          path: '/audio',
        ),
        localPeerId: 'mac',
        remoteHost: 'phone-right.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );
      sent.clear();

      await coordinator.updateGroup(
        sinks: const <String, AudioChannelRole>{
          'phone-left': AudioChannelRole.stereo,
        },
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      expect(sent.map((item) => item.control.action), <AudioGroupControlAction>[
        AudioGroupControlAction.groupStop,
        AudioGroupControlAction.groupUpdate,
      ]);
      expect(sent[0].peerId, 'phone-right');
      expect(sent[1].peerId, 'phone-left');
      expect(sent[1].control.channelRole, AudioChannelRole.stereo);
      expect(coordinator.session?.streamId, 'stream-1');
      expect(coordinator.session?.sinks.keys, <String>['phone-left']);
      expect(
        coordinator.session?.sinks['phone-left']?.channelRole,
        AudioChannelRole.stereo,
      );
    });

    test('sink applies group update without restarting playback', () async {
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupOffer,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          sinkPeerIds: <String>['phone'],
          format: format,
          path: '/audio',
          channelRole: AudioChannelRole.left,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupUpdate,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.right,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );

      expect(
        calls.where((call) => call.method == 'startPlayback'),
        hasLength(1),
      );
      expect(
        coordinator.session?.sinks['phone']?.channelRole,
        AudioChannelRole.right,
      );
    });

    test('pausePlaybackAsSink sends groupStop and keeps rejoin context',
        () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        channelRole: AudioChannelRole.right,
        targetLatencyMs: 77,
      );
      expect(coordinator.isPlaybackActive, isTrue);
      sent.clear();

      await coordinator.pausePlaybackAsSink();

      expect(sent, hasLength(1));
      expect(sent.single.peerId, 'mac');
      expect(sent.single.control.action, AudioGroupControlAction.groupStop);
      expect(sent.single.control.groupId, 'group-1');
      expect(sent.single.control.streamId, 'stream-1');
      expect(sent.single.control.sessionId, 'session-phone');
      expect(sent.single.control.sourcePeerId, 'mac');
      expect(sent.single.control.sinkPeerId, 'phone');
      expect(sent.single.control.channelRole, AudioChannelRole.right);
      expect(sent.single.control.targetLatencyMs, 77);
      expect(coordinator.isPlaybackActive, isFalse);
      expect(coordinator.hasLiveSession, isFalse);
      expect(coordinator.canRejoinAsSink, isTrue);
      expect(coordinator.rejoinSourcePeerId, 'mac');
      expect(
        calls.where((call) {
          if (call.method != 'stopPlayback') {
            return false;
          }
          final arguments = Map<Object?, Object?>.from(call.arguments as Map);
          return arguments['sessionId'] == 'stream-1';
        }),
        hasLength(1),
      );
    });

    test(
        'pausePlaybackAsSink during pending rejoin sends groupStop from context',
        () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        channelRole: AudioChannelRole.right,
        targetLatencyMs: 77,
      );
      await coordinator.pausePlaybackAsSink();
      expect(await coordinator.requestRejoinAsSink(), isTrue);
      sent.clear();

      await coordinator.pausePlaybackAsSink();

      expect(sent, hasLength(1), reason: 'rejoin 在途时暂停不得是 no-op');
      expect(sent.single.peerId, 'mac');
      expect(sent.single.control.action, AudioGroupControlAction.groupStop);
      expect(sent.single.control.groupId, 'group-1');
      expect(sent.single.control.streamId, 'stream-1');
      expect(sent.single.control.sessionId, 'session-phone');
      expect(sent.single.control.sinkPeerId, 'phone');
      expect(sent.single.control.channelRole, AudioChannelRole.right);
      expect(sent.single.control.targetLatencyMs, 77);
      expect(coordinator.canRejoinAsSink, isTrue, reason: '暂停后媒体卡的播放键仍是重试入口');
      expect(coordinator.rejoinSourcePeerId, 'mac');
    });

    test('pause during pending rejoin declines the crossing offer', () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        channelRole: AudioChannelRole.stereo,
        targetLatencyMs: 55,
      );
      await coordinator.pausePlaybackAsSink();
      expect(await coordinator.requestRejoinAsSink(), isTrue);
      // join 在途时用户按下暂停 = 取消在途 join
      await coordinator.pausePlaybackAsSink();
      sent.clear();

      // 源端对已取消 join 的应答 offer 在信道上交错到达
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone-2',
        channelRole: AudioChannelRole.stereo,
        targetLatencyMs: 55,
      );

      expect(coordinator.isPlaybackActive, isFalse,
          reason: '暂停后交错到达的陈旧 offer 不得被自动接受回到"播放中"');
      expect(coordinator.canRejoinAsSink, isTrue, reason: '媒体卡的播放键仍是重试入口');
      expect(sent, hasLength(1));
      expect(sent.single.peerId, 'mac');
      expect(sent.single.control.action, AudioGroupControlAction.groupStop,
          reason: '回 groupStop 让源端按暂停语义标记 stopped(幂等)');

      // 拒收是一次性的:用户再次播放后,新 offer 正常接受
      sent.clear();
      expect(await coordinator.requestRejoinAsSink(), isTrue);
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone-3',
        channelRole: AudioChannelRole.stereo,
        targetLatencyMs: 55,
      );
      expect(coordinator.isPlaybackActive, isTrue);
    });

    test('disconnect during pending rejoin declines the crossing offer',
        () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        channelRole: AudioChannelRole.stereo,
        targetLatencyMs: 55,
      );
      await coordinator.pausePlaybackAsSink();
      expect(await coordinator.requestRejoinAsSink(), isTrue);
      await coordinator.disconnectPlaybackAsSink();
      sent.clear();

      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone-2',
        channelRole: AudioChannelRole.stereo,
        targetLatencyMs: 55,
      );

      expect(coordinator.isPlaybackActive, isFalse,
          reason: '断开后交错到达的陈旧 offer 不得自动重启播放');
      expect(sent, hasLength(1));
      expect(sent.single.control.action, AudioGroupControlAction.groupStop);

      // 一次性:源端此后主动 re-offer(重新添加 sink)仍可接受
      sent.clear();
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone-3',
        channelRole: AudioChannelRole.stereo,
        targetLatencyMs: 55,
      );
      expect(coordinator.isPlaybackActive, isTrue);
    });

    test('source groupStop clears paused rejoin context', () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        channelRole: AudioChannelRole.stereo,
        targetLatencyMs: 88,
      );
      await coordinator.pausePlaybackAsSink();
      expect(coordinator.session, isNull);
      expect(coordinator.canRejoinAsSink, isTrue);
      var notifications = 0;
      coordinator.addListener(() {
        notifications += 1;
      });

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupStop,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.stereo,
          targetLatencyMs: 88,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );

      expect(coordinator.canRejoinAsSink, isFalse);
      expect(coordinator.rejoinSourcePeerId, isEmpty);
      expect(notifications, 1);
    });

    test('requestRejoinAsSink sends sinkJoinRequest with saved context',
        () async {
      final idleCoordinator = AudioGroupCoordinator();
      expect(await idleCoordinator.requestRejoinAsSink(), isFalse);

      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        channelRole: AudioChannelRole.left,
        targetLatencyMs: 88,
      );
      sent.clear();
      expect(await coordinator.requestRejoinAsSink(), isFalse);
      expect(sent, isEmpty);

      await coordinator.pausePlaybackAsSink();
      sent.clear();

      expect(await coordinator.requestRejoinAsSink(), isTrue);

      expect(sent, hasLength(1));
      expect(sent.single.peerId, 'mac');
      expect(
        sent.single.control.action,
        AudioGroupControlAction.sinkJoinRequest,
      );
      expect(sent.single.control.groupId, 'group-1');
      expect(sent.single.control.streamId, 'stream-1');
      expect(sent.single.control.sessionId, 'session-phone');
      expect(sent.single.control.sourcePeerId, 'mac');
      expect(sent.single.control.sinkPeerId, 'phone');
      expect(sent.single.control.channelRole, AudioChannelRole.left);
      expect(sent.single.control.targetLatencyMs, 88);

      sent.clear();
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone-2',
        channelRole: AudioChannelRole.left,
        targetLatencyMs: 88,
      );
      expect(coordinator.isPlaybackActive, isTrue);
      expect(coordinator.canRejoinAsSink, isFalse);
      expect(sent.single.control.action, AudioGroupControlAction.groupAccept);
    });

    test('paused sink accepts a fresh offer without occupying the group',
        () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        channelRole: AudioChannelRole.stereo,
        targetLatencyMs: 55,
      );
      sent.clear();

      await coordinator.pausePlaybackAsSink();
      expect(coordinator.hasLiveSession, isFalse);
      expect(coordinator.canRejoinAsSink, isTrue);
      sent.clear();

      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-2',
        streamId: 'stream-2',
        sessionId: 'session-phone-2',
        channelRole: AudioChannelRole.stereo,
        targetLatencyMs: 66,
      );

      expect(coordinator.isPlaybackActive, isTrue);
      expect(coordinator.canRejoinAsSink, isFalse);
      expect(sent, hasLength(1));
      expect(sent.single.peerId, 'mac');
      expect(sent.single.control.action, AudioGroupControlAction.groupAccept);
      expect(sent.single.control.groupId, 'group-2');
      expect(
        calls.where((call) {
          if (call.method != 'startPlayback') {
            return false;
          }
          final arguments = Map<Object?, Object?>.from(call.arguments as Map);
          return arguments['sessionId'] == 'stream-2';
        }),
        hasLength(1),
      );
    });

    test('rejoin offer failure keeps retry context', () async {
      final sent = <_SentGroupControl>[];
      var codecAttempts = 0;
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: (format) async {
          codecAttempts += 1;
          if (codecAttempts > 1) {
            throw StateError('playback unavailable');
          }
          return _pcmCodec(format);
        },
        playbackGainProvider: () async => 1.0,
      );
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        channelRole: AudioChannelRole.left,
        targetLatencyMs: 88,
      );
      await coordinator.pausePlaybackAsSink();
      expect(coordinator.canRejoinAsSink, isTrue);
      sent.clear();

      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone-2',
        channelRole: AudioChannelRole.left,
        targetLatencyMs: 88,
      );

      expect(coordinator.isPlaybackActive, isFalse);
      expect(coordinator.canRejoinAsSink, isTrue);
      expect(
        sent
            .singleWhere(
              (item) => item.control.action == AudioGroupControlAction.error,
            )
            .peerId,
        'mac',
      );
    });

    test('disconnectPlaybackAsSink sends groupStop and clears playback state',
        () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        channelRole: AudioChannelRole.right,
        targetLatencyMs: 77,
      );
      sent.clear();

      await coordinator.disconnectPlaybackAsSink();

      expect(sent, hasLength(1));
      expect(sent.single.peerId, 'mac');
      expect(sent.single.control.action, AudioGroupControlAction.groupStop);
      expect(sent.single.control.groupId, 'group-1');
      expect(sent.single.control.streamId, 'stream-1');
      expect(sent.single.control.sessionId, 'session-phone');
      expect(sent.single.control.sourcePeerId, 'mac');
      expect(sent.single.control.sinkPeerId, 'phone');
      expect(sent.single.control.channelRole, AudioChannelRole.right);
      expect(sent.single.control.targetLatencyMs, 77);
      expect(coordinator.isPlaybackActive, isFalse);
      expect(coordinator.canRejoinAsSink, isFalse);
      expect(coordinator.session, isNull);
    });

    test('disconnectPlaybackAsSink notifies source while paused', () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
      );
      await _offerSinkPlayback(
        coordinator,
        sent: sent,
        localPeerId: 'phone',
        sourcePeerId: 'mac',
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        channelRole: AudioChannelRole.left,
        targetLatencyMs: 88,
      );
      await coordinator.pausePlaybackAsSink();
      sent.clear();

      await coordinator.disconnectPlaybackAsSink();

      expect(sent, hasLength(1));
      expect(sent.single.peerId, 'mac');
      expect(sent.single.control.action, AudioGroupControlAction.groupStop);
      expect(sent.single.control.groupId, 'group-1');
      expect(sent.single.control.streamId, 'stream-1');
      expect(sent.single.control.sessionId, 'session-phone');
      expect(sent.single.control.sourcePeerId, 'mac');
      expect(sent.single.control.sinkPeerId, 'phone');
      expect(sent.single.control.channelRole, AudioChannelRole.left);
      expect(sent.single.control.targetLatencyMs, 88);
      expect(coordinator.isPlaybackActive, isFalse);
      expect(coordinator.canRejoinAsSink, isFalse);
      expect(coordinator.session, isNull);
    });

    test('source re-offers a sink on sinkJoinRequest', () async {
      final sent = <_SentGroupControl>[];
      var sessionIndex = 0;
      final coordinator = AudioGroupCoordinator(
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-${++sessionIndex}',
      );
      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone': AudioChannelRole.stereo,
        },
        format: format,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );
      sent.clear();

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupStop,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-1',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.stereo,
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );
      expect(
        coordinator.session?.sinks['phone']?.state,
        AudioGroupSinkState.stopped,
      );

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.sinkJoinRequest,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-1',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.stereo,
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      expect(sent, hasLength(1));
      expect(sent.single.peerId, 'phone');
      expect(sent.single.control.action, AudioGroupControlAction.groupOffer);
      expect(sent.single.control.sessionId, 'session-2');
      expect(sent.single.control.groupId, 'group-1');
      expect(sent.single.control.streamId, 'stream-1');
      expect(sent.single.control.sourcePeerId, 'mac');
      expect(sent.single.control.sinkPeerId, 'phone');
      expect(sent.single.control.channelRole, AudioChannelRole.stereo);
      expect(
        coordinator.session?.sinks['phone']?.state,
        AudioGroupSinkState.offered,
      );
      expect(coordinator.session?.state, AudioGroupState.offering);
    });

    test('sinkJoinRequest does not re-offer other terminal sinks', () async {
      final sent = <_SentGroupControl>[];
      var sessionIndex = 0;
      final coordinator = AudioGroupCoordinator(
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-${++sessionIndex}',
      );
      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone-a': AudioChannelRole.left,
          'phone-b': AudioChannelRole.right,
        },
        format: format,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );
      sent.clear();

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupReject,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-1',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-a',
          channelRole: AudioChannelRole.left,
          errorMessage: 'sink failed earlier',
        ),
        localPeerId: 'mac',
        remoteHost: 'phone-a.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupStop,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-2',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-b',
          channelRole: AudioChannelRole.right,
        ),
        localPeerId: 'mac',
        remoteHost: 'phone-b.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );
      expect(
        coordinator.session?.sinks['phone-a']?.state,
        AudioGroupSinkState.failed,
      );
      expect(
        coordinator.session?.sinks['phone-b']?.state,
        AudioGroupSinkState.stopped,
      );

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.sinkJoinRequest,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-2',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone-b',
          channelRole: AudioChannelRole.right,
        ),
        localPeerId: 'mac',
        remoteHost: 'phone-b.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      expect(sent, hasLength(1));
      expect(sent.single.peerId, 'phone-b');
      expect(sent.single.control.action, AudioGroupControlAction.groupOffer);
      expect(sent.single.control.sinkPeerId, 'phone-b');
      expect(sent.single.control.channelRole, AudioChannelRole.right);
      expect(
        coordinator.session?.sinks['phone-a']?.state,
        AudioGroupSinkState.failed,
      );
      expect(
        coordinator.session?.sinks['phone-b']?.state,
        AudioGroupSinkState.offered,
      );
    });

    test('source detaches fanout when sink reports groupStop', () async {
      final transports = <String, _FakeAudioGroupTransport>{};
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (uri) async {
          final transport = _FakeAudioGroupTransport();
          transports[uri.host] = transport;
          return transport;
        },
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-1',
      );
      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone': AudioChannelRole.stereo,
        },
        format: format,
        sendControl: (_, __) {},
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.stereo,
          path: '/audio',
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );
      expect(transports['phone.local']?.closed, isFalse);

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupStop,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.stereo,
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );

      expect(transports['phone.local']?.closed, isTrue);
      expect(
        coordinator.session?.sinks['phone']?.state,
        AudioGroupSinkState.stopped,
      );
    });

    test('source turns clock report into sink timing metrics and correction',
        () async {
      final sent = <_SentGroupControl>[];
      var now = 1000000;
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (_) async => _FakeAudioGroupTransport(),
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-1',
        clockMicros: () => now,
      );
      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone': AudioChannelRole.stereo,
        },
        format: format,
        sendControl: (_, __) {},
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.stereo,
          path: '/audio',
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );
      expect(sent.single.control.action, AudioGroupControlAction.clockProbe);
      expect(sent.single.control.sentAtMicros, 1000000);
      sent.clear();

      now = 1021000;
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.clockReport,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          sentAtMicros: 1000000,
          receivedAtMicros: 1120000,
          sinkClockMicros: 1121000,
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      final sink = coordinator.session?.sinks['phone'];
      expect(sink?.clockOffsetMicros, 110000);
      expect(sink?.rttMicros, 20000);
      expect(sent.single.peerId, 'phone');
      expect(sent.single.control.action, AudioGroupControlAction.clockReport);
      expect(sent.single.control.clockOffsetMicros, 110000);
    });

    test('source retries clock probing when a preflight sample is congested',
        () async {
      final sent = <_SentGroupControl>[];
      var now = 1000000;
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (_) async => _FakeAudioGroupTransport(),
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-1',
        clockMicros: () => now,
      );
      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone': AudioChannelRole.stereo,
        },
        format: format,
        sendControl: (_, __) {},
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.stereo,
          path: '/audio',
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );
      sent.clear();

      now = 1558000;
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.clockReport,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          sentAtMicros: 1000000,
          receivedAtMicros: 1400000,
          sinkClockMicros: 1401000,
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      expect(
        calls.where((call) => call.method == 'startCapture'),
        isEmpty,
      );
      expect(sent.single.control.action, AudioGroupControlAction.clockProbe);
    });

    test('sink answers clock probe with local receive and send timestamps',
        () async {
      final sent = <_SentGroupControl>[];
      var now = 1100000;
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
        clockMicros: () => now,
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupOffer,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          sinkPeerIds: <String>['phone'],
          format: format,
          path: '/audio',
          channelRole: AudioChannelRole.stereo,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );

      now = 1120000;
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.clockProbe,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          sentAtMicros: 1000000,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      expect(sent.single.peerId, 'mac');
      expect(sent.single.control.action, AudioGroupControlAction.clockReport);
      expect(sent.single.control.sentAtMicros, 1000000);
      expect(sent.single.control.receivedAtMicros, 1120000);
      expect(sent.single.control.sinkClockMicros, 1120000);
    });

    test('source stores latency reports as synchronization evidence', () async {
      final sent = <_SentGroupControl>[];
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        transportFactory: (_) async => _FakeAudioGroupTransport(),
        groupIdFactory: () => 'group-1',
        streamIdFactory: () => 'stream-1',
        sessionIdFactory: () => 'session-1',
      );
      coordinator.startGroup(
        sourcePeerId: 'mac',
        sinks: const <String, AudioChannelRole>{
          'phone': AudioChannelRole.stereo,
        },
        format: format,
        sendControl: (_, __) {},
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.stereo,
          path: '/audio',
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );
      sent.clear();

      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.latencyReport,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          bufferDepthMicros: 42000,
          latePacketCount: 3,
          syncErrorMicros: 7000,
        ),
        localPeerId: 'mac',
        remoteHost: 'phone.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );

      final sink = coordinator.session?.sinks['phone'];
      expect(sink?.bufferTargetMicros, 42000);
      expect(sink?.latePacketCount, 3);
      expect(sink?.syncErrorMicros, 7000);
      expect(sent.single.control.action, AudioGroupControlAction.clockProbe);
    });

    test('sink reports playback evidence after receiving audio packet',
        () async {
      final sent = <_SentGroupControl>[];
      var now = 1000;
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
        clockMicros: () => now,
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupOffer,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          sinkPeerIds: <String>['phone'],
          format: format,
          path: '/audio',
          channelRole: AudioChannelRole.stereo,
          targetLatencyMs: 160,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac.local',
        remotePort: 10002,
        sendControl: (peerId, control) {
          sent.add(_SentGroupControl(peerId, control));
        },
      );
      sent.clear();

      await coordinator.handlePacket(AudioGroupPacketFrame(
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        sourcePeerId: 'mac',
        sequence: 1,
        captureTimeMicros: 0,
        targetPlaybackTimeMicros: 2000,
        durationMicros: 20000,
        channelMask: AudioChannelMask.stereo,
        payload: Uint8List(0),
      ));

      expect(sent.single.peerId, 'mac');
      expect(sent.single.control.action, AudioGroupControlAction.latencyReport);
      expect(sent.single.control.bufferDepthMicros, 0);
      expect(sent.single.control.latePacketCount, 0);
      expect(sent.single.control.syncErrorMicros, 0);
    });

    test('sink packet handling is not blocked by a slow native audio write',
        () async {
      final slowWrite = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'writePcm') {
          return slowWrite.future;
        }
        return;
      });

      var now = 100000;
      final coordinator = AudioGroupCoordinator(
        platform: platform,
        codecFactory: _pcmCodec,
        playbackGainProvider: () async => 1.0,
        clockMicros: () => now,
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupOffer,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          sinkPeerIds: <String>['phone'],
          format: format,
          path: '/audio',
          channelRole: AudioChannelRole.stereo,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.clockReport,
          groupId: 'group-1',
          streamId: 'stream-1',
          sessionId: 'session-phone',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          clockOffsetMicros: 0,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac.local',
        remotePort: 10002,
        sendControl: (_, __) {},
      );

      final packetFuture = coordinator.handlePacket(AudioGroupPacketFrame(
        groupId: 'group-1',
        streamId: 'stream-1',
        sessionId: 'session-phone',
        sourcePeerId: 'mac',
        sequence: 1,
        captureTimeMicros: 0,
        targetPlaybackTimeMicros: now,
        durationMicros: 20000,
        channelMask: AudioChannelMask.stereo,
        payload: Uint8List.fromList(<int>[1, 0, 2, 0]),
      ));

      await expectLater(
        packetFuture.timeout(const Duration(milliseconds: 50)),
        completes,
      );
      expect(calls.where((call) => call.method == 'writePcm'), hasLength(1));

      slowWrite.complete();
      await Future<void>.delayed(Duration.zero);
    });

    test('group playback uses a smaller Dart-side native lead window', () {
      final source =
          File('lib/audio/audio_group_coordinator.dart').readAsStringSync();

      expect(source, contains('_nativePlaybackLeadMicros = 35000'));
      expect(source, contains('_maxPlaybackPumpIntervalMicros = 10000'));
      expect(source, contains('_playbackPumpDelayMicros(report)'));
      expect(source, contains('outputLeadMicros: _nativePlaybackLeadMicros'));
    });
  });
}

class _SentGroupControl {
  const _SentGroupControl(this.peerId, this.control);

  final String peerId;
  final AudioGroupControlMessage control;
}

Future<AudioCodec> _pcmCodec(AudioStreamFormat format) async {
  return PcmPassthroughAudioCodec(
    AudioCodecConfig.fromStreamFormat(format),
  );
}

Future<void> _offerSinkPlayback(
  AudioGroupCoordinator coordinator, {
  required List<_SentGroupControl> sent,
  required String localPeerId,
  required String sourcePeerId,
  required String groupId,
  required String streamId,
  required String sessionId,
  required AudioChannelRole channelRole,
  required int targetLatencyMs,
}) async {
  await coordinator.handleControlMessage(
    AudioGroupControlMessage(
      action: AudioGroupControlAction.groupOffer,
      groupId: groupId,
      streamId: streamId,
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: localPeerId,
      sinkPeerIds: <String>[localPeerId],
      format: const AudioStreamFormat(
        codec: AudioCodecKind.pcmS16le,
        sampleRate: 48000,
        channels: 2,
        frameDurationMs: 20,
        bitRate: 128000,
      ),
      path: '/audio',
      channelRole: channelRole,
      targetLatencyMs: targetLatencyMs,
    ),
    localPeerId: localPeerId,
    remoteHost: '$sourcePeerId.local',
    remotePort: 10002,
    sendControl: (peerId, control) {
      sent.add(_SentGroupControl(peerId, control));
    },
  );
}

class _FakeAudioGroupTransport implements AudioGroupPacketTransport {
  final sentPackets = <AudioGroupPacketFrame>[];
  bool closed = false;

  @override
  Future<PacketSendResult> send(AudioGroupPacketFrame packet) {
    if (!closed) {
      sentPackets.add(packet);
    }
    return Future<PacketSendResult>.value(
      closed ? PacketSendResult.closed : PacketSendResult.sent,
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
