import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/adb/adb_host_client.dart';
import 'package:whisper/window_stream/android/agent/agent_control_client.dart';
import 'package:whisper/window_stream/android/agent/agent_wire.dart';
import 'package:whisper/window_stream/android/scrcpy/scrcpy_stream_worker.dart';
import 'package:whisper/window_stream/core/media_packet.dart';
import 'package:whisper/window_stream/core/window_source.dart';
import 'package:whisper/window_stream/pipeline/media_sink.dart';

Uint8List _token(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (seed + i * 7) & 0xff));

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Reads a socket's bytes as they come, for a fake agent.
class _Inbox {
  _Inbox(Socket socket) {
    socket.listen(_add, onDone: () => _done = true);
  }

  final _bytes = BytesBuilder();
  bool _done = false;
  Completer<void>? _waiting;

  void _add(Uint8List chunk) {
    _bytes.add(chunk);
    _waiting?.complete();
    _waiting = null;
  }

  Future<Uint8List> take(int count) async {
    while (_bytes.length < count) {
      if (_done) {
        throw StateError('closed');
      }
      _waiting = Completer<void>();
      await _waiting!.future.timeout(const Duration(seconds: 3));
    }
    final all = _bytes.takeBytes();
    _bytes.add(all.sublist(count));
    return all.sublist(0, count);
  }
}

class _MemorySink implements MediaSink {
  final video = <Uint8List>[];

  @override
  MediaPacketWriter beginVideo(int surface, int length) => _Writer(video);

  @override
  MediaPacketWriter beginAudio(int surface, int length) => _Writer([]);

  @override
  void configureAudio(
    int surface, {
    required int sampleRate,
    required int channels,
  }) {}
}

class _Writer implements MediaPacketWriter {
  _Writer(this._into);

  final List<Uint8List> _into;
  final _bytes = BytesBuilder();

  @override
  void write(Uint8List chunk) => _bytes.add(chunk);

  @override
  void commit({required int ptsUs, required bool config, required bool key}) {
    _into.add(_bytes.takeBytes());
  }

  @override
  void discard() {}
}

