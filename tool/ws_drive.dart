// Calls Whisper's debug-only `ext.whisper.*` VM service extensions
// (lib/debug/automation_hooks.dart) from the command line. No packages
// needed: it speaks the VM service's JSON-RPC over a WebSocket.
//
//   dart run tool/ws_drive.dart <vm> <method> [params-json] [options]
//   dart run tool/ws_drive.dart <vm> --list
//
// <vm>      the VM service: `8181`, `127.0.0.1:8181`, the URL Flutter prints
//           (`http://127.0.0.1:8181/AbCdEf=/`) or a full `ws://…/ws` URI.
//           A fixed port without auth codes: start the app with
//           FLUTTER_ENGINE_SWITCHES=2 FLUTTER_ENGINE_SWITCH_1=vm-service-port=8181
//           FLUTTER_ENGINE_SWITCH_2=disable-service-auth-codes (desktop), or
//           `flutter run --device-vmservice-port=8181 --disable-service-auth-codes`.
// <method>  `ws.sources`, `files.browse`, … (`ext.whisper.` is optional);
//           `help` lists them.
// params    a JSON object, e.g. '{"peer":"…","windowId":42}'. Strings go as
//           they are, other values as JSON text (the hooks parse both).
//
// Options:
//   --wait <s>     wait up to s seconds for the app to register the hooks
//   --field <name> --out <file>
//                  write a base64 field of the answer (jpeg, png) to a file
//   --compact      print the answer on one line
//
// Exit codes: 0 answered ok, 1 the hook answered ok:false, 2 usage or
// connection problems.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  try {
    exitCode = await _run(args);
  } on _Usage catch (problem) {
    stderr.writeln(problem.message);
    stderr.writeln(
      'usage: dart run tool/ws_drive.dart <vm> <method> [params-json] '
      '[--wait s] [--field name --out file] [--compact]\n'
      '       dart run tool/ws_drive.dart <vm> --list',
    );
    exitCode = 2;
  } on SocketException catch (error) {
    stderr.writeln('cannot reach the VM service: ${error.message}');
    exitCode = 2;
  } on WebSocketException catch (error) {
    stderr.writeln('cannot reach the VM service: ${error.message}');
    exitCode = 2;
  } on HttpException catch (error) {
    stderr.writeln('not a VM service: ${error.message}');
    exitCode = 2;
  } on TimeoutException catch (error) {
    stderr.writeln('timed out: ${error.message}');
    exitCode = 2;
  }
}

class _Usage implements Exception {
  const _Usage(this.message);

  final String message;
}

