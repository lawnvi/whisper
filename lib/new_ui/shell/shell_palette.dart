import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// One result: what it is, what kind of thing it is, what picking it does.
class PaletteItem {
  const PaletteItem({
    required this.glyph,
    required this.name,
    required this.category,
    required this.onRun,
    this.keywords = const [],
  });

  final WhisperGlyph glyph;
  final String name, category;
  final VoidCallback onRun;

  /// Other words it answers to, besides its name.
  final List<String> keywords;
}

/// The best [limit] matches: names that start with the query, then names that
/// contain it, then category and other keywords.
List<PaletteItem> paletteMatches(
  List<PaletteItem> items,
  String query, {
  int limit = 8,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return items.take(limit).toList(growable: false);
  final starts = <PaletteItem>[];
  final contains = <PaletteItem>[];
  final other = <PaletteItem>[];
  for (final item in items) {
    final name = item.name.toLowerCase();
    if (name.startsWith(q)) {
      starts.add(item);
    } else if (name.contains(q)) {
      contains.add(item);
    } else if (item.category.toLowerCase().contains(q) ||
        item.keywords.any((k) => k.toLowerCase().contains(q))) {
      other.add(item);
    }
  }
  return [...starts, ...contains, ...other].take(limit).toList(growable: false);
}

/// docs/design/surfaces.md「全局搜索」.
Future<void> showShellPalette(
  BuildContext context, {
  required List<PaletteItem> items,
  required Future<List<PaletteItem>> Function(String query) searchMessages,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) =>
        ShellPalette(items: items, searchMessages: searchMessages),
  );
}

class ShellPalette extends StatefulWidget {
  const ShellPalette({
    super.key,
    required this.items,
    required this.searchMessages,
  });

  final List<PaletteItem> items;
  final Future<List<PaletteItem>> Function(String query) searchMessages;

  @override
  State<ShellPalette> createState() => _ShellPaletteState();
}

class _ShellPaletteState extends State<ShellPalette> {
  /// A search slower than this shows what is already known, then the rest.
  static const _messagesPatience = Duration(milliseconds: 120);

  final _controller = TextEditingController();
  final _focus = FocusNode();
  int _selected = 0;
  late List<PaletteItem> _results = paletteMatches(widget.items, '');
  int _searchGeneration = 0;
  bool _searching = false;
  Timer? _patience;

  @override
  void dispose() {
    _patience?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _show(List<PaletteItem> results) {
    setState(() {
      _results = results.take(8).toList(growable: false);
      _selected = 0;
    });
  }

  /// What is on screen stays until its replacement is ready: messages come from
  /// the database a moment later, and showing the list without them first would
  /// make it blink, or say there are no results when there are.
  Future<void> _onChanged(String text) async {
    final generation = ++_searchGeneration;
    final query = text.trim();
    final direct = paletteMatches(widget.items, query);
    _patience?.cancel();
    if (query.isEmpty) {
      _searching = false;
      _show(direct);
      return;
    }
    _searching = true;
    _patience = Timer(_messagesPatience, () {
      if (mounted && generation == _searchGeneration) _show(direct);
    });
    var found = const <PaletteItem>[];
    try {
      found = await widget.searchMessages(query);
    } on Object {
      // The rest of the results are still worth showing.
    }
    if (!mounted || generation != _searchGeneration) return;
    _patience?.cancel();
    _searching = false;
    _show([...direct, ...found]);
  }

  void _run(PaletteItem item) {
    Navigator.of(context).pop();
    item.onRun();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final results = _results;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown && results.isNotEmpty) {
      setState(() => _selected = (_selected + 1).clamp(0, results.length - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp && results.isNotEmpty) {
      setState(() => _selected = (_selected - 1).clamp(0, results.length - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter) {
      // Still searching: what is on screen is for the previous text.
      final current = _searching
          ? paletteMatches(widget.items, _controller.text)
          : results;
      if (current.isNotEmpty) {
        _run(current[_searching ? 0 : _selected.clamp(0, current.length - 1)]);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    final results = _results;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(WhisperRadius.l),
    );
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 70, left: 12, right: 12),
        child: SpringBuilder(
          from: .96,
          value: 1,
          spring: WhisperSprings.snappy,
          builder: (context, s, child) =>
              Transform.scale(scale: s, child: child),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: shape,
                shadows: WhisperShadow.e3(Theme.of(context).brightness),
              ),
              child: WhisperGlass(
                kind: GlassKind.panel,
                shape: shape,
                child: Material(
                  type: MaterialType.transparency,
                  child: Focus(
                    onKeyEvent: _onKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 50,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: Center(
                              child: TextField(
                                controller: _controller,
                                focusNode: _focus,
                                autofocus: true,
                                onChanged: _onChanged,
                                cursorColor: c.accent,
                                style: TextStyle(
                                  fontSize: type.title,
                                  color: c.ink,
                                ),
                                decoration: InputDecoration(
                                  isCollapsed: true,
                                  filled: false,
                                  fillColor: Colors.transparent,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  hintText: l10n.shellSearch,
                                  hintStyle: TextStyle(
                                    fontSize: type.title,
                                    color: c.ink3,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                          child: results.isEmpty
                              ? Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Text(
                                    l10n.shellPaletteEmpty,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: type.note,
                                      color: c.ink2Glass,
                                    ),
                                  ),
                                )
                              : Column(
                                  children: [
                                    for (final (i, item) in results.indexed)
                                      _Result(
                                        item: item,
                                        selected: i == _selected,
                                        onHover: () {
                                          if (_selected != i) {
                                            setState(() => _selected = i);
                                          }
                                        },
                                        onTap: () => _run(item),
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.item,
    required this.selected,
    required this.onHover,
    required this.onTap,
  });

  final PaletteItem item;
  final bool selected;
  final VoidCallback onHover, onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    final ink = selected ? c.onAccent : c.ink;
    final second = selected ? c.onAccent : c.ink2Glass;
    return MouseRegion(
      // Only when the pointer moves: results appearing under a pointer that is
      // standing still must not take the selection.
      onHover: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? c.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(WhisperRadius.s),
          ),
          child: Row(
            children: [
              WhisperIcon(item.glyph, size: 15, color: second),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: type.body, color: ink),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                item.category,
                style: TextStyle(fontSize: type.note, color: second),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
