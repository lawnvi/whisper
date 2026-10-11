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
      elevationError = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'getInputServiceState') {
              return states.length > 1 ? states.removeAt(0) : states.single;
            }
            if (elevationError != null) throw elevationError!;
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('stays off the platform channel away from Windows', () async {
      final service = controller(supported: false);

      await service.refresh();
      final result = await service.install();

      expect(result, WindowsInputServiceResult.failed);
      expect(service.state, WindowsInputServiceState.unsupported);
      expect(calls, isEmpty);
    });

    test('waits for the elevated helper to bring the service up', () async {
      states = <String>['notInstalled', 'stopped', 'running'];
      final service = controller();
      final busy = <bool>[];
      service.addListener(() => busy.add(service.busy));

      final result = await service.install();

      expect(result, WindowsInputServiceResult.applied);
      expect(service.state, WindowsInputServiceState.running);
      expect(calls.first, 'installInputService');
      expect(busy, <bool>[true, false]);
    });

    test('a declined elevation prompt is not reported as a failure', () async {
      elevationError = PlatformException(code: 'cancelled');
      final service = controller();

      final result = await service.install();

      expect(result, WindowsInputServiceResult.cancelled);
      expect(service.state, WindowsInputServiceState.notInstalled);
      expect(service.busy, isFalse);
      expect(calls, <String>['installInputService']);
    });

    test('reports a service that never starts', () async {
      states = <String>['stopped'];
      final service = controller();

      final result = await service.install();

      expect(result, WindowsInputServiceResult.failed);
      expect(service.state, WindowsInputServiceState.stopped);
      expect(
        calls.where((call) => call == 'getInputServiceState'),
        hasLength(3),
      );
    });

    test('reads an outdated service and removes it on request', () async {
      states = <String>['outdated'];
      final service = controller();
      await service.refresh();
      expect(service.state, WindowsInputServiceState.outdated);

      states = <String>['running', 'notInstalled'];
      final result = await service.uninstall();

      expect(result, WindowsInputServiceResult.applied);
      expect(service.state, WindowsInputServiceState.notInstalled);
      expect(calls, contains('uninstallInputService'));
    });
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
      // session is unlocked, and the user's own desktop is never served.
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

    test('the pipe is limited to the signed-in user of the session', () {
      expect(service, contains('WTSQueryUserToken(session_id, &token)'));
      expect(service, contains(r'L"O:SYG:SYD:P(A;;GA;;;SY)(A;;GRGW;;;"'));
      expect(service, contains('FILE_FLAG_FIRST_PIPE_INSTANCE'));
      expect(service, contains('PIPE_REJECT_REMOTE_CLIENTS'));
      expect(service, contains('client_session != session_id_'));
      // Pipe names are global; only LocalSystem's pipe gets the keystrokes.
      expect(client, contains('IsWellKnownSid(owner, WinLocalSystemSid)'));
      expect(client, contains('if (!OwnedByLocalSystem(pipe) ||'));
      expect(
        client,
        contains('SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION'),
      );
    });

    test('the service runs from an administrator-only folder', () {
      // The app installs per user, so its own folder is user-writable.
      expect(service, contains('SHGetKnownFolderPath(FOLDERID_ProgramFiles'));
      expect(
        service,
        contains(
          r'L"\"" + target + L"\" " + whisper_input_service::kServiceArgument',
        ),
      );
      expect(service, contains('SERVICE_AUTO_START'));
      expect(service, contains('TokenSessionId'));
      expect(service, contains(r'L"winsta0\\default"'));
      expect(service, contains('WTSGetActiveConsoleSessionId()'));
    });

    test('whisper.exe is the service and starts without Flutter', () {
      final main = File('windows/runner/main.cpp').readAsStringSync();
      // The copy under Program Files has neither Flutter nor the plugins
      // beside it, so its roles must return before anything else runs.
      expect(
        main.indexOf('RunInputServiceCommand()'),
        inInclusiveRange(0, main.indexOf('SingleInstanceLock')),
      );
      final windows = File('windows/CMakeLists.txt').readAsStringSync();
      expect(windows, contains(r'"/DELAYLOAD:${FLUTTER_LIBRARY_NAME}"'));
      expect(
        windows,
        contains(r'"/DELAYLOAD:$<TARGET_FILE_NAME:${plugin}_plugin>"'),
      );
      expect(windows, contains('"delayimp.lib"'));
      expect(
        windows.indexOf('include(flutter/generated_plugins.cmake)'),
        lessThan(windows.indexOf('/DELAYLOAD:')),
      );
      expect(windows, isNot(contains('whisper_input_service')));
      expect(
        File('windows/runner/CMakeLists.txt').readAsStringSync(),
        contains('"input_service.cpp"'),
      );

      final copy = RegExp(
        r'bool CopyServiceFiles\([\s\S]*?\n}',
      ).firstMatch(service)!.group(0)!;
      // The runtime DLLs ship next to the app, not system-wide.
      expect(
        copy,
        contains('for (const wchar_t* library : kRuntimeLibraries)'),
      );
      expect(service, contains('L"vcruntime140_1.dll"'));
      expect(copy, isNot(contains('flutter')));

      final dispatch = service.substring(
        service.indexOf('std::optional<int> RunInputServiceCommand()'),
      );
      expect(dispatch, contains('if (IsInstalledCopy()) {'));
      expect(
        dispatch.indexOf('if (IsInstalledCopy()) {'),
        lessThan(dispatch.indexOf('return std::nullopt;')),
      );
      expect(client, contains('GetModuleFileNameW('));
      expect(client, isNot(contains('kExecutableName')));
    });

    test('the plugin falls back to the service only when SendInput fails', () {
      final injectInput = RegExp(
        r'UINT InjectInput\(UINT count, INPUT\* inputs\)[\s\S]*?\n  }',
      ).firstMatch(plugin)!.group(0)!;
      expect(
        injectInput.indexOf('SendInput(count, inputs, sizeof(INPUT))'),
        lessThan(injectInput.indexOf('input_service_.SendInput(')),
      );
      expect(injectInput, contains('if (sent != 0) {'));
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

    test('the installer installs and updates the service unless opted out', () {
      final installer = File('windows/installer.nsi').readAsStringSync();
      final installArgument = RegExp(
        r'kInstallArgument\[\] = L"([\w-]+)"',
      ).firstMatch(protocol)!.group(1)!;
      final optOutValue = RegExp(
        r'kOptOutRegistryValue\[\] = L"(\w+)"',
      ).firstMatch(protocol)!.group(1)!;
      final install = installer.substring(
        installer.indexOf('Section "Install"'),
        installer.indexOf('Section "Uninstall"'),
      );
      final hook =
          'ExecShellWait "runas" "\$INSTDIR\\\${APP_EXE}" "$installArgument"';
      // The new whisper.exe has to be in place before it installs itself.
      expect(install.indexOf(r'File /r "${BUILD_DIR}\*.*"'), greaterThan(0));
      expect(
        install.indexOf(hook),
        greaterThan(install.indexOf(r'File /r "${BUILD_DIR}\*.*"')),
      );
      // Removing the service in the app must survive the next upgrade.
      expect(
        installer,
        contains('!define INPUT_SERVICE_OPT_OUT "$optOutValue"'),
      );
      expect(
        install.indexOf(
          r'ReadRegDWORD $0 HKCU "Software\${APP_NAME}" "${INPUT_SERVICE_OPT_OUT}"',
        ),
        inInclusiveRange(0, install.indexOf(hook)),
      );
      expect(install, contains(r'StrCmp $0 "1" input_service_installed'));
      expect(installer, contains('!define APP_NAME "Whisper"'));
      expect(
        protocol,
        contains(r'kOptOutRegistryKey[] = L"Software\\Whisper"'),
      );
      expect(client, contains('RegSetKeyValueW(HKEY_CURRENT_USER,'));
      expect(client, contains('RegDeleteKeyValueW(HKEY_CURRENT_USER,'));
      expect(
        plugin,
        contains('RemoteInputServiceClient::RememberOptOut(uninstall);'),
      );
    });

    test('the uninstaller removes the service through whisper.exe', () {
      final installer = File('windows/installer.nsi').readAsStringSync();
      final serviceName = RegExp(
        r'kServiceName\[\] = L"(\w+)"',
      ).firstMatch(protocol)!.group(1)!;
      final uninstallArgument = RegExp(
        r'kUninstallArgument\[\] = L"([\w-]+)"',
      ).firstMatch(protocol)!.group(1)!;
      expect(installer, contains('!define INPUT_SERVICE_NAME "$serviceName"'));
      final uninstall = installer.substring(
        installer.indexOf('Section "Uninstall"'),
      );
      expect(
        uninstall.indexOf(
          'ExecShellWait "runas" "\$INSTDIR\\\${APP_EXE}" "$uninstallArgument"',
        ),
        inInclusiveRange(0, uninstall.indexOf(r'RMDir /r "$INSTDIR"')),
      );
      // Nothing extra to build, ship or check for in the release workflow.
      expect(installer, isNot(contains('whisper_input_service.exe')));
      expect(
        File('.github/workflows/release.yml').readAsStringSync(),
        isNot(contains('whisper_input_service')),
      );
    });

    test('the setting shows the state as a value, not a switch', () {
      final settings = File('lib/page/settings.dart').readAsStringSync();
      final row = RegExp(
        r'if \(_windowsInputService\.supported\)[\s\S]*?\n                          \),\n',
      ).firstMatch(settings)!.group(0)!;
      // A machine-wide service behind a UAC prompt has more states than on
      // and off, and installing it is not a preference to flip.
      expect(row, isNot(contains('CupertinoSwitch')));
      expect(row, contains('trailing: WindowsLockScreenInputStatus('));
      expect(row, contains('changeWindowsLockScreenInput('));
      expect(row, contains('enabled: !service.busy,'));
      expect(
        settings,
        contains(
          'widget.windowsInputService ?? WindowsInputServiceController.shared',
        ),
      );

      final control = File(
        'lib/widget/windows_input_service_setting.dart',
      ).readAsStringSync();
      // A dot carries the colour; the wording still names the state.
      expect(control, contains('palette.trusted'));
      expect(control, contains('palette.warning'));
      expect(control, contains('shape: BoxShape.circle'));
      expect(control, isNot(contains('FilledButton')));
      // One standard confirmation, then UAC.
      expect(control, contains('await confirmAction('));
      expect(control, contains('isDestructive: uninstall,'));
      expect(control, contains('l10n.windowsLockScreenInputFailed'));

      for (final path in [
        'lib/l10n/app_zh.arb',
        'lib/l10n/app_en.arb',
        'lib/l10n/app_es.arb',
      ]) {
        final arb = File(path).readAsStringSync();
        for (final key in [
          'windowsLockScreenInput',
          'windowsLockScreenInputHint',
          'windowsLockScreenInputDesc',
          'windowsLockScreenInputUninstallDesc',
          'windowsLockScreenInputNotInstalled',
          'windowsLockScreenInputRunning',
          'windowsLockScreenInputStopped',
          'windowsLockScreenInputOutdated',
          'windowsLockScreenInputInstall',
          'windowsLockScreenInputRepair',
          'windowsLockScreenInputUninstall',
          'windowsLockScreenInputWorking',
          'windowsLockScreenInputFailed',
        ]) {
          expect(arb, contains('"$key"'), reason: '$path lacks $key');
        }
      }
    });
  });
}
