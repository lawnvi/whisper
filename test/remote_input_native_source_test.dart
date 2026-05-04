import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Windows remote input native source', () {
    late String source;

    setUpAll(() {
      source =
          File('windows/runner/remote_input_plugin.cpp').readAsStringSync();
    });

    test('injects keyboard events with scan codes', () {
      expect(source, contains('MapVirtualKeyW'));
      expect(source, contains('KEYEVENTF_SCANCODE'));
      expect(source, contains('KEYEVENTF_EXTENDEDKEY'));
      expect(source, contains('input.ki.wScan'));
    });

    test('does not synthesize caps lock releases during cleanup', () {
      final releaseCommonModifierKeys = RegExp(
        r'void ReleaseCommonModifierKeys\(\)[\s\S]*?\n  void InjectEvent',
      ).firstMatch(source)!.group(0)!;
      expect(releaseCommonModifierKeys, isNot(contains('VK_CAPITAL')));
    });

    test('releases suppressed modifier keys when capture stops or pauses', () {
      expect(
        source,
        contains(
            'ReleaseCommonModifierKeys();\n    capture_session_id_.clear();'),
      );
      expect(
        source,
        contains(
          'ReleaseCommonModifierKeys();\n'
          '      MoveCaptureCursorToLocalEdge();\n'
          '      capture_active_ = false;',
        ),
      );
    });

    test('pins the local cursor to the capture edge when pausing', () {
      final pauseCapture = RegExp(
        r'void PauseCapture\([\s\S]*?\n  void StopInjection',
      ).firstMatch(source)!.group(0)!;
      expect(pauseCapture, contains('MoveCaptureCursorToLocalEdge();'));

      final moveCaptureCursor = RegExp(
        r'void MoveCaptureCursorToLocalEdge\([\s\S]*?\n  bool IsEdgeActivation',
      ).firstMatch(source)!.group(0)!;
      expect(moveCaptureCursor, contains('SetCursorPos('));
      expect(moveCaptureCursor, contains('SM_XVIRTUALSCREEN'));
      expect(moveCaptureCursor, contains('capture_edge_ == "left"'));
      expect(
          moveCaptureCursor, contains('ClampInt(static_cast<int>(current.x)'));
      expect(moveCaptureCursor, isNot(contains('std::min')));
      expect(moveCaptureCursor, isNot(contains('std::max')));
    });

    test('captures all keyboard events in the low-level hook', () {
      expect(source, contains('HandleLowLevelKeyboard(wparam,'));
      expect(source, isNot(contains('LLKHF_INJECTED')));

      final lowLevelKeyboard = RegExp(
        r'bool HandleLowLevelKeyboard\([\s\S]*?\n  bool HandleWindowMessage',
      ).firstMatch(source)!.group(0)!;
      expect(lowLevelKeyboard, contains('EmitInputEvent("key"'));
      expect(lowLevelKeyboard, isNot(contains('IsSystemMetaKey(')));
    });

    test('activates capture from the low-level mouse hook before keys arrive',
        () {
      expect(source, contains('HandleLowLevelMouse('));
      expect(source, contains('ActivateCapture("hook")'));
      expect(source, contains('pending_active_start_ = true;'));
    });

    test('only mouse movement can activate capture at the edge', () {
      final lowLevelMouse = RegExp(
        r'bool HandleLowLevelMouse\([\s\S]*?\n  bool HandleLowLevelKeyboard',
      ).firstMatch(source)!.group(0)!;
      expect(lowLevelMouse, contains('WPARAM wparam'));
      expect(lowLevelMouse, contains('wparam != WM_MOUSEMOVE'));

      final rawMouse = RegExp(
        r'void HandleRawMouse\([\s\S]*?\n  void HandleRawKeyboard',
      ).firstMatch(source)!.group(0)!;
      expect(rawMouse, contains('const bool has_button_or_wheel'));
      expect(rawMouse, contains('!has_button_or_wheel'));
    });

    test('activates keyboard capture when the first key arrives at the edge',
        () {
      expect(source, contains('IsCursorAtCaptureEdge('));
      expect(source, contains('ActivateCapture("keyboard")'));
    });

    test('does not duplicate keyboard events from raw input', () {
      final rawKeyboard = RegExp(
        r'void HandleRawKeyboard\([\s\S]*?\n  bool IsEdgeActivation',
      ).firstMatch(source)!.group(0)!;
      expect(rawKeyboard, isNot(contains('EmitInputEvent("key"')));
    });

    test('keeps low-level keyboard hook parameters available for chaining', () {
      final lowLevelKeyboardProc = RegExp(
        r'static LRESULT CALLBACK LowLevelKeyboardProc\([\s\S]*?\n  bool RegisterRawInput',
      ).firstMatch(source)!.group(0)!;
      expect(lowLevelKeyboardProc, contains('WPARAM wparam'));
      expect(
        lowLevelKeyboardProc,
        contains('CallNextHookEx(nullptr, code, wparam, lparam)'),
      );
    });

    test('keeps raw keyboard input disabled', () {
      final rawKeyboard = RegExp(
        r'void HandleRawKeyboard\([\s\S]*?\n  bool IsEdgeActivation',
      ).firstMatch(source)!.group(0)!;
      expect(
        rawKeyboard,
        contains('void HandleRawKeyboard(const RAWKEYBOARD&) {}'),
      );
    });

    test('reports hook installation and keyboard capture diagnostics', () {
      expect(source, contains('GetLastError()'));
      expect(source, contains('EmitDiagnostic('));
      expect(source, contains('"onDiagnostic"'));
      expect(source, contains('windows remote input capture started'));
      expect(source, contains('windows keyboard hook vk='));
      expect(source, contains('windows keyboard hook inactive vk='));
      expect(source, contains('windows remote input capture paused'));
      expect(source, contains('releaseSequence'));
      expect(source, contains('releaseActivationSequence'));
      expect(source, contains('capture_activation_sequence_'));
      expect(source, contains('windows remote input ignored stale pause'));
      expect(
        source,
        isNot(contains('sequence_ > static_cast<uint64_t>(release_sequence)')),
      );
    });

    test('suppresses mouse events even when drivers mark them injected', () {
      expect(source, isNot(contains('LLMHF_INJECTED')));
      expect(source, contains('return capture_active_;'));
    });

    test('keeps macOS Command and Control distinct in native fallback mapping',
        () {
      expect(source, contains('case 54: return VK_RWIN;'));
      expect(source, contains('case 55: return VK_LWIN;'));
      expect(source, contains('case 59: return VK_LCONTROL;'));
      expect(source, contains('case 62: return VK_RCONTROL;'));
    });

    test('maps Windows Caps Lock to macOS Caps Lock in native fallback', () {
      expect(source, contains('case VK_CAPITAL: return 57;'));
    });
  });

  group('macOS remote input native source', () {
    late String source;

    setUpAll(() {
      source = File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();
    });

    test('posts modifier keys as flagsChanged events', () {
      expect(source, contains('keyEvent.type = .flagsChanged'));
      expect(source, contains('isInjectedModifierKey(Int(keyCode))'));
    });

    test('uses HID keyboard events and handles Caps Lock as input switching',
        () {
      expect(source, contains('import Carbon.HIToolbox'));
      expect(source, contains('CGEventSource(stateID: .hidSystemState)'));
      expect(source, contains('toggleKeyboardInputSource()'));
      expect(source, contains('TISSelectInputSource'));
    });

    test('emits sink-side diagnostics for key injection and caps switching',
        () {
      expect(source, contains('"onDiagnostic"'));
      expect(source, contains('NSLog("remote input diagnostic: %@"'));
      expect(source, contains('mac remote input injection started'));
      expect(source, contains('mac remote input injection release reason='));
      expect(source, contains('mac remote key inject'));
      expect(source, contains('mac caps input source switched'));
    });

    test('preserves native modifier event flags while adding active modifiers',
        () {
      expect(
        source,
        contains(
            'keyEvent.flags = keyEvent.flags.union(injectedModifierFlags)'),
      );
    });

    test('posts Control arrow shortcuts as a complete system shortcut', () {
      expect(source, contains('handleSystemControlArrowShortcut'));
      expect(source, contains('postSystemControlArrowShortcut'));
      expect(source, contains('systemShortcutEventSource'));
      expect(source, contains('suppressedSystemControlArrowKeyCodes'));
    });

    test('tracks injected mouse position for reverse edge release decisions',
        () {
      expect(source, contains('private var injectedMousePoint'));
      expect(source, contains('injectedMousePoint = nil'));
      expect(
        source,
        contains('injectedMousePoint ?? CGEvent(source: nil)?.location'),
      );
      expect(
        source,
        contains(
            'entryPoint == nil && injectedMouseEnteredInterior && isReverseInjectionRelease'),
      );
      expect(source, contains('injectedMousePoint = point'));
    });

    test('arms reverse edge release only after entering screen interior', () {
      expect(source, contains('private var injectedMouseEnteredInterior'));
      expect(source, contains('injectedMouseEnteredInterior = false'));
      expect(
        source,
        contains('injectedMouseEnteredInterior && isReverseInjectionRelease'),
      );
      expect(source, contains('updateInjectedMouseInteriorState'));
      expect(source, contains('injectedMouseEnteredInterior = true'));
    });

    test('keeps Windows Control and Meta distinct in native fallback mapping',
        () {
      expect(source, contains('case 0x11, 0xA2: return 59'));
      expect(source, contains('case 0xA3: return 62'));
      expect(source, contains('case 0x5B: return 55'));
      expect(source, contains('case 0x5C: return 54'));
    });

    test('maps Windows Caps Lock to macOS Caps Lock in sink fallback', () {
      expect(source, contains('case 0x14: return 57'));
    });

    test('logs remote key injection details for debugging', () {
      expect(source, contains('import OSLog'));
      expect(source, contains('remote key inject session='));
      expect(source, contains('post remote key mac='));
    });
  });
}
