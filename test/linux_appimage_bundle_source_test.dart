import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final script = File('linux/build_appimage.sh').readAsStringSync();

  String section(String source, String start, String end) {
    final from = source.indexOf(start);
    return source.substring(from, source.indexOf(end, from));
  }

  test('the AppImage carries the libraries desktops often lack', () {
    // The AppImage catalog's clean Ubuntu stopped at the first of these:
    // "libkeybinder-3.0.so.0: cannot open shared object file".
    final bundled = section(script, 'BUNDLED_LIBS=(', ')');
    for (final lib in [
      'libkeybinder-3.0.so.0',
      'libayatana-appindicator3.so.1',
      'libayatana-indicator3.so.7',
      'libayatana-ido3-0.4.so.0',
      'libdbusmenu-glib.so.4',
      'libdbusmenu-gtk3.so.4',
      'libsecret-1.so.0',
    ]) {
      expect(bundled, contains(lib));
    }

    // Flutter's plugins look for libraries in the build machine's folder.
    expect(
      script,
      contains(
        r"patchelf --set-rpath '$ORIGIN' "
        '"\${lib}"',
      ),
    );
    // A library that is neither bundled nor expected on the system stops
    // the build instead of the app.
    expect(script, contains('which is neither bundled'));
    expect(script, contains('if (( unresolved )); then\n  exit 1'));
  });

  test('the bundled GStreamer only stands in where the system has none', () {
    // System GStreamer plugins only work with the system's GStreamer.
    expect(section(script, 'BUNDLED_LIBS=(', ')'), isNot(contains('libgst')));
    expect(
      section(script, 'FALLBACK_LIBS=(', ')'),
      contains('libgstreamer-1.0.so.0'),
    );

    final appRun = section(
      script,
      'has_system_lib() {',
      r'exec "${HERE}/usr/bin/whisper" "$@"',
    );
    expect(appRun, contains('! has_system_lib libgstreamer-1.0.so.0'));
    expect(
      appRun,
      contains(r'export LD_LIBRARY_PATH="${HERE}/usr/bin/lib/fallback'),
    );
  });

  test('the AppImage opens without libfuse2', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    expect(workflow, isNot(contains('AppImage/AppImageKit')));
    expect(
      workflow,
      contains('AppImage/appimagetool/releases/download/1.9.1/'),
    );
    expect(workflow, contains('APPIMAGE_RUNTIME_FILE=/tmp/appimage-runtime'));
    expect(workflow, contains('| sha256sum -c -'));
    expect(script, contains('--runtime-file "\${APPIMAGE_RUNTIME_FILE}"'));
  });

  test('the deb asks for the tray library', () {
    final deb = File('linux/build_deb.sh').readAsStringSync();
    final depends = deb.substring(deb.indexOf('Depends:')).split('\n').first;

    expect(depends, contains('libayatana-appindicator3-1'));
  });
}
