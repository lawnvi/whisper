import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// CRC-32 (IEEE 802.3, as in zip), slicing by 8 bytes.
class ShareCrc32 {
  static final Uint32List _tables = _buildTables();

  int _crc = 0xFFFFFFFF;

  int get value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;

  void add(List<int> data) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final t = _tables;
    var crc = _crc;
    var i = 0;
    final n = bytes.length;
    final fast = n - 8;
    while (i <= fast) {
      final one =
          crc ^
          (bytes[i] |
              (bytes[i + 1] << 8) |
              (bytes[i + 2] << 16) |
              (bytes[i + 3] << 24));
      crc =
          t[0x700 + (one & 0xff)] ^
          t[0x600 + ((one >> 8) & 0xff)] ^
          t[0x500 + ((one >> 16) & 0xff)] ^
          t[0x400 + ((one >> 24) & 0xff)] ^
          t[0x300 + bytes[i + 4]] ^
          t[0x200 + bytes[i + 5]] ^
          t[0x100 + bytes[i + 6]] ^
          t[bytes[i + 7]];
      i += 8;
    }
    while (i < n) {
      crc = t[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
      i++;
    }
    _crc = crc & 0xFFFFFFFF;
  }

  static int of(List<int> data) => (ShareCrc32()..add(data)).value;

  static Uint32List _buildTables() {
    final t = Uint32List(8 * 256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      t[n] = c;
    }
    for (var n = 0; n < 256; n++) {
      var c = t[n];
      for (var k = 1; k < 8; k++) {
        c = t[c & 0xff] ^ (c >> 8);
        t[k * 256 + n] = c;
      }
    }
    return t;
  }
}

/// One entry of a zip being streamed: a folder (name ends with `/`) or a
/// file read from [path].
class ShareZipEntry {
  const ShareZipEntry.folder(this.name, this.modified)
    : path = null,
      size = 0,
      mode = 0x41ED; // drwxr-xr-x

  const ShareZipEntry.file(
    this.name,
    String this.path,
    this.size,
    this.modified, {
    this.mode = 0x81A4, // -rw-r--r--
  });

  /// '/'-separated path inside the zip.
  final String name;
  final String? path;
  final int size;
  final DateTime modified;

  /// Unix mode with the file type bits.
  final int mode;

  bool get isFolder => path == null;
}

/// A file changed size while it was being zipped; the download is cut off
/// rather than handing out a zip that does not match its own directory.
class ShareZipChangedException implements Exception {
  const ShareZipChangedException(this.name);

  final String name;

  @override
  String toString() => 'ShareZipChangedException($name)';
}

/// Too many entries to zip in one go.
class ShareZipTooLargeException implements Exception {
  const ShareZipTooLargeException();

  @override
  String toString() => 'ShareZipTooLargeException';
}

/// The entries of a zip, walked again each time it is called, always in
/// the same order.
typedef ShareZipSource = Stream<ShareZipEntry> Function();

/// A zip laid out before it is written: files are stored (not compressed),
/// so every offset and the total [length] are known up front and the
/// download shows real progress. CRCs go in data descriptors after each
/// file, computed while it streams. ZIP64 records are used where a size,
/// offset or the entry count needs them; names are UTF-8.
///
/// The entries are never all held in memory: the source is walked once to
/// lay the zip out, again to send the files, and a third time to write the
/// central directory. Between the passes only a CRC and a check value per
/// entry are kept (8 bytes); anything that changed in between cuts the
/// download.
class ShareZipPlan {
  ShareZipPlan._(
    this._source, {
    required this.forceZip64,
    required this.count,
    required int centralOffset,
    required int centralLength,
  }) : _centralOffset = centralOffset,
       _centralLength = centralLength,
       _zip64End =
           forceZip64 ||
           count >= _max16 ||
           centralOffset >= _max32 ||
           centralLength >= _max32 {
    length =
        _centralOffset +
        _centralLength +
        (_zip64End ? _zip64EndLength + _zip64LocatorLength : 0) +
        _endLength;
  }

  /// Lays out the zip of [source], walking it once.
  static Future<ShareZipPlan> plan(
    ShareZipSource source, {
    bool forceZip64 = false,
    int maxEntries = defaultMaxEntries,
  }) async {
    final measure = _Measure(forceZip64);
    await for (final entry in source()) {
      measure.add(entry);
      if (measure.count > maxEntries) {
        throw const ShareZipTooLargeException();
      }
    }
    return measure.finish(source);
  }

  /// The zip of entries already at hand.
  factory ShareZipPlan.of(
    List<ShareZipEntry> entries, {
    bool forceZip64 = false,
  }) {
    final measure = _Measure(forceZip64);
    entries.forEach(measure.add);
    return measure.finish(() => Stream.fromIterable(entries));
  }

  /// A million entries keep the per-entry bookkeeping near 8 MB.
  static const defaultMaxEntries = 1000000;

