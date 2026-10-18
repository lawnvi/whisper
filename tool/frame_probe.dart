// Reads the frame counter that window-stream test windows draw (see the
// layout below) from snapshots and screenshots, so a test can check that a
// streamed window's picture is live and how far it got.
//
//   dart run tool/frame_probe.dart <image> [<image>...]
//
// One JSON line per image: {"file", "ok", "value", "matches": [{"value",
// "x", "y", "cell"}], "width", "height"} or {"file", "ok": false, "error"}.
// Exit code 0 when every image had a counter, 1 otherwise (2: unreadable).
//
// Layout (cell = 16 logical px, i.e. round(16 × backing scale) physical):
// a quiet zone of grey (128,128,128), 22 × 4 cells, at (16, 16) logical px
// from the window's client top-left; inside it at cell (1, 1) the code,
// 20 × 2 cells. Row 0: guard WHITE BLACK WHITE BLACK, then the counter's
// bits 15..0 (1 = WHITE (255,255,255), 0 = BLACK). Row 1: row 0 inverted
// cell by cell. The counter is the number of frames presented, mod 65536.
//
// Reads baseline JPEG (any subsampling; only the luma is decoded), PNG
// (8/16-bit grey, RGB, palette, with or without alpha; not interlaced) and
// 24/32-bit BMP, without packages.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/frame_probe.dart <image> [...]');
    exitCode = 2;
    return;
  }
  var allFound = true;
  for (final path in args) {
    Map<String, Object?> line;
    try {
      final image = decodeLuma(File(path).readAsBytesSync());
      final matches = findFrameCounters(image);
      line = {
        'file': path,
        'ok': matches.isNotEmpty,
        if (matches.isNotEmpty) 'value': matches.first.value,
        'matches': [for (final match in matches) match.toJson()],
        'width': image.width,
        'height': image.height,
        if (matches.isEmpty) 'error': 'no frame counter found',
      };
      allFound &= matches.isNotEmpty;
    } on FormatException catch (error) {
      line = {'file': path, 'ok': false, 'error': error.message};
      allFound = false;
      exitCode = 2;
    } on FileSystemException catch (error) {
      line = {'file': path, 'ok': false, 'error': error.message};
      allFound = false;
      exitCode = 2;
    }
    stdout.writeln(jsonEncode(line));
  }
  if (exitCode == 0 && !allFound) {
    exitCode = 1;
  }
}

/// An 8-bit luma picture, row-major.
class LumaImage {
  LumaImage(this.width, this.height, [Uint8List? pixels])
    : pixels = pixels ?? Uint8List(width * height);

  final int width;
  final int height;
  final Uint8List pixels;

  int at(int x, int y) {
    final cx = x < 0 ? 0 : (x >= width ? width - 1 : x);
    final cy = y < 0 ? 0 : (y >= height ? height - 1 : y);
    return pixels[cy * width + cx];
  }

  /// Mean of the 3×3 pixels around (x, y).
  double around(double x, double y) {
    final ix = x.floor();
    final iy = y.floor();
    var sum = 0;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        sum += at(ix + dx, iy + dy);
      }
    }
    return sum / 9;
  }
}

int _luma(int r, int g, int b) => (r * 299 + g * 587 + b * 114 + 500) ~/ 1000;

/// JPEG, PNG or BMP → luma.
LumaImage decodeLuma(Uint8List bytes) {
  if (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return _JpegLumaDecoder(bytes).decode();
  }
  if (bytes.length > 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return _decodePng(bytes);
  }
  if (bytes.length > 54 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return _decodeBmp(bytes);
  }
  throw const FormatException('not a JPEG, PNG or BMP image');
}

// ---------------------------------------------------------------- counter

class FrameCounterMatch {
  const FrameCounterMatch({
    required this.value,
    required this.x,
    required this.y,
    required this.cell,
  });

  final int value;

  /// Top-left of the code (not the quiet zone), in image pixels.
  final double x;
  final double y;
  final double cell;

