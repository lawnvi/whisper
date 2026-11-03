import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Stops the UI drifting while it is being rebuilt (docs/design/migration.md
/// 「防止再次走样」): raw values in lib/page and lib/widget can only go down, and
/// new files start at zero. It guards against drift, not for looks: quality
/// still takes looking at screenshots next to docs/design/reference/.
///
/// After removing raw values, lower the baseline:
///   UPDATE_UI_RATCHET=1 flutter test test/ui_design_ratchet_test.dart
/// That never raises a count. Splitting a file moves its counts by hand in the
/// baseline; the totals still may not grow.

const _baselinePath = 'test/ui_design_ratchet_baseline.json';
const _scanned = ['lib/page', 'lib/widget'];

class _Rule {
  const _Rule(this.name, this.pattern, this.advice);

  final String name;
  final String pattern;
  final String advice;

  int count(String code) => RegExp(pattern).allMatches(code).length;
}

const _rules = [
  _Rule(
    'color',
    r'\bColor\(\s*0x[0-9a-fA-F]+\s*\)',
    'a raw Color(0x…). Use context.wc, see DESIGN.md「色彩」',
  ),
  _Rule(
    'fontSize',
    r'\bfontSize:\s*[\d.]+',
    'a literal fontSize. Use WhisperType, see DESIGN.md「字体」',
  ),
  _Rule(
    'duration',
    r'\bDuration\(\s*milliseconds:',
    'Duration(milliseconds:). Use WhisperSprings, see DESIGN.md「动效」',
  ),
  _Rule(
    'radius',
    r'\bBorderRadius\.circular\(\s*[\d.]+\s*\)',
    'a literal BorderRadius. Use WhisperRadius, see DESIGN.md「形状」',
  ),
];

/// Comments may quote old values; only code counts.
String _withoutComments(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'(^|\s)//.*$', multiLine: true), '');

Map<String, int> _countsIn(String source) {
  final code = _withoutComments(source);
  return {
    for (final rule in _rules)
      if (rule.count(code) > 0) rule.name: rule.count(code),
  };
}

Map<String, Map<String, int>> _scan() {
  final found = <String, Map<String, int>>{};
  for (final root in _scanned) {
    final files = Directory(root).listSync(recursive: true).whereType<File>();
    for (final file in files) {
      if (!file.path.endsWith('.dart')) continue;
      final counts = _countsIn(file.readAsStringSync());
      if (counts.isNotEmpty) {
        found[file.path.replaceAll(r'\', '/')] = counts;
      }
    }
  }
  return found;
}

Map<String, Map<String, int>> _readBaseline() {
  final raw =
      jsonDecode(File(_baselinePath).readAsStringSync())
          as Map<String, dynamic>;
  return raw.map(
    (file, counts) => MapEntry(file, (counts as Map<String, dynamic>).cast()),
  );
}

void _writeBaseline(Map<String, Map<String, int>> baseline) {
  final sorted = {
    for (final file in baseline.keys.toList()..sort())
      file: {
        for (final rule in _rules)
          if (baseline[file]!.containsKey(rule.name))
            rule.name: baseline[file]![rule.name]!,
      },
  };
  File(_baselinePath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(sorted)}\n',
  );
}

int _total(Map<String, Map<String, int>> counts, String rule) =>
    counts.values.fold(0, (sum, file) => sum + (file[rule] ?? 0));

void main() {
  test('counts raw values and ignores comments', () {
    expect(
      _countsIn('''
// Color(0xFF000000) in a comment
/* fontSize: 12 */
final a = Color(0xFF112233);
final b = TextStyle(fontSize: 13.5);
final c = TextStyle(fontSize: type.body);
final d = const Duration(milliseconds: 300);
final e = Duration(seconds: 1);
final f = BorderRadius.circular(8);
final g = BorderRadius.circular(WhisperRadius.m);
'''),
      {'color': 1, 'fontSize': 1, 'duration': 1, 'radius': 1},
    );
  });

  test('raw UI values only go down', () {
    final current = _scan();
    if (Platform.environment['UPDATE_UI_RATCHET'] == '1') {
      if (!File(_baselinePath).existsSync()) {
        _writeBaseline(current);
        return;
      }
      final old = _readBaseline();
      _writeBaseline({
        for (final file in old.keys)
          if (current.containsKey(file))
            file: {
              for (final rule in old[file]!.keys)
                if ((current[file]![rule] ?? 0) > 0)
                  rule: (current[file]![rule]!).clamp(0, old[file]![rule]!),
            },
      });
      return;
    }

    final baseline = _readBaseline();
    final problems = <String>[];
    for (final file in current.keys.toList()..sort()) {
      for (final rule in _rules) {
        final now = current[file]![rule.name] ?? 0;
        final allowed = baseline[file]?[rule.name] ?? 0;
        if (now > allowed) {
          final where = baseline.containsKey(file)
              ? 'went from $allowed to $now'
              : 'is a new file, which must have none, but has $now';
          problems.add('$file $where: ${rule.advice}.');
        }
      }
    }
    for (final rule in _rules) {
      final now = _total(current, rule.name);
      final allowed = _total(baseline, rule.name);
      if (now > allowed) {
        problems.add(
          'In total, "${rule.name}" went from $allowed to $now: ${rule.advice}.',
        );
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the baseline is tight, so the ratchet holds what was gained', () {
    if (Platform.environment['UPDATE_UI_RATCHET'] == '1') return;
    final current = _scan();
    final baseline = _readBaseline();
    final stale = <String>[];
    baseline.forEach((file, counts) {
      counts.forEach((rule, allowed) {
        final now = current[file]?[rule] ?? 0;
        if (now < allowed) stale.add('$file $rule: $allowed → $now');
      });
    });
    expect(
      stale,
      isEmpty,
      reason:
          'Good, these went down. Lock it in with '
          'UPDATE_UI_RATCHET=1 flutter test test/ui_design_ratchet_test.dart\n'
          '${stale.join('\n')}',
    );
  });
}
