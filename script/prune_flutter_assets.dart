import 'dart:io';

const _opusPackages = <String>{
  'opus_codec_android',
  'opus_codec_ios',
  'opus_codec_linux',
  'opus_codec_macos',
  'opus_codec_web',
  'opus_codec_windows',
};

const _keptOpusPackage = <String, String>{
  'android': 'opus_codec_android',
  'ios': 'opus_codec_ios',
  'linux-x64': 'opus_codec_linux',
  'macos': 'opus_codec_macos',
  'windows-x64': 'opus_codec_windows',
};

void pruneFlutterAssets({
  required String platform,
  required Directory flutterAssets,
}) {
  final keptPackage = _keptOpusPackage[platform];
  if (keptPackage == null) {
    throw ArgumentError.value(platform, 'platform', 'unsupported platform');
  }

  final packages = Directory('${flutterAssets.path}/packages');
  if (!packages.existsSync()) {
    return;
  }

  for (final package in _opusPackages) {
    if (package == keptPackage) {
      continue;
    }
    final directory = Directory('${packages.path}/$package');
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }

  if (platform == 'linux-x64') {
    _deleteIfPresent(
      File('${packages.path}/opus_codec_linux/assets/libopus_aarch64.so.blob'),
    );
  } else if (platform == 'windows-x64') {
    _deleteIfPresent(
      File('${packages.path}/opus_codec_windows/assets/libopus_x86.dll.blob'),
    );
  }
}

void _deleteIfPresent(File file) {
  if (file.existsSync()) {
    file.deleteSync();
  }
}

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln(
      'usage: dart script/prune_flutter_assets.dart '
      '<platform> <flutter_assets_dir>',
    );
    exitCode = 64;
    return;
  }

  pruneFlutterAssets(
    platform: arguments[0],
    flutterAssets: Directory(arguments[1]),
  );
}