  Map<String, Object?> toJson() => {
    'value': value,
    'x': x.round(),
    'y': y.round(),
    'cell': double.parse(cell.toStringAsFixed(2)),
  };
}

const int _bits = 16;
const int _cells = 4 + _bits;

/// Every counter in [image], top to bottom.
List<FrameCounterMatch> findFrameCounters(LumaImage image) {
  final found = <FrameCounterMatch>[];
  final runStarts = <int>[];
  final runBright = <bool>[];
  for (var y = 0; y < image.height; y++) {
    runStarts.clear();
    runBright.clear();
    final row = y * image.width;
    bool? last;
    // 160, not 128: the grey quiet zone must not run into the first
    // (white) guard cell.
    for (var x = 0; x < image.width; x++) {
      final bright = image.pixels[row + x] >= 160;
      if (bright != last) {
        runStarts.add(x);
        runBright.add(bright);
        last = bright;
      }
    }
    runStarts.add(image.width);
    for (var i = 0; i + 4 < runStarts.length; i++) {
      if (!runBright[i] ||
          runBright[i + 1] ||
          !runBright[i + 2] ||
          runBright[i + 3]) {
        continue;
      }
      final lengths = [
        for (var k = 0; k < 4; k++) runStarts[i + k + 1] - runStarts[i + k],
      ];
      final shortest = lengths.reduce(math.min);
      final longest = lengths.reduce(math.max);
      // The last guard cell may merge with a black first data bit.
      final guardLongest = math.max(
        lengths[0],
        math.max(lengths[1], lengths[2]),
      );
      if (shortest < 3 || guardLongest > shortest * 1.6 + 1) {
        continue;
      }
      if (longest > guardLongest * 1.6 + 1 && lengths[3] != longest) {
        continue;
      }
      final cell = (lengths[0] + lengths[1] + lengths[2]) / 3;
      final x0 = runStarts[i].toDouble();
      if (found.any(
        (match) =>
            (match.x - x0).abs() < match.cell * 2 &&
            y >= match.y - match.cell &&
            y <= match.y + match.cell * 3,
      )) {
        continue;
      }
      final match = _readAt(image, x0, y, cell);
      if (match != null) {
        found.add(match);
      }
    }
  }
  return found;
}

/// Tries to read a counter whose first guard cell starts at [x0] on a row
/// that crosses row 0 at [y].
FrameCounterMatch? _readAt(LumaImage image, double x0, int y, double cell) {
  bool white(double x, double y) => image.around(x, y) >= 192;
  // Vertical extent of row 0 (first guard cell, white) and row 1 (second
  // guard cell, white there): grey above and below is not white.
  final xc0 = x0 + cell / 2;
  var top = y;
  while (top > 0 && image.at(xc0.floor(), top - 1) >= 192) {
    top--;
  }
  var bottom0 = y;
  while (bottom0 + 1 < image.height &&
      image.at(xc0.floor(), bottom0 + 1) >= 192) {
    bottom0++;
  }
  // Row 1 is white under the second guard cell; start inside it.
  final xc1 = (x0 + cell * 1.5).floor();
  var bottom1 = math.min(image.height - 1, bottom0 + (cell / 2).ceil());
  if (image.at(xc1, bottom1) < 192) {
    return null;
  }
  while (bottom1 + 1 < image.height && image.at(xc1, bottom1 + 1) >= 192) {
    bottom1++;
  }
  final cellY = (bottom1 + 1 - top) / 2;
  if (cellY < cell * 0.6 || cellY > cell * 1.6) {
    return null;
  }
  final y0 = top + cellY / 2;
  final y1 = top + cellY * 1.5;
  // Refine the horizontal pitch: row 0 and row 1 differ in every column of
  // the code and match in the grey around it.
  bool differs(double x) =>
      (image.around(x, y0) - image.around(x, y1)).abs() >= 96;
  // Between two columns both rows change colour at once, so the difference
  // dips for a pixel or two; only a longer stretch ends the code.
  final gapLimit = math.max(3, (cell * 0.5).ceil());
  final limit = math.min(image.width - 1.0, x0 + cell * (_cells + 3));
  var end = x0;
  var gap = 0;
  for (var x = x0; x <= limit; x++) {
    if (differs(x)) {
      end = x;
      gap = 0;
    } else if (++gap > gapLimit) {
      break;
    }
  }
  final pitch = (end + 1 - x0) / _cells;
  if (pitch < cell * 0.8 || pitch > cell * 1.25) {
    return null;
  }
  // Grey before the code (the quiet zone), where there is room for it.
  if (x0 - pitch / 2 >= 1) {
    final before = image.around(x0 - pitch / 2, y0);
    if (before < 40 || before > 216) {
      return null;
    }
  }
  var value = 0;
  for (var k = 0; k < _cells; k++) {
    final x = x0 + (k + 0.5) * pitch;
    final a = image.around(x, y0);
    final b = image.around(x, y1);
    if ((a - 128).abs() < 48 || (b - 128).abs() < 48) {
      return null;
    }
    final bit = a >= 128;
    if (bit == (b >= 128)) {
      return null;
    }
    if (k < 4) {
      if (bit != (k.isEven)) {
        return null;
      }
      continue;
    }
    value = (value << 1) | (bit ? 1 : 0);
  }
  if (!white(x0 + pitch / 2, y0)) {
    return null;
  }
  return FrameCounterMatch(value: value, x: x0, y: top.toDouble(), cell: pitch);
}

