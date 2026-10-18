import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/android/agent/agent_wire.dart';

/// Same hash as `script/build_window_agent.sh`: every input file's path
/// (relative to the repo, dotfiles skipped), a NUL, then its bytes, in byte
/// order of the paths.
String _sourceHash() {
  final files = <String>[
    for (final dir in ['android_agent/src', 'android_agent/upstream'])
      for (final entity in Directory(dir).listSync(recursive: true))
        if (entity is File && !entity.uri.pathSegments.last.startsWith('.'))
          entity.path.replaceAll(r'\', '/'),
    'script/build_window_agent.sh',
  ]..sort((a, b) => _compareBytes(utf8.encode(a), utf8.encode(b)));
  final output = AccumulatorSink<Digest>();
  final input = sha256.startChunkedConversion(output);
  for (final path in files) {
    input.add([...utf8.encode(path), 0]);
    input.add(File(path).readAsBytesSync());
  }
  input.close();
  return output.events.single.toString();
}

int _compareBytes(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) {
      return a[i] - b[i];
    }
  }
  return a.length - b.length;
}

class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];

  @override
  void add(T event) => events.add(event);

  @override
  void close() {}
}

void main() {
  final sidecarJson =
      jsonDecode(
            File('assets/window_stream/whisper-agent.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final sidecar = AgentSidecar.fromJson(sidecarJson);

  test('the committed agent jar was built from the current sources', () {
    expect(
      sidecar.sourceSha256,
      _sourceHash(),
      reason: 'android_agent/ changed: run ./script/build_window_agent.sh',
    );
  });

  test('the sidecar describes the committed jar', () {
    final jar = File(
      'assets/window_stream/whisper-agent.jar',
    ).readAsBytesSync();
    expect(sha256.convert(jar).toString(), sidecar.jarSha256);
    expect(sidecar.protocol, AgentWire.protocolVersion);
    expect(sidecarJson['scrcpyVersion'], '5.0.1');
    final main = File(
      'android_agent/src/com/vireen/whisper/agent/AgentMain.java',
    ).readAsStringSync();
    expect(main, contains('VERSION = "${sidecar.agentVersion}"'));
  });

  test('upstream scrcpy stays unmodified and credited', () {
    final notes = File('android_agent/UPSTREAM.md').readAsStringSync();
    expect(notes, contains('Patches applied to upstream files: none.'));
    expect(File('android_agent/upstream/LICENSE').existsSync(), isTrue);
    final notice = File('assets/window_stream/NOTICE.txt').readAsStringSync();
    expect(notice, contains('whisper-agent.jar'));
    expect(notice, contains('Apache License 2.0'));
  });

  test('the agent ships to desktops only', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final asset in ['whisper-agent.jar', 'whisper-agent.json']) {
      expect(
        pubspec,
        contains(
          '- path: assets/window_stream/$asset\n'
          '      platforms: [macos, windows, linux]',
        ),
      );
    }
  });

  test('the agent checks peers and the token before anything else', () {
    final server = File(
      'android_agent/src/com/vireen/whisper/agent/AgentServer.java',
    ).readAsStringSync();
    expect(server, contains('peer.getUid() != 0 && peer.getUid() != 2000'));
    expect(server, contains('Wire.readHello(socket.getInputStream(), token)'));
    expect(server, contains('setSoTimeout(HELLO_TIMEOUT_MS)'));
    final wire = File(
      'android_agent/src/com/vireen/whisper/agent/Wire.java',
    ).readAsStringSync();
    expect(wire, contains('constantTimeEquals(token, expectedToken)'));
    // A per-session agent (older desktops) still takes its token from the
    // environment, never a command line.
    final main = File(
      'android_agent/src/com/vireen/whisper/agent/AgentMain.java',
    ).readAsStringSync();
    expect(main, contains('System.getenv("WHISPER_AGENT_TOKEN")'));
    // The persistent agent makes its own token and keeps it in a 0600 state
    // file, never on a command line.
    expect(main, contains('new SecureRandom().nextBytes(token)'));
    final stateFile = File(
      'android_agent/src/com/vireen/whisper/agent/StateFile.java',
    ).readAsStringSync();
    expect(stateFile, contains('Os.chmod(temp.getPath(), 0600)'));
    expect(stateFile, contains('Os.chmod(DIR, 0700)'));
    // The persistent agent is started detached (survives adb) by the shared
    // launch scripts, and the token is never passed as an argument.
    final launch = File(
      'lib/window_stream/android/agent/agent_launch.dart',
    ).readAsStringSync();
    expect(launch, contains('setsid app_process /'));
    expect(launch, contains('AgentWire.mainClass} --daemon'));
    expect(launch, isNot(contains('WHISPER_AGENT_TOKEN')));
    // The phone's own Whisper reaches the agent over loopback, checking the
    // caller's uid and a challenge instead of sending the token.
    final appLink = File(
      'android_agent/src/com/vireen/whisper/agent/AppLink.java',
    ).readAsStringSync();
    expect(appLink, contains('owner != expected'));
    expect(appLink, contains('Wire.clientProof(appToken, hello.raw, nonce)'));
  });

  test('closing a display keeps its app in the background', () {
    final stream = File(
      'android_agent/src/com/vireen/whisper/agent/AgentStream.java',
    ).readAsStringSync();
    expect(stream, contains('"vd_destroy_content=false"'));
    expect(stream, contains('server.tasks().keepInBackground(task, front)'));
  });
}