  static const _max16 = 0xFFFF;
  static const _max32 = 0xFFFFFFFF;
  static const _zip64EndLength = 56;
  static const _zip64LocatorLength = 20;
  static const _endLength = 22;

  final ShareZipSource _source;
  final bool forceZip64;

  /// Entries in the zip.
  final int count;
  final int _centralOffset;
  final int _centralLength;
  final bool _zip64End;

  /// Exact size of the whole zip in bytes.
  late final int length;

  /// The zip's bytes. [onBytes] hears how many were produced. Reading
  /// follows the listener: a paused subscription pauses the file reads.
  Stream<List<int>> stream({
    void Function(int bytes)? onBytes,
    Stream<List<int>> Function(String path)? open,
  }) async* {
    final read = open ?? (path) => File(path).openRead();
    final crcs = Uint32List(count);
    final checks = Uint32List(count);
    var index = 0;
    var offset = 0;
    await for (final entry in _source()) {
      if (index >= count) {
        throw ShareZipChangedException(entry.name);
      }
      final name = utf8.encode(entry.name);
      final layout = _Layout(entry, name, offset, _zip64(entry));
      final header = layout.localHeader();
      onBytes?.call(header.length);
      yield header;
      checks[index] = _check(name, entry);
      if (!entry.isFolder) {
        final crc = ShareCrc32();
        var written = 0;
        await for (final chunk in read(entry.path!)) {
          written += chunk.length;
          if (written > entry.size) {
            throw ShareZipChangedException(entry.name);
          }
          crc.add(chunk);
          onBytes?.call(chunk.length);
          yield chunk;
        }
        if (written != entry.size) {
          throw ShareZipChangedException(entry.name);
        }
        crcs[index] = crc.value;
        final descriptor = layout.descriptor(crcs[index]);
        onBytes?.call(descriptor.length);
        yield descriptor;
      }
      offset += layout.localLength + entry.size + layout.descriptorLength;
      index++;
    }
    if (index != count || offset != _centralOffset) {
      throw const ShareZipChangedException('entries');
    }
    final central = BytesBuilder(copy: false);
    index = 0;
    offset = 0;
    await for (final entry in _source()) {
      final name = utf8.encode(entry.name);
      if (index >= count || checks[index] != _check(name, entry)) {
        throw ShareZipChangedException(entry.name);
      }
      final layout = _Layout(entry, name, offset, _zip64(entry));
      central.add(layout.centralHeader(crcs[index], forceZip64));
      offset += layout.localLength + entry.size + layout.descriptorLength;
      index++;
      if (central.length >= 64 * 1024) {
        final bytes = central.takeBytes();
        onBytes?.call(bytes.length);
        yield bytes;
      }
    }
    if (index != count) {
      throw const ShareZipChangedException('entries');
    }
    central.add(_end());
    final bytes = central.takeBytes();
    onBytes?.call(bytes.length);
    yield bytes;
  }

  bool _zip64(ShareZipEntry entry) => forceZip64 || entry.size >= _max32;

  /// Same name and size as on the pass before.
  static int _check(List<int> name, ShareZipEntry entry) =>
      (ShareCrc32.of(name) ^
          (entry.size & 0xFFFFFFFF) ^
          ((entry.size >> 32) * 0x9E3779B1) ^
          (entry.isFolder ? 0x5bd1e995 : 0)) &
      0xFFFFFFFF;

  Uint8List _end() {
    final out = _Writer();
    if (_zip64End) {
      final recordOffset = _centralOffset + _centralLength;
      out
        ..u32(0x06064b50)
        ..u64(_zip64EndLength - 12)
        ..u16(_versionMadeBy)
        ..u16(45)
        ..u32(0)
        ..u32(0)
        ..u64(count)
        ..u64(count)
        ..u64(_centralLength)
        ..u64(_centralOffset)
        ..u32(0x07064b50)
        ..u32(0)
        ..u64(recordOffset)
        ..u32(1);
    }
    out
      ..u32(0x06054b50)
      ..u16(0)
      ..u16(0)
      ..u16(_zip64End && count >= _max16 ? _max16 : count)
      ..u16(_zip64End && count >= _max16 ? _max16 : count)
      ..u32(_zip64End ? _max32 : _centralLength)
      ..u32(_zip64End ? _max32 : _centralOffset)
      ..u16(0);
    return out.take();
  }
}

/// Sizes the zip one entry at a time.
class _Measure {
  _Measure(this.forceZip64);

  final bool forceZip64;
  var count = 0;
  var _offset = 0;
  var _central = 0;

  void add(ShareZipEntry entry) {
    final name = utf8.encode(entry.name);
    final zip64 = forceZip64 || entry.size >= ShareZipPlan._max32;
    final layout = _Layout(entry, name, _offset, zip64);
    _central += layout.centralLength(forceZip64);
    _offset += layout.localLength + entry.size + layout.descriptorLength;
    count++;
  }

  ShareZipPlan finish(ShareZipSource source) => ShareZipPlan._(
    source,
    forceZip64: forceZip64,
    count: count,
    centralOffset: _offset,
    centralLength: _central,
  );
}