/// Draws a counter the way test windows do, into an RGB buffer (tests and
/// reference images): quiet zone at ([left], [top]) in pixels.
void drawFrameCounter(
  Uint8List rgb,
  int width,
  int value, {
  int left = 16,
  int top = 16,
  int cell = 16,
}) {
  void fill(int x, int y, int w, int h, int v) {
    for (var yy = y; yy < y + h; yy++) {
      for (var xx = x; xx < x + w; xx++) {
        final i = (yy * width + xx) * 3;
        rgb[i] = v;
        rgb[i + 1] = v;
        rgb[i + 2] = v;
      }
    }
  }

  fill(left, top, cell * (_cells + 2), cell * 4, 128);
  for (var k = 0; k < _cells; k++) {
    final bit = k < 4 ? k.isEven : (value >> (_bits - 1 - (k - 4))) & 1 == 1;
    final x = left + cell * (k + 1);
    fill(x, top + cell, cell, cell, bit ? 255 : 0);
    fill(x, top + cell * 2, cell, cell, bit ? 0 : 255);
  }
}

// -------------------------------------------------------------------- BMP

LumaImage _decodeBmp(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final offset = data.getUint32(10, Endian.little);
  final width = data.getInt32(18, Endian.little);
  final rawHeight = data.getInt32(22, Endian.little);
  final bpp = data.getUint16(28, Endian.little);
  final compression = data.getUint32(30, Endian.little);
  if (width <= 0 || rawHeight == 0 || (bpp != 24 && bpp != 32)) {
    throw const FormatException('only 24- and 32-bit BMP are read');
  }
  if (compression != 0 && compression != 3) {
    throw const FormatException('compressed BMP is not read');
  }
  final height = rawHeight.abs();
  final stride = ((width * bpp + 31) ~/ 32) * 4;
  final image = LumaImage(width, height);
  for (var y = 0; y < height; y++) {
    final source = offset + (rawHeight > 0 ? height - 1 - y : y) * stride;
    for (var x = 0; x < width; x++) {
      final i = source + x * (bpp ~/ 8);
      image.pixels[y * width + x] = _luma(bytes[i + 2], bytes[i + 1], bytes[i]);
    }
  }
  return image;
}

// -------------------------------------------------------------------- PNG

