import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Linux remote input native backend', () {
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

    test('builds the Wayland portal injection backend as an optional feature',
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
    });

    test('prefers portal injection and falls back to XTest when unavailable',
        () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('enum class InjectionBackend'));
      expect(plugin, contains('InjectionBackend::kPortal'));
      expect(plugin, contains('InjectionBackend::kX11'));
      expect(plugin, contains('TryStartPortalInjection'));
      expect(plugin, contains('StartX11Injection'));
      expect(
        plugin.indexOf('TryStartPortalInjection'),
        lessThan(plugin.indexOf('StartX11Injection(')),
      );
      expect(
          plugin, contains('RemoteInputTraceEvent::kPortalInjectionStarted'));
      expect(plugin, contains('RemoteInputTraceEvent::kX11InjectionStarted'));
    });

    test('prefers InputCapture portal capture and falls back to X11 capture',
        () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('CaptureBackend::kPortal'));
      expect(plugin, contains('TryStartPortalCapture'));
      expect(plugin, contains('StartX11Capture'));
      expect(plugin, contains('StartInputCapturePortalSession'));
      expect(plugin, contains('org.freedesktop.portal.InputCapture'));
      expect(plugin, contains('SetPointerBarriers'));
      expect(plugin, contains('InputCaptureActivatedCallback'));
      expect(plugin, contains('ei_new_receiver'));
      expect(plugin, contains('EI_EVENT_POINTER_MOTION'));
      expect(
        plugin.indexOf('TryStartPortalCapture'),
        lessThan(plugin.indexOf('StartX11Capture(')),
      );
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
    });

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
            'return enable_value == nullptr || std::strcmp(enable_value, "1") != 0;'),
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
      expect(
        plugin,
        contains('XGrabPointer(\n        display, root, False,'),
      );
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
        isNot(contains('for (const auto& route : capture_routes_) {\n'
            '        if (IsEdgeActivation(')),
      );
    });

    test('traces Linux injection with allowlisted events only', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('RemoteInputTraceEvent::kInjectionStarted'));
      expect(plugin, contains('RemoteInputTraceEvent::kInjectedEvent'));
      expect(
          plugin, contains('RemoteInputTraceEvent::kInjectionReleaseRouted'));
      expect(
          plugin, contains('RemoteInputTraceEvent::kInjectionReleaseLegacy'));
      expect(plugin, isNot(contains('injection move session=')));
      expect(plugin, isNot(contains('requested=')));
      expect(plugin, isNot(contains('actual=')));
    });

    test('tracks injected cursor position without trusting XWayland queries',
        () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('has_injected_cursor_position_'));
      expect(plugin, contains('RememberInjectedCursorPositionLocked'));
      expect(plugin, contains('InjectedCursorPositionLocked'));
      expect(plugin, contains('injected_cursor_x_ + delta_x'));
      expect(plugin, contains('x + delta_x <= bounds.left + kEdgeThreshold'));
      expect(plugin, contains('XQueryPointer can remain stale under XWayland'));
    });

    test('rejects Linux injection while the desktop is locked', () {
      final plugin = File('linux/remote_input_plugin.cc').readAsStringSync();

      expect(plugin, contains('IsLinuxDesktopLocked'));
      expect(plugin, contains('org.gnome.ScreenSaver'));
      expect(plugin, contains('GetActive'));
      expect(
        plugin,
        contains('Unlock the Linux desktop before sharing keyboard and mouse'),
      );
      expect(plugin.indexOf('IsLinuxDesktopLocked()'),
          lessThan(plugin.indexOf('XOpenDisplay(nullptr)')));
    });
  });
}