/// One path segment as a zip entry name part: a backslash (legal in Linux
/// names) would be read as a separator on Windows.
String shareZipSegment(String name) => name.replaceAll('\\', '_');

/// Unix, spec version 4.5.
const _versionMadeBy = (3 << 8) | 45;

class _Layout {
  _Layout(this.entry, this.name, this.offset, this.zip64);

  final ShareZipEntry entry;
  final List<int> name;
  final int offset;

  /// Sizes in ZIP64 fields (local extra, 8-byte descriptor).
  final bool zip64;

  static const _flagUtf8 = 0x0800;
  static const _flagDescriptor = 0x0008;
  static const _max32 = 0xFFFFFFFF;

  int get _flags => _flagUtf8 | (entry.isFolder ? 0 : _flagDescriptor);
  int get _localExtraLength => zip64 ? 20 : 0;
  int get localLength => 30 + name.length + _localExtraLength;
  int get descriptorLength => entry.isFolder ? 0 : (zip64 ? 24 : 16);

  bool _offsetNeeds64(bool force) => force || offset >= _max32;
  bool _sizeNeeds64(bool force) => force || entry.size >= _max32;

  int _centralExtraLength(bool force) {
    final fields =
        (_sizeNeeds64(force) ? 2 : 0) + (_offsetNeeds64(force) ? 1 : 0);
    return fields == 0 ? 0 : 4 + 8 * fields;
  }

  int centralLength(bool force) =>
      46 + name.length + _centralExtraLength(force);

  int get _versionNeeded => zip64 ? 45 : 20;

  Uint8List localHeader() {
    final out = _Writer()
      ..u32(0x04034b50)
      ..u16(_versionNeeded)
      ..u16(_flags)
      ..u16(0)
      ..u16(_dosTime(entry.modified))
      ..u16(_dosDate(entry.modified))
      ..u32(0)
      ..u32(zip64 ? _max32 : 0)
      ..u32(zip64 ? _max32 : 0)
      ..u16(name.length)
      ..u16(_localExtraLength)
      ..add(name);
    if (zip64) {
      // Sizes here are known, so they are given rather than left at zero;
      // the descriptor repeats them along with the CRC.
      out
        ..u16(0x0001)
        ..u16(16)
        ..u64(entry.size)
        ..u64(entry.size);
    }
    return out.take();
  }

  Uint8List descriptor(int crc) {
    final out = _Writer()
      ..u32(0x08074b50)
      ..u32(crc);
    if (zip64) {
      out
        ..u64(entry.size)
        ..u64(entry.size);
    } else {
      out
        ..u32(entry.size)
        ..u32(entry.size);
    }
    return out.take();
  }

  Uint8List centralHeader(int crc, bool force) {
    final size64 = _sizeNeeds64(force);
    final offset64 = _offsetNeeds64(force);
    final extra = _centralExtraLength(force);
    final out = _Writer()
      ..u32(0x02014b50)
      ..u16(_versionMadeBy)
      ..u16(size64 || offset64 ? 45 : _versionNeeded)
      ..u16(_flags)
      ..u16(0)
      ..u16(_dosTime(entry.modified))
      ..u16(_dosDate(entry.modified))
      ..u32(crc)
      ..u32(size64 ? _max32 : entry.size)
      ..u32(size64 ? _max32 : entry.size)
      ..u16(name.length)
      ..u16(extra)
      ..u16(0)
      ..u16(0)
      ..u16(0)
      ..u32(((entry.mode & 0xFFFF) << 16) | (entry.isFolder ? 0x10 : 0))
      ..u32(offset64 ? _max32 : offset)
      ..add(name);
    if (extra > 0) {
      out
        ..u16(0x0001)
        ..u16(extra - 4);
      if (size64) {
        out
          ..u64(entry.size)
          ..u64(entry.size);
      }
      if (offset64) {
        out.u64(offset);
      }
    }
    return out.take();
  }
}

int _dosTime(DateTime when) {
  final t = _dosClamp(when);
  return (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);
}

int _dosDate(DateTime when) {
  final t = _dosClamp(when);
  return ((t.year - 1980) << 9) | (t.month << 5) | t.day;
}

DateTime _dosClamp(DateTime when) {
  final local = when.toLocal();
  if (local.year < 1980) {
    return DateTime(1980);
  }
  if (local.year > 2107) {
    return DateTime(2107, 12, 31, 23, 59, 58);
  }
  return local;
}

class _Writer {
  final _builder = BytesBuilder();
  final _scratch = ByteData(8);

  void u16(int value) {
    _scratch.setUint16(0, value & 0xFFFF, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 2));
  }

  void u32(int value) {
    _scratch.setUint32(0, value & 0xFFFFFFFF, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 4));
  }

  void u64(int value) {
    _scratch.setUint64(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 8));
  }

  void add(List<int> value) => _builder.add(value);

  Uint8List take() => _builder.takeBytes();
}
