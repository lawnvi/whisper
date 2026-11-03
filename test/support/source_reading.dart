import 'dart:io';

/// Source tests read code as text, which ties them to where the code lives.
/// These helpers keep them independent of how files are split and of the order
/// of members. New tests should test behavior; see docs/design/migration.md.

const _deviceList = 'lib/page/deviceList.dart';
const _deviceListFolder = 'lib/page/device_list';

/// The device list's code: the old single file and whatever is split out of it.
String deviceListSource() {
  final parts = <File>[
    if (File(_deviceList).existsSync()) File(_deviceList),
    if (Directory(_deviceListFolder).existsSync())
      ...Directory(_deviceListFolder)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
  ]..sort((a, b) => a.path.compareTo(b.path));
  return parts.map((file) => file.readAsStringSync()).join('\n');
}

/// [path]'s code, treating the device list as one thing however it is split.
String readSource(String path) =>
    path == _deviceList ? deviceListSource() : File(path).readAsStringSync();

/// One member of a class or library, from [signature] to the end of its body.
/// Comments and strings cannot confuse it, and neither can what comes next.
String memberSource(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) {
    throw StateError('Missing member: $signature');
  }
  return source.substring(start, _endOfBody(source, start));
}

int _endOfBody(String source, int start) {
  var round = 0, curly = 0, square = 0;
  var i = start;
  while (i < source.length) {
    final skipped = _skipCommentOrString(source, i);
    if (skipped != i) {
      i = skipped;
      continue;
    }
    final c = source[i];
    if (c == '(') round++;
    if (c == ')') round--;
    if (c == '[') square++;
    if (c == ']') square--;
    if (c == '{') {
      curly++;
    }
    if (c == '}') {
      curly--;
      if (curly == 0 && round == 0 && square == 0) return i + 1;
    }
    // An arrow body or a field ends at the first top-level semicolon.
    if (c == ';' && curly == 0 && round == 0 && square == 0) return i + 1;
    i++;
  }
  throw StateError('Unterminated member at $start');
}

int _skipCommentOrString(String s, int i) {
  if (s.startsWith('//', i)) {
    final end = s.indexOf('\n', i);
    return end < 0 ? s.length : end;
  }
  if (s.startsWith('/*', i)) {
    final end = s.indexOf('*/', i);
    return end < 0 ? s.length : end + 2;
  }
  final raw =
      s[i] == 'r' && i + 1 < s.length && (s[i + 1] == "'" || s[i + 1] == '"');
  final q = raw ? i + 1 : i;
  if (s[q] != "'" && s[q] != '"') return i;
  final triple = s.startsWith(s[q] * 3, q);
  final close = triple ? s[q] * 3 : s[q];
  var j = q + close.length;
  while (j < s.length) {
    if (!raw && s[j] == r'\') {
      j += 2;
      continue;
    }
    if (s.startsWith(close, j)) return j + close.length;
    // Interpolation can hold quotes of its own.
    if (!raw && s.startsWith(r'${', j)) {
      var depth = 1;
      j += 2;
      while (j < s.length && depth > 0) {
        final skipped = _skipCommentOrString(s, j);
        if (skipped != j) {
          j = skipped;
          continue;
        }
        if (s[j] == '{') depth++;
        if (s[j] == '}') depth--;
        j++;
      }
      continue;
    }
    j++;
  }
  return s.length;
}
