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
  final sizes = <String, int>{};
  for (final path in (listed.stdout as String).split('\x00')) {
    if (path.isEmpty || limitFor(path) == null) continue;
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

  if (update) {
    if (problems.isNotEmpty) {
      stderr.writeln('The baseline only goes down. Fix these first:');
      problems.forEach(stderr.writeln);
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
  stdout.writeln(
    'File sizes ok: ${baseline.length} files still over the limit, none grew.',
  );
}
