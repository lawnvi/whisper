import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/android/agent/agent_launch.dart';
import 'package:whisper/window_stream/android/agent/agent_link.dart';
import 'package:whisper/window_stream/android/agent/agent_wire.dart';

Uint8List _bytes(int seed, int n) =>
    Uint8List.fromList(List.generate(n, (i) => (seed + i) & 0xff));

void main() {
  group('app-link handshake', () {
    test('matches the Java fixture (WireTest.appProofsFixture)', () {
      final token = Uint8List.fromList(List.generate(32, (i) => i));
      final nonce = Uint8List.fromList(List.generate(32, (i) => 0x40 + i));
      final agentNonce = Uint8List.fromList(List.generate(32, (i) => 0x80 + i));
      final hello = AgentWire.appHello(AgentWire.roleControl, 0, nonce);
      String hex(List<int> b) =>
          b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      expect(
        hex(AgentWire.agentProof(token, hello, agentNonce)),
        'e4ddd461114ffa5e6f2d6257c4839d0ea45d0e60dca85e3797ab25467d9fb233',
      );
      expect(
        hex(AgentWire.clientProof(token, hello, agentNonce)),
        '3f90f97e9d0f9d308fa247989e6b6a5acad6277eeb63d3c9513d426912ec49d5',
      );
    });

    test(
      'a faithful agent is accepted and payload bytes pass through',
      () async {
        final token = _bytes(5, 32);
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        server.listen((socket) async {
          final chunks = StreamIterator(socket);
          final hello = await _take(chunks, AgentWire.appHelloBytes);
          final agentNonce = _bytes(200, AgentWire.nonceBytes);
          socket.add(agentNonce);
          socket.add(AgentWire.agentProof(token, hello, agentNonce));
          await _take(chunks, AgentWire.macBytes); // client proof
          socket.add(utf8.encode('hello-from-agent'));
        });
        final link = AgentLinkInfo(port: server.port, token: token);
        final connection = await AgentLink.connect(
          link,
          role: AgentWire.roleControl,
        );
        final first = await connection.input.first;
        expect(utf8.decode(first), 'hello-from-agent');
        connection.destroy();
      },
    );

    test('an agent that cannot prove the token is refused', () async {
      final token = _bytes(5, 32);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) async {
        final chunks = StreamIterator(socket);
        await _take(chunks, AgentWire.appHelloBytes);
        socket.add(_bytes(1, AgentWire.nonceBytes + AgentWire.macBytes));
      });
      final link = AgentLinkInfo(port: server.port, token: token);
      await expectLater(
        AgentLink.connect(link, role: AgentWire.roleControl),
        throwsA(isA<AgentLinkException>()),
      );
    });
  });

  group('AgentLinkInfo.fromMap', () {
    test('rejects a wrong-length token or bad port', () {
      expect(
        AgentLinkInfo.fromMap({'port': 5, 'token': _bytes(0, 32)}),
        isNotNull,
      );
      expect(
        AgentLinkInfo.fromMap({'port': 0, 'token': _bytes(0, 32)}),
        isNull,
      );
      expect(
        AgentLinkInfo.fromMap({'port': 5, 'token': _bytes(0, 16)}),
        isNull,
      );
    });
  });

  group('AgentLaunch', () {
    final sidecar = AgentSidecar.fromJson(
      jsonDecode(
            File('assets/window_stream/whisper-agent.json').readAsStringSync(),
          )
          as Map<String, dynamic>,
    );

    test('the start script is detached and names no token', () {
      final script = AgentLaunch.startScript(sidecar);
      expect(script, contains('setsid app_process / '));
      expect(script, contains('--daemon'));
      expect(script, isNot(contains('TOKEN')));
    });

    test('the probe parses a running agent and the jar', () {
      final output =
          '@@state\n'
          '{"pid":42,"protocol":2,"version":"2.0.0","jarSha":"$abc",'
          '"socket":"whisper_agent","token":"${'ab' * 32}"}\n'
          '@@jar\n${sidecar.jarSha256}  /data/local/tmp/x.jar\n@@end\n';
      final probe = AgentLaunch.parseProbe(output, sidecar);
      expect(probe.jarPresent, isTrue);
      expect(probe.running, isNotNull);
      expect(probe.running!.pid, 42);
      expect(probe.running!.protocol, 2);
      expect(probe.running!.hasToken, isTrue);
    });

    test('a phone-side probe without a token still parses', () {
      const output =
          '@@state\n'
          '{"pid":7,"protocol":2,"version":"2.0.0","jarSha":"$abc",'
          '"socket":"whisper_agent","token":""}\n@@jar\n@@end\n';
      final state = AgentLaunch.parseProbe(output, sidecar).running;
      expect(state, isNotNull);
      expect(state!.hasToken, isFalse);
    });

    test('only a newer idle agent is replaced', () {
      AgentDaemonState running(String version, String sha) => AgentDaemonState(
        pid: 1,
        protocol: AgentWire.protocolVersion,
        version: version,
        jarSha: sha,
        socket: 'whisper_agent',
        token: _bytes(0, 32),
      );
      // Same build: keep it.
      expect(
        AgentLaunch.shouldReplace(
          running('2.0.0', sidecar.jarSha256),
          sidecar,
          streams: 0,
        ),
        isFalse,
      );
      // Older build, idle: replace.
      expect(
        AgentLaunch.shouldReplace(
          running('1.9.0', 'ff' * 32),
          sidecar,
          streams: 0,
        ),
        isTrue,
      );
      // Older build but streaming: leave it.
      expect(
        AgentLaunch.shouldReplace(
          running('1.9.0', 'ff' * 32),
          sidecar,
          streams: 1,
        ),
        isFalse,
      );
      // A different protocol is always replaced when idle.
      expect(
        AgentLaunch.shouldReplace(
          AgentDaemonState(
            pid: 1,
            protocol: AgentWire.protocolVersion + 1,
            version: '9.9.9',
            jarSha: 'ff' * 32,
            socket: 'whisper_agent',
            token: _bytes(0, 32),
          ),
          sidecar,
          streams: 0,
        ),
        isTrue,
      );
    });

    test('version order is numeric', () {
      expect(AgentLaunch.compareVersions('2.0.10', '2.0.9'), greaterThan(0));
      expect(AgentLaunch.compareVersions('2.0.0', '2.0.0'), 0);
      expect(AgentLaunch.compareVersions('1.9.0', '2.0.0'), lessThan(0));
    });
  });
}

const abc = 'abababababababababababababababababababababababababababababababab';

Future<Uint8List> _take(StreamIterator<Uint8List> chunks, int count) async {
  final buffer = BytesBuilder();
  while (buffer.length < count) {
    if (!await chunks.moveNext()) {
      throw StateError('closed');
    }
    buffer.add(chunks.current);
  }
  final all = buffer.takeBytes();
  return Uint8List.sublistView(all, 0, count);
}