Future<int> _run(List<String> args) async {
  final positional = <String>[];
  var waitSeconds = 0.0;
  String? field;
  String? out;
  var compact = false;
  var list = false;
  for (var i = 0; i < args.length; i++) {
    String value() {
      if (i + 1 >= args.length) {
        throw _Usage('${args[i]} needs a value');
      }
      return args[++i];
    }

    switch (args[i]) {
      case '--wait':
        waitSeconds = double.tryParse(value()) ?? 0;
      case '--field':
        field = value();
      case '--out':
        out = value();
      case '--compact':
        compact = true;
      case '--list':
        list = true;
      default:
        positional.add(args[i]);
    }
  }
  if (positional.isEmpty || (!list && positional.length < 2)) {
    throw const _Usage('missing arguments');
  }
  if ((field == null) != (out == null)) {
    throw const _Usage('--field and --out go together');
  }
  final uri = vmServiceUri(positional[0]);
  final method = list
      ? null
      : positional[1].startsWith('ext.')
      ? positional[1]
      : 'ext.whisper.${positional[1]}';
  final params = <String, String>{};
  if (positional.length > 2) {
    final decoded = jsonDecode(positional[2]);
    if (decoded is! Map) {
      throw const _Usage('params must be a JSON object');
    }
    for (final MapEntry(:key, :value) in decoded.entries) {
      params['$key'] = value is String ? value : jsonEncode(value);
    }
  }

  final deadline = DateTime.now().add(
    Duration(milliseconds: (waitSeconds * 1000).round()),
  );
  // With --wait, the app may still be starting: retry the connection too.
  _VmService service;
  while (true) {
    try {
      service = await _VmService.connect(uri);
      break;
    } on Object {
      if (!DateTime.now().isBefore(deadline)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  try {
    String? isolateId;
    List<String> extensions = const [];
    while (true) {
      (isolateId, extensions) = await service.findWhisperIsolate(
        method ?? 'ext.whisper.help',
      );
      if (isolateId != null || !DateTime.now().isBefore(deadline)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (isolateId == null) {
      stderr.writeln(
        method == null || extensions.isEmpty
            ? 'no isolate has the ext.whisper hooks (a debug build calls '
                  'registerAutomationHooks() in main)'
            : '$method is not registered; known: ${extensions.join(', ')}',
      );
      return 2;
    }
    if (method == null) {
      for (final name in extensions) {
        stdout.writeln(name);
      }
      return 0;
    }
    final response = await service.call(method, {
      'isolateId': isolateId,
      ...params,
    });
    final error = response['error'];
    if (error != null) {
      stderr.writeln(const JsonEncoder.withIndent('  ').convert(error));
      return 2;
    }
    final result = response['result'];
    final body = result is Map ? Map<String, Object?>.from(result) : result;
    if (field != null && out != null && body is Map) {
      final value = body[field];
      if (value is! String) {
        stderr.writeln('the answer has no "$field"');
        return 1;
      }
      await File(out).writeAsBytes(base64Decode(value));
      body[field] = '<${base64Decode(value).length} bytes written to $out>';
    }
    stdout.writeln(
      compact
          ? jsonEncode(body)
          : const JsonEncoder.withIndent('  ').convert(body),
    );
    return body is Map && body['ok'] == false ? 1 : 0;
  } finally {
    await service.close();
  }
}

/// `8181`, `host:8181`, `http://host:8181/token=/` or `ws://…` → the
/// service's WebSocket URI.
Uri vmServiceUri(String text) {
  var value = text.trim();
  if (RegExp(r'^\d+$').hasMatch(value)) {
    value = '127.0.0.1:$value';
  }
  if (!value.contains('://')) {
    value = 'ws://$value';
  }
  var uri = Uri.parse(value);
  final scheme = switch (uri.scheme) {
    'http' || 'ws' => 'ws',
    'https' || 'wss' => 'wss',
    _ => throw _Usage('not a VM service address: $text'),
  };
  var path = uri.path;
  if (!path.endsWith('/ws')) {
    path = '${path.endsWith('/') ? path : '$path/'}ws';
  }
  uri = uri.replace(scheme: scheme, path: path);
  return uri;
}

class _VmService {
  _VmService._(this._socket) {
    _subscription = _socket.listen(
      (message) {
        if (message is! String) {
          return;
        }
        final decoded = jsonDecode(message);
        if (decoded is Map && decoded['id'] != null) {
          _pending
              .remove('${decoded['id']}')
              ?.complete(decoded.cast<String, Object?>());
        }
      },
      onDone: () {
        for (final pending in _pending.values) {
          pending.completeError(
            const WebSocketException('the VM service closed the connection'),
          );
        }
        _pending.clear();
      },
    );
  }

  static Future<_VmService> connect(Uri uri) async {
    final socket = await WebSocket.connect(
      uri.toString(),
    ).timeout(const Duration(seconds: 10));
    return _VmService._(socket);
  }

  final WebSocket _socket;
  late final StreamSubscription<Object?> _subscription;
  final _pending = <String, Completer<Map<String, Object?>>>{};
  var _nextId = 1;

  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = '${_nextId++}';
    final completer = _pending[id] = Completer<Map<String, Object?>>();
    _socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    // Opening a window or a pairing can take a while; a minute is plenty.
    return completer.future.timeout(const Duration(seconds: 90));
  }

  /// The isolate that registered [method], and every ext.whisper method
  /// any isolate has (for the error message).
  Future<(String?, List<String>)> findWhisperIsolate(String method) async {
    final vm = await call('getVM');
    final isolates = (vm['result'] as Map?)?['isolates'] as List? ?? const [];
    final known = <String>{};
    String? found;
    for (final isolate in isolates) {
      final id = (isolate as Map)['id'] as String;
      final details = await call('getIsolate', {'isolateId': id});
      final rpcs =
          ((details['result'] as Map?)?['extensionRPCs'] as List?)
              ?.cast<String>() ??
          const <String>[];
      final whisper = rpcs.where((rpc) => rpc.startsWith('ext.whisper.'));
      known.addAll(whisper);
      if (found == null && rpcs.contains(method)) {
        found = id;
      }
    }
    return (found, known.toList()..sort());
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}
