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
import 'package:whisper/helper/native_streaming_sha256.dart';
import 'package:whisper/helper/privacy_log.dart';

enum FileOperationKind {
  storageQuery,
  pickerScan,
  fileManagerOpen,
  fileManagerReveal,
  platformChannel,
}

enum FileOperationState { failed }

enum DesktopFileManagerPlatform { macOS, windows, linux }

typedef FileManagerProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class FileManagerCommand {
  const FileManagerCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

const _androidDirChannel = MethodChannel("com.vireen.whisper/android_dir");
const _iosDirChannel = MethodChannel("com.vireen.whisper/ios_dir");
const _desktopFileManagerChannel = MethodChannel(
  'com.vireen.whisper/file_manager',
);

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
      return await _androidDirChannel.invokeMethod<int>('availableBytes', {
        'path': path,
      });
    }
    if (Platform.isIOS) {
      return await _iosDirChannel.invokeMethod<int>('availableBytes', {
        'path': path,
      });
    }
    if (Platform.isWindows) {
      return await _availableBytesOnWindows(path);
    }
    if (Platform.isMacOS || Platform.isLinux) {
      return await _availableBytesFromDf(path);
    }
  } catch (error) {
    _logFileOperation(FileOperationKind.storageQuery, error: error);
  }

  return null;
}

Future<void> notifyFileVisibleToAndroidPickers(String path) async {
  if (!Platform.isAndroid || path.isEmpty) {
    return;
  }

  try {
    await _androidDirChannel.invokeMethod<void>('scanFile', {'path': path});
  } catch (error) {
    _logFileOperation(FileOperationKind.pickerScan, error: error);
  }
}

Future<void> notifyExistingDownloadsVisibleToAndroidPickers() async {
  if (!Platform.isAndroid) {
    return;
  }

  try {
    final dir = await downloadDir();
    if (!dir.existsSync()) {
      return;
    }
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (name.startsWith('.') || name.endsWith('.part')) {
        continue;
      }
      await notifyFileVisibleToAndroidPickers(entity.path);
    }
  } catch (error) {
    _logFileOperation(FileOperationKind.pickerScan, error: error);
  }
}

void openFile(String path) async {
  if (path.endsWith(".apk") && Platform.isAndroid) {
    if (await Permission.requestInstallPackages.isDenied) {
      await Permission.requestInstallPackages.request();
    }
  }
  OpenFilex.open(path);
}

