import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:open_dir/open_dir.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:whisper/helper/local.dart';

import 'helper.dart';

const _androidDirChannel = MethodChannel("com.vireen.whisper/android_dir");
const _iosDirChannel = MethodChannel("com.vireen.whisper/ios_dir");

bool hasEnoughStorageForFile({
  required int fileSize,
  required int? availableBytes,
  int reserveBytes = 32 * 1024 * 1024,
}) {
  if (fileSize <= 0 || availableBytes == null) {
    return true;
  }
  return availableBytes >= fileSize + reserveBytes;
}

bool isFileIntegrityValid({
  required String expectedMd5,
  required String actualMd5,
}) {
  if (expectedMd5.isEmpty) {
    return true;
  }
  return expectedMd5.toLowerCase() == actualMd5.toLowerCase();
}

Future<int?> availableBytesForPath(String path) async {
  if (path.isEmpty) {
    return null;
  }

  try {
    if (Platform.isAndroid) {
      return await _androidDirChannel.invokeMethod<int>(
        'availableBytes',
        {'path': path},
      );
    }
    if (Platform.isIOS) {
      return await _iosDirChannel.invokeMethod<int>(
        'availableBytes',
        {'path': path},
      );
    }
    if (Platform.isWindows) {
      return await _availableBytesOnWindows(path);
    }
    if (Platform.isMacOS || Platform.isLinux) {
      return await _availableBytesFromDf(path);
    }
  } catch (error) {
    logger.i('Failed to determine available storage for $path: $error');
  }

  return null;
}

void openFile(String path) async {
  if (path.endsWith(".apk") && Platform.isAndroid) {
    if (await Permission.requestInstallPackages.isDenied) {
      await Permission.requestInstallPackages.request();
    }
  }
  OpenFilex.open(path);
}

void openDir(String path, {parent = false}) async {
  var file = File(path);
  if (!file.existsSync()) {
    var dir = await downloadDir();
    path = dir.path;
  } else if (parent) {
    if (await _revealFileInFileManager(path)) {
      return;
    }
    path = file.parent.path;
  }

  logger.i("打开文件: $path");
  if (Platform.isMacOS) {
    openFinder(path);
  } else if (Platform.isAndroid) {
    // openFolderInFileManager();
    // openFileExplorer(path);
    await openAndroidDir(path);
  } else if (Platform.isIOS) {
    // openFileExplorer(path);
    await openIosDir(path);
  } else if (Platform.isWindows || Platform.isLinux) {
    final openDirPlugin = OpenDir();
    await openDirPlugin.openNativeDir(path: path);
  }
}

void openFinder(String path) async {
  // 使用系统命令打开 Finder 并显示特定文件夹
  ProcessResult result = await Process.run('open', [path]);

  // 处理执行结果
  if (result.exitCode == 0) {
    logger.i('Finder opened successfully');
  } else {
    logger.i('Error opening Finder: ${result.stderr}');
  }
}

Future<bool> _revealFileInFileManager(String path) async {
  if (!File(path).existsSync()) {
    return false;
  }

  try {
    if (Platform.isMacOS) {
      final result = await Process.run('open', ['-R', path]);
      if (result.exitCode == 0) {
        logger.i('Finder revealed file successfully');
        return true;
      }
      logger.i('Error revealing file in Finder: ${result.stderr}');
      return false;
    }

    if (Platform.isWindows) {
      final result = await Process.run('explorer', ['/select,', path]);
      if (result.exitCode == 0) {
        logger.i('Explorer revealed file successfully');
        return true;
      }
      logger.i('Error revealing file in Explorer: ${result.stderr}');
      return false;
    }

    if (Platform.isLinux) {
      final revealCommands = <List<String>>[
        ['nautilus', '--select', path],
        ['dolphin', '--select', path],
      ];

      for (final command in revealCommands) {
        try {
          final result = await Process.run(command.first, command.sublist(1));
          if (result.exitCode == 0) {
            logger.i('${command.first} revealed file successfully');
            return true;
          }
        } catch (_) {
          // Try the next file manager command.
        }
      }
    }
  } catch (error) {
    logger.i('Error revealing file in file manager: $error');
  }

  return false;
}

Future<String> fileMD5(File file, [int? start, int? end]) async {
  var value = await md5.bind(file.openRead(start, end)).first;
  return value.toString();
}

Future<String> fileChecksum(
  File file, {
  String algorithm = 'sha256',
  int? start,
  int? end,
}) async {
  final digest = _checksumHash(algorithm);
  final value = await digest.bind(file.openRead(start, end)).first;
  return value.toString();
}

Hash _checksumHash(String algorithm) {
  return switch (algorithm.toLowerCase()) {
    'md5' => md5,
    'sha256' => sha256,
    'none' => throw ArgumentError.value(
        algorithm,
        'algorithm',
        'Checksum disabled',
      ),
    _ => throw ArgumentError.value(
        algorithm,
        'algorithm',
        'Unsupported checksum algorithm',
      ),
  };
}

String bytesChecksum(
  List<int> bytes, {
  String algorithm = 'sha256',
}) {
  return _checksumHash(algorithm).convert(bytes).toString();
}

class StreamingChecksum {
  StreamingChecksum({
    String algorithm = 'sha256',
  })  : _digestSink = _DigestSink(),
        _closed = false {
    _inputSink = _checksumHash(algorithm).startChunkedConversion(_digestSink);
  }

  final _DigestSink _digestSink;
  late final ByteConversionSink _inputSink;
  bool _closed;

