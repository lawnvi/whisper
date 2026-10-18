import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/byte_stream_reader.dart';

/// Talks to a running adb server over its host protocol (TCP 5037) instead of
/// spawning the adb command line. Running the CLI can kill a server started by
/// a different adb version (e.g. Android Studio's); the protocol cannot.
class AdbHostClient {
  AdbHostClient({
    this.host = '127.0.0.1',
    this.port = 5037,
    Duration connectTimeout = const Duration(seconds: 2),
  }) : _connectTimeout = connectTimeout;

  final String host;
  final int port;
  final Duration _connectTimeout;

  Future<_AdbChannel> _open() async {
    try {
      final socket = await Socket.connect(host, port, timeout: _connectTimeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      return _AdbChannel(socket);
    } on SocketException catch (error) {
      throw AdbServerUnavailable(error.message);
    }
  }

  /// Opens a connection and sends one request; throws [AdbException] on FAIL.
  Future<_AdbChannel> _request(String service) async {
    final channel = await _open();
    try {
      await channel.send(service);
      await channel.expectOkay();
      return channel;
    } catch (_) {
      await channel.close();
      rethrow;
    }
  }

  /// Sends a request whose reply is one length-prefixed string.
  Future<String> _query(String service) async {
    final channel = await _request(service);
    try {
      return await channel.readLengthPrefixed();
    } finally {
      await channel.close();
    }
  }

  Future<int> serverVersion() async {
    return int.parse(await _query('host:version'), radix: 16);
  }

  Future<List<AdbDevice>> devices() async {
    return AdbDevice.parseList(await _query('host:devices-l'));
  }

  /// Emits the full device list now and whenever it changes.
  Stream<List<AdbDevice>> trackDevices() {
    late StreamController<List<AdbDevice>> controller;
    _AdbChannel? channel;
    Future<void> run() async {
      try {
        channel = await _request('host:track-devices-l');
        while (!controller.isClosed) {
          final payload = await channel!.readLengthPrefixed();
          if (!controller.isClosed) {
            controller.add(AdbDevice.parseList(payload));
          }
        }
      } on ByteStreamClosed {
        if (!controller.isClosed) {
          controller.addError(const AdbServerUnavailable('tracking ended'));
        }
      } catch (error, stack) {
        if (!controller.isClosed) {
          controller.addError(error, stack);
        }
      } finally {
        await channel?.close();
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    }

    controller = StreamController<List<AdbDevice>>(
      onListen: run,
      onCancel: () async {
        await channel?.close();
      },
    );
    return controller.stream;
  }

  /// Forwards a local TCP port to [remote] (e.g. `localabstract:name`).
  /// With [localPort] 0 the server picks a free port and returns it.
  Future<int> forward(String serial, String remote, {int localPort = 0}) async {
    final channel = await _request(
      'host-serial:$serial:forward:tcp:$localPort;$remote',
    );
    try {
      await channel.expectOkay();
      if (localPort != 0) {
        return localPort;
      }
      return int.parse(await channel.readLengthPrefixed());
    } finally {
      await channel.close();
    }
  }

  Future<void> killForward(String serial, int localPort) async {
    final channel = await _request(
      'host-serial:$serial:killforward:tcp:$localPort',
    );
    try {
      await channel.expectOkay();
    } finally {
      await channel.close();
    }
  }

  Future<List<AdbForward>> listForwards() async {
    final text = await _query('host:list-forward');
    return [
      for (final line in const LineSplitter().convert(text))
        if (AdbForward.tryParse(line) case final forward?) forward,
    ];
  }

  Future<Set<String>> features(String serial) async {
    final text = await _query('host-serial:$serial:features');
    return text.split(',').where((item) => item.isNotEmpty).toSet();
  }

  Future<_AdbChannel> _openTransport(String serial, String service) async {
    final channel = await _request('host:transport:$serial');
    try {
      await channel.send(service);
      await channel.expectOkay();
      return channel;
    } catch (_) {
      await channel.close();
      rethrow;
    }
  }

  /// Runs a command to completion. Uses the shell v2 protocol so stdout,
  /// stderr and the exit code stay separate.
  Future<AdbShellResult> shell(
    String serial,
    String command, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final channel = await _openTransport(serial, 'shell,v2,raw:$command');
    final stdout = BytesBuilder(copy: false);
    final stderr = BytesBuilder(copy: false);
    var exitCode = -1;
    try {
      await () async {
        while (true) {
          final header = await channel.reader.read(5);
          final id = header[0];
          final length = ByteData.sublistView(
            header,
            1,
          ).getUint32(0, Endian.little);
          final data = await channel.reader.read(length);
          switch (id) {
            case 1:
              stdout.add(data);
            case 2:
              stderr.add(data);
            case 3:
              exitCode = data.isEmpty ? 0 : data[0];
              return;
          }
        }
      }().timeout(timeout);
    } on ByteStreamClosed {
      // Older servers close without an exit packet.
    } finally {
      await channel.close();
    }
    return AdbShellResult(
      exitCode: exitCode,
      stdout: utf8.decode(stdout.takeBytes(), allowMalformed: true),
      stderr: utf8.decode(stderr.takeBytes(), allowMalformed: true),
    );
  }

  /// Starts a long-running command and streams its output. Closing the
  /// session closes the adb stream, which ends the command on the device
  /// unless it detached itself.
  Future<AdbShellSession> shellSession(String serial, String command) async {
    final channel = await _openTransport(serial, 'shell,v2,raw:$command');
    return AdbShellSession._(channel);
  }

  /// Pushes [data] to [remotePath] with the sync protocol.
  Future<void> push(
    String serial,
    Uint8List data,
    String remotePath, {
    int mode = 420, // 0644
    DateTime? modified,
  }) async {
    final channel = await _openTransport(serial, 'sync:');
    try {
      final spec = utf8.encode('$remotePath,$mode');
      channel.sink.add(_syncHeader('SEND', spec.length));
      channel.sink.add(spec);
      const chunkSize = 64 * 1024;
      for (var offset = 0; offset < data.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, data.length);
        channel.sink.add(_syncHeader('DATA', end - offset));
        channel.sink.add(Uint8List.sublistView(data, offset, end));
      }
      final mtime =
          ((modified ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000);
      channel.sink.add(_syncHeader('DONE', mtime));
      await channel.sink.flush();
      final reply = await channel.reader.read(8);
      final id = ascii.decode(reply.sublist(0, 4));
      final length = ByteData.sublistView(reply, 4).getUint32(0, Endian.little);
      if (id != 'OKAY') {
        final message = utf8.decode(
          await channel.reader.read(length),
          allowMalformed: true,
        );
        throw AdbException('push failed: $message');
      }
      channel.sink.add(_syncHeader('QUIT', 0));
      await channel.sink.flush();
    } finally {
      await channel.close();
    }
  }

  /// `adb connect host:port` (wireless debugging, after pairing).
  Future<String> connect(String hostAndPort) {
    return _query('host:connect:$hostAndPort');
  }

  Future<String> disconnect(String hostAndPort) {
    return _query('host:disconnect:$hostAndPort');
  }

  /// `adb pair host:port code`.
  Future<String> pair(String hostAndPort, String code) {
    return _query('host:pair:$code:$hostAndPort');
  }

  static Uint8List _syncHeader(String id, int value) {
    final bytes = Uint8List(8);
    bytes.setRange(0, 4, ascii.encode(id));
    ByteData.sublistView(bytes).setUint32(4, value, Endian.little);
    return bytes;
  }
}

class _AdbChannel {
  _AdbChannel(this._socket) : reader = ByteStreamReader(_socket);

  final Socket _socket;
  final ByteStreamReader reader;

  IOSink get sink => _socket;

  Future<void> send(String service) async {
    final payload = utf8.encode(service);
    _socket.add(ascii.encode(payload.length.toRadixString(16).padLeft(4, '0')));
    _socket.add(payload);
    await _socket.flush();
  }

  Future<void> expectOkay() async {
    final status = ascii.decode(await reader.read(4));
    if (status == 'OKAY') {
      return;
    }
    if (status == 'FAIL') {
      throw AdbException(await readLengthPrefixed());
    }
    throw AdbException('unexpected adb status "$status"');
  }

  Future<String> readLengthPrefixed() async {
    final length = int.parse(ascii.decode(await reader.read(4)), radix: 16);
    return utf8.decode(await reader.read(length), allowMalformed: true);
  }

  Future<void> close() async {
    await reader.cancel();
    _socket.destroy();
  }
}

/// Output of a long-running shell command.
class AdbShellSession {
  AdbShellSession._(this._channel) {
    _pump();
  }

  final _AdbChannel _channel;
  final _stdout = StreamController<String>.broadcast();
  final _exit = Completer<int>();

  /// Decoded stdout and stderr text, chunk by chunk.
  Stream<String> get output => _stdout.stream;
  Future<int> get exitCode => _exit.future;

  Future<void> _pump() async {
    const decoder = Utf8Decoder(allowMalformed: true);
    try {
      while (true) {
        final header = await _channel.reader.read(5);
        final id = header[0];
        final length = ByteData.sublistView(
          header,
          1,
        ).getUint32(0, Endian.little);
        final data = await _channel.reader.read(length);
        if (id == 1 || id == 2) {
          _stdout.add(decoder.convert(data));
        } else if (id == 3) {
          _finish(data.isEmpty ? 0 : data[0]);
          return;
        }
      }
    } catch (_) {
      _finish(-1);
    }
  }

  void _finish(int code) {
    if (!_exit.isCompleted) {
      _exit.complete(code);
    }
    if (!_stdout.isClosed) {
      _stdout.close();
    }
  }

  Future<void> close() async {
    await _channel.close();
    _finish(-1);
  }
}

/// A `pgrep -f` / `pkill -f` pattern that matches [text] in other processes'
/// command lines but not in the shell running the command, whose own command
/// line contains the pattern verbatim (`[c]om.x` matches `com.x`, but the
/// literal `[c]om.x` does not). A plain pattern makes pkill end its own shell.
String shellProcessPattern(String text) {
  if (text.isEmpty) {
    throw ArgumentError.value(text, 'text', 'must not be empty');
  }
  return "'[${text[0]}]${text.substring(1)}'";
}

class AdbShellResult {
  const AdbShellResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

class AdbException implements Exception {
  const AdbException(this.message);

  final String message;

  @override
  String toString() => 'AdbException: $message';
}

class AdbServerUnavailable extends AdbException {
  const AdbServerUnavailable(super.message);
}

enum AdbDeviceState {
  device,
  unauthorized,
  offline,
  authorizing,
  connecting,
  other,
}

class AdbDevice {
  const AdbDevice({
    required this.serial,
    required this.state,
    this.model = '',
    this.product = '',
    this.device = '',
    this.transportId,
    this.usb = false,
  });

  final String serial;
  final AdbDeviceState state;
  final String model;
  final String product;
  final String device;
  final int? transportId;
  final bool usb;

  /// Connected over wireless debugging rather than a cable.
  bool get wireless =>
      !usb && (serial.contains(':') || serial.contains('._adb-tls'));

  bool get ready => state == AdbDeviceState.device;

  static List<AdbDevice> parseList(String text) {
    return [
      for (final line in const LineSplitter().convert(text))
        if (tryParse(line) case final device?) device,
    ];
  }

  static AdbDevice? tryParse(String line) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 2 || fields.first.isEmpty) {
      return null;
    }
    final values = <String, String>{};
    var usb = false;
    for (final field in fields.skip(2)) {
      final colon = field.indexOf(':');
      if (colon <= 0) {
        continue;
      }
      final key = field.substring(0, colon);
      values[key] = field.substring(colon + 1);
      if (key == 'usb') {
        usb = true;
      }
    }
    return AdbDevice(
      serial: fields[0],
      state: switch (fields[1]) {
        'device' => AdbDeviceState.device,
        'unauthorized' => AdbDeviceState.unauthorized,
        'offline' => AdbDeviceState.offline,
        'authorizing' => AdbDeviceState.authorizing,
        'connecting' => AdbDeviceState.connecting,
        _ => AdbDeviceState.other,
      },
      model: (values['model'] ?? '').replaceAll('_', ' '),
      product: values['product'] ?? '',
      device: values['device'] ?? '',
      transportId: int.tryParse(values['transport_id'] ?? ''),
      usb: usb,
    );
  }
}

class AdbForward {
  const AdbForward({
    required this.serial,
    required this.local,
    required this.remote,
  });

  final String serial;
  final String local;
  final String remote;

  int? get localTcpPort =>
      local.startsWith('tcp:') ? int.tryParse(local.substring(4)) : null;

  static AdbForward? tryParse(String line) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length != 3) {
      return null;
    }
    return AdbForward(serial: fields[0], local: fields[1], remote: fields[2]);
  }
}
