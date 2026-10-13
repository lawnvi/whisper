import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Linux app does not need libmpv to start', () {
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();
    final debScript = File('linux/build_deb.sh').readAsStringSync();

    // Linked to libmpv, the video plugin stops the whole app from starting
    // wherever the build machine's libmpv.so.N is missing. Seen on Arch,
    // which ships libmpv.so.2 against the libmpv.so.1 of Ubuntu 22.04.
    final rule = cmake.substring(
      cmake.indexOf('if(TARGET media_kit_video_plugin)'),
      cmake.indexOf('# === Installation ==='),
    );
    expect(rule, contains('list(REMOVE_ITEM WHISPER_VIDEO_PLUGIN_LIBRARIES'));
    expect(rule, contains('PkgConfig::mpv'));
    expect(rule, contains('--allow-shlib-undefined'));

    // The package may not demand a libmpv either, and a build that links
    // one again is refused.
    final control = debScript.substring(
      debScript.indexOf('Depends:'),
      debScript.indexOf('Maintainer:'),
    );
    expect(control.split('\n').first, isNot(contains('mpv')));
    expect(control, contains('Recommends: libmpv2 | libmpv1'));
    expect(debScript, contains("grep -q 'NEEDED.*libmpv'"));
  });

  test('video is only started through the check for libmpv', () {
    // The plugin's calls into libmpv bind on first use. Reaching them with
    // no libmpv loaded ends the process, so nothing may start media_kit
    // without going through the helper that loads it.
    final direct = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('desktop_video_library.dart')) continue;
      if (entity.readAsStringSync().contains('MediaKit.ensureInitialized')) {
        direct.add(entity.path);
      }
    }
    expect(direct, isEmpty);

    final helper = File(
      'lib/helper/desktop_video_library.dart',
    ).readAsStringSync();
    expect(helper, contains("'dlopen'"));
    expect(helper, contains('_rtldLazy | _rtldGlobal'));
    expect(
      File('lib/helper/video_thumbnail.dart').readAsStringSync(),
      contains('if (!ensureDesktopVideoLibrary()) {\n    return null;'),
    );
    expect(
      File('lib/cast_receiver/playback_engine.dart').readAsStringSync(),
      contains('if (!ensureDesktopVideoLibrary()) {\n      throw StateError'),
    );
  });
}
