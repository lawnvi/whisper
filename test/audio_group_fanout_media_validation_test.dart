import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/svrmanager.dart';

const _sourcePeerId = 'source-peer';
const _sinkPeerId = 'sink-peer';

final _mediaKey = Uint8List.fromList(
  List<int>.generate(32, (index) => index + 1),
);

Uri _mediaUri(
  int port, {
  required String sessionId,
  required String token,
}) {
  return buildPeerPacketUri(
    host: '127.0.0.1',
    port: port,
    path: '/audio',
    queryParameters: <String, String>{
      'session': sessionId,
      'token': token,
    },
  );
}

void main() {
  // AudioGroupCoordinator.shared 构造时会注册平台通道 handler,需要 binding。
  // 本文件不能使用裸 HttpClient(TestWidgetsFlutterBinding 会替换为假实现)。
  TestWidgetsFlutterBinding.ensureInitialized();

  late SessionUpgradeTokenRegistry tokens;
  late AudioShareManager audioManager;
  late WsSvrManager server;
  late int port;

  setUp(() async {
    tokens = SessionUpgradeTokenRegistry();
    audioManager = AudioShareManager();
    // 不注入 audioGroupClaimValidator / audioGroupPacketValidator,
    // 让 svrmanager 的生产校验读取 AudioGroupCoordinator.shared 的组会话。
    server = WsSvrManager.forTesting(
      audioManager: audioManager,
      remoteInputManager: RemoteInputManager(),
      sessionUpgradeTokens: tokens,
      mediaPeerClaimValidator: (_) => true,
    );
    final result = await server.startServer(0);
    expect(result.isSuccess, isTrue);
    port = result.port;
  });

  tearDown(() async {
    await AudioGroupCoordinator.shared.stopLocal();
    await server.closeGracefully(closeServer: true, forceServerClose: true);
  });

  test(
      'production group packet validation delivers fanout packets whose '
      'session id is the stream id', () async {
    final group = AudioGroupCoordinator.shared.startGroup(
      sourcePeerId: _sourcePeerId,
      sinks: <String, AudioChannelRole>{
        _sinkPeerId: AudioChannelRole.stereo,
      },
      format: const AudioStreamFormat(
        codec: AudioCodecKind.opus,
        sampleRate: 48000,
        channels: 2,
        frameDurationMs: 20,
        bitRate: 128000,
      ),
      sendControl: (_, __) {},
    );
    final sinkSessionId = group.sinks[_sinkPeerId]!.sessionId;
    expect(sinkSessionId, isNotEmpty);
    expect(sinkSessionId, isNot(group.streamId));

    final delivered = Completer<AudioGroupPacketFrame>();
    audioManager.onGroupPacket = (packet) {
      if (!delivered.isCompleted) {
        delivered.complete(packet);
      }
    };
    final token = tokens.issue(
      route: '/audio',
      namespace: 'audio-group',
      sessionId: sinkSessionId,
      peerId: _sourcePeerId,
      mediaMacKey: _mediaKey,
      now: DateTime.now(),
    );
    final transport = await AudioGroupWebSocketPacketTransport.connect(
      _mediaUri(port, sessionId: sinkSessionId, token: token),
      mediaMacKey: _mediaKey,
      sessionId: sinkSessionId,
      peerId: _sourcePeerId,
    );
    await transport.send(
      AudioGroupPacketFrame(
        groupId: group.groupId,
        streamId: group.streamId,
        // 生产 fanout 形态:组播包的 sessionId 即共享 streamId,
        // 而 claim 绑定的是每-sink 独立 sessionId。
        sessionId: group.streamId,
        sourcePeerId: _sourcePeerId,
        sequence: 1,
        captureTimeMicros: 10,
        targetPlaybackTimeMicros: 20,
        durationMicros: 20000,
        channelMask: AudioChannelMask.stereo,
        payload: Uint8List.fromList(<int>[6, 7]),
      ),
    );

    final packet = await delivered.future.timeout(const Duration(seconds: 2));
    expect(packet.sessionId, group.streamId);
    expect(packet.streamId, group.streamId);
    expect(packet.sourcePeerId, _sourcePeerId);
    await transport.close();
  });
}