LumaImage _decodePng(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var offset = 8;
  int? width;
  int? height;
  var depth = 8;
  var colorType = 0;
  Uint8List? palette;
  final compressed = BytesBuilder(copy: false);
  while (offset + 8 <= bytes.length) {
    final length = data.getUint32(offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    final body = Uint8List.sublistView(bytes, offset + 8, offset + 8 + length);
    offset += 12 + length;
    switch (type) {
      case 'IHDR':
        final header = ByteData.sublistView(body);
        width = header.getUint32(0);
        height = header.getUint32(4);
        depth = body[8];
        colorType = body[9];
        if (body[12] != 0) {
          throw const FormatException('interlaced PNG is not read');
        }
      case 'PLTE':
        palette = Uint8List.fromList(body);
      case 'IDAT':
        compressed.add(body);
      case 'IEND':
        offset = bytes.length;
    }
  }
  if (width == null || height == null) {
    throw const FormatException('PNG without a header');
  }
  final channels = switch (colorType) {
    0 => 1,
    2 => 3,
    3 => 1,
    4 => 2,
    6 => 4,
    _ => throw const FormatException('unknown PNG colour type'),
  };
  if (depth != 8 && depth != 16 && !(colorType == 3 && depth <= 8)) {
    throw const FormatException('PNG bit depth not read');
  }
  final bitsPerPixel = channels * depth;
  final bpp = math.max(1, bitsPerPixel ~/ 8);
  final stride = (width * bitsPerPixel + 7) ~/ 8;
  final raw = Uint8List.fromList(ZLibCodec().decode(compressed.takeBytes()));
  if (raw.length < height * (stride + 1)) {
    throw const FormatException('PNG data is short');
  }
  var previous = Uint8List(stride);
  final image = LumaImage(width, height);
  for (var y = 0; y < height; y++) {
    final start = y * (stride + 1);
    final filter = raw[start];
    final line = Uint8List.sublistView(raw, start + 1, start + 1 + stride);
    for (var i = 0; i < stride; i++) {
      final a = i >= bpp ? line[i - bpp] : 0;
      final b = previous[i];
      final c = i >= bpp ? previous[i - bpp] : 0;
      final predictor = switch (filter) {
        0 => 0,
        1 => a,
        2 => b,
        3 => (a + b) >> 1,
        4 => _paeth(a, b, c),
        _ => throw const FormatException('bad PNG filter'),
      };
      line[i] = (line[i] + predictor) & 0xFF;
    }
    for (var x = 0; x < width; x++) {
      int sample(int channel) {
        if (depth == 16) {
          return line[(x * channels + channel) * 2];
        }
        if (depth == 8) {
          return line[x * channels + channel];
        }
        final bit = x * depth;
        return (line[bit >> 3] >> (8 - depth - (bit & 7))) & ((1 << depth) - 1);
      }

      final value = switch (colorType) {
        0 || 4 => sample(0),
        2 || 6 => _luma(sample(0), sample(1), sample(2)),
        _ => () {
          final index = sample(0) * 3;
          final colors = palette;
          if (colors == null || index + 2 >= colors.length) {
            return 0;
          }
          return _luma(colors[index], colors[index + 1], colors[index + 2]);
        }(),
      };
      image.pixels[y * width + x] = value;
    }
    previous = line;
  }
  return image;
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) {
    return a;
  }
  return pb <= pc ? b : c;
}

// ------------------------------------------------------------------- JPEG

class _Huffman {
  _Huffman(Uint8List counts, Uint8List symbols) : _symbols = symbols {
    var code = 0;
    var k = 0;
    for (var length = 1; length <= 16; length++) {
      _valueOffset[length] = k - code;
      code += counts[length - 1];
      k += counts[length - 1];
      _maxCode[length] = counts[length - 1] == 0 ? -1 : code - 1;
      code <<= 1;
    }
  }

  final Uint8List _symbols;
  final _maxCode = List<int>.filled(18, -1);
  final _valueOffset = List<int>.filled(18, 0);