Future<void> openDir(String path, {bool parent = false}) async {
  var file = File(path);
  if (!file.existsSync()) {
    var dir = await downloadDir();
    path = dir.path;
  } else if (parent) {
    if (await revealFileInFileManager(path)) {
      return;
    }
    path = file.parent.path;
  }

  if (Platform.isMacOS) {
    await openFinder(path);
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

Future<void> openFinder(String path) async {
  // 使用系统命令打开 Finder 并显示特定文件夹
  ProcessResult result = await Process.run('open', [path]);

  // 处理执行结果
  if (result.exitCode != 0) {
    _logFileOperation(
      FileOperationKind.fileManagerOpen,
      exitCode: result.exitCode,
    );
  }
}

DesktopFileManagerPlatform? _currentDesktopFileManagerPlatform() {
  if (Platform.isMacOS) {
    return DesktopFileManagerPlatform.macOS;
  }
  if (Platform.isWindows) {
    return DesktopFileManagerPlatform.windows;
  }
  if (Platform.isLinux) {
    return DesktopFileManagerPlatform.linux;
  }
  return null;
}

List<FileManagerCommand> fileManagerRevealCommands(
  DesktopFileManagerPlatform platform,
  String path,
) {
  switch (platform) {
    case DesktopFileManagerPlatform.macOS:
      return <FileManagerCommand>[
        FileManagerCommand('open', <String>['-R', path]),
      ];
    case DesktopFileManagerPlatform.windows:
      return <FileManagerCommand>[
        FileManagerCommand('explorer.exe', <String>['/select,', path]),
      ];
    case DesktopFileManagerPlatform.linux:
      final fileUri = Uri.file(path).toString().replaceAll("'", '%27');
      return <FileManagerCommand>[
        // FileManager1 works with the user's default file manager on GNOME,
        // KDE and other freedesktop-compatible desktops.
        FileManagerCommand('gdbus', <String>[
          'call',
          '--session',
          '--dest',
          'org.freedesktop.FileManager1',
          '--object-path',
          '/org/freedesktop/FileManager1',
          '--method',
          'org.freedesktop.FileManager1.ShowItems',
          "['$fileUri']",
          '',
        ]),
        FileManagerCommand('nautilus', <String>['--select', path]),
        FileManagerCommand('dolphin', <String>['--select', path]),
      ];
  }
}

Future<bool> revealFileInFileManager(
  String path, {
  DesktopFileManagerPlatform? platform,
  FileManagerProcessRunner processRunner = Process.run,
}) async {
  final file = File(path);
  if (!file.existsSync()) {
    return false;
  }
  final targetPath = file.absolute.path;

  final resolvedPlatform = platform ?? _currentDesktopFileManagerPlatform();
  if (resolvedPlatform == null) {
    return false;
  }

  if (platform == null &&
      resolvedPlatform == DesktopFileManagerPlatform.macOS) {
    try {
      final revealed = await _desktopFileManagerChannel.invokeMethod<bool>(
        'revealFile',
        <String, String>{'path': targetPath},
      );
      if (revealed == true) {
        return true;
      }
    } catch (error) {
      // Older builds do not have the native channel; keep the command fallback.
      _logFileOperation(FileOperationKind.platformChannel, error: error);
    }
  }

  for (final command in fileManagerRevealCommands(
    resolvedPlatform,
    targetPath,
  )) {
    try {
      final result = await processRunner(command.executable, command.arguments);
      if (result.exitCode == 0) {
        return true;
      }
      _logFileOperation(
        FileOperationKind.fileManagerReveal,
        exitCode: result.exitCode,
      );
    } catch (error) {
      _logFileOperation(FileOperationKind.fileManagerReveal, error: error);
    }
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

String bytesChecksum(List<int> bytes, {String algorithm = 'sha256'}) {
  return _checksumHash(algorithm).convert(bytes).toString();
}

class StreamingChecksum {
  StreamingChecksum({String algorithm = 'sha256'})
    : _native = algorithm == 'sha256' && _nativeSha256Enabled
          ? NativeStreamingSha256()
          : null,
      _digestSink = _DigestSink(),
      _closed = false {
    if (_native == null) {
      _inputSink = _checksumHash(algorithm).startChunkedConversion(_digestSink);
    }
  }

  static bool _nativeSha256Enabled = false;

  static void installNativeSha256Acceleration() {
    final probe = NativeStreamingSha256();
    if (probe.close() !=
        'e3b0c44298fc1c149afbf4c8996fb924'
            '27ae41e4649b934ca495991b7852b855') {
      throw StateError('Native SHA-256 self-test failed');
    }
    _nativeSha256Enabled = true;
  }

  final NativeStreamingSha256? _native;
  final _DigestSink _digestSink;
  ByteConversionSink? _inputSink;
  bool _closed;
  String? _value;

  void add(List<int> bytes) {
    if (_closed) {
      throw StateError('Cannot add bytes after checksum is closed');
    }
    final native = _native;
    if (native != null) {
      native.add(bytes);
    } else {
      _inputSink!.add(bytes);
    }
  }

  String close() {
    final existing = _value;
    if (existing != null) {
      return existing;
    }
    final native = _native;
    final String value;
    if (native != null) {
      value = native.close();
    } else {
      _inputSink!.close();
      value = _digestSink.value.toString();
    }
    _closed = true;
    _value = value;
    return value;
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
    dir = Directory(p.join(dir.path, 'whisper'));
  }
  if (!dir.existsSync()) {
    dir.createSync();
  }
  return dir;
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
  } on PlatformException catch (error) {
    _logFileOperation(FileOperationKind.platformChannel, error: error);
  }
  return result;
}

Future<String> openIosDir(String path) async {
  String result = "";
  try {
    await _iosDirChannel.invokeMethod('openFolder', {'path': path});
  } on PlatformException catch (error) {
    _logFileOperation(FileOperationKind.platformChannel, error: error);
  }
  return result;
}

Future<int?> _availableBytesFromDf(String path) async {
  final result = await Process.run('df', ['-k', path]);
  if (result.exitCode != 0) {
    _logFileOperation(
      FileOperationKind.storageQuery,
      exitCode: result.exitCode,
    );
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
  final drive = root
      .replaceAll('\\', '')
      .replaceAll('/', '')
      .replaceAll(':', '');
  if (drive.isEmpty) {
    return null;
  }

  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    "(Get-PSDrive -Name '$drive').Free",
  ]);
  if (result.exitCode != 0) {
    _logFileOperation(
      FileOperationKind.storageQuery,
      exitCode: result.exitCode,
    );
    return null;
  }

  return int.tryParse(result.stdout.toString().trim());
}

void _logFileOperation(FileOperationKind kind, {Object? error, int? exitCode}) {
  privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
    PrivacyField.kind: kind,
    PrivacyField.state: FileOperationState.failed,
    if (error != null) PrivacyField.errorType: privacyLog.errorType(error),
    if (exitCode != null) PrivacyField.exitCode: exitCode,
  });
}
