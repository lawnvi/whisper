import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Windows remote input native source', () {
    late String source;

    setUpAll(() {
      source = File(
        'windows/runner/remote_input_plugin.cpp',
      ).readAsStringSync();
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
          'ReleaseCommonModifierKeys();\n    capture_session_id_.clear();',
        ),
      );
      expect(source, contains('capture_requires_interior_rearm_ = true;'));
    });

    test('pins the local cursor to the capture edge when pausing', () {
      final pauseCapture = RegExp(
        r'void PauseCapture\([\s\S]*?\n  void StopInjection',
      ).firstMatch(source)!.group(0)!;
      expect(
        pauseCapture,
        contains('MoveCaptureCursorToLocalEdge(release_edge_unit);'),
      );

      final moveCaptureCursor = RegExp(
        r'void MoveCaptureCursorToLocalEdge\([\s\S]*?\n  bool IsEdgeActivation',
      ).firstMatch(source)!.group(0)!;
      expect(moveCaptureCursor, contains('SetCursorPos('));
      expect(moveCaptureCursor, contains('CaptureArea()'));
      expect(moveCaptureCursor, contains('capture_segment_'));
      expect(moveCaptureCursor, contains('SegmentCoordinate'));
      expect(moveCaptureCursor, contains('capture_edge_ == "left"'));
      expect(
        moveCaptureCursor,
        contains('ClampInt(static_cast<int>(current.x)'),
      );
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

    test(
      'activates capture from the low-level mouse hook before keys arrive',
      () {
        expect(source, contains('HandleLowLevelMouse('));
        expect(source, contains('ActivateCapture("hook")'));
        expect(source, contains('pending_active_start_ = true;'));
      },
    );

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

    test('requires local interior movement before rearming an edge', () {
      final lowLevelMouse = RegExp(
        r'bool HandleLowLevelMouse\([\s\S]*?\n  bool HandleLowLevelKeyboard',
      ).firstMatch(source)!.group(0)!;
      final pauseCapture = RegExp(
        r'void PauseCapture\([\s\S]*?\n  void StopInjection',
      ).firstMatch(source)!.group(0)!;

      expect(source, contains('capture_requires_interior_rearm_'));
      expect(source, contains('CaptureCursorEnteredInterior'));
      expect(
        pauseCapture,
        contains('capture_requires_interior_rearm_ = true;'),
      );
      expect(
        lowLevelMouse.indexOf('capture_requires_interior_rearm_'),
        lessThan(lowLevelMouse.indexOf('IsEdgeActivation')),
      );
    });

    test(
      'activates keyboard capture when the first key arrives at the edge',
      () {
        expect(source, contains('IsCursorAtCaptureEdge('));
        expect(source, contains('ActivateCapture("keyboard")'));
      },
    );

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

    test('reports allowlisted hook and capture diagnostic events', () {
      expect(source, contains('GetLastError()'));
      expect(source, contains('EmitDiagnostic('));
      expect(source, contains('"onDiagnostic"'));
      expect(source, contains('RemoteInputDiagnosticEvent::kCaptureStarted'));
      expect(source, contains('RemoteInputDiagnosticEvent::kEventCaptured'));
      expect(source, contains('RemoteInputDiagnosticEvent::kEventIgnored'));
      expect(source, contains('RemoteInputDiagnosticEvent::kCapturePaused'));
      expect(source, contains('releaseSequence'));
      expect(source, contains('releaseActivationSequence'));
      expect(source, contains('capture_activation_sequence_'));
      expect(
        source,
        contains('RemoteInputDiagnosticEvent::kStalePauseIgnored'),
      );
      expect(
        source,
        isNot(contains('sequence_ > static_cast<uint64_t>(release_sequence)')),
      );
    });

    test(
      'uses monitor topology and shared edge units for multi-screen input',
      () {
        expect(source, contains('EnumDisplayMonitors'));
        expect(source, contains('GetMonitorInfoW'));
        expect(source, contains('getDisplayTopology'));
        expect(source, contains('DisplayTopologyValue'));
        expect(source, contains('capture_display_id_'));
        expect(source, contains('injection_display_id_'));
        expect(source, contains('EdgeUnitForPoint'));
        expect(source, contains('"edgeUnit"'));
        expect(source, contains('PointInSegment'));
        expect(source, contains('GetMapSegments'));
        expect(source, contains('struct CaptureRoute'));
        expect(source, contains('GetMapCaptureRoutes'));
        expect(source, contains('capture_routes_'));
        expect(source, contains('ApplyCaptureRoute'));
        expect(source, contains('UpdateInjectionRouteFromPayload'));
        expect(source, contains('JsonString(json, "sinkDisplayId"'));
        expect(source, contains('injection_routes_'));
        expect(source, contains('ReverseInjectionSourceEdgeUnit'));
        expect(source, contains('"sourceEdgeUnit"'));
      },
    );

    test('returns source route metadata for routed Windows reverse release', () {
      expect(source, contains('struct InjectionReleaseRoute'));
      expect(
        source,
        contains(
          'std::optional<InjectionReleaseRoute> ReverseInjectionSourceEdgeUnit',
        ),
      );
      expect(source, contains('route.source_display_id'));
      expect(source, contains('route.source_edge'));
      expect(source, contains('"sourceDisplayId"'));
      expect(source, contains('"sourceEdge"'));
      expect(source, contains('"sourceSegmentStart"'));
      expect(source, contains('"sourceSegmentEnd"'));
    });

    test(
      'arms Windows reverse edge release only after entering screen interior',
      () {
        expect(source, contains('injected_cursor_entered_interior_'));
        expect(source, contains('UpdateInjectedCursorInteriorState'));
        expect(
          source,
          contains(
            '!JsonBool(json, "activeStart") && injected_cursor_entered_interior_',
          ),
        );
      },
    );

    test(
      'routes Windows portals by crossing route id instead of first match',
      () {
        expect(source, contains('std::string route_id;'));
        expect(source, contains('"routeId"'));
        expect(source, contains('JsonEscapedString'));
        expect(source, contains('JsonStringValue'));
        expect(source, contains('ResolveCaptureCrossing'));
        expect(source, contains('ResolveCaptureCursorRoute'));
        expect(source, contains('ResolveInjectionReleaseCrossing'));
        expect(source, contains('previous_point'));
        expect(
          source,
          isNot(
            contains(
              'for (const auto& route : capture_routes_) {\n'
              '        if (IsEdgeActivationForRoute(route, point, delta_x, delta_y))',
            ),
          ),
        );
        expect(
          source,
          isNot(
            contains(
              'for (const auto& route : capture_routes_) {\n'
              '        if (IsCursorAtRouteEdge(route, point))',
            ),
          ),
        );
      },
    );

    test('keeps non-contiguous Windows portal endpoints enterable', () {
      expect(source, contains('other.source_segment.start <= segment.end'));
      expect(source, contains('other.sink_segment.start <= segment.end'));
    });

    test('suppresses mouse events even when drivers mark them injected', () {
      expect(source, isNot(contains('LLMHF_INJECTED')));
      expect(source, contains('return capture_active_;'));
    });

    test('clamps injected mouse movement through the Windows input queue', () {
      expect(source, contains('POINT CurrentCursorPoint() const'));
      expect(source, contains('POINT ClampToVirtualScreen(POINT point) const'));
      expect(source, contains('void MoveCursorToPoint(POINT point)'));
      expect(source, contains('MOUSEEVENTF_ABSOLUTE'));
      expect(source, contains('MOUSEEVENTF_VIRTUALDESK'));

      final clampToVirtualScreen = RegExp(
        r'POINT ClampToVirtualScreen\(POINT point\) const[\s\S]*?\n  void MoveCursorToPoint',
      ).firstMatch(source)!.group(0)!;
      expect(clampToVirtualScreen, contains('VirtualScreenArea()'));
      expect(clampToVirtualScreen, isNot(contains('InjectionArea()')));
      expect(clampToVirtualScreen, isNot(contains('injection_display_id_')));

      final injectEvent = RegExp(
        r'void InjectEvent\([\s\S]*?\n  bool IsInjectionReverseRelease',
      ).firstMatch(source)!.group(0)!;
      final mouseMoveCase = RegExp(
        r'if \(event_type == "mouseMove"\)[\s\S]*?\n      return;',
      ).firstMatch(injectEvent)!.group(0)!;
      expect(mouseMoveCase, contains('current = CurrentCursorPoint();'));
      expect(
        mouseMoveCase,
        contains('POINT target = {current.x + delta_x, current.y + delta_y};'),
      );
      expect(mouseMoveCase, contains('target = ClampToVirtualScreen(target);'));
      expect(mouseMoveCase, contains('MoveCursorToPoint(target);'));
      expect(mouseMoveCase, isNot(contains('SetCursorPos')));
      expect(mouseMoveCase, isNot(contains('MOUSEEVENTF_MOVE')));
    });

    test('coalesces simple mouse clicks before injecting them on Windows', () {
      expect(source, contains('pending_injected_buttons_'));
      expect(source, contains('void QueueInjectedButtonDown(int button)'));
      expect(source, contains('void FlushPendingInjectedButtons()'));
      expect(source, contains('void SendMouseButtonClick(int button)'));

      final injectEvent = RegExp(
        r'void InjectEvent\([\s\S]*?\n  bool IsInjectionReverseRelease',
      ).firstMatch(source)!.group(0)!;
      final mouseMoveCase = RegExp(
        r'if \(event_type == "mouseMove"\)[\s\S]*?\n      return;',
      ).firstMatch(injectEvent)!.group(0)!;
      expect(mouseMoveCase, contains('FlushPendingInjectedButtons();'));

      final mouseButtonCase = RegExp(
        r'if \(event_type == "mouseButton"\)[\s\S]*?\n      return;',
      ).firstMatch(injectEvent)!.group(0)!;
      expect(mouseButtonCase, contains('QueueInjectedButtonDown(button);'));
      expect(mouseButtonCase, contains('ReleaseInjectedButton(button);'));
      expect(
        mouseButtonCase,
        isNot(contains('SendMouseButton(button, down);')),
      );
    });

    test(
      'keeps macOS Command and Control distinct in native fallback mapping',
      () {
        expect(source, contains('case 54: return VK_RWIN;'));
        expect(source, contains('case 55: return VK_LWIN;'));
        expect(source, contains('case 59: return VK_LCONTROL;'));
        expect(source, contains('case 62: return VK_RCONTROL;'));
      },
    );

    test('maps Windows Caps Lock to macOS Caps Lock in native fallback', () {
      expect(source, contains('case VK_CAPITAL: return 57;'));
    });

    test('retains fractional touchpad scroll before Windows injection', () {
      expect(source, contains('ConsumeInjectedScrollDelta'));
      expect(source, contains('injected_scroll_remainder_x_'));
      expect(source, contains('injected_scroll_remainder_y_'));
      expect(source, contains('FlushInjectedScrollRemainder'));
      expect(source, contains('JsonNumber(json, "scrollPhase")'));
      expect(source, contains('JsonNumber(json, "momentumPhase")'));
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

    test('requires local interior movement before rearming an edge', () {
      final handleEvent = RegExp(
        r'fileprivate func handleEvent\([\s\S]*?\n  private func interceptLocalPasteShortcut',
      ).firstMatch(source)!.group(0)!;
      final pauseCapture = RegExp(
        r'private func pauseCapture\([\s\S]*?\n  fileprivate func handleEvent',
      ).firstMatch(source)!.group(0)!;

      expect(source, contains('captureRequiresInteriorRearm'));
      expect(source, contains('captureRearmMotion'));
      expect(pauseCapture, contains('captureRequiresInteriorRearm = true'));
      expect(
        handleEvent.indexOf('captureRequiresInteriorRearm'),
        lessThan(handleEvent.indexOf('captureActivationCrossing')),
      );
    });

    test('creates a virtual HID keyboard for hardware-like Caps Lock', () {
      expect(source, contains('CGEventSource(stateID: .hidSystemState)'));
      expect(source, contains('emitInjectedDiagnostic()'));
      expect(source, contains('import IOKit.hid'));
      expect(source, contains('IOHIDUserDeviceCreateWithProperties'));
      expect(source, contains('kIOHIDReportDescriptorKey'));
      expect(source, contains('kIOHIDPrimaryUsagePageKey'));
      expect(source, contains('kIOHIDPrimaryUsageKey'));
      expect(source, contains('IOHIDUserDeviceSetDispatchQueue'));
      expect(source, contains('IOHIDUserDeviceActivate'));
      expect(source, isNot(contains('TISSelectInputSource')));
      expect(source, contains('postInputSourceShortcut()'));
      expect(source, contains('let spaceKey = CGKeyCode(49)'));
      expect(source, contains('remoteInputShortcutEventMarker'));
      expect(source, contains('remoteInputShortcutSuppressionCallback'));
      final capsPosting = RegExp(
        r'private func postVirtualCapsLockTap\(\)[\s\S]*?\n  private func postInputSourceShortcut',
      ).firstMatch(source)!.group(0)!;
      expect(capsPosting, contains('ensureVirtualKeyboardDevice()'));
      expect(capsPosting, contains('guard let device = virtualKeyboardDevice'));
      expect(capsPosting, contains('if !postInputSourceShortcut()'));
      expect(
        capsPosting.indexOf('guard let device = virtualKeyboardDevice'),
        lessThan(capsPosting.indexOf('postInputSourceShortcut()')),
      );

      for (final path in <String>[
        'macos/Runner/DebugProfile.entitlements',
        'macos/Runner/Release.entitlements',
      ]) {
        final entitlements = File(path).readAsStringSync();
        expect(entitlements, isNot(contains('com.apple.security.app-sandbox')));
        expect(
          entitlements,
          isNot(contains('com.apple.developer.hid.virtual.device')),
        );
        expect(
          entitlements,
          isNot(
            contains(
              'com.apple.security.temporary-exception.iokit-user-client-class',
            ),
          ),
        );
        expect(
          entitlements,
          isNot(contains('com.apple.security.temporary-exception.sbpl')),
        );
      }

      final intelEntitlements = File(
        'macos/Runner/IntelVirtualHID.entitlements',
      ).readAsStringSync();
      expect(
        intelEntitlements,
        contains('com.apple.developer.hid.virtual.device'),
      );
      final buildScript = File('script/build_and_run.sh').readAsStringSync();
      expect(buildScript, contains('INTEL_VIRTUAL_HID_ENTITLEMENTS='));
      expect(
        buildScript,
        contains(
          r'sign_app "$X64_RELEASE_APP_BUNDLE" '
          r'"$INTEL_VIRTUAL_HID_ENTITLEMENTS"',
        ),
      );
      expect(source, contains('postSyntheticCapsLockTap()'));
    });

    test('keeps existing macOS data when leaving App Sandbox', () {
      final databaseSource = File(
        'lib/model/LocalDatabase.dart',
      ).readAsStringSync();

      expect(source, contains('migrateSandboxedPreferencesIfNeeded()'));
      expect(source, contains('WHISPER_SANDBOX_PREFERENCES_MIGRATED_V1'));
      expect(source, contains('Library/Containers'));
      expect(source, contains('key.hasPrefix("flutter")'));
      expect(databaseSource, contains('Future<Directory> _databaseDirectory'));
      expect(
        databaseSource,
        contains(r'$home/Library/Containers/com.vireen.whisper/Data/Documents'),
      );
      expect(databaseSource, contains('getApplicationSupportDirectory()'));
    });

    test('coalesces the Apple Silicon 57 to 255 Caps companion pair', () {
      expect(source, contains('normalizedCapturedMacKeyCode'));
      expect(source, contains('rawKeyCode == 255'));
      expect(source, contains('return 57'));
      expect(source, contains('isCapturedCapsLockEvent'));
      expect(source, contains('payload["modifierSemantic"] = "capsLock"'));
      expect(source, contains('payload["macCapsLockKeyCode"] = rawMacKeyCode'));
      expect(
        source,
        contains(
          'payload["macCapsLockFlags"] = Int64(bitPattern: event.flags.rawValue)',
        ),
      );
      expect(source, contains('? true'));
      expect(source, contains('lastCapturedPrimaryCapsLockTimestamp'));
      expect(source, contains('shouldSkipCapturedCapsLockCompanionEvent'));
      final coalescing = RegExp(
        r'private func shouldSkipCapturedCapsLockCompanionEvent\([\s\S]*?\n  private func modifierFlag',
      ).firstMatch(source)!.group(0)!;
      expect(coalescing, contains('if rawKeyCode == 57'));
      expect(coalescing, contains('guard rawKeyCode == 255'));
      expect(
        coalescing,
        contains('timestamp - primaryTimestamp <= 250_000_000'),
      );
      expect(coalescing, contains('.captureCompanion'));
    });

    test('deduplicates legacy payloads before posting one remote Caps tap', () {
      expect(source, contains('lastInjectedPrimaryCapsLockTimeMicros'));
      expect(source, contains('shouldSkipInjectedCapsLockCompanionEvent'));
      expect(source, contains('down || isMacCapsToggle'));
      expect(source, contains('sourcePlatform == "macos"'));
      expect(source, contains('postVirtualCapsLockTap()'));
      expect(source, contains('report: [0, 0, 0x39, 0, 0, 0, 0, 0]'));
      expect(source, contains('deadline: .now() + 0.08'));
      expect(source, contains('IOHIDUserDeviceHandleReportWithTimeStamp'));
      expect(source, contains('[UInt8](repeating: 0, count: 8)'));
      expect(
        source,
        contains('eventTimeMicros - primaryTimeMicros <= 250_000'),
      );
      expect(source, isNot(contains('selectInputSourceForRemoteCapsLock')));
      expect(source, isNot(contains('postInputSourceRefreshEvent')));
    });

    test(
      'emits allowlisted diagnostics for key injection and caps switching',
      () {
        expect(source, contains('"onDiagnostic"'));
        expect(source, contains('emitDiagnostic(event: .injectionStarted)'));
        expect(source, contains('emitDiagnostic(event: .injectionReleased)'));
        expect(source, contains('case injectedEvent = "injected_event"'));
        expect(source, contains('emitInjectedDiagnostic()'));
        expect(source, isNot(contains('capsShortcutPosted')));
        expect(source, isNot(contains('capsLockPosted')));
        expect(source, isNot(contains('NSLog(')));
      },
    );

    test(
      'requires accessibility permission before accepting sink injection',
      () {
        final injectionCase = RegExp(
          r'case "startInjection":[\s\S]*?case "injectEvent":',
        ).firstMatch(source)!.group(0)!;

        expect(injectionCase, contains('ensureAccessibilityPermission()'));
        expect(injectionCase, contains('openAccessibilitySettings()'));
        expect(injectionCase, contains('remote-input-permission-denied'));
        expect(
          injectionCase.indexOf('ensureAccessibilityPermission()'),
          lessThan(injectionCase.indexOf('injectionSessionId = sessionId')),
        );
      },
    );

    test('builds capture event tap mask with explicit CGEventMask values', () {
      expect(source, contains('remoteInputEventMask(for type: CGEventType)'));
      expect(source, contains('remoteInputCaptureEventMask'));
      expect(source, contains('eventsOfInterest: remoteInputCaptureEventMask'));
      expect(source, isNot(contains('(1 << CGEventType.mouseMoved.rawValue)')));
    });

    test('preserves required arrow flags while using injected modifiers', () {
      final postKeyboardEvent = RegExp(
        r'private func postKeyboardEvent\([\s\S]*?\n  private func setInjectedKey',
      ).firstMatch(source)!.group(0)!;

      expect(source, isNot(contains('remoteInputNativeModifierFlags')));
      expect(
        postKeyboardEvent,
        contains(
          'let nativeFlags = nativeFlagsForRemoteKey(keyCode: Int(keyCode))',
        ),
      );
      expect(
        postKeyboardEvent,
        contains('keyEvent.flags = nativeFlags.union(injectedModifierFlags)'),
      );
      expect(
        postKeyboardEvent,
        isNot(contains('keyEvent.flags = injectedModifierFlags')),
      );
      expect(
        postKeyboardEvent,
        isNot(contains('keyEvent.flags = keyEvent.flags.union')),
      );

      final nativeFlags = RegExp(
        r'private func nativeFlagsForRemoteKey\([\s\S]*?\n  private func setInjectedKey',
      ).firstMatch(source)!.group(0)!;
      expect(nativeFlags, contains('case 123, 124, 125, 126'));
      expect(nativeFlags, contains('.maskSecondaryFn'));
      expect(nativeFlags, contains('.maskNumericPad'));
    });

    test('keeps generated native flags off regular macOS key injection', () {
      final postKeyboardEvent = RegExp(
        r'private func postKeyboardEvent\([\s\S]*?\n  private func setInjectedKey',
      ).firstMatch(source)!.group(0)!;

      expect(source, contains('nativeFlagsForRemoteKey(keyCode:'));
      expect(
        postKeyboardEvent,
        contains(
          'let nativeFlags = nativeFlagsForRemoteKey(keyCode: Int(keyCode))',
        ),
      );
      expect(
        postKeyboardEvent,
        isNot(
          contains(
            'keyEvent.flags.subtracting(remoteInputNativeModifierFlags)',
          ),
        ),
      );

      final nativeFlags = RegExp(
        r'private func nativeFlagsForRemoteKey\([\s\S]*?\n  private func setInjectedKey',
      ).firstMatch(source)!.group(0)!;
      expect(nativeFlags, contains('case 123, 124, 125, 126'));
      expect(nativeFlags, contains('.maskSecondaryFn'));
      expect(nativeFlags, contains('.maskNumericPad'));
      expect(nativeFlags, contains('return CGEventFlags()'));
    });

    test(
      'routes app-local Command text shortcuts through Flutter focus actions',
      () {
        expect(source, contains('suppressedAppCommandShortcutKeyCodes'));
        expect(source, contains('handleAppCommandTextShortcut'));
        expect(source, contains('appCommandTextShortcut'));
        expect(source, contains('sendFlutterTextShortcut'));
        expect(source, contains('NSApp.isActive'));
        expect(source, contains('"onTextShortcut"'));
        expect(source, contains('"selectAll"'));
        expect(source, contains('"copy"'));
        expect(source, contains('"cut"'));
        expect(source, contains('"paste"'));

        final injectEvent = RegExp(
          r'private func injectEvent\([\s\S]*?\n  private func payloadData',
        ).firstMatch(source)!.group(0)!;
        expect(
          injectEvent,
          contains(
            'if handleAppCommandTextShortcut(keyCode: keyCode, down: down)',
          ),
        );
        expect(
          injectEvent.indexOf('updateInjectedModifierFlags'),
          lessThan(injectEvent.indexOf('handleAppCommandTextShortcut')),
        );
        expect(
          injectEvent.indexOf('handleAppCommandTextShortcut'),
          lessThan(injectEvent.indexOf('postKeyboardEvent')),
        );
      },
    );

    test('lets Control arrow shortcuts use the normal HID key path', () {
      expect(source, isNot(contains('handleSystemControlArrowShortcut')));
      expect(source, isNot(contains('postSystemControlArrowShortcut')));
      expect(source, isNot(contains('systemShortcutEventSource')));
      expect(source, isNot(contains('suppressedSystemControlArrowKeyCodes')));
    });

    test(
      'tracks injected mouse position for reverse edge release decisions',
      () {
        expect(source, contains('private var injectedMousePoint'));
        expect(source, contains('injectedMousePoint = nil'));
        expect(
          source,
          contains('injectedMousePoint ?? CGEvent(source: nil)?.location'),
        );
        expect(
          source,
          contains('entryPoint == nil && injectedMouseEnteredInterior'),
        );
        expect(source, contains('reverseInjectionSourceEdgeUnit'));
        expect(source, contains('isReverseInjectionRelease('));
        expect(source, contains('injectedMousePoint = point'));
      },
    );

    test('clamps injected mouse movement to the controlled desktop', () {
      expect(source, contains('private func clampedInjectedMousePoint'));

      final clampedInjectedMousePoint = RegExp(
        r'private func clampedInjectedMousePoint\(_ point: CGPoint\) -> CGPoint \{[\s\S]*?\n  \}',
      ).firstMatch(source)!.group(0)!;
      expect(clampedInjectedMousePoint, contains('virtualDisplayBounds()'));
      expect(clampedInjectedMousePoint, isNot(contains('injectionBounds()')));
      expect(clampedInjectedMousePoint, isNot(contains('injectionDisplayId')));

      final injectEvent = RegExp(
        r'private func injectEvent\([\s\S]*?\n  private func payloadData',
      ).firstMatch(source)!.group(0)!;
      final mouseMoveCase = RegExp(
        r'case "mouseMove":[\s\S]*?case "mouseButton":',
      ).firstMatch(injectEvent)!.group(0)!;
      expect(mouseMoveCase, contains('let requestedPoint = shouldMove'));
      expect(
        mouseMoveCase,
        contains('let point = clampedInjectedMousePoint(requestedPoint)'),
      );
      expect(source, contains('emitInjectedDiagnostic()'));
      expect(source, isNot(contains('requested=%{public}d,%{public}d')));
    });

    test('requests the visible cursor when receiving remote mouse input', () {
      expect(source, contains('showCursorForRemoteInjection'));
      expect(source, contains('for _ in 0..<8'));
      expect(source, contains('NSCursor.unhide()'));
      expect(source, contains('NSCursor.setHiddenUntilMouseMoves(false)'));
      expect(
        source,
        contains('CGAssociateMouseAndMouseCursorPosition(boolean_t(1))'),
      );
      expect(source, contains('CGWarpMouseCursorPosition(point)'));
      expect(source, contains('CGDisplayShowCursor(CGMainDisplayID())'));
      expect(source, isNot(contains('cursorShown')));
      expect(source, contains('Thread.isMainThread'));

      final injectionCase = RegExp(
        r'case "startInjection":[\s\S]*?case "injectEvent":',
      ).firstMatch(source)!.group(0)!;
      expect(injectionCase, contains('showCursorForRemoteInjection(at: nil)'));

      final injectEvent = RegExp(
        r'private func injectEvent\([\s\S]*?\n  private func payloadData',
      ).firstMatch(source)!.group(0)!;
      final mouseMoveCase = RegExp(
        r'case "mouseMove":[\s\S]*?case "mouseButton":',
      ).firstMatch(injectEvent)!.group(0)!;
      expect(
        mouseMoveCase,
        contains('showCursorForRemoteInjection(at: point)'),
      );
    });

    test('marks macOS injected double clicks with CG click state', () {
      expect(source, contains('private var injectedLastClickButton'));
      expect(source, contains('private func injectedClickState'));

      final injectEvent = RegExp(
        r'private func injectEvent\([\s\S]*?\n  private func payloadData',
      ).firstMatch(source)!.group(0)!;
      final mouseButtonCase = RegExp(
        r'case "mouseButton":[\s\S]*?case "mouseWheel":',
      ).firstMatch(injectEvent)!.group(0)!;
      expect(
        mouseButtonCase,
        contains('setIntegerValueField(.mouseEventClickState'),
      );
    });

    test('arms reverse edge release only after entering screen interior', () {
      expect(source, contains('private var injectedMouseEnteredInterior'));
      expect(source, contains('injectedMouseEnteredInterior = false'));
      expect(
        source,
        contains('entryPoint == nil && injectedMouseEnteredInterior'),
      );
      expect(source, contains('updateInjectedMouseInteriorState'));
      expect(source, contains('injectedMouseEnteredInterior = true'));
    });

    test(
      'uses NSScreen topology and shared edge units for multi-screen input',
      () {
        expect(source, contains('case "getDisplayTopology"'));
        expect(source, contains('NSScreen.screens'));
        expect(source, contains('CGDisplayBounds'));
        expect(source, contains('CGDisplayIsMain'));
        expect(source, contains('screenDisplayId'));
        expect(source, contains('captureDisplayId'));
        expect(source, contains('injectionDisplayId'));
        expect(source, contains('edgeUnitForPoint'));
        expect(source, contains('"edgeUnit"'));
        expect(source, contains('pointWithinSegment'));
        expect(source, contains('captureSegments(from: args["segments"])'));
        expect(source, contains('private struct CaptureRoute'));
        expect(source, contains('captureRoutes(from: args["segments"])'));
        expect(source, contains('applyCaptureRoute'));
        expect(source, contains('pointWithinCaptureSegments'));
        expect(source, contains('updateInjectionRoute(from: data)'));
        expect(source, contains('data["sinkDisplayId"]'));
        expect(source, contains('private struct InjectionRoute'));
        expect(source, contains('reverseInjectionSourceEdgeUnit'));
        expect(source, contains('"sourceEdgeUnit"'));
      },
    );

    test('uses CG display bounds for macOS virtual mouse bounds', () {
      expect(
        source,
        contains(
          'let frame = cgDisplayBounds(displayId: screenDisplayId(screen)) ?? screen.frame',
        ),
      );
      expect(source, isNot(contains('bounds = bounds.union(screen.frame)')));
    });

    test('returns source route metadata for routed macOS reverse release', () {
      expect(source, contains('private struct InjectionReleaseRoute'));
      expect(
        source,
        contains(
          'private func reverseInjectionSourceEdgeUnit(\n    currentPoint: CGPoint,\n    deltaX: CGFloat,\n    deltaY: CGFloat\n  ) -> InjectionReleaseRoute?',
        ),
      );
      expect(source, contains('route.sourceDisplayId'));
      expect(source, contains('route.sourceEdge'));
      expect(source, contains('"sourceDisplayId"'));
      expect(source, contains('"sourceEdge"'));
      expect(source, contains('"sourceSegmentStart"'));
      expect(source, contains('"sourceSegmentEnd"'));
    });

    test(
      'routes macOS portals by crossing route id instead of first match',
      () {
        expect(source, contains('let routeId: String'));
        expect(source, contains('"routeId"'));
        expect(source, contains('resolveCaptureCrossing'));
        expect(source, contains('resolveInjectionReleaseCrossing'));
        expect(source, contains('max(bounds.minX, bounds.maxX - 1)'));
        expect(source, contains('max(bounds.minY, bounds.maxY - 1)'));
        expect(source, contains('previousPoint'));
        expect(
          source,
          isNot(contains('return captureRoutes.first { route in')),
        );
      },
    );

    test('keeps non-contiguous macOS portal endpoints enterable', () {
      expect(source, contains('other.sourceSegmentStart <= end'));
      expect(source, contains('other.sinkSegmentStart <= end'));
    });

    test(
      'keeps Windows Control and Meta distinct in native fallback mapping',
      () {
        expect(source, contains('case 0x11, 0xA2: return 59'));
        expect(source, contains('case 0xA3: return 62'));
        expect(source, contains('case 0x5B: return 55'));
        expect(source, contains('case 0x5C: return 54'));
      },
    );

    test('maps Windows Caps Lock to macOS Caps Lock in sink fallback', () {
      expect(source, contains('case 0x14: return 57'));
    });

    test('traces remote key injection without payload details', () {
      expect(source, contains('import OSLog'));
      expect(source, contains('WHISPER_REMOTE_INPUT_TRACE'));
      expect(source, contains('traceRemoteInput(.injectedEvent'));
      expect(source, contains('emitInjectedDiagnostic()'));
      expect(source, isNot(contains('keyInjected')));
      expect(source, isNot(contains('remote key inject session=')));
      expect(source, isNot(contains('post remote key mac=')));
    });

    test('captures macOS precise scroll metadata for normalization', () {
      expect(source, contains('scrollWheelEventPointDeltaAxis1'));
      expect(source, contains('scrollWheelEventPointDeltaAxis2'));
      expect(source, contains('scrollWheelEventIsContinuous'));
      expect(source, contains('NSEvent(cgEvent: event)'));
      expect(source, contains('hasPreciseScrollingDeltas'));
      expect(source, contains(r'Double($0.scrollingDeltaX)'));
      expect(source, contains(r'Double($0.scrollingDeltaY)'));
      expect(source, contains('scrollWheelEventFixedPtDeltaAxis1'));
      expect(source, contains('scrollWheelEventFixedPtDeltaAxis2'));
      expect(source, contains('scrollWheelEventScrollPhase'));
      expect(source, contains('scrollWheelEventMomentumPhase'));
      expect(source, contains('"pointDeltaY"'));
      expect(source, contains('"isContinuous"'));
    });

    test(
      'injects native line and pixel scrolling without losing fractions',
      () {
        expect(source, contains('private func postInjectedScrollEvent'));
        expect(source, contains('consumeInjectedScrollDelta'));
        expect(source, contains('injectedScrollRemainderX'));
        expect(source, contains('injectedScrollRemainderY'));
        expect(source, contains('let unit: CGScrollEventUnit'));
        expect(source, contains('isPixel ? .pixel : .line'));
        expect(source, contains('.scrollWheelEventFixedPtDeltaAxis1'));
        expect(source, contains('.scrollWheelEventScrollPhase'));
        expect(source, contains('.scrollWheelEventMomentumPhase'));
      },
    );
  });
}