  int decode(_BitReader bits) {
    var code = 0;
    for (var length = 1; length <= 16; length++) {
      code = (code << 1) | bits.bit();
      if (code <= _maxCode[length]) {
        return _symbols[code + _valueOffset[length]];
      }
    }
    throw const FormatException('bad JPEG Huffman code');
  }
}

class _BitReader {
  _BitReader(this._bytes, this.offset);

  final Uint8List _bytes;
  int offset;
  int _buffer = 0;
  int _count = 0;

  /// A marker (RSTn, EOI) was reached; reads return zeros after it.
  int? marker;

  int bit() {
    if (_count == 0) {
      _fill();
    }
    _count--;
    return (_buffer >> _count) & 1;
  }

  void _fill() {
    if (marker != null || offset >= _bytes.length) {
      _buffer = 0;
      _count = 8;
      return;
    }
    var byte = _bytes[offset++];
    if (byte == 0xFF) {
      final next = offset < _bytes.length ? _bytes[offset] : 0xD9;
      if (next == 0) {
        offset++;
      } else {
        marker = next;
        offset--;
        byte = 0;
      }
    }
    _buffer = byte;
    _count = 8;
  }

  int receive(int length) {
    var value = 0;
    for (var i = 0; i < length; i++) {
      value = (value << 1) | bit();
    }
    return value;
  }

  static int extend(int value, int length) =>
      length == 0 || value >= (1 << (length - 1))
      ? value
      : value - (1 << length) + 1;

  /// Skips to just after the next RSTn marker.
  void restart() {
    _count = 0;
    _buffer = 0;
    if (marker == null) {
      while (offset + 1 < _bytes.length &&
          !(_bytes[offset] == 0xFF &&
              _bytes[offset + 1] >= 0xD0 &&
              _bytes[offset + 1] <= 0xD7)) {
        offset++;
      }
    }
    if (offset + 1 < _bytes.length &&
        _bytes[offset] == 0xFF &&
        _bytes[offset + 1] >= 0xD0 &&
        _bytes[offset + 1] <= 0xD7) {
      offset += 2;
    }
    marker = null;
  }
}

class _Component {
  _Component(this.id, this.h, this.v, this.table);

  final int id;
  final int h;
  final int v;
  final int table;
  int dcTable = 0;
  int acTable = 0;
  int predictor = 0;
}

const _zigzag = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, //
  12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
];

class _JpegLumaDecoder {
  _JpegLumaDecoder(this._bytes);

  final Uint8List _bytes;
  final _quant = List<List<int>?>.filled(4, null);
  final _dc = List<_Huffman?>.filled(4, null);
  final _ac = List<_Huffman?>.filled(4, null);
  final _components = <_Component>[];
  int _width = 0;
  int _height = 0;
  int _restartInterval = 0;
  late final List<double> _cos = [
    for (var x = 0; x < 8; x++)
      for (var u = 0; u < 8; u++)
        (u == 0 ? math.sqrt1_2 : 1.0) *
            math.cos((2 * x + 1) * u * math.pi / 16),
  ];

