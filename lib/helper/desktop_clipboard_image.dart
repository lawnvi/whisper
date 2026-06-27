import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class ClipboardImageDraft {
  const ClipboardImageDraft({
    required this.path,
    required this.fileName,
    required this.size,
    required this.bytes,
  });

  final String path;
  final String fileName;
  final int size;
  final Uint8List bytes;
}

class DesktopClipboardImageReader {
  static const channelName = 'com.vireen.whisper/desktop_clipboard_image';

  const DesktopClipboardImageReader({
    MethodChannel channel = const MethodChannel(channelName),
    Future<Directory> Function()? tempDirectoryProvider,
    DateTime Function()? nowProvider,
  })  : _channel = channel,
        _tempDirectoryProvider = tempDirectoryProvider,
        _nowProvider = nowProvider;

  final MethodChannel _channel;
  final Future<Directory> Function()? _tempDirectoryProvider;
  final DateTime Function()? _nowProvider;

  Future<ClipboardImageDraft?> readImageDraft() async {
    final Uint8List? bytes;
    try {
      bytes = await _channel.invokeMethod<Uint8List>('readImagePng');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }

    if (bytes == null || bytes.isEmpty) {
      return null;
    }

    try {
      final baseDir = _tempDirectoryProvider == null
          ? Directory.systemTemp
          : await _tempDirectoryProvider();
      final directory =
          Directory(p.join(baseDir.path, 'whisper_clipboard_images'));
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final fileName = await _uniqueFileName(directory);
      final file = File(p.join(directory.path, fileName));
      await file.writeAsBytes(bytes, flush: true);
      return ClipboardImageDraft(
        path: file.path,
        fileName: fileName,
        size: bytes.length,
        bytes: bytes,
      );
    } on FileSystemException {
      return null;
    }
  }

  Future<String> _uniqueFileName(Directory directory) async {
    final now = _nowProvider?.call() ?? DateTime.now();
    final baseName = 'Screenshot ${_formatTimestamp(now)}';
    var fileName = '$baseName.png';
    var candidate = File(p.join(directory.path, fileName));
    var suffix = 2;
    while (await candidate.exists()) {
      fileName = '$baseName-$suffix.png';
      candidate = File(p.join(directory.path, fileName));
      suffix++;
    }
    return fileName;
  }

  String _formatTimestamp(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final second = value.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour.$minute.$second';
  }
}
