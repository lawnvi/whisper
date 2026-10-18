// Samples where an isolate spends its time, for transfer speed work:
//
//   dart tool/cpu_profile.dart <vm-service ws uri> [seconds] [isolate name]
//
// The process must run with the VM service on (`flutter test
// --enable-vmservice`; test/manual/lan_transfer_peer.dart prints the address
// in its ready event). Prints the functions most often on top of the stack
// (self) and most often anywhere on it (total), per isolate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: cpu_profile.dart <ws uri> [seconds] [isolate]');
    exitCode = 64;
    return;
  }
  final seconds = args.length > 1 ? int.parse(args[1]) : 10;
  final only = args.length > 2 ? args[2] : null;
  final socket = await WebSocket.connect(args[0]);
  final pending = <String, Completer<Map<String, Object?>>>{};
  var nextId = 1;
  socket.listen((message) {
    final reply = jsonDecode(message as String) as Map<String, Object?>;
    pending.remove(reply['id'])?.complete(reply);
  });
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = '${nextId++}';
    final completer = pending[id] = Completer<Map<String, Object?>>();
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future.timeout(const Duration(minutes: 2));
  }

  final vm = (await call('getVM'))['result'] as Map;
  final isolates = [
    for (final isolate in vm['isolates'] as List)
      if (only == null || (isolate as Map)['name'].toString().contains(only))
        isolate as Map,
  ];
  for (final isolate in isolates) {
    await call('clearCpuSamples', {'isolateId': isolate['id']});
  }
  stdout.writeln('sampling ${isolates.length} isolate(s) for ${seconds}s');
  await Future<void>.delayed(Duration(seconds: seconds));
  for (final isolate in isolates) {
    final reply = await call('getCpuSamples', {
      'isolateId': isolate['id'],
      'timeOriginMicros': 0,
      'timeExtentMicros': 0x7fffffffffffffff,
    });
    final result = reply['result'] as Map?;
    if (result == null) {
      stdout.writeln('${isolate['name']}: ${reply['error']}');
      continue;
    }
    final functions = [
      for (final entry in result['functions'] as List)
        _name((entry as Map)['function'] as Map),
    ];
    final samples = result['samples'] as List;
    final self = <String, int>{};
    final total = <String, int>{};
    for (final sample in samples) {
      final stack = ((sample as Map)['stack'] as List).cast<int>();
      if (stack.isEmpty) {
        continue;
      }
      self.update(functions[stack.first], (n) => n + 1, ifAbsent: () => 1);
      for (final name in {for (final index in stack) functions[index]}) {
        total.update(name, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final count = samples.length;
    stdout.writeln(
      '\n== ${isolate['name']}: $count samples '
      '(${result['samplePeriod']} us apart)',
    );
    void top(String title, Map<String, int> counts, int limit) {
      stdout.writeln('-- $title');
      final sorted = counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final entry in sorted.take(limit)) {
        final share = (100 * entry.value / count).toStringAsFixed(1);
        stdout.writeln('${share.padLeft(5)}%  ${entry.key}');
      }
    }

    top('self', self, 30);
    top('total', total, 45);
  }
  await socket.close();
}

String _name(Map function) {
  final name = function['name']?.toString() ?? '?';
  final owner = function['owner'];
  final ownerName = owner is Map ? owner['name']?.toString() : null;
  final location = function['location'];
  final scriptRef = location is Map ? location['script'] : null;
  final script = scriptRef is Map ? scriptRef['uri'] : null;
  final where = script == null
      ? ''
      : '  [${script.toString().split('/').last}]';
  final kind = function['type'] == 'NativeFunction' ? '  (native)' : '';
  return '${ownerName == null || ownerName == name ? '' : '$ownerName.'}'
      '$name$where$kind';
}
