import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Source-level checks for KDE Plasma as a window source
// (packages/window_stream_native/linux/capture/kwin_*).
//
// Checked on Ubuntu 26.04 with Plasma 6.6 (2026-10-21): KWin hands its
// screencast and input protocols only to an executable a .desktop file
// names; a virtual output it creates is laid out beside the real ones at
// scale 1 until reconfigured; it reads new .desktop files only when it next
// looks (a second or so); and a KWin script is the only way to move other
// apps' windows.
void main() {
  const linux = 'packages/window_stream_native/linux';
  String read(String path) => File('$linux/$path').readAsStringSync();

  test('KWin protocols are generated at build time, never vendored code', () {
    final cmake = read('CMakeLists.txt');
    for (final protocol in [
      'zkde-screencast-unstable-v1',
      'fake-input',
      'kde-output-device-v2',
      'kde-output-management-v2',
    ]) {
      expect(cmake, contains(protocol));
      expect(
        File('$linux/capture/protocols/$protocol.xml').existsSync(),
        isTrue,
      );
    }
    expect(cmake, contains('client-header'));
    expect(cmake, contains('private-code'));
    expect(cmake, contains('WSN_HAVE_KWIN_PROTOCOLS'));
  });

  test('every output-device event has a listener (KWin may send them all)', () {
    final wayland = read('capture/kwin_wayland.cc');
    final xml = File(
      '$linux/capture/protocols/kde-output-device-v2.xml',
    ).readAsStringSync();
    final device = RegExp(
      r'<interface name="kde_output_device_v2"[\s\S]*?</interface>',
    ).firstMatch(xml)!.group(0)!;
    for (final event in RegExp(r'<event name="(\w+)"').allMatches(device)) {
      final name = event.group(1)!;
      expect(
        wayland,
        anyOf(contains('l.$name = '), contains('WSN_IGNORE(l, $name)')),
        reason: 'kde_output_device_v2.$name',
      );
    }
  });

  test(
    'virtual outputs go below the real ones, out of the pointer\'s reach',
    () {
      final cast = read('capture/kwin_screencast.cc');
      expect(cast, contains('bottom + kGap'));
      expect(cast, contains('kSlotWidth'));
      expect(cast, contains('kwin::ConfigureOutput(connector_'));
      // KWin's own pick of scale is replaced by the one asked for.
      expect(cast, contains('std::fabs(ours->scale - wanted_scale_) < 0.01'));
    },
  );

  test('only KWin may drive the script channel', () {
    final helper = read('capture/kwin_helper.cc');
    expect(helper, contains('OwnerOf("org.kde.KWin")'));
    expect(helper, contains('org.freedesktop.DBus.Error.AccessDenied'));
  });

  test('the script puts windows back when Whisper goes away', () {
    final script = read('capture/kwin_script.h');
    expect(script, contains('workspace.screensChanged.connect'));
    expect(script, contains('restore(w, o)'));
    for (final kept in [
      'noBorder',
      'allDesktops',
      'maximize',
      'fullScreen',
      'keepAbove',
      'minimized',
    ]) {
      expect(script, contains('o.$kept'), reason: kept);
    }
  });

  test('keys wait for the window to be activated and the pointer read', () {
    final helper = read('capture/kwin_helper.cc');
    expect(helper, contains('waits_++;'));
    expect(helper, contains('if (waits_ > 0 || !input_.empty())'));
    // Any script, any keyboard layout: Unicode keysyms.
    expect(helper, contains('0x01000000u | c'));
  });

  test('the .desktop file KWin goes by', () {
    final helper = read('capture/kwin_helper.cc');
    expect(helper, contains('NoDisplay=true'));
    expect(
      helper,
      contains('zkde_screencast_unstable_v1,org_kde_kwin_fake_input'),
    );
    expect(helper, contains('org.kde.KWin.ScreenShot2'));
    // Replaced atomically: KDE notices a new file by its directory changing.
    expect(helper, contains('g_file_set_contents(own_path.c_str()'));
    for (final script in ['linux/build_deb.sh', 'linux/build_rpm.sh']) {
      final text = File(script).readAsStringSync();
      expect(
        text,
        contains(
          'X-KDE-Wayland-Interfaces=zkde_screencast_unstable_v1,org_kde_kwin_fake_input',
        ),
        reason: script,
      );
    }
  });

  test(
    'KWin withholding its protocols is "desktop unsupported", not a login',
    () {
      final helper = File('$linux/capture/helper.cc').readAsStringSync();
      expect(
        helper,
        contains('state == HelperState::kDenied ? WSN_CAPTURE_ERROR_DESKTOP'),
      );
      expect(read('capture/session.cc'), contains('Fail(HelperFailure(state)'));
    },
  );
}
