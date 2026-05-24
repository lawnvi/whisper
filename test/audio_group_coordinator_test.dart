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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const format = AudioStreamFormat(
    codec: AudioCodecKind.pcmS16le,
    sampleRate: 48000,
    channels: 2,
    frameDurationMs: 20,
    bitRate: 128000,
  );

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
        ),
        localPeerId: 'mac',
        remoteHost: 'left.local',
        remotePort: 10002,
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
        ),
        localPeerId: 'mac',
        remoteHost: 'right.local',
        remotePort: 10002,
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

    test('group playback uses a smaller Dart-side native lead window', () {
      final source =
          File('lib/audio/audio_group_coordinator.dart').readAsStringSync();

      expect(source, contains('_nativePlaybackLeadMicros = 35000'));
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

class _FakeAudioGroupTransport implements AudioGroupPacketTransport {
  final sentPackets = <AudioGroupPacketFrame>[];
  bool closed = false;

  @override
  void send(AudioGroupPacketFrame packet) {
    if (!closed) {
      sentPackets.add(packet);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
