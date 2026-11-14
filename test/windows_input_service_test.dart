import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/update_signature.dart';
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
      // Any program of the user can start on a desktop named Screen-saver,
      // an elevated one included; the screen saver only needs waking.
      expect(handle, contains('wake_only && !IsPointerMotion(inputs[i])'));
      expect(
        handle.indexOf('IsPointerMotion(inputs[i])'),
        lessThan(handle.indexOf('SendInput(')),
      );
      final motion = RegExp(
        r'static bool IsPointerMotion\([\s\S]*?\n  }',
      ).firstMatch(service)!.group(0)!;
      expect(motion, contains('input.type == INPUT_MOUSE'));
      expect(motion, contains('(input.mi.dwFlags & ~kMotionFlags) == 0'));

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
      expect(install, isNot(contains('kAllowElevatedValue')));
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

    // The service runs as LocalSystem and updates itself, with no prompt,
    // from the app's folder, which anything the user runs can write to. If
    // any of these checks went, a program of the user's could get its own
    // code run as LocalSystem, or bring back an older service.
    test('the service updates itself only to signed, newer files', () {
      final manifest = File(
        'windows/runner/input_service_manifest.cpp',
      ).readAsStringSync();
      final update = File(
        'windows/runner/input_service_update.cpp',
      ).readAsStringSync();

      // The keys that sign update packages, and no other.
      final keys = RegExp(
        r'const SigningKey kManifestSigningKeys\[\] = \{([\s\S]*?)\n\};',
      ).firstMatch(manifest)!.group(1)!;
      final native = [
        for (final key in RegExp(r'\{([^{}]*)\}').allMatches(keys))
          base64.encode([
            for (final byte in RegExp(
              r'0x([0-9a-f]{2})',
            ).allMatches(key.group(1)!))
              int.parse(byte.group(1)!, radix: 16),
          ]),
      ];
      expect(native, whisperUpdateSigningKeys);
      expect(manifest, contains('crypto_ed25519_check('));
      expect(
        manifest,
        contains(
          'constexpr char kHeader[] = '
          '"whisper-input-service-v1\\n";',
        ),
      );

      final body = update.substring(update.indexOf('DWORD ReadOffer('));
      int at(String code) {
        final index = body.indexOf(code);
        expect(index, isNonNegative, reason: code);
        return index;
      }

      // What the client offers is read as the client's user, from a local
      // drive: never with this machine's rights or credentials.
      expect(
        at('ClientIdentity client(process);'),
        lessThan(at('LocalProcessDirectory(process)')),
      );
      expect(
        at('LocalProcessDirectory(process)'),
        lessThan(at('ReadWholeFile(')),
      );
      expect(update, contains('== DRIVE_REMOTE'));
      expect(at('VerifyManifest('), lessThan(at('IsNewer(')));
      expect(
        at('if (!IsNewer(manifest.version, kOwnVersion)) {'),
        lessThan(at('ReadWholeFile(source + L"\\\\" + name')),
      );
      expect(at('!= file.sha512'), lessThan(at('Replace(target, files)')));
      expect(at('Replace(target, files)'), lessThan(at('StartRestart(')));
      // Nobody can change a file between its check and its copy.
      expect(update, contains('GENERIC_READ, FILE_SHARE_READ, nullptr,'));

      final handle = RegExp(
        r'DWORD Handle\(const Request& request, Response\* response\)[\s\S]*?\n  }',
      ).firstMatch(service)!.group(0)!;
      expect(
        handle,
        contains(
          'return request.version < whisper_input_service::kUpdateVersion',
        ),
      );
      // The restart role does nothing for the app's own copy.
      expect(
        service,
        contains(
          'if (mode == whisper_input_service::kRestartArgument && '
          'IsInstalledCopy()) {',
        ),
      );

      // Everything elevated but installing runs the installed copy, which
      // only an administrator can have put in Program Files.
      final elevated = RegExp(
        r'DWORD RunElevated\(const wchar_t\* argument\) \{[\s\S]*?\n  }',
      ).firstMatch(client)!.group(0)!;
      expect(
        elevated,
        contains(
          'if (wcscmp(argument, whisper_input_service::kInstallArgument) != 0',
        ),
      );
      expect(elevated, contains('path = installed;'));
      expect(protocol, contains('FOLDERID_ProgramFiles'));
      final installer = File('windows/installer.nsi').readAsStringSync();
      expect(
        installer,
        contains(
          r'ExecShellWait "runas" "${INPUT_SERVICE_EXE}" '
          '"--uninstall-input-service"',
        ),
      );
    });

    test('the release signs the input service apart from the build', () {
      final workflow = File('.github/workflows/release.yml').readAsStringSync();
      String job(String name) {
        final start = workflow.indexOf('\n  $name:\n');
        expect(start, isNonNegative, reason: name);
        final end = workflow.indexOf(RegExp(r'\n  [a-z-]+:\n'), start + 1);
        return workflow.substring(start, end < 0 ? workflow.length : end);
      }

      final build = job('build-on-windows');
      final sign = job('sign-windows-input-service');
      final package = job('package-windows');
      expect(build, isNot(contains('secrets.')));
      expect(sign, contains(r'${{ secrets.UPDATE_SIGNING_KEY }}'));
      expect(sign, contains('script/sign_input_service.sh'));
      expect(sign, isNot(contains('flutter')));
      // Only what is published, whose version verify-release-version held
      // to pubspec.yaml: a test run's manifest, at any version, would be
      // taken by every service and never expire.
      expect(
        sign,
        contains(
          "if: \${{ startsWith(github.ref, 'refs/tags/') || "
          "(github.event_name == 'workflow_dispatch' && inputs.publish) }}",
        ),
      );
      expect(package, isNot(contains('secrets.')));
      expect(package, contains('whisper_input_service.manifest.sig'));
      expect(job('publish-release'), contains('- package-windows'));
    });
  });
}