  void add(List<int> bytes) {
    if (_closed) {
      throw StateError('Cannot add bytes after checksum is closed');
    }
    _inputSink.add(bytes);
  }

  String close() {
    if (!_closed) {
      _inputSink.close();
      _closed = true;
    }
    return _digestSink.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value {
    final value = _value;
    if (value == null) {
      throw StateError('Digest has not been produced yet');
    }
    return value;
  }

  @override
  void add(Digest data) {
    if (_value != null) {
      throw StateError('Digest can only be produced once');
    }
    _value = data;
  }

  @override
  void close() {}
}

Future<StreamingChecksum> streamingChecksumForFilePrefix(
  File file, {
  required String algorithm,
  required int end,
}) async {
  final checksum = StreamingChecksum(algorithm: algorithm);
  if (end <= 0) {
    return checksum;
  }
  await for (final chunk in file.openRead(0, end)) {
    checksum.add(chunk);
  }
  return checksum;
}

Future<String> resumeProofHash(
  File file, {
  required int resumeOffset,
  required int chunkSize,
}) async {
  if (resumeOffset <= 0 || chunkSize <= 0) {
    return '';
  }
  final proofEnd = resumeOffset;
  final proofStart = proofEnd - chunkSize;
  if (proofStart < 0) {
    return '';
  }
  return fileChecksum(
    file,
    algorithm: 'sha256',
    start: proofStart,
    end: proofEnd,
  );
}

Future<Directory> downloadDir() async {
  var path = await LocalSetting().savePath();

  if (path.isNotEmpty && Directory(path).existsSync()) {
    return Directory(path);
  }

  Directory? dir;
  if (Platform.isIOS || Platform.isMacOS) {
    return await getApplicationDocumentsDirectory();
  } else if (Platform.isAndroid) {
    dir = Directory("/sdcard/Download/whisper");
  } else {
    dir = await getDownloadsDirectory();
    if (dir == null) {
      return await getApplicationDocumentsDirectory();
    }
    dir = Directory("${dir.path}/whisper");
  }
  if (!dir.existsSync()) {
    dir.createSync();
  }
  return dir;
}

Future<Directory> transferTempDir() async {
  final base = await downloadDir();
  final dir = Directory('${base.path}/.whisper/transfers');
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return dir;
}

Future<String> allocateFinalDownloadPath(String fileName) async {
  final appDir = await downloadDir();
  var candidate = File('${appDir.path}/$fileName');
  var idx = 1;
  final arr = fileName.split(".");
  var before = fileName;
  var dot = "";
  if (arr.length > 1) {
    dot = arr[arr.length - 1];
    before = fileName.substring(0, fileName.length - 1 - dot.length);
  }
  while (candidate.existsSync()) {
    candidate =
        File('${appDir.path}/$before-$idx${dot.isEmpty ? '' : '.$dot'}');
    idx++;
  }
  return candidate.path;
}

Future<String> transferTempFilePath(String transferId) async {
  final dir = await transferTempDir();
  return '${dir.path}/$transferId.part';
}

Future<void> writeResumableChunk(
  File file, {
  required int offset,
  required Uint8List payload,
}) async {
  if (!file.existsSync()) {
    await file.parent.create(recursive: true);
    await file.create(recursive: true);
  }
  final currentLength = await file.length();
  if (offset > currentLength) {
    throw StateError(
      'Cannot write resumable chunk at $offset when file length is $currentLength',
    );
  }
  final writer = await file.open(mode: FileMode.append);
  try {
    await writer.truncate(offset);
    await writeResumableChunkToOpenFile(
      writer,
      offset: offset,
      payload: payload,
      flush: true,
    );
  } finally {
    await writer.close();
  }
}

Future<void> writeResumableChunkToOpenFile(
  RandomAccessFile writer, {
  required int offset,
  required Uint8List payload,
  bool flush = false,
}) async {
  await writer.setPosition(offset);
  await writer.writeFrom(payload);
  if (flush) {
    await writer.flush();
  }
}

Future<bool> openAndroidDir(String path) async {
  bool result = false;
  try {
    await _androidDirChannel.invokeMethod('openFolder', {'path': path});
  } on PlatformException catch (e) {
    logger.i(e.toString());
  }
  return result;
}

Future<String> openIosDir(String path) async {
  String result = "";
  try {
    await _iosDirChannel.invokeMethod('openFolder', {'path': path});
  } on PlatformException catch (e) {
    logger.i(e.toString());
  }
  logger.i(result);
  return result;
}

Future<int?> _availableBytesFromDf(String path) async {
  final result = await Process.run('df', ['-k', path]);
  if (result.exitCode != 0) {
    logger.i('df failed for $path: ${result.stderr}');
    return null;
  }

  final lines = result.stdout
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (lines.length < 2) {
    return null;
  }

  final columns = lines.last.split(RegExp(r'\s+'));
  if (columns.length < 4) {
    return null;
  }

  final availableKb = int.tryParse(columns[3]);
  if (availableKb == null) {
    return null;
  }
  return availableKb * 1024;
}

Future<int?> _availableBytesOnWindows(String path) async {
  final root = p.rootPrefix(path);
  final drive =
      root.replaceAll('\\', '').replaceAll('/', '').replaceAll(':', '');
  if (drive.isEmpty) {
    return null;
  }

  final result = await Process.run(
    'powershell',
    [
      '-NoProfile',
      '-Command',
      "(Get-PSDrive -Name '$drive').Free",
    ],
  );
  if (result.exitCode != 0) {
    logger.i('PowerShell storage query failed for $path: ${result.stderr}');
    return null;
  }

  return int.tryParse(result.stdout.toString().trim());
}
