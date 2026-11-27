// Keeps source files from growing past a size where nobody can hold them in
// their head. New files stay under the limit; files already over it are
// listed in tool/size_baseline.txt and may only shrink.
//
//   dart run tool/check_sizes.dart           fail on files over their limit
//   dart run tool/check_sizes.dart --update  lower the baseline after a split
import 'dart:io';

const dartLimit = 1000;
const nativeLimit = 1500;
const baselinePath = 'tool/size_baseline.txt';
const uiSocketBaselinePath = 'tool/ui_socket_import_baseline.txt';

const uiPrefixes = <String>['lib/page/', 'lib/new_ui/', 'lib/widget/'];
const allowedUiSocketFiles = <String>{'svrmanager.dart', 'socket_events.dart'};
final _socketImportPattern = RegExp(
  r'''^\s*(?:import|export)\s+['"](?:package:whisper/socket/|(?:\.\./)+socket/)([^'"]+)['"]''',
  multiLine: true,
);

const nativeExtensions = {
  '.c', '.cc', '.cpp', '.h', '.hpp', '.m', '.mm', '.swift', '.kt', '.java', //
};

// Generated, vendored or not ours to split.
bool skipped(String path) =>
    path.startsWith('test/') ||
    path.startsWith('whisper-web/') ||
    path.startsWith('android_agent/upstream/') ||
    path.contains('/third_party/') ||
    path.startsWith('third_party/') ||
    path.endsWith('.g.dart') ||
    path.startsWith('lib/l10n/app_localizations');

int? limitFor(String path) {
  if (skipped(path)) return null;
  if (path.endsWith('.dart')) return dartLimit;
  final dot = path.lastIndexOf('.');
  if (dot > 0 && nativeExtensions.contains(path.substring(dot))) {
    return nativeLimit;
  }
  return null;
}

Future<void> main(List<String> args) async {
  final update = args.contains('--update');
  final listed = await Process.run('git', ['ls-files', '-z']);
  if (listed.exitCode != 0) {
    stderr.writeln('git ls-files failed: ${listed.stderr}');
    exit(2);
  }
  final trackedFiles = (listed.stdout as String)
      .split('\x00')
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
  final sizes = <String, int>{};
  for (final path in trackedFiles) {
    if (limitFor(path) == null) continue;
    final file = File(path);
    if (!file.existsSync()) continue;
    sizes[path] = '\n'.allMatches(file.readAsStringSync()).length;
  }

  final baseline = <String, int>{};
  final baselineFile = File(baselinePath);
  if (baselineFile.existsSync()) {
    for (final line in baselineFile.readAsLinesSync()) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('#')) continue;
      final space = text.indexOf(' ');
      baseline[text.substring(space + 1)] = int.parse(text.substring(0, space));
    }
  }

  final problems = <String>[];
  final next = <String, int>{};
  for (final entry in sizes.entries) {
    final limit = limitFor(entry.key)!;
    final allowed = baseline[entry.key];
    if (entry.value <= limit) continue;
    if (allowed == null) {
      problems.add('${entry.key}: ${entry.value} lines, limit $limit');
      next[entry.key] = entry.value;
    } else if (entry.value > allowed) {
      problems.add(
        '${entry.key}: grew to ${entry.value} lines from $allowed; '
        'split it before adding more',
      );
      next[entry.key] = allowed;
    } else {
      next[entry.key] = entry.value;
    }
  }

  final uiSocketProblems = _checkUiSocketImports(
    trackedFiles,
    update: update,
    hasSizeProblems: problems.isNotEmpty,
  );

  if (update) {
    if (problems.isNotEmpty || uiSocketProblems.isNotEmpty) {
      stderr.writeln('The baseline only goes down. Fix these first:');
      problems.forEach(stderr.writeln);
      uiSocketProblems.forEach(stderr.writeln);
      exit(1);
    }
    final paths = next.keys.toList()..sort();
    baselineFile.writeAsStringSync(
      '# Files already over the size limit (Dart $dartLimit, native '
      '$nativeLimit lines).\n'
      '# They may only shrink: run `dart run tool/check_sizes.dart --update` '
      'after a split.\n'
      '${paths.map((path) => '${next[path]} $path').join('\n')}\n',
    );
    stdout.writeln('${paths.length} files over the limit recorded.');
    return;
  }
  if (problems.isNotEmpty) {
    stderr.writeln('Files over their size limit (see AGENTS.md):');
    problems.forEach(stderr.writeln);
    exit(1);
  }
  if (uiSocketProblems.isNotEmpty) {
    stderr.writeln(
      'UI files must not import lib/socket/ internals (see AGENTS.md):',
    );
    uiSocketProblems.forEach(stderr.writeln);
    exit(1);
  }
  stdout.writeln(
    'File sizes ok: ${baseline.length} files still over the limit, none grew.',
  );
}

List<String> _checkUiSocketImports(
  List<String> trackedFiles, {
  required bool update,
  required bool hasSizeProblems,
}) {
  final actual = <String>{};
  for (final path in trackedFiles) {
    if (!path.endsWith('.dart') ||
        !uiPrefixes.any((prefix) => path.startsWith(prefix))) {
      continue;
    }
    final file = File(path);
    if (!file.existsSync()) continue;
    for (final match in _socketImportPattern.allMatches(
      file.readAsStringSync(),
    )) {
      final target = match.group(1)!;
      if (!allowedUiSocketFiles.contains(target)) {
        actual.add('$path $target');
      }
    }
  }
  final baselineFile = File(uiSocketBaselinePath);
  final baseline = <String>{};
  if (baselineFile.existsSync()) {
    for (final line in baselineFile.readAsLinesSync()) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('#')) continue;
      baseline.add(text);
    }
  }
  final problems = <String>[
    for (final entry in (actual.difference(baseline).toList()..sort()))
      '$entry (import WsSvrManager or ISocketEvent instead)',
  ];
  if (update && problems.isEmpty && !hasSizeProblems) {
    final sorted = actual.toList()..sort();
    baselineFile.writeAsStringSync(
      '# Existing UI -> lib/socket/ internal imports allowed temporarily.\n'
      '# UI reaches the network through svrmanager.dart and socket_events.dart only.\n'
      '# This list may only shrink: run `dart run tool/check_sizes.dart --update`\n'
      '# after removing an internal import.\n'
      '${sorted.join('\n')}${sorted.isEmpty ? '' : '\n'}',
    );
    stdout.writeln(
      '${sorted.length} UI -> socket internal imports recorded.',
    );
  }
  return problems;
}
