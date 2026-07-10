import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('native log privacy source gates', () {
    test('Android logging is owned by an explicit opt-in typed allowlist', () {
      final privacyLog = File(
        'android/app/src/main/kotlin/com/vireen/whisper/NativePrivacyLog.kt',
      );
      expect(privacyLog.existsSync(), isTrue);
      if (!privacyLog.existsSync()) {
        return;
      }

      final helper = privacyLog.readAsStringSync();
      final android = _readSources('android/app/src/main', const {
        '.kt',
        '.java',
      });
      expect(helper, contains('enum class NativeLogEvent'));
      expect(helper, contains('enum class NativeLogReason'));
      expect(
        helper,
        contains('System.getenv("WHISPER_REMOTE_INPUT_TRACE") == "1"'),
      );
      expect(helper, isNot(contains('ApplicationInfo.FLAG_DEBUGGABLE')));
      expect(helper, contains('if (!enabled) return'));
      _expectTypedWrappers(helper, RegExp(r'fun event\s*\('));
      expect(_matches(android, RegExp(r'\bLog\.[vdiew]\s*\(')), 1);
      expect(android, isNot(contains(', error)')));
      expect(android, isNot(contains(', exception)')));
      expect(android, isNot(contains('session=\$sessionId')));
      expect(android, isNot(contains('active=\$activeSessionId')));
      expect(android, isNot(contains('peakLeft=')));
      expect(android, isNot(contains('peakRight=')));
      expect(android, isNot(contains('NativeLogEvent.audioWriteProgress')));
    });

    test('Apple native logs use one typed opt-in event sink', () {
      final macos = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      final ios = _readSources('ios/Runner', const {'.swift', '.m', '.mm'});

      expect(macos, contains('enum RemoteInputTraceEvent'));
      expect(
        macos,
        contains(
          'ProcessInfo.processInfo.environment["WHISPER_REMOTE_INPUT_TRACE"] == "1"',
        ),
      );
      expect(macos, isNot(contains('#if DEBUG')));
      expect(macos, contains('traceRemoteInput('));
      _expectTypedWrappers(
        macos,
        RegExp(r'private func traceRemoteInput\s*\('),
      );
      _expectTypedWrappers(
        macos,
        RegExp(r'private func emitDiagnostic\s*\('),
      );
      _expectTypedWrappers(
        macos,
        RegExp(r'private func emitInjectedDiagnostic\s*\('),
      );
      expect(_matches(macos, RegExp(r'\bos_log\s*\(')), 1);
      expect(macos, isNot(contains('NSLog(')));
      expect(macos, isNot(contains('session=%{public}@')));
      expect(macos, isNot(contains('remote key inject')));
      expect(macos, isNot(contains('remote mouse inject')));
      expect(macos, isNot(contains('post remote key mac=')));
      expect(macos, isNot(contains('WhisperAudioCapture frame session=')));
      expect(macos, isNot(contains('audioCaptureProgress')));
      expect(macos, isNot(contains('frameLogCount')));
      expect(
        _matches(ios, RegExp(r'\b(NSLog|os_log|print)\s*\(')),
        0,
      );
    });

    test('Linux trace and Windows diagnostics accept only event enums', () {
      final linuxRemote =
          File('linux/remote_input_plugin.cc').readAsStringSync();
      final linuxAudio = File('linux/audio_share_plugin.cc').readAsStringSync();
      final windows =
          File('windows/runner/remote_input_plugin.cpp').readAsStringSync();

      expect(linuxRemote, contains('enum class RemoteInputTraceEvent'));
      expect(
        linuxRemote,
        contains(
          'return value != nullptr && std::strcmp(value, "1") == 0;',
        ),
      );
      expect(
        linuxRemote,
        contains('TraceRemoteInput(RemoteInputTraceEvent event'),
      );
      _expectTypedWrappers(
        linuxRemote,
        RegExp(r'void TraceRemoteInput\s*\('),
      );
      _expectTypedWrappers(
        linuxRemote,
        RegExp(r'void EmitDiagnostic\s*\('),
      );
      expect(_matches(linuxRemote, RegExp(r'\bg_printerr\s*\(')), 1);
      expect(linuxRemote, isNot(contains('TraceRemoteInput(trace.str())')));
      expect(linuxRemote, isNot(contains('TraceRemoteInput("')));
      expect(linuxRemote, isNot(contains('session=" +')));
      expect(linuxAudio, isNot(contains('g_print(')));

      expect(windows, contains('enum class RemoteInputDiagnosticEvent'));
      expect(
        windows,
        contains(
          'return value != nullptr && std::strcmp(value, "1") == 0;',
        ),
      );
      expect(
        windows,
        contains('EmitDiagnostic(RemoteInputDiagnosticEvent event)'),
      );
      _expectTypedWrappers(
        windows,
        RegExp(r'void EmitDiagnostic\s*\('),
      );
      expect(windows, contains('WHISPER_REMOTE_INPUT_TRACE'));
      expect(windows, isNot(contains('EmitDiagnostic(diagnostic.str())')));
      expect(windows, isNot(contains('windows keyboard hook vk=')));
      expect(windows, isNot(contains('windows keyboard hook inactive vk=')));
      expect(windows, isNot(contains('cursor=" <<')));
    });

    test('Linux application warnings use a typed stable reason', () {
      final application = File('linux/my_application.cc').readAsStringSync();

      expect(application, contains('enum class ApplicationLogReason'));
      expect(
        application,
        contains('LogApplicationWarning(ApplicationLogReason reason)'),
      );
      expect(_matches(application, RegExp(r'\bg_warning\s*\(')), 1);
      _expectTypedWrappers(
        application,
        RegExp(r'void LogApplicationWarning\s*\('),
      );
      expect(application, isNot(contains('error->message')));
      expect(application, isNot(contains('error.message')));
    });

    test('native diagnostic events never carry routing session ids', () {
      final macos =
          File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();
      final linux = File('linux/remote_input_plugin.cc').readAsStringSync();
      final windows =
          File('windows/runner/remote_input_plugin.cpp').readAsStringSync();

      final macDiagnostic = _block(
        macos,
        RegExp(r'private func emitDiagnostic\s*\('),
      );
      final linuxDiagnostic = _block(
        linux,
        RegExp(r'void EmitDiagnostic\s*\('),
      );
      final windowsDiagnostic = _block(
        windows,
        RegExp(r'void EmitDiagnostic\s*\('),
      );
      for (final diagnostic in [
        macDiagnostic,
        linuxDiagnostic,
        windowsDiagnostic,
      ]) {
        expect(diagnostic, contains('event'));
        expect(diagnostic, isNot(contains('sessionId')));
        expect(diagnostic, isNot(contains('session_id')));
        expect(diagnostic, isNot(contains('SessionId')));
      }
      expect(
        linux,
        contains('event->method != "onDiagnostic"'),
      );
    });

    test('injected-event diagnostics are generic and payload-free', () {
      final macos =
          File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();
      final linux = File('linux/remote_input_plugin.cc').readAsStringSync();
      final windows =
          File('windows/runner/remote_input_plugin.cpp').readAsStringSync();
      final allowlists = [
        _enumBlock(macos, 'RemoteInputTraceEvent'),
        _enumBlock(linux, 'RemoteInputTraceEvent'),
        _enumBlock(windows, 'RemoteInputDiagnosticEvent'),
      ];

      for (final allowlist in allowlists) {
        expect(
          allowlist,
          anyOf(
            contains('injected'),
            contains('EventCaptured'),
            contains('event_captured'),
          ),
        );
        expect(
          allowlist.toLowerCase(),
          isNot(RegExp(r'caps|key|mouse|cursor|coord|delta|payload|code')),
        );
      }
    });

    test('native sinks never receive raw errors or sensitive fields', () {
      const scannerFixture = r'''
debugPrint('body');
Logger.error('body');
Log.wtf(TAG, "body");
System.err.println("body");
g_message("body");
g_debug("body");
std::cerr << "body";
fprintf(stderr, "body");
OutputDebugStringW(L"body");

void TraceRemoteInput(RemoteInputTraceEvent event) {}
void TraceRemoteInput(const std::string& raw_message) {}
''';
      expect(_sinkStatements(scannerFixture), hasLength(9));
      final fixtureDeclarations = _declarations(
        scannerFixture,
        RegExp(r'void TraceRemoteInput\s*\('),
      ).toList();
      expect(fixtureDeclarations, hasLength(2));
      expect(
        fixtureDeclarations.where(_hasUnsafeWrapperParameter),
        hasLength(1),
      );

      final sources = [
        _readSources('android/app/src/main', const {'.kt', '.java'}),
        _readSources('ios/Runner', const {'.swift', '.m', '.mm'}),
        _readSources('macos/Runner', const {'.swift', '.m', '.mm'}),
        _readSources('linux', const {'.cc', '.cpp', '.c'}),
        _readSources('windows/runner', const {'.cc', '.cpp', '.c'}),
      ];
      final calls = sources.expand(_sinkStatements).toList();
      expect(calls, hasLength(4));

      for (final call in calls) {
        final normalized = call.toLowerCase();
        for (final forbidden in const [
          'activesessionid',
          'clipboard',
          'code',
          'content',
          'coord',
          'dx=',
          'dy=',
          'endpoint',
          'error',
          'error->message',
          'exception',
          'group',
          'host',
          'input',
          'ip=',
          'key',
          'localizeddescription',
          'message_content',
          'message',
          'notification',
          'pairingcode',
          'path=',
          'publickey',
          'remoteaddress',
          'session',
          'signature',
          'stream',
          'token=',
          'uid=',
          'uri=',
          'user_id',
          '.what',
          'x=',
          'y=',
        ]) {
          expect(normalized, isNot(contains(forbidden)), reason: call);
        }
      }
    });
  });
}