void main() {
  group('AgentWire', () {
    test('hello matches the Java side byte for byte', () {
      // Same fixture as android_agent/test/.../WireTest.java.
      final token = Uint8List.fromList(List.generate(32, (i) => i));
      expect(
        _hex(AgentWire.hello(AgentWire.roleInput, 7, token)),
        '5741473104000000070001020304050607'
        '08090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      );
      expect(() => AgentWire.hello(1, 0, Uint8List(8)), throwsArgumentError);
    });

    test('messages survive arbitrary chunking', () {
      final bytes = BytesBuilder()
        ..add(AgentWire.frame({'id': 1, 'result': '你好'}))
        ..add(
          AgentWire.frame({
            'event': 'closed',
            'data': {'stream': 2},
          }),
        );
      final all = bytes.takeBytes();
      final reader = AgentMessageReader();
      final out = <Object?>[];
      for (var i = 0; i < all.length; i += 3) {
        out.addAll(
          reader.add(
            Uint8List.sublistView(all, i, (i + 3).clamp(0, all.length)),
          ),
        );
      }
      expect(out, [
        {'id': 1, 'result': '你好'},
        {
          'event': 'closed',
          'data': {'stream': 2},
        },
      ]);
    });

    test('an oversized length is refused before buffering', () {
      expect(
        () => AgentMessageReader().add(Uint8List.fromList([0x7f, 0, 0, 0])),
        throwsFormatException,
      );
    });

    test('sidecar names the jar on the phone after its hash', () {
      final sidecar = AgentSidecar.fromJson({
        'agentVersion': '1.0.0',
        'protocol': 1,
        'jarSha256': 'ab' * 32,
        'sourceSha256': 'cd' * 32,
      });
      expect(
        sidecar.devicePath,
        '/data/local/tmp/whisper-agent-abababababababab.jar',
      );
      expect(
        () => AgentSidecar.fromJson({'protocol': 1, 'jarSha256': '../../x'}),
        throwsFormatException,
      );
    });
  });

  group('AgentControlClient', () {
    late ServerSocket server;
    late Future<Socket> accepted;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      accepted = server.first;
    });

    tearDown(() => server.close());

    test('says hello, matches replies by id and forwards events', () async {
      final token = _token(5);
      final client = await AgentControlClient.connect(
        port: server.port,
        token: token,
      );
      final agent = await accepted;
      final inbox = _Inbox(agent);
      final hello = await inbox.take(AgentWire.helloBytes);
      expect(hello, AgentWire.hello(AgentWire.roleControl, 0, token));

      final events = <AgentEvent>[];
      client.events.listen(events.add);
      final apps = client.call('apps');
      final tasks = client.call('tasks');
      final requests = AgentMessageReader();
      final received = <Map>[];
      while (received.length < 2) {
        final length = ByteData.sublistView(await inbox.take(4)).getUint32(0);
        received.addAll(
          requests
              .add(
                Uint8List.fromList([
                  ...(ByteData(4)..setUint32(0, length)).buffer.asUint8List(),
                  ...await inbox.take(length),
                ]),
              )
              .cast<Map>(),
        );
      }
      expect(received.map((r) => r['method']), ['apps', 'tasks']);
      // Answer out of order, with an event in between.
      agent
        ..add(AgentWire.frame({'id': received[1]['id'], 'result': []}))
        ..add(
          AgentWire.frame({
            'event': 'launched',
            'data': {'stream': 1, 'displayId': 9},
          }),
        )
        ..add(AgentWire.frame({'id': received[0]['id'], 'error': 'no apps'}));
      expect(await tasks, isEmpty);
      await expectLater(
        apps,
        throwsA(
          isA<AgentCallException>().having(
            (e) => e.message,
            'message',
            'no apps',
          ),
        ),
      );
      expect(events.single.name, 'launched');
      expect(events.single.data['displayId'], 9);

      // Losing the agent fails pending calls and completes done.
      final pending = client.call('ping');
      await agent.close();
      agent.destroy();
      await expectLater(pending, throwsA(isA<AgentCallException>()));
      await client.done;
      expect(client.isClosed, isTrue);
    });
  });

  test('scrcpy worker opens agent sockets with role hellos', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final token = _token(9);
    final hellos = <Uint8List>[];
    final sockets = <Socket>[];
    server.listen((socket) async {
      sockets.add(socket);
      final inbox = _Inbox(socket);
      final hello = await inbox.take(AgentWire.helloBytes);
      hellos.add(hello);
      if (hello[4] == AgentWire.roleVideo) {
        // Status byte, H.264 codec id, session meta, one config packet.
        final config = [0, 0, 0, 1, 0x67];
        socket.add([
          0,
          0x68,
          0x32,
          0x36,
          0x34,
          0x80,
          0,
          0,
          0,
          0,
          0,
          4,
          0x38,
          0,
          0,
          9,
          0x60,
          0x40,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          config.length,
          ...config,
        ]);
      }
    });
    final sink = _MemorySink();
    final events = <StreamTransportEvent>[];
    final worker = ScrcpyStreamWorker(
      surface: 1,
      spec: ScrcpySocketsSpec(
        port: server.port,
        audio: true,
        agentToken: token,
        agentStream: 3,
      ),
      sink: sink,
      emit: events.add,
    );
    await worker.start();
    for (var i = 0; i < 50 && (sink.video.isEmpty || hellos.length < 3); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(events.whereType<TransportConnected>(), hasLength(1));
    expect(hellos.map((h) => h[4]), [
      AgentWire.roleVideo,
      AgentWire.roleAudio,
      AgentWire.roleInput,
    ]);
    for (final hello in hellos) {
      expect(ByteData.sublistView(hello, 5, 9).getUint32(0), 3);
      expect(hello.sublist(9), token);
    }
    final size = events.whereType<TransportVideoSize>().single;
    expect([size.width, size.height], [1080, 2400]);
    expect(sink.video.single, [0, 0, 0, 1, 0x67]);
    await worker.close();
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  });

  test('the coordinator falls back to scrcpy when the agent fails', () {
    final source = File(
      'lib/window_stream/window_stream_coordinator.dart',
    ).readAsStringSync();
    expect(source, contains('AndroidAgentSource.launch('));
    expect(
      source,
      contains("_diag('agent failed, using scrcpy fallback: \$error');"),
    );
    expect(source, contains('if (losses.length >= 3)'));
  });

  test('a window closes when its app is gone from the phone', () {
    final source = File(
      'lib/window_stream/android/agent/android_agent_source.dart',
    ).readAsStringSync();
    // Polled while streams run; two empty looks in a row, not one.
    expect(source, contains('Timer.periodic(const Duration(seconds: 2)'));
    expect(source, contains('if (_emptyChecks >= 2)'));
    expect(source, contains('status: StreamStatus.appExited'));
    final page = File(
      'lib/page/window_stream/flow_space_page.dart',
    ).readAsStringSync();
    // Closing an app from the recents closes its window here too.
    expect(page, contains('if (outcome == TaskCloseOutcome.closed) {'));
    expect(
      page,
      contains('if (session != null && !session.state.isTerminal) {'),
    );
  });

  test('process patterns never match the shell that runs them', () {
    expect(shellProcessPattern('com.x.Main'), "'[c]om.x.Main'");
    final pattern = RegExp('[c]om.x.Main');
    expect(pattern.hasMatch('app_process / com.x.Main sock'), isTrue);
    expect(pattern.hasMatch("sh -c pkill -f '[c]om.x.Main'"), isFalse);
    // Every pgrep/pkill -f in the window-stream code goes through the helper.
    for (final file in Directory(
      'lib/window_stream',
    ).listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) {
        continue;
      }
      for (final match in RegExp(
        r'p(?:grep|kill) -f ([^\s;]+)',
      ).allMatches(file.readAsStringSync())) {
        expect(
          match.group(1),
          startsWith(r'${shellProcessPattern('),
          reason: '${file.path}: ${match.group(0)}',
        );
      }
    }
  });
}
