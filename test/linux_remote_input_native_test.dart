import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Linux remote input native backend', () {
    test('manual portal input preserves desktop EIS and checks text first', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
      final start = plugin.substring(
        plugin.indexOf('  bool StartInjection('),
        plugin.indexOf('  bool StartX11Injection('),
      );
      expect(start, contains('manual && RemoteDesktopPortalAvailable()'));
      expect(
        start,
        contains('StartRemoteDesktopPortalSession(&session, error, false)'),
      );
      expect(start, contains('TryStartPortalInjection('));
      final text = plugin.substring(
        plugin.indexOf('  bool InjectManualText('),
        plugin.indexOf('  void InjectEvent('),
      );
      expect(text, contains('session_id != injection_session_id_'));
      expect(text, contains('g_utf8_validate'));
      expect(text, contains('text->size() > 4096'));
      expect(
        text.indexOf('XKeysymToKeycode(portal_x_display_'),
        lessThan(text.indexOf('ManualPortalKeyLocked(')),
      );
      expect(text, isNot(contains('XChangeKeyboardMapping')));
      expect(text, isNot(contains('gtk_clipboard_set')));
      // Text the layout cannot type goes whole through the GNOME helper,
      // and only into a text field.
      expect(text, contains('CommitTextThroughShellHelper(portal_connection_'));
      final helper = plugin.substring(
        plugin.indexOf('bool CommitTextThroughShellHelper('),
        plugin.indexOf('bool MutterServiceAvailable('),
      );
      expect(helper.indexOf('"textInput"'), lessThan(helper.indexOf('"Text"')));
      expect(helper, contains('G_DBUS_CALL_FLAGS_NO_AUTO_START'));
    });

    test('manual movement skips edge release and preserves pixel scroll', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
      expect(plugin, contains('!manual_injection_ && !active_start'));
      expect(plugin, contains('!manual_injection_ && active_start'));
      expect(plugin, contains('manual_remainder_x_ = raw_x - delta_x'));
      final portal = plugin.substring(
        plugin.indexOf('  void InjectManualPortalEventLocked('),
        plugin.indexOf('  void InjectPortalEventLocked('),
      );
      expect(portal, contains('JsonString(json, "scrollUnit") != "pixel"'));
      expect(portal, contains('(wheel ? -gain : gain)'));
      expect(portal, contains('if (wheel && delivered)'));
      expect(
        portal.indexOf('JsonNumber(json, "deltaY")'),
        lessThan(portal.indexOf('"finish", g_variant_new_boolean(true)')),
      );
      expect(portal, contains('&finish, 0.0, 0.0'));
      expect(portal, contains('SetInjectedButton(button, down)'));
      expect(portal, contains('SetInjectedKey(key, down)'));
    });

    test('release builds require and bundle the Wayland client library', () {
      final workflow = File('.github/workflows/release.yml').readAsStringSync();
      final cmake = File('linux/CMakeLists.txt').readAsStringSync();
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
      expect(workflow, contains('script/build_linux_libei.sh'));
      expect(workflow, contains('WHISPER_REQUIRE_WAYLAND_INPUT=ON'));
      expect(cmake, contains('message(FATAL_ERROR'));
      expect(cmake, contains('RENAME "libei.so.1"'));
      expect(plugin, contains('Wayland remote input requires libei'));
    });

    test('caches injection topology outside the mouse event path', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
      final releaseRouting = RegExp(
        r'Maybe<InjectionReleaseCrossing> InjectionReleaseCrossingForRoute\([\s\S]*?\n  bool SegmentContains',
      ).firstMatch(plugin)!.group(0)!;
      expect(releaseRouting, contains('InjectionBoundsForDisplayLocked'));
      expect(
        releaseRouting,
        isNot(contains('BoundsForDisplay(InjectionBoundsDisplayLocked')),
      );
      expect(plugin, contains('RefreshInjectionDisplaysLocked();'));
    });

    test('registers an X11 remote input plugin with capture and injection', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
      final header = File('linux/remote_input_plugin.h').readAsStringSync();
      final cmake = File('linux/CMakeLists.txt').readAsStringSync();
      final app = File('linux/my_application.cc').readAsStringSync();

      expect(header, contains('remote_input_plugin_register'));
      expect(cmake, contains('"remote_input_plugin.cc"'));
      expect(cmake, contains('HAVE_X11_REMOTE_INPUT'));
      expect(app, contains('#include "remote_input_plugin.h"'));
      expect(app, contains('remote_input_plugin_register'));
      expect(plugin, contains('com.vireen.whisper/remote_input'));
      expect(plugin, contains('startCapture'));
      expect(plugin, contains('startInjection'));
      expect(plugin, contains('injectEvent'));
      expect(plugin, contains('getDisplayTopology'));
      expect(plugin, contains('DisplayTopologyValue'));
      expect(plugin, contains('XGrabPointer'));
      expect(plugin, contains('XGrabKeyboard'));
      expect(plugin, contains('XTestFake'));
      expect(plugin, contains('EdgeUnitForPoint'));
      expect(plugin, contains('PointInSegment'));
      expect(plugin, contains('"edgeUnit"'));
      expect(plugin, contains('sourcePlatform'));
      expect(plugin, contains('linuxKeyCode'));
      expect(plugin, contains('RemoteInputTraceEvent::kCaptureStarted'));
      expect(plugin, contains('RemoteInputTraceEvent::kInjectionStarted'));
    });

    test(
      'builds the Wayland portal injection backend as an optional feature',
      () {
        final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
        final cmake = File('linux/CMakeLists.txt').readAsStringSync();

        expect(cmake, contains('pkg_check_modules(LIBEI_REMOTE_INPUT'));
        expect(cmake, contains('HAVE_LIBEI_REMOTE_INPUT'));
        expect(plugin, contains('#include <libei.h>'));
        expect(plugin, contains('HAVE_LIBEI_REMOTE_INPUT'));
        expect(plugin, contains('StartPortalInjection'));
        expect(plugin, contains('RemoteDesktopPortalAvailable'));
        expect(plugin, contains('StartRemoteDesktopPortalSession'));
        expect(plugin, contains('ConnectToEis'));
        expect(plugin, contains('persist_mode'));
        expect(plugin, contains('restore_token'));
        expect(plugin, contains('LoadPortalRestoreToken'));
        expect(plugin, contains('SavePortalRestoreToken'));
        expect(plugin, contains('org.freedesktop.portal.RemoteDesktop'));
        expect(plugin, contains('ConnectToEIS'));
      },
    );

    test('injects through the portal on Wayland and XTest on X11', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('enum class InjectionBackend'));
      expect(plugin, contains('InjectionBackend::kPortal'));
      expect(plugin, contains('InjectionBackend::kX11'));
      final start = _method(plugin, '  bool StartInjection(');
      final wayland = start.indexOf('if (IsWaylandSession())');
      expect(wayland, isNonNegative);
      expect(
        start.indexOf('manual && RemoteDesktopPortalAvailable()'),
        greaterThan(wayland),
      );
      expect(start.indexOf('TryStartPortalInjection('), greaterThan(wayland));
      expect(
        start.indexOf('StartX11Injection('),
        greaterThan(start.indexOf('TryStartPortalInjection(')),
      );
      expect(
        plugin,
        contains('RemoteInputTraceEvent::kPortalInjectionStarted'),
      );
      expect(plugin, contains('RemoteInputTraceEvent::kX11InjectionStarted'));
    });

    test('captures through the portal on Wayland and the X11 grab on X11', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('CaptureBackend::kPortal'));
      expect(plugin, contains('StartInputCapturePortalSession'));
      expect(plugin, contains('org.freedesktop.portal.InputCapture'));
      expect(plugin, contains('SetPointerBarriers'));
      expect(plugin, contains('InputCaptureActivatedCallback'));
      expect(plugin, contains('ei_new_receiver'));
      expect(plugin, contains('EI_EVENT_POINTER_MOTION'));
      // An X11 session never reaches the portal, which would ask every time.
      final start = _method(plugin, '  bool StartCapture(');
      final wayland = start.indexOf('if (IsWaylandSession())');
      expect(wayland, isNonNegative);
      expect(start.indexOf('TryStartPortalCapture('), greaterThan(wayland));
      expect(
        start.indexOf('StartX11Capture('),
        greaterThan(start.indexOf('TryStartPortalCapture(')),
      );
    });

    test('releases Wayland input capture on the release hotkey', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(
        _method(plugin, '  bool TryStartPortalCapture(').split('#else').first,
        isNot(contains('(void)release_hotkey;')),
      );
      expect(
        plugin,
        contains('input_capture_release_hotkey_ = release_hotkey;'),
      );
      final events = _method(plugin, '  void HandleInputCaptureEiEventLocked(');
      expect(events, contains('TrackInputCaptureModifierLocked(key, press)'));
      expect(
        events.indexOf('IsInputCaptureReleaseHotkeyLocked(key)'),
        lessThan(events.indexOf('"key", ++input_capture_sequence_')),
      );
      // Later events stay here until the compositor stops the capture.
      expect(
        events.indexOf('if (input_capture_hotkey_fired_)'),
        lessThan(events.indexOf('case EI_EVENT_POINTER_MOTION:')),
      );
      final release = _method(
        plugin,
        '  void ReleaseInputCaptureForHotkeyLocked(',
      );
      expect(
        release,
        contains('EmitReleaseForSession(capture_session_id_, "hotkey"'),
      );
      expect(release, contains('SendInputCaptureReleaseLocked(nullptr)'));
      final hotkey = _method(
        plugin,
        '  bool IsInputCaptureReleaseHotkeyLocked(',
      );
      expect(hotkey, contains('"ctrl+alt+esc"'));
      expect(hotkey, contains('KEY_ESC'));
    });

    test(
      'uses persistent InputCapture portal sessions when version 2 is available',
      () {
        final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

        expect(plugin, contains('InputCapturePortalVersion'));
        expect(plugin, contains('StartInputCapturePortalSessionV2'));
        expect(plugin, contains('StartInputCapturePortalSessionV1'));
        expect(plugin, contains('CreateSession2'));
        expect(plugin, contains('LoadInputCapturePortalRestoreToken'));
        expect(plugin, contains('SaveInputCapturePortalRestoreToken'));
        expect(plugin, contains('input-capture-portal-token'));
        expect(plugin, contains('persist_mode'));
        expect(plugin, contains('restore_token'));
        expect(
          plugin.indexOf('StartInputCapturePortalSessionV2'),
          lessThan(plugin.indexOf('StartInputCapturePortalSessionV1')),
        );
      },
    );

    test('does not release X11 keys when no injection backend is active', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
      final releaseModifiers = RegExp(
        r'void ReleaseCommonModifierKeysLocked\(\)[\s\S]*?\n  }\n#endif',
      ).firstMatch(plugin)!.group(0)!;

      expect(
        releaseModifiers,
        contains('injection_backend_ == InjectionBackend::kNone'),
      );
      expect(
        releaseModifiers.indexOf(
          'injection_backend_ == InjectionBackend::kNone',
        ),
        lessThan(releaseModifiers.indexOf('SendKeyboardKeyLocked')),
      );
    });

    test('uses strict edge motion before reactivating capture', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
      final edgeActivation = RegExp(
        r'bool IsEdgeActivation\([\s\S]*?\n  bool ShouldRecenter',
      ).firstMatch(plugin)!.group(0)!;

      expect(edgeActivation, contains('delta_x < 0'));
      expect(edgeActivation, contains('delta_y < 0'));
      expect(edgeActivation, contains('delta_y > 0'));
      expect(edgeActivation, contains('delta_x > 0'));
      expect(edgeActivation, isNot(contains('delta_x <= 0')));
      expect(edgeActivation, isNot(contains('delta_y <= 0')));
      expect(edgeActivation, isNot(contains('delta_x >= 0')));
      expect(edgeActivation, isNot(contains('delta_y >= 0')));
    });

    test('requires local interior movement before rearming X11 capture', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
      final captureLoop = RegExp(
        r'void CaptureLoop\([\s\S]*?\n  bool ConsumePauseRequest',
      ).firstMatch(plugin)!.group(0)!;
      final pauseRequest = RegExp(
        r'bool ConsumePauseRequest\([\s\S]*?\n  bool QueryPointer',
      ).firstMatch(plugin)!.group(0)!;

      expect(plugin, contains('CaptureCursorEnteredInterior'));
      expect(captureLoop, contains('requires_interior_rearm'));
      expect(pauseRequest, contains('*requires_interior_rearm = true;'));
      expect(
        captureLoop.indexOf('if (requires_interior_rearm)'),
        lessThan(captureLoop.indexOf('ResolveCaptureCrossing')),
      );
    });

    test('hides the local X11 cursor by default with a diagnostic bypass', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('CreateHiddenCursor'));
      expect(plugin, contains('XCreatePixmapCursor'));
      expect(plugin, contains('XFreeCursor'));
      expect(plugin, contains('WHISPER_REMOTE_INPUT_SHOW_SOURCE_CURSOR'));
      expect(plugin, contains('WHISPER_REMOTE_INPUT_TRACE'));
      expect(plugin, contains('WHISPER_REMOTE_INPUT_DISABLE_RAW_MOTION'));
      expect(plugin, contains('WHISPER_REMOTE_INPUT_ENABLE_RAW_MOTION'));
      expect(plugin, contains('ShouldShowSourceCursor'));
      expect(plugin, contains('ShouldDisableRawMotion'));
      expect(
        plugin,
        contains(
          'return enable_value == nullptr || std::strcmp(enable_value, "1") != 0;',
        ),
      );
      expect(plugin, contains('TraceRemoteInput'));
      expect(plugin, contains('g_printerr'));
      expect(plugin, contains('enum class RemoteInputTraceEvent'));
      expect(plugin, contains('RemoteInputTraceEvent::kCaptureActive'));
      expect(plugin, contains('RemoteInputTraceEvent::kEventCaptured'));
      expect(plugin, isNot(contains('RemoteInputTraceEvent::kRawMotion')));
      expect(plugin, isNot(contains('RemoteInputTraceEvent::kMouseMotion')));
      expect(plugin, isNot(contains('RemoteInputTraceEvent::kKeyCaptured')));
      expect(
        plugin,
        contains('show_source_cursor ? None : CreateHiddenCursor'),
      );
      expect(plugin, contains('XGrabPointer(\n        display, root, False,'));
      expect(plugin, contains('hidden_cursor'));
    });

    test('uses XInput2 raw motion for Linux capture deltas when available', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
      final cmake = File('linux/CMakeLists.txt').readAsStringSync();

      expect(cmake, contains('XI_REMOTE_INPUT'));
      expect(cmake, contains('HAVE_XI_REMOTE_INPUT'));
      expect(cmake, contains('XRANDR_REMOTE_INPUT'));
      expect(cmake, contains('HAVE_XRANDR_REMOTE_INPUT'));
      expect(plugin, contains('#include <X11/extensions/XInput2.h>'));
      expect(plugin, contains('#include <X11/extensions/Xrandr.h>'));
      expect(plugin, contains('XRRGetMonitors'));
      expect(plugin, contains('XI_RawMotion'));
      expect(plugin, contains('XGetEventData'));
      expect(plugin, contains('RawMotionDelta'));
      expect(plugin, contains('raw_remainder_x'));
    });

    test('keeps remote input native code compatible with C++14', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();
      final cmake = File('linux/CMakeLists.txt').readAsStringSync();

      expect(cmake, contains('cxx_std_14'));
      expect(plugin, isNot(contains('#include <optional>')));
      expect(plugin, isNot(contains('std::optional')));
      expect(plugin, isNot(contains('std::nullopt')));
      expect(plugin, contains('class Maybe'));
    });

    test('routes X11 multi-display portals with stable route ids', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('struct CaptureRoute'));
      expect(plugin, contains('struct InjectionRoute'));
      expect(plugin, contains('struct InjectionReleaseRoute'));
      expect(plugin, contains('CaptureRoutesValue'));
      expect(plugin, contains('InjectionRoutesValue'));
      expect(plugin, contains('capture_routes_'));
      expect(plugin, contains('injection_routes_'));
      expect(plugin, contains('ResolveCaptureCrossing'));
      expect(plugin, contains('ResolveInjectionReleaseCrossing'));
      expect(plugin, contains('UpdateInjectionRouteFromPayload'));
      expect(plugin, contains('routeId'));
      expect(plugin, contains('JsonEscapedString'));
      expect(plugin, contains('JsonStringValue'));
      expect(plugin, contains('"sourceEdgeUnit"'));
      expect(plugin, contains('"sourceDisplayId"'));
      expect(plugin, contains('"sourceEdge"'));
      expect(plugin, contains('"sourceSegmentStart"'));
      expect(plugin, contains('"sourceSegmentEnd"'));
      expect(plugin, contains('other.source_segment.start <= segment.end'));
      expect(plugin, contains('other.sink_segment.start <= segment.end'));
      expect(
        plugin,
        isNot(
          contains(
            'for (const auto& route : capture_routes_) {\n'
            '        if (IsEdgeActivation(',
          ),
        ),
      );
    });

    test('traces Linux injection with allowlisted events only', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('RemoteInputTraceEvent::kInjectionStarted'));
      expect(plugin, contains('RemoteInputTraceEvent::kInjectedEvent'));
      expect(
        plugin,
        contains('RemoteInputTraceEvent::kInjectionReleaseRouted'),
      );
      expect(
        plugin,
        contains('RemoteInputTraceEvent::kInjectionReleaseLegacy'),
      );
      expect(plugin, isNot(contains('injection move session=')));
      expect(plugin, isNot(contains('requested=')));
      expect(plugin, isNot(contains('actual=')));
    });

    test(
      'tracks injected cursor position without trusting XWayland queries',
      () {
        final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

        expect(plugin, contains('has_injected_cursor_position_'));
        expect(plugin, contains('RememberInjectedCursorPositionLocked'));
        expect(plugin, contains('InjectedCursorPositionLocked'));
        expect(plugin, contains('injected_cursor_x_ + delta_x'));
        expect(plugin, contains('x + delta_x <= bounds.left + kEdgeThreshold'));
        expect(
          plugin,
          contains('XQueryPointer can remain stale under XWayland'),
        );
      },
    );

    test('rejects Linux injection while the desktop is locked', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('IsLinuxDesktopLocked'));
      expect(plugin, contains('org.gnome.ScreenSaver'));
      expect(plugin, contains('GetActive'));
      expect(
        plugin,
        contains('Unlock the Linux desktop before sharing keyboard and mouse'),
      );
      expect(
        plugin.indexOf('IsLinuxDesktopLocked()'),
        lessThan(plugin.indexOf('XOpenDisplay(nullptr)')),
      );
    });

    test(
      'accumulates precise scroll deltas before discrete Linux injection',
      () {
        final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

        expect(plugin, contains('InjectMouseWheelLocked'));
        expect(plugin, contains('injected_scroll_remainder_x_'));
        expect(plugin, contains('injected_scroll_remainder_y_'));
        expect(plugin, contains('std::trunc(injected_scroll_remainder_x_'));
        expect(plugin, contains('JsonNumber(json, "scrollPhase")'));
        expect(plugin, contains('JsonNumber(json, "momentumPhase")'));
      },
    );
  });
}

/// The body of the class method that starts with [signature] (two-space
/// indented, so it ends at the first closing brace at that indent).
String _method(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNonNegative, reason: signature);
  return source.substring(start, source.indexOf('\n  }\n', start));
}