String _readSources(String root, Set<String> extensions) {
  final directory = Directory(root);
  if (!directory.existsSync()) {
    return '';
  }
  final files = directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => extensions.any(file.path.endsWith))
      .where((file) => !file.path.contains('GeneratedPluginRegistrant'))
      .where((file) => !file.path.contains('/flutter/ephemeral/'))
      .where((file) => !file.path.contains('/build/'))
      .toList()
    ..sort((left, right) => left.path.compareTo(right.path));
  return files.map((file) => file.readAsStringSync()).join('\n');
}

int _matches(String source, RegExp pattern) =>
    pattern.allMatches(source).length;

final RegExp _sinkStartPattern = RegExp(
  r'\b(?:debugPrint(?:Stack)?|print|NSLog|os_log|'
  r'(?:android\.util\.)?Log\.(?:v|d|i|w|e|wtf)|'
  r'(?:Logger|logger)\.(?:trace|debug|info|warn|warning|error|fatal|log)|'
  r'System\.(?:out|err)\.(?:print|println|printf)|'
  r'g_(?:print|printerr|warning|message|debug)|'
  r'fprintf|printf|syslog|OutputDebugString(?:A|W)?)\s*\('
  r'|\bstd::(?:cout|cerr|clog)\s*<<',
);

