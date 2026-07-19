import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../script/prune_flutter_assets.dart';

void main() {
  test('release builds prune assets before packaging', () {
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    final macosScript = File('script/build_and_run.sh').readAsStringSync();
    final debScript = File('linux/build_deb.sh').readAsStringSync();

    expect(gradle, contains('pruneFlutterAssetsRelease'));
    expect(gradle, contains('copyFlutterAssetsRelease'));
    expect(workflow, contains('prune_flutter_assets.dart ios'));
    expect(workflow, contains('prune_flutter_assets.dart windows-x64'));
    expect(workflow, contains('Foreign Opus assets remain'));
    expect(macosScript, contains('prune_flutter_assets.dart macos'));
    expect(debScript, contains('prune_flutter_assets.dart" linux-x64'));
  });

  test('keeps only the target Opus package assets', () {
    final temp = Directory.systemTemp.createTempSync('whisper-assets-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final assets = Directory('${temp.path}/flutter_assets');

    for (final package in <String>[
      'opus_codec_android',
      'opus_codec_ios',
      'opus_codec_linux',
      'opus_codec_macos',
      'opus_codec_web',
      'opus_codec_windows',
    ]) {
      final file = File('${assets.path}/packages/$package/assets/payload');
      file.createSync(recursive: true);
      file.writeAsStringSync(package);
    }

    pruneFlutterAssets(platform: 'android', flutterAssets: assets);

    expect(
      Directory('${assets.path}/packages/opus_codec_android').existsSync(),
      isTrue,
    );
    expect(
      Directory('${assets.path}/packages/opus_codec_windows').existsSync(),
      isFalse,
    );
    expect(
      Directory('${assets.path}/packages/opus_codec_web').existsSync(),
      isFalse,
    );
  });

  test('removes unused Opus architecture assets', () {
    final temp = Directory.systemTemp.createTempSync('whisper-assets-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final assets = Directory('${temp.path}/flutter_assets');
    final windowsAssets = Directory(
      '${assets.path}/packages/opus_codec_windows/assets',
    )..createSync(recursive: true);
    File('${windowsAssets.path}/libopus_x64.dll.blob').writeAsBytesSync([1]);
    File('${windowsAssets.path}/libopus_x86.dll.blob').writeAsBytesSync([1]);

    pruneFlutterAssets(platform: 'windows-x64', flutterAssets: assets);

    expect(
      File('${windowsAssets.path}/libopus_x64.dll.blob').existsSync(),
      isTrue,
    );
    expect(
      File('${windowsAssets.path}/libopus_x86.dll.blob').existsSync(),
      isFalse,
    );
  });
}
