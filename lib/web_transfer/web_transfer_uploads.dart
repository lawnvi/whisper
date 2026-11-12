import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/socket/transfer_file_name.dart';
import 'package:whisper/socket/verified_file_publisher.dart';

import 'web_transfer_protocol.dart';

/// Why a chunk was not taken.
enum WebChunkRefusal { position, size, space, failed }

class WebChunkException implements Exception {
  const WebChunkException(this.reason);

  final WebChunkRefusal reason;

  @override
  String toString() => 'WebChunkException($reason)';
}

/// A file a browser is sending, written in order into a hidden file beside
/// where it ends up. The SHA-256 is taken as the bytes arrive: the page cannot
/// send one (no `crypto.subtle` on plain HTTP), but publishing wants it.
class WebUpload {
  WebUpload({
    required this.offer,
    required this.directory,
    required this.transferId,
    this.modified,
  }) : tempPath = p.join(directory.path, '.whisper-web-${offer.id}.part');

  final WebOffer offer;
  final Directory directory;
  final String transferId;
  final String tempPath;

  /// When the file was last changed on the visitor's device.
  final DateTime? modified;

  int _committed = 0;
  RandomAccessFile? _file;
  final _digest = _Digest();
  ByteConversionSink? _hash;
  bool _writing = false;
  bool _closed = false;

  /// Bytes written so far, in order.
  int get committed => _committed;

  bool get complete => _committed == offer.size;

  /// A chunk is being written: another one is told where to start instead.
  bool get busy => _writing;

  Future<void> open() async {
    _file = await File(tempPath).open(mode: FileMode.write);
    _hash = sha256.startChunkedConversion(_digest);
  }

  /// Writes the chunk that starts at [start] and is [length] long. Bytes that
  /// arrived before the body broke off stay: [committed] says where the next
  /// chunk starts. Throws [WebChunkException].
  Future<void> write(int start, int length, Stream<List<int>> body) async {
    final file = _file;
    if (file == null || _closed) {
      throw const WebChunkException(WebChunkRefusal.failed);
    }
    if (start != _committed || _writing) {
      throw const WebChunkException(WebChunkRefusal.position);
    }
    if (start + length > offer.size || length > webMaxChunkBytes) {
      throw const WebChunkException(WebChunkRefusal.size);
    }
    _writing = true;
    var taken = 0;
    try {
      await for (final chunk in body) {
        if (taken + chunk.length > length) {
          throw const WebChunkException(WebChunkRefusal.size);
        }
        await file.writeFrom(chunk);
        _hash!.add(chunk);
        taken += chunk.length;
        _committed += chunk.length;
      }
    } on WebChunkException {
      rethrow;
    } on FileSystemException catch (error) {
      throw WebChunkException(
        _isDiskFull(error) ? WebChunkRefusal.space : WebChunkRefusal.failed,
      );
    } finally {
      _writing = false;
    }
  }

  /// Moves the finished file to a free name in [directory] (never over an
  /// existing one) and returns where it went.
  Future<String> publish() async {
    final file = _file;
    if (file == null || !complete || _closed) {
      throw StateError('upload is not complete');
    }
    await file.flush();
    await file.close();
    _file = null;
    _hash!.close();
    final snapshot = await VerifiedTransferSnapshot.openFromStreamingDigest(
      File(tempPath),
      expectedSize: offer.size,
      streamingSha256: _digest.value.toString(),
    );
    final when = modified;
    final DownloadFileReservation reservation;
    try {
      reservation = await publishVerifiedDownload(
        snapshot,
        directory,
        webSafeFileName(offer.name),
        preparePublishedFile: when == null
            ? null
            : (published) => _touch(published, when),
      );
      await releaseDownloadReservation(reservation);
    } finally {
      // Windows keeps the temp name while a handle on it is open, even after a
      // hard link took the content.
      await snapshot.close();
    }
    await _deleteTemp();
    _closed = true;
    return reservation.path;
  }

  /// Gives up: the hidden file goes.
  Future<void> discard() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _file?.close();
    } on FileSystemException {
      // Already closed or gone.
    }
    _file = null;
    await _deleteTemp();
  }

  Future<void> _deleteTemp() async {
    try {
      await File(tempPath).delete();
    } on FileSystemException {
      // Moved or never made.
    }
  }

  static Future<void> _touch(File file, DateTime when) async {
    try {
      await file.setLastModified(when);
    } on FileSystemException {
      // The time is a nicety.
    }
  }

  // ENOSPC on Linux, macOS and Android; ERROR_DISK_FULL and
  // ERROR_HANDLE_DISK_FULL on Windows.
  static bool _isDiskFull(FileSystemException error) =>
      switch (error.osError?.errorCode) {
        28 || 112 || 39 => true,
        _ => false,
      };
}

/// A name a browser sent, made safe to save: no folders, no characters a
/// system refuses, no name a system reserves, at most
/// [maxIncomingFileNameBytes]. The extension is kept when it can be.
String webSafeFileName(String name) {
  var base = name.split(RegExp(r'[/\\]')).last;
  final cleaned = StringBuffer();
  for (final rune in base.runes) {
    final bad =
        rune <= 0x1f ||
        (rune >= 0x7f && rune <= 0x9f) ||
        '<>:"|?*'.runes.contains(rune) ||
        (rune >= 0xd800 && rune <= 0xdfff);
    cleaned.writeCharCode(bad ? 0x5f : rune);
  }
  base = cleaned.toString().trim();
  while (base.endsWith('.') || base.endsWith(' ')) {
    base = base.substring(0, base.length - 1);
  }
  while (base.startsWith('.')) {
    base = base.substring(1);
  }
  if (base.isEmpty) {
    base = 'file';
  }
  final extension = p.extension(base);
  var stem = base.substring(0, base.length - extension.length);
  if (stem.isEmpty) {
    stem = 'file';
  }
  final keep = utf8.encode(extension).length <= 16 ? extension : '';
  while (stem.isNotEmpty &&
      utf8.encode('$stem$keep').length > maxIncomingFileNameBytes) {
    stem = String.fromCharCodes(stem.runes.take(stem.runes.length - 1));
  }
  var result = '$stem$keep';
  if (!validateIncomingFileName(result)) {
    // A reserved name such as CON.
    result = '_$result';
  }
  return validateIncomingFileName(result) ? result : 'file';
}

class _Digest implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('no digest yet'));

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
