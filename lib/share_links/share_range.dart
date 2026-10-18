/// What a `Range` request header asks of a file of a known size.
sealed class ShareRange {
  const ShareRange();
}

/// The whole file (no header, an empty file, a unit other than bytes, or
/// several ranges, which this server answers with the whole file).
class ShareRangeWhole extends ShareRange {
  const ShareRangeWhole();
}

/// Bytes [start] to [end], both inclusive.
class ShareRangePart extends ShareRange {
  const ShareRangePart(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;

  @override
  bool operator ==(Object other) =>
      other is ShareRangePart && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ShareRangePart($start-$end)';
}

/// Answered with 416 and `Content-Range: bytes */size`.
class ShareRangeUnsatisfiable extends ShareRange {
  const ShareRangeUnsatisfiable();
}

final _single = RegExp(r'^\s*(\d*)\s*-\s*(\d*)\s*$');

/// Reads a `Range` header (RFC 9110 §14) for a file of [size] bytes.
ShareRange parseShareRange(String? header, int size) {
  if (header == null || header.trim().isEmpty || size <= 0) {
    return const ShareRangeWhole();
  }
  final eq = header.indexOf('=');
  if (eq < 0) {
    return const ShareRangeUnsatisfiable();
  }
  if (header.substring(0, eq).trim().toLowerCase() != 'bytes') {
    return const ShareRangeWhole();
  }
  final spec = header.substring(eq + 1);
  if (spec.contains(',')) {
    return const ShareRangeWhole();
  }
  final match = _single.firstMatch(spec);
  if (match == null) {
    return const ShareRangeUnsatisfiable();
  }
  final first = match.group(1)!;
  final last = match.group(2)!;
  if (first.isEmpty && last.isEmpty) {
    return const ShareRangeUnsatisfiable();
  }
  // Numbers too long to parse are past the end of any file.
  const tooLong = 18;
  if (first.length > tooLong) {
    return const ShareRangeUnsatisfiable();
  }
  if (first.isEmpty) {
    if (last.length > tooLong) {
      return ShareRangePart(0, size - 1);
    }
    final suffix = int.parse(last);
    if (suffix == 0) {
      return const ShareRangeUnsatisfiable();
    }
    final start = suffix >= size ? 0 : size - suffix;
    return ShareRangePart(start, size - 1);
  }
  final start = int.parse(first);
  if (start >= size) {
    return const ShareRangeUnsatisfiable();
  }
  if (last.isEmpty || last.length > tooLong) {
    return ShareRangePart(start, size - 1);
  }
  final end = int.parse(last);
  if (end < start) {
    return const ShareRangeUnsatisfiable();
  }
  return ShareRangePart(start, end >= size ? size - 1 : end);
}
