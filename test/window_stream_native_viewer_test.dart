import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every C/C++ source of one platform's plugin, without the test tools.
String nativeSources(String platform) {
  final root = Directory('packages/window_stream_native/$platform');
  final files =
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (file) =>
                RegExp(r'\.(c|cc|cpp|h|hpp)$').hasMatch(file.path) &&
                !file.path.contains('${Platform.pathSeparator}tools'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files.map((file) => file.readAsStringSync()).join('\n');
}

/// Definitions of [name] in [source] (calls and prototypes do not match).
int functionDefinitions(String source, String name) => RegExp(
  r'^[ \t]*(?:[A-Za-z_]\w*[ \t*&]+)*'
  '$name'
  r'[ \t]*\([^;{}]*\)\s*\{',
  multiLine: true,
).allMatches(source).length;

String read(String path) => File(path).readAsStringSync();

void main() {
  const plugin = 'packages/window_stream_native';
  const swift = '$plugin/macos/Classes';
  const windows = '$plugin/windows/receiver';
  const linux = '$plugin/linux/receiver';

  test('every platform exports the viewer volume and strings entry points', () {
    final header = read('$plugin/src/window_stream_native.h');
    for (final name in const [
      'wsn_surface_set_volume',
      'wsn_set_strings',
      'wsn_capture_set_pixel_ratio',
    ]) {
      expect(header, contains('$name('));
      final macos = Directory(swift)
          .listSync()
          .whereType<File>()
          .map((file) => file.readAsStringSync())
          .join('\n');
      expect(macos, contains('@_cdecl("$name")'), reason: name);
      for (final platform in const ['windows', 'linux']) {
        expect(
          functionDefinitions(nativeSources(platform), name),
          1,
          reason: '$name must be defined once in the $platform plugin',
        );
      }
    }
    expect(header, contains('#define WSN_WINDOW_VOLUME 9'));
    expect(header, contains('#define WSN_FLAG_REFLOW 0x2'));
    // Windows and Linux leave the pixel ratio to the host for now.
    expect(
      read('$plugin/windows/exports_capture.cpp'),
      contains('The host keeps its own density here for now.'),
    );
    expect(
      read('$plugin/linux/exports_capture.cc'),
      contains('The host keeps its own density here for now.'),
    );
  });

  test('each window has its own volume control once it has sound', () {
    // macOS: a speaker button at the trailing end of the title bar, added
    // when the window has sound, opening a slider and a mute toggle.
    final control = read('$swift/VolumeControl.swift');
    expect(control, contains('NSTitlebarAccessoryViewController'));
    expect(control, contains('accessory.layoutAttribute = .trailing'));
    expect(control, contains('"speaker.wave.2"'));
    expect(control, contains('"speaker.slash"'));
    expect(control, contains('NSPopover()'));
    expect(control, contains('NSSlider('));
    expect(control, contains('WSNConst.windowVolume'));
    expect(read('$swift/StreamSurface.swift'), contains('showVolumeControl()'));
    // Windows: a layered button owned by the window (only its face takes
    // the pointer) and a flyout with a trackbar and a mute toggle.
    final win = read('$windows/volume_control.cpp');
    expect(
      win,
      contains('WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE'),
    );
    expect(win, contains('return MA_NOACTIVATE;'));
    expect(win, contains('TRACKBAR_CLASSW'));
    expect(win, contains('BS_OWNERDRAW'));
    expect(win, contains('ULW_ALPHA'));
    final winSurface = read('$windows/surface.cpp');
    expect(winSurface, contains('volume_control_->SetAvailable()'));
    expect(winSurface, contains('EmitWindow(id, WSN_WINDOW_VOLUME, volume)'));
    expect(winSurface, contains('volume_control_->Wheel(point'));
    // Linux: a button in the window's own GtkHeaderBar with a popover.
    final gtk = read('$linux/surface.cc');
    expect(gtk, contains('gtk_header_bar_new()'));
    expect(
      gtk,
      contains('gtk_window_set_titlebar(GTK_WINDOW(window_), header_)'),
    );
    expect(gtk, contains('gtk_menu_button_set_popover'));
    expect(
      gtk,
      contains('gtk_widget_set_focus_on_click(volume_button_, FALSE)'),
    );
    expect(gtk, contains('gtk_widget_set_no_show_all(volume_button_, TRUE)'));
    expect(gtk, contains('EmitWindow(id_, WSN_WINDOW_VOLUME, shown_volume_)'));
  });

  test('volume changes from Dart are shown, never reported back', () {
    final control = read('$swift/VolumeControl.swift');
    final fromDart = RegExp(
      r'func setVolume\(_ value: Double\) \{[\s\S]*?\n  \}',
    ).firstMatch(control)!.group(0)!;
    expect(fromDart, contains('emitted = value'));
    expect(fromDart, isNot(contains('emitWindow')));
    final win = read('$windows/volume_control.cpp');
    final winFromDart = RegExp(
      r'void VolumeControl::SetVolume\(double volume\) \{[\s\S]*?\n\}',
    ).firstMatch(win)!.group(0)!;
    expect(winFromDart, contains('reported_ = volume_;'));
    expect(winFromDart, isNot(contains('on_report_')));
    final gtk = read('$linux/surface.cc');
    expect(gtk, contains('self->reported_volume_ = level;'));
    expect(gtk, contains('if (self->syncing_volume_) return;'));
  });

  test('reports are throttled while the slider moves', () {
    expect(
      read('$swift/VolumeControl.swift'),
      contains('private static let emitInterval: CFTimeInterval = 0.1'),
    );
    expect(
      read('$windows/volume_control.cpp'),
      contains('constexpr double kReportInterval = 0.1;'),
    );
    expect(
      read('$linux/surface.cc'),
      contains('constexpr int64_t kVolumeReportUs = 100000;'),
    );
  });

  test('the volume is a gain ramped over 20 ms on every output path', () {
    final mac = read('$swift/AudioOutput.swift');
    expect(mac, contains('gainStep = 1 / Float(max(1, sampleRate / 50))'));
    expect(mac, contains('* headroom * gain)'));
    expect(mac, contains('func setVolume(_ volume: Double)'));
    for (final path in ['$windows/audio_out.cpp', '$linux/audio_out.cc']) {
      final source = read(path);
      expect(source, contains('constexpr int kGainRampMs = 20;'), reason: path);
      expect(source, contains('gain_ + gain_step_'), reason: path);
      expect(source, contains('gain_ - gain_step_'), reason: path);
      expect(source, contains('ApplyGainLocked(tail);'), reason: path);
      // Cubic taper, 0 silent, 1 as sent.
      expect(source, contains('return level * level * level;'), reason: path);
    }
    // A later configure starts at the window's volume.
    expect(
      read('$swift/StreamSurface.swift'),
      contains('volume: self.currentVolume'),
    );
    expect(
      read('$windows/surface.cpp'),
      contains('std::move(title), volume_)'),
    );
    expect(read('$linux/surface.cc'), contains('audio_title_, volume_)'));
  });

  test('REFLOW lifts the aspect lock and settles after a resize', () {
    final window = read('$swift/StreamWindow.swift');
    expect(
      window,
      contains(
        'if !reflow {\n      window.contentAspectRatio = self.videoSize',
      ),
    );
    expect(
      window,
      contains('private static let aspectTolerance: CGFloat = 0.02'),
    );
    expect(
      window,
      contains('private static let settleDelay: TimeInterval = 2'),
    );
    expect(window, contains('if reflow {\n      scheduleSettle()'));
    // Zoom takes the whole frame: the other side lays out for it.
    expect(window, contains('if reflow {\n      return newFrame\n    }'));
    final win = read('$windows/surface.cpp');
    expect(win, contains('if (reflow_) break;'));
    expect(win, contains('constexpr UINT kSettleDelayMs = 2000;'));
    expect(
      win,
      contains(
        'if (reflow_ && resized_in_move_) SetTimer(hwnd_, kTimerSettle, kSettleDelayMs, nullptr);',
      ),
    );
    expect(
      win,
      contains(
        'if (reflow_ && SameShape(client.right, client.bottom, width, height)) return;',
      ),
    );
    final gtk = read('$linux/surface.cc');
    expect(gtk, contains('constexpr guint kSettleQuietMs = 300;'));
    expect(gtk, contains('constexpr guint kSettleDelayMs = 2000;'));
    expect(gtk, contains('if (reflow_ && by_user) ScheduleSettle();'));
    // Every platform reads the flag.
    expect(
      read('$swift/WindowStreamNative.swift'),
      contains('flagReflow: Int32 = 0x2'),
    );
    expect(
      read('$windows/surface.cpp'),
      contains('(flags & WSN_FLAG_REFLOW) != 0'),
    );
    expect(
      read('$plugin/linux/exports_surface.cc'),
      contains('(flags & WSN_FLAG_REFLOW) != 0'),
    );
  });

  test('input mapping stays on the letterboxed picture', () {
    expect(
      read('$swift/StreamWindow.swift'),
      contains('AVMakeRect(aspectRatio: videoSize, insideRect: bounds)'),
    );
    expect(
      read('$windows/surface.cpp'),
      contains(
        'return LetterboxRect(client.right, client.bottom, width, height);',
      ),
    );
    final gtk = read('$linux/surface.cc');
    expect(gtk, contains('*x = (width - *w) / 2;'));
  });
}
