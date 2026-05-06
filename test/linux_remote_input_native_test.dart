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
      expect(plugin, contains('"linux remote input capture started'));
      expect(plugin, contains('"linux remote input injection started'));
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
      expect(plugin, contains('sourceCursorHidden='));
      expect(plugin, contains('rawMotionDisabled='));
      expect(plugin, contains('linux remote input native active'));
      expect(plugin, contains('linux remote input native mouse raw'));
      expect(plugin, contains('linux remote input native mouse motion'));
      expect(plugin, contains('linux remote input native key'));
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
  });
}
