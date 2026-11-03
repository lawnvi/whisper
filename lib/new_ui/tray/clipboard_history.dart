/// One thing that was on the clipboard.
class ClipEntry {
  const ClipEntry({
    required this.text,
    required this.from,
    required this.at,
    this.image = false,
  });

  /// What it says, or the name of an image.
  final String text;

  /// The device it came from; empty when copied on this one.
  final String from;
  final DateTime at;
  final bool image;
}

/// surfaces.md「最近的剪贴板」: in memory only, five at most, gone on exit. Local
/// storage is not encrypted and a password must not reach the disk, so what the
/// system marks as sensitive is not even kept here.
class ClipboardHistory {
  ClipboardHistory({this.limit = 5});

  final int limit;
  final List<ClipEntry> _entries = [];

  String? _current;

  /// Newest first. Copying from this list does not reorder it.
  List<ClipEntry> get entries => List.unmodifiable(_entries);

  /// What is on the clipboard now.
  String get current =>
      _current ?? (_entries.isEmpty ? '' : _entries.first.text);

  /// Records what was just copied. Copying something already listed moves it to
  /// the top instead of listing it twice. What the list itself just put on the
  /// clipboard comes back here too, and is not a new copy.
  void add(ClipEntry entry, {bool sensitive = false}) {
    if (sensitive || entry.text.trim().isEmpty) return;
    if (entry.text == _current &&
        _entries.any((e) => e.text == entry.text && e.image == entry.image)) {
      return;
    }
    _current = null;
    _entries.removeWhere((e) => e.text == entry.text && e.image == entry.image);
    _entries.insert(0, entry);
    if (_entries.length > limit) _entries.removeRange(limit, _entries.length);
  }

  /// [text] went back on the clipboard from the list: it is the current one, and
  /// stays where it is. Rows that move when pressed cannot be read or pressed.
  void markCurrent(String text) {
    if (_entries.any((e) => e.text == text)) _current = text;
  }

  void clear() {
    _entries.clear();
    _current = null;
  }
}