  LumaImage decode() {
    var offset = 2;
    LumaImage? image;
    while (offset + 4 <= _bytes.length) {
      if (_bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      final marker = _bytes[offset + 1];
      if (marker == 0xFF) {
        offset++;
        continue;
      }
      if (marker == 0xD9) {
        break;
      }
      final length = (_bytes[offset + 2] << 8) | _bytes[offset + 3];
      final body = offset + 4;
      switch (marker) {
        case 0xDB:
          _readQuant(body, body + length - 2);
        case 0xC4:
          _readHuffman(body, body + length - 2);
        case 0xC0 || 0xC1:
          _readFrame(body);
        case 0xC2 || 0xC3 || 0xC5 || 0xC6 || 0xC7 || 0xC9 || 0xCA || 0xCB:
          throw const FormatException(
            'progressive or lossless JPEG is not read (convert to PNG first)',
          );
        case 0xDD:
          _restartInterval = (_bytes[body] << 8) | _bytes[body + 1];
        case 0xDA:
          final reader = _readScanHeader(body);
          image ??= LumaImage(_width, _height);
          if (_scan.contains(_components.first)) {
            _decodeScan(reader, image);
          } else {
            _skipEntropyData(reader);
          }
          offset = reader.offset;
          continue;
      }
      offset = body + length - 2;
    }
    if (image == null) {
      throw const FormatException('JPEG without image data');
    }
    return image;
  }

  void _readQuant(int start, int end) {
    var i = start;
    while (i < end) {
      final precision = _bytes[i] >> 4;
      final id = _bytes[i] & 3;
      i++;
      final table = List<int>.filled(64, 0);
      for (var k = 0; k < 64; k++) {
        table[_zigzag[k]] = precision == 0
            ? _bytes[i + k]
            : (_bytes[i + 2 * k] << 8) | _bytes[i + 2 * k + 1];
      }
      i += precision == 0 ? 64 : 128;
      _quant[id] = table;
    }
  }

  void _readHuffman(int start, int end) {
    var i = start;
    while (i < end) {
      final kind = _bytes[i] >> 4;
      final id = _bytes[i] & 3;
      final counts = Uint8List.sublistView(_bytes, i + 1, i + 17);
      final total = counts.fold<int>(0, (sum, n) => sum + n);
      final symbols = Uint8List.sublistView(_bytes, i + 17, i + 17 + total);
      final table = _Huffman(counts, symbols);
      if (kind == 0) {
        _dc[id] = table;
      } else {
        _ac[id] = table;
      }
      i += 17 + total;
    }
  }

  void _readFrame(int body) {
    if (_bytes[body] != 8) {
      throw const FormatException('only 8-bit JPEG is read');
    }
    _height = (_bytes[body + 1] << 8) | _bytes[body + 2];
    _width = (_bytes[body + 3] << 8) | _bytes[body + 4];
    final count = _bytes[body + 5];
    _components.clear();
    for (var i = 0; i < count; i++) {
      final at = body + 6 + i * 3;
      _components.add(
        _Component(
          _bytes[at],
          _bytes[at + 1] >> 4,
          _bytes[at + 1] & 15,
          _bytes[at + 2],
        ),
      );
    }
  }

  late List<_Component> _scan;

  _BitReader _readScanHeader(int body) {
    final count = _bytes[body];
    _scan = [];
    for (var i = 0; i < count; i++) {
      final id = _bytes[body + 1 + i * 2];
      final tables = _bytes[body + 2 + i * 2];
      final component = _components.firstWhere(
        (c) => c.id == id,
        orElse: () => throw const FormatException('bad JPEG scan'),
      );
      component
        ..dcTable = tables >> 4
        ..acTable = tables & 15
        ..predictor = 0;
      _scan.add(component);
    }
    final length = (_bytes[body - 2] << 8) | _bytes[body - 1];
    return _BitReader(_bytes, body + length - 2);
  }

  /// Moves [bits] to the marker after a scan's entropy-coded data.
  void _skipEntropyData(_BitReader bits) {
    var offset = bits.offset;
    while (offset + 1 < _bytes.length &&
        !(_bytes[offset] == 0xFF &&
            _bytes[offset + 1] != 0 &&
            (_bytes[offset + 1] < 0xD0 || _bytes[offset + 1] > 0xD7))) {
      offset++;
    }
    bits.offset = offset;
  }

  void _decodeScan(_BitReader bits, LumaImage image) {
    if (_width == 0 || _height == 0) {
      throw const FormatException('JPEG scan before its frame header');
    }
    final luma = _components.first;
    final hMax = _components.map((c) => c.h).reduce(math.max);
    final vMax = _components.map((c) => c.v).reduce(math.max);
    final single = _scan.length == 1;
    final block = List<int>.filled(64, 0);
    final mcuWidth = single ? 8 : 8 * hMax;
    final mcuHeight = single ? 8 : 8 * vMax;
    // A single-component scan of the luma covers its own blocks only.
    final lumaWidth = (_width * luma.h / hMax).ceil();
    final lumaHeight = (_height * luma.v / vMax).ceil();
    final mcusX = single ? (lumaWidth / 8).ceil() : (_width / mcuWidth).ceil();
    final mcusY = single
        ? (lumaHeight / 8).ceil()
        : (_height / mcuHeight).ceil();
    var mcu = 0;
    for (var my = 0; my < mcusY; my++) {
      for (var mx = 0; mx < mcusX; mx++) {
        if (_restartInterval > 0 && mcu > 0 && mcu % _restartInterval == 0) {
          bits.restart();
          for (final component in _scan) {
            component.predictor = 0;
          }
        }
        mcu++;
        for (final component in _scan) {
          final blocksX = single ? 1 : component.h;
          final blocksY = single ? 1 : component.v;
          for (var by = 0; by < blocksY; by++) {
            for (var bx = 0; bx < blocksX; bx++) {
              final keep = identical(component, luma);
              _decodeBlock(bits, component, block, keep);
              if (keep) {
                // Luma pixel scale: the luma may itself be subsampled
                // (rare); its samples then cover more than one pixel.
                final sx = hMax ~/ luma.h;
                final sy = vMax ~/ luma.v;
                final x0 = single ? mx * 8 * sx : (mx * luma.h + bx) * 8 * sx;
                final y0 = single ? my * 8 * sy : (my * luma.v + by) * 8 * sy;
                _put(image, block, component, x0, y0, sx, sy);
              }
            }
          }
        }
      }
    }
    _skipEntropyData(bits);
  }

  void _decodeBlock(
    _BitReader bits,
    _Component component,
    List<int> block,
    bool keep,
  ) {
    final dc = _dc[component.dcTable];
    final ac = _ac[component.acTable];
    if (dc == null || ac == null) {
      throw const FormatException('JPEG Huffman table missing');
    }
    block.fillRange(0, 64, 0);
    final size = dc.decode(bits);
    final diff = size == 0 ? 0 : _BitReader.extend(bits.receive(size), size);
    component.predictor += diff;
    block[0] = component.predictor;
    var k = 1;
    while (k < 64) {
      final symbol = ac.decode(bits);
      final run = symbol >> 4;
      final length = symbol & 15;
      if (length == 0) {
        if (run != 15) {
          break;
        }
        k += 16;
        continue;
      }
      k += run;
      if (k > 63) {
        break;
      }
      final value = _BitReader.extend(bits.receive(length), length);
      if (keep) {
        block[_zigzag[k]] = value;
      }
      k++;
    }
  }

  void _put(
    LumaImage image,
    List<int> block,
    _Component component,
    int x0,
    int y0,
    int sx,
    int sy,
  ) {
    final quant = _quant[component.table];
    if (quant == null) {
      throw const FormatException('JPEG quantisation table missing');
    }
    final coefficients = List<double>.generate(
      64,
      (i) => block[i] * 1.0 * quant[i],
    );
    // Separable inverse DCT: rows, then columns.
    final temp = List<double>.filled(64, 0);
    for (var v = 0; v < 8; v++) {
      for (var x = 0; x < 8; x++) {
        var sum = 0.0;
        for (var u = 0; u < 8; u++) {
          sum += _cos[x * 8 + u] * coefficients[v * 8 + u];
        }
        temp[v * 8 + x] = sum / 2;
      }
    }
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        var sum = 0.0;
        for (var v = 0; v < 8; v++) {
          sum += _cos[y * 8 + v] * temp[v * 8 + x];
        }
        final value = (sum / 2 + 128).round().clamp(0, 255);
        for (var dy = 0; dy < sy; dy++) {
          final py = y0 + y * sy + dy;
          if (py >= image.height) {
            continue;
          }
          for (var dx = 0; dx < sx; dx++) {
            final px = x0 + x * sx + dx;
            if (px < image.width) {
              image.pixels[py * image.width + px] = value;
            }
          }
        }
      }
    }
  }
}
