import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const ownedDirectories = <String>[
    'lib/page',
    'lib/state',
    'lib/audio',
    'lib/remote_input',
    'lib/helper',
  ];
  const ownedFiles = <String>[
    'lib/main.dart',
    'lib/model/LocalDatabase.dart',
    'lib/socket/file_transfer_engine.dart',
    'lib/socket/file_transfer_v3.dart',
  ];

  test('owned network privacy slice contains no forbidden leak patterns', () {
    final sources = _dartSources(ownedDirectories, ownedFiles);
    final patterns = <String, RegExp>{
      'message or raw frame body': RegExp(
        r'文本消息：|收到消息[^\n]*content|send evt to ui|'
        r'message(?:Data)?\.(?:content|message)[^;\n]*'
        r'(?:logger|debugPrint|print)|'
        r'(?:logger|debugPrint|print)[^;\n]*'
        r'message(?:Data)?\.(?:content|message)',
        caseSensitive: false,
      ),
      'path, URI, or endpoint': RegExp(
        r'path=\$path|uri=\$uri|remoteAddress=|Serving at ws://|wifi ip',
        caseSensitive: false,
      ),
      'dependency or service serialization': RegExp(
        r'printLogs:\s*true|service[^\n]*toString\(|svr\.toString\(',
        caseSensitive: false,
      ),
      'trusted peer discovery attributes': RegExp(
        r'trustedPeers[^\n]{0,200}attributes|'
        r'attributes\s*:\s*\{[\s\S]{0,500}trustedPeers',
        caseSensitive: false,
      ),
      'token or query sink': RegExp(
        r'(?:logger|debugPrint|print|developer\.log)[^;\n]*'
        r'(?:token|query)|'
        r'(?:token|query)[^;\n]*'
        r'(?:logger|debugPrint|print|developer\.log)',
        caseSensitive: false,
      ),
      'remote error copied into state': RegExp(
        r'(?:lastError|errorMessage)\s*:\s*'
        r'(?:message|control)\.errorMessage',
      ),
      'raw local error copied into transfer state': RegExp(
        r'error\.message|osError\?\.message|'
        r"return\s+'[^']*\$error'",
      ),
      'native diagnostic text copied into Dart logs': RegExp(
        r'diagnostic\.message|error\.message',
      ),
      'remote-input payload trace': RegExp(
        r'\b(?:dx|dy|unitX|unitY)=\$',
      ),
    };

    final violations = <String>[];
    for (final entry in sources.entries) {
      for (final pattern in patterns.entries) {
        for (final match in pattern.value.allMatches(entry.value)) {
          violations.add(
            '${entry.key}:${_lineNumber(entry.value, match.start)} '
            '${pattern.key}',
          );
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('owned network privacy slice routes logging through PrivacyLog', () {
    final sources = _dartSources(ownedDirectories, ownedFiles);
    final sinkPatterns = <RegExp>[
      RegExp(
        r'\blogger\s*\.\s*(?:t|d|i|w|e|f|v|wtf)\b',
        caseSensitive: false,
      ),
      RegExp(r'\bdebugPrint(?:Stack)?\b'),
      RegExp(r'\bprint\b(?=\s*(?:\(|[,;)])|\s*$)'),
      RegExp(r'\bdeveloper\.log\b'),
      RegExp(r'(?<!\.)\b(?:stdout|stderr)\b'),
    ];

    final violations = <String>{};
    for (final entry in sources.entries) {
      for (final pattern in sinkPatterns) {
        for (final match in pattern.allMatches(entry.value)) {
          final isOwnedDeveloperSink =
              entry.key == 'lib/helper/privacy_log.dart' &&
                  match.group(0) == 'developer.log';
          if (!isOwnedDeveloperSink) {
            violations.add(
              '${entry.key}:${_lineNumber(entry.value, match.start)} '
              '${match.group(0)}',
            );
          }
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('server start failures never render the exception object', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final startServer = source.substring(
      source.indexOf('Future<void> _startServer'),
      source.indexOf('@override\n  void onPairing'),
    );

    expect(startServer, isNot(contains('result.error}')));
    expect(startServer, contains('DeviceListOperationKind.serverStart'));
    expect(startServer, contains('privacyLog.errorType(error)'));
    expect(startServer, contains('description:'));
    expect(startServer, contains('startServerFailed'));
  });

  test('remote-input packet traces require explicit opt-in and stay bounded',
      () {
    final source = File('lib/remote_input/remote_input_coordinator.dart')
        .readAsStringSync();

    expect(source, contains('static const int _packetTraceLimit = 8;'));
    expect(
      source,
      matches(RegExp(
        r'bool\s+get\s+_shouldTracePackets\s*=>\s*'
        r"Platform\.environment\['WHISPER_REMOTE_INPUT_TRACE'\]\s*==\s*'1'",
      )),
    );
    expect(
      source,
      matches(RegExp(
        r'if\s*\(\s*_shouldTracePackets\s*&&\s*'
        r'_sinkPacketTraceCount\s*<\s*_packetTraceLimit',
      )),
    );
    expect(
      source,
      matches(RegExp(
        r'if\s*\(\s*_shouldTracePackets\s*&&\s*'
        r'_sourcePacketTraceCount\s*<\s*_packetTraceLimit',
      )),
    );
  });
}

Map<String, String> _dartSources(List<String> roots, List<String> paths) {
  final files = <File>[];
  for (final root in roots) {
    files.addAll(
      Directory(root).listSync(recursive: true).whereType<File>().where(
            (file) =>
                file.path.endsWith('.dart') && !file.path.endsWith('.g.dart'),
          ),
    );
  }
  files.addAll(paths.map(File.new).where((file) => file.existsSync()));
  files.sort((left, right) => left.path.compareTo(right.path));
  return <String, String>{
    for (final file in files) file.path: file.readAsStringSync(),
  };
}

int _lineNumber(String source, int offset) {
  return '\n'.allMatches(source.substring(0, offset)).length + 1;
}
