import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/windows_input_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WindowsInputServiceController', () {
    const channel = MethodChannel('test/windows_input_service');
    final calls = <String>[];
    late List<String> states;
    late bool elevated;
    PlatformException? elevationError;

    WindowsInputServiceController controller({bool supported = true}) {
      return WindowsInputServiceController(
        channel: channel,
        supported: supported,
        pollInterval: Duration.zero,
        pollAttempts: 3,
      );
    }

    setUp(() {
      calls.clear();
      states = <String>['notInstalled'];
      elevated = false;
      elevationError = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'getInputServiceState') {
              return states.length > 1 ? states.removeAt(0) : states.single;
            }
            if (call.method == 'getElevatedInputAllowed') return elevated;
            if (elevationError != null) throw elevationError!;
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('uninstalling withdraws elevated control with the service', () async {
      states = <String>['running'];
      elevated = true;
      final service = controller();
      await service.refresh();
      expect(service.elevatedAllowed, isTrue);

      states = <String>['notInstalled'];
      final result = await service.uninstall();

      expect(result, WindowsInputServiceResult.applied);
      expect(service.elevatedAllowed, isFalse);
      expect(calls, isNot(contains('disableElevatedInput')));
    });

    test(
      'a declined elevated-control prompt does not change the flag',
      () async {
        states = <String>['running'];
        elevated = true;
        final service = controller();
        await service.refresh();

        elevationError = PlatformException(code: 'cancelled');
        final result = await service.setElevatedAllowed(false);

        expect(result, WindowsInputServiceResult.cancelled);
        expect(service.elevatedAllowed, isTrue);
        expect(calls, contains('disableElevatedInput'));
      },
    );
  });

  group('Windows input service source', () {
    final service = File('windows/runner/input_service.cpp').readAsStringSync();
    final protocol = File(
      'windows/runner/input_service_protocol.h',
    ).readAsStringSync();
    final client = File(
      'windows/runner/remote_input_service_client.h',
    ).readAsStringSync();
    final plugin = File(
      'windows/runner/remote_input_plugin.cpp',
    ).readAsStringSync();

    test('the LocalSystem agent only types on a locked session', () {
      final mayInject = RegExp(
        r'bool MayInject\(const std::wstring& desktop\)[\s\S]*?\n  }',
      ).firstMatch(service)!.group(0)!;
      // UAC consent and Ctrl+Alt+Del share the Winlogon desktop while the
      // session is unlocked, and the user's own desktop is never served,
      // unless an administrator has allowed it.
      expect(
        mayInject,
        contains(
          'if (IsDesktop(desktop, kScreenSaverDesktop) ||\n'
          '        whisper_input_service::ElevatedInputAllowed()) {\n'
          '      return true;',
        ),
      );
      expect(mayInject, contains('if (!IsDesktop(desktop, kLockDesktop)) {'));
      expect(mayInject, contains('SessionIsLocked(session_id_)'));
      expect(service, contains('WTS_SESSIONSTATE_LOCK'));

      final handle = RegExp(
        r'DWORD Handle\(const Request& request, Response\* response\)[\s\S]*?\n  }',
      ).firstMatch(service)!.group(0)!;
      expect(handle, contains('if (!desktop_.Attach(&desktop)) {'));
      expect(
        handle.indexOf('if (!MayInject(desktop)) {'),
        lessThan(handle.indexOf('GetCursorPos(')),
      );
      expect(
        handle.indexOf('if (!MayInject(desktop)) {'),
        lessThan(handle.indexOf('SendInput(')),
      );
      expect(
        handle,
        contains('request.count > whisper_input_service::kMaxInputs'),
      );

      final copyInput = RegExp(
        r'static bool CopyInput\([\s\S]*?\n  }',
      ).firstMatch(service)!.group(0)!;
      expect(copyInput, contains('source.type == INPUT_MOUSE'));
      expect(copyInput, contains('source.type == INPUT_KEYBOARD'));
      expect(copyInput, isNot(contains('dwExtraInfo')));
      expect(copyInput, contains('return false;'));
    });

    test('reaching UAC prompts is an administrator-only policy', () {
      // Kept under HKLM, where only an elevated role can write it, and read
      // from there by the agent rather than taken from a request.
      expect(
        protocol,
        contains(r'kPolicyRegistryKey[] = L"SOFTWARE\\Whisper\\InputService"'),
      );
      final allowed = RegExp(
        r'inline bool ElevatedInputAllowed\(\)[\s\S]*?\n}',
      ).firstMatch(protocol)!.group(0)!;
      expect(allowed, contains('RegGetValueW(HKEY_LOCAL_MACHINE,'));
      expect(allowed, contains('value != 0;'));

      final policy = RegExp(
        r'DWORD SetElevatedPolicy\(bool allow\)[\s\S]*?\n}',
      ).firstMatch(service)!.group(0)!;
      expect(policy, contains('RegSetKeyValueW(\n      HKEY_LOCAL_MACHINE,'));

      final dispatch = service.substring(
        service.indexOf('std::optional<int> RunInputServiceCommand()'),
      );
      expect(
        dispatch,
        contains(
          'if (mode == whisper_input_service::kEnableElevatedArgument) {\n'
          '    return static_cast<int>(SetElevatedPolicy(true));',
        ),
      );
      expect(
        dispatch,
        contains(
          'if (mode == whisper_input_service::kDisableElevatedArgument) {\n'
          '    return static_cast<int>(SetElevatedPolicy(false));',
        ),
      );

      // Removing the service withdraws it, so a reinstall starts without it.
      final uninstall = RegExp(
        r'DWORD Uninstall\(\)[\s\S]*?\n}',
      ).firstMatch(service)!.group(0)!;
      expect(
        uninstall,
        contains(
          'RegDeleteKeyW(HKEY_LOCAL_MACHINE, '
          'whisper_input_service::kPolicyRegistryKey);',
        ),
      );
      final install = RegExp(
        r'DWORD Install\(\)[\s\S]*?\n}',
      ).firstMatch(service)!.group(0)!;
      expect(install, isNot(contains('kPolicyRegistryKey')));
    });

    test('the app changes the policy only behind a UAC prompt', () {
      expect(plugin, contains('whisper_input_service::ElevatedInputAllowed()'));
      final change = RegExp(
        r'if \(method == "enableElevatedInput" \|\| '
        r'method == "disableElevatedInput"\) \{[\s\S]*?\n    }',
      ).firstMatch(plugin)!.group(0)!;
      expect(change, contains('RunInputServiceElevated('));
      expect(change, contains('kEnableElevatedArgument'));
      expect(change, contains('kDisableElevatedArgument'));
      expect(plugin, isNot(contains('RegSetKeyValueW(HKEY_LOCAL_MACHINE')));
      expect(client, isNot(contains('HKEY_LOCAL_MACHINE')));
    });

    test('the plugin uses the service only where SendInput cannot reach', () {
      final anywhere = RegExp(
        r'UINT SendInputAnywhere\(UINT count, INPUT\* inputs\)[\s\S]*?\n}',
      ).firstMatch(plugin)!.group(0)!;
      // An administrator's window in front, where Windows drops SendInput
      // without a word: the service, which refuses unless allowed.
      final above = anywhere.indexOf('if (ForegroundIsAbove()) {');
      final send = anywhere.indexOf('SendInput(count, inputs, sizeof(INPUT))');
      expect(above, isNonNegative);
      expect(above, lessThan(send));
      expect(plugin, contains('return ProcessIntegrity(process_id) > own;'));
      // Anywhere else only when SendInput itself fails.
      expect(send, lessThan(anywhere.lastIndexOf('ServiceSendInput(')));
      expect(anywhere, contains('if (sent != 0) {'));
      expect(
        plugin,
        contains(
          'UINT InjectInput(UINT count, INPUT* inputs) {\n'
          '    return SendInputAnywhere(count, inputs);',
        ),
      );
      // Every other injection goes through InjectInput.
      expect(RegExp(r'(?<![.\w])SendInput\(').allMatches(plugin), hasLength(1));
      expect(
        plugin,
        contains(
          'return GetCursorPos(point) == TRUE || '
          'input_service_.CursorPos(point);',
        ),
      );
      expect(plugin, contains('method == "getInputServiceState"'));
      expect(plugin, contains('error == ERROR_CANCELLED'));
      expect(client, contains('info.lpVerb = L"runas";'));
    });
  });
}
