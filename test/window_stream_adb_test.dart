import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/adb/adb_host_client.dart';
import 'package:whisper/window_stream/adb/adb_locator.dart';
import 'package:whisper/window_stream/core/byte_stream_reader.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';

/// Minimal adb server: answers one request per connection with [respond].
class _FakeAdbServer {
  _FakeAdbServer(this.respond);

  final Future<void> Function(
    String service,
    Socket socket,
    ByteStreamReader reader,
  )
  respond;
  late final ServerSocket _server;
  final requests = <String>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) async {
      final reader = ByteStreamReader(socket);
      try {
        while (true) {
          final length = int.parse(
            ascii.decode(await reader.read(4)),
            radix: 16,
          );
          final service = utf8.decode(await reader.read(length));
          requests.add(service);
          await respond(service, socket, reader);
        }
      } catch (_) {
        socket.destroy();
      }
    });
  }

  Future<void> close() => _server.close();
}

Uint8List _hex(String payload) {
  final bytes = utf8.encode(payload);
  return Uint8List.fromList([
    ...ascii.encode(bytes.length.toRadixString(16).padLeft(4, '0')),
    ...bytes,
  ]);
}

Uint8List _shellPacket(int id, List<int> data) {
  final header = ByteData(5)
    ..setUint8(0, id)
    ..setUint32(1, data.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...data]);
}

void main() {
  test('parses devices -l output including wireless entries', () {
    final devices = AdbDevice.parseList(
      'R5ABC123 device usb:1-1 product:pd model:Pixel_8 device:shiba transport_id:3\n'
      'adb-R5ABC123-xYz._adb-tls-connect._tcp offline transport_id:2\n'
      '192.168.1.5:41234 unauthorized transport_id:4\n',
    );
    expect(devices, hasLength(3));
    expect(devices[0].ready, isTrue);
    expect(devices[0].usb, isTrue);
    expect(devices[0].model, 'Pixel 8');
    expect(devices[0].transportId, 3);
    expect(devices[1].wireless, isTrue);
    expect(devices[1].state, AdbDeviceState.offline);
    expect(devices[2].state, AdbDeviceState.unauthorized);
    expect(devices[2].wireless, isTrue);
  });

  test('parses forward list', () {
    final forward = AdbForward.tryParse(
      'R5ABC tcp:51234 localabstract:scrcpy_0000abcd',
    );
    expect(forward?.localTcpPort, 51234);
    expect(forward?.remote, 'localabstract:scrcpy_0000abcd');
    expect(AdbForward.tryParse('garbage'), isNull);
  });

  group('host protocol against a fake server', () {
    late _FakeAdbServer server;
    late AdbHostClient client;
    final pushed = BytesBuilder();
    String? pushedSpec;

    setUp(() async {
      pushed.clear();
      pushedSpec = null;
      server = _FakeAdbServer((service, socket, reader) async {
        if (service == 'host:version') {
          socket.add(ascii.encode('OKAY'));
          socket.add(_hex('0029'));
        } else if (service.startsWith('host-serial:S1:forward:tcp:0;')) {
          socket.add(ascii.encode('OKAYOKAY'));
          socket.add(_hex('51234'));
        } else if (service == 'host:transport:S1') {
          socket.add(ascii.encode('OKAY'));
        } else if (service.startsWith('shell,v2,raw:')) {
          socket.add(ascii.encode('OKAY'));
          socket.add(_shellPacket(1, utf8.encode('out\n')));
          socket.add(_shellPacket(2, utf8.encode('err')));
          socket.add(_shellPacket(3, [7]));
        } else if (service == 'sync:') {
          socket.add(ascii.encode('OKAY'));
          while (true) {
            final header = await reader.read(8);
            final id = ascii.decode(header.sublist(0, 4));
            final value = ByteData.sublistView(
              header,
              4,
            ).getUint32(0, Endian.little);
            if (id == 'SEND') {
              pushedSpec = utf8.decode(await reader.read(value));
            } else if (id == 'DATA') {
              pushed.add(await reader.read(value));
            } else if (id == 'DONE') {
              socket.add(ascii.encode('OKAY'));
              socket.add(Uint8List(4));
            } else if (id == 'QUIT') {
              await socket.close();
              return;
            }
          }
        } else if (service.startsWith('host:transport:')) {
          socket.add(ascii.encode('FAIL'));
          socket.add(_hex("device 'S9' not found"));
        } else {
          socket.add(ascii.encode('FAIL'));
          socket.add(_hex('unsupported'));
        }
        await socket.flush();
      });
      await server.start();
      client = AdbHostClient(port: server.port);
    });

    tearDown(() => server.close());

    test('version and forward with an allocated port', () async {
      expect(await client.serverVersion(), 41);
      expect(await client.forward('S1', 'localabstract:x'), 51234);
    });

    test('shell v2 separates stdout, stderr and exit code', () async {
      final result = await client.shell('S1', 'echo out');
      expect(result.stdout, 'out\n');
      expect(result.stderr, 'err');
      expect(result.exitCode, 7);
      expect(server.requests, contains('shell,v2,raw:echo out'));
    });

    test('push streams data in sync chunks', () async {
      final data = Uint8List.fromList(List.generate(150000, (i) => i & 0xff));
      await client.push('S1', data, '/data/local/tmp/x.jar');
      expect(pushedSpec, '/data/local/tmp/x.jar,420');
      expect(pushed.takeBytes(), data);
    });

    test('FAIL replies become AdbException with the message', () async {
      await expectLater(
        client.shell('S9', 'true'),
        throwsA(
          isA<AdbException>().having(
            (e) => e.message,
            'message',
            contains('S9'),
          ),
        ),
      );
    });
  });

  test('locator reports a missing adb as a typed failure', () async {
    final locator = AdbLocator(
      environment: const {'PATH': '/nowhere', 'HOME': '/nohome'},
      resolvedExecutable: '/app/Contents/MacOS/whisper',
      fileExists: (_) => false,
    );
    expect(locator.findExecutable(), isNull);
    await expectLater(
      locator.ensureServer(client: AdbHostClient(port: 1)),
      throwsA(
        isA<WindowStreamFailure>().having(
          (f) => f.reason,
          'reason',
          WindowStreamFailureReason.adbUnavailable,
        ),
      ),
    );
  });

  test('locator prefers a bundled adb over SDK and PATH copies', () {
    final locator = AdbLocator(
      environment: const {
        'PATH': '/usr/bin',
        'HOME': '/Users/me',
        'ANDROID_HOME': '/sdk',
      },
      resolvedExecutable: '/Applications/Whisper.app/Contents/MacOS/whisper',
      fileExists: (path) => path.endsWith('/adb') || path.endsWith('adb.exe'),
    );
    final found = locator.findExecutable()!;
    expect(found, contains('Whisper.app'));
  });

  test(
    'byte reader returns exact reads across chunks and reports closing',
    () async {
      final controller = StreamController<List<int>>();
      final reader = ByteStreamReader(controller.stream);
      controller.add([1, 2]);
      controller.add([3, 4, 5]);
      expect(await reader.read(3), [1, 2, 3]);
      expect(await reader.read(2), [4, 5]);
      unawaited(controller.close());
      await expectLater(reader.read(1), throwsA(isA<ByteStreamClosed>()));
    },
  );
}