Iterable<String> _sinkStatements(String source) sync* {
  for (final match in _sinkStartPattern.allMatches(source)) {
    if (match.group(0)!.trimRight().endsWith('<<')) {
      final semicolon = source.indexOf(';', match.end);
      yield source.substring(
        match.start,
        semicolon < 0 ? source.length : semicolon + 1,
      );
      continue;
    }
    var depth = 1;
    var index = match.end;
    while (index < source.length && depth > 0) {
      final character = source[index];
      if (character == '(') {
        depth++;
      } else if (character == ')') {
        depth--;
      }
      index++;
    }
    yield source.substring(match.start, index);
  }
}

Iterable<String> _declarations(String source, RegExp startPattern) sync* {
  for (final match in startPattern.allMatches(source)) {
    var depth = 1;
    var index = match.end;
    while (index < source.length && depth > 0) {
      final character = source[index];
      if (character == '(') {
        depth++;
      } else if (character == ')') {
        depth--;
      }
      index++;
    }
    yield source.substring(match.start, index);
  }
}

bool _hasUnsafeWrapperParameter(String declaration) {
  return RegExp(
    r'\b(?:String|Any|Object|Throwable|Exception|Error|GError|HRESULT|Uri|URL|Data|CGPoint|CGKeyCode)\b|'
    r'std::string|char\s*\*',
  ).hasMatch(declaration);
}

void _expectTypedWrappers(String source, RegExp startPattern) {
  final declarations = _declarations(source, startPattern).toList();
  expect(declarations, isNotEmpty, reason: startPattern.pattern);
  for (final declaration in declarations) {
    expect(
      _hasUnsafeWrapperParameter(declaration),
      isFalse,
      reason: declaration,
    );
    expect(
      declaration,
      anyOf(
        matches(RegExp(r'\(\s*\)')),
        contains('NativeLogEvent'),
        contains('RemoteInputTraceEvent'),
        contains('RemoteInputDiagnosticEvent'),
        contains('ApplicationLogReason'),
      ),
      reason: declaration,
    );
  }
}

String _block(String source, RegExp startPattern) {
  final match = startPattern.firstMatch(source);
  expect(match, isNotNull, reason: startPattern.pattern);
  final openBrace = source.indexOf('{', match!.end);
  expect(openBrace, isNonNegative, reason: startPattern.pattern);
  var depth = 1;
  var index = openBrace + 1;
  while (index < source.length && depth > 0) {
    final character = source[index];
    if (character == '{') {
      depth++;
    } else if (character == '}') {
      depth--;
    }
    index++;
  }
  return source.substring(match.start, index);
}

String _enumBlock(String source, String name) {
  return _block(
    source,
    RegExp('enum(?: class)? $name(?:\\s*:[^{]+)?\\s*'),
  );
}
