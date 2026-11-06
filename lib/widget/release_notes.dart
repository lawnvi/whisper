import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/message_link_text.dart';

/// A release's notes drawn the way GitHub shows them. The release script writes
/// headings, lists and a link; a body edited on GitHub may use the rest of the
/// common Markdown. What isn't understood stays as text.
class ReleaseNotes extends StatefulWidget {
  const ReleaseNotes({super.key, required this.markdown, required this.onOpen});

  final String markdown;

  /// Only http and https links are offered.
  final void Function(Uri uri) onOpen;

  @override
  State<ReleaseNotes> createState() => _ReleaseNotesState();
}

class _ReleaseNotesState extends State<ReleaseNotes> {
  /// GitHub allows far more than a dialog should hold.
  static const _limit = 8000;

  final _recognizers = <TapGestureRecognizer>[];

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final c = context.wc;
    final type = WhisperType(touch: !isDesktop());
    var text = widget.markdown;
    if (text.length > _limit) {
      final cut = text.lastIndexOf('\n', _limit);
      text = '${text.substring(0, cut > 0 ? cut : _limit)}\n\n…';
    }
    final inline = _Inline(
      colors: c,
      recognizers: _recognizers,
      onOpen: widget.onOpen,
    );
    final blocks = _parse(text);
    final children = <Widget>[];
    _Block? previous;
    for (final block in blocks) {
      if (previous != null) {
        children.add(SizedBox(height: _gap(previous, block)));
      }
      children.add(_build(block, inline, c, type));
      previous = block;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  static double _gap(_Block above, _Block below) {
    if (below.kind == _Kind.heading) return 14;
    if (above.kind == _Kind.heading) return 6;
    if (above.kind == _Kind.item && below.kind == _Kind.item) return 3;
    return 8;
  }

  Widget _build(_Block block, _Inline inline, WhisperColors c, WhisperType t) {
    switch (block.kind) {
      case _Kind.heading:
        return Text.rich(
          TextSpan(children: inline.spans(block.text)),
          style: TextStyle(
            fontSize: block.level <= 3 ? t.body : t.note,
            height: 1.4,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        );
      case _Kind.paragraph:
        return Text.rich(TextSpan(children: inline.spans(block.text)));
      case _Kind.item:
        return Padding(
          padding: EdgeInsetsDirectional.only(start: block.level * 16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 12),
                child: Text(block.marker, style: TextStyle(color: c.ink3)),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text.rich(TextSpan(children: inline.spans(block.text))),
              ),
            ],
          ),
        );
      case _Kind.quote:
        return DecoratedBox(
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(color: c.border, width: 3),
            ),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 10),
            child: Text.rich(
              TextSpan(children: inline.spans(block.text)),
              style: TextStyle(color: c.ink3),
            ),
          ),
        );
      case _Kind.code:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(WhisperRadius.xs),
          ),
          child: Text(
            block.text,
            style: TextStyle(
              fontFamily: WhisperMono.family,
              fontFamilyFallback: WhisperMono.fallback,
              fontSize: WhisperSizes.code,
            ),
          ),
        );
      case _Kind.rule:
        return SizedBox(
          height: 1,
          width: double.infinity,
          child: ColoredBox(color: c.sep),
        );
    }
  }
}

enum _Kind { heading, paragraph, item, quote, code, rule }

class _Block {
  _Block(this.kind, this.text, {this.level = 0, this.marker = ''});

  final _Kind kind;
  String text;

  /// A heading's level, or how deep a list item sits.
  final int level;

  /// A list item's bullet or number.
  final String marker;
}

final _heading = RegExp(r'^ {0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$');
final _rule = RegExp(r'^ {0,3}([-*_])(?:\s*\1){2,}\s*$');
final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d{1,9})[.)]\s+(.*)$');
final _quote = RegExp(r'^ {0,3}>\s?(.*)$');
final _fence = RegExp(r'^ {0,3}(```|~~~)');

/// Lines into blocks. A line break inside a paragraph stays a line break, as
/// GitHub shows it in a release.
List<_Block> _parse(String markdown) {
  final blocks = <_Block>[];
  _Block? open;
  String? fence;
  final code = <String>[];
  for (final line in markdown.replaceAll('\r\n', '\n').split('\n')) {
    if (fence != null) {
      if (line.trimLeft().startsWith(fence)) {
        blocks.add(_Block(_Kind.code, code.join('\n')));
        code.clear();
        fence = null;
      } else {
        code.add(line);
      }
      continue;
    }
    final fenceStart = _fence.firstMatch(line);
    if (fenceStart != null) {
      fence = fenceStart.group(1);
      open = null;
      continue;
    }
    if (line.trim().isEmpty) {
      open = null;
      continue;
    }
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      blocks.add(
        _Block(
          _Kind.heading,
          heading.group(2)!,
          level: heading.group(1)!.length,
        ),
      );
      open = null;
      continue;
    }
    if (_rule.hasMatch(line)) {
      blocks.add(_Block(_Kind.rule, ''));
      open = null;
      continue;
    }
    final bullet = _bullet.firstMatch(line);
    final numbered = bullet == null ? _numbered.firstMatch(line) : null;
    if (bullet != null || numbered != null) {
      final indent = (bullet ?? numbered)!.group(1)!.replaceAll('\t', '    ');
      blocks.add(
        open = _Block(
          _Kind.item,
          bullet != null ? bullet.group(2)! : numbered!.group(3)!,
          level: (indent.length ~/ 2).clamp(0, 3),
          marker: bullet != null ? '•' : '${numbered!.group(2)}.',
        ),
      );
      continue;
    }
    final quote = _quote.firstMatch(line);
    if (quote != null) {
      if (open?.kind == _Kind.quote) {
        open!.text += '\n${quote.group(1)}';
      } else {
        blocks.add(open = _Block(_Kind.quote, quote.group(1)!));
      }
      continue;
    }
    switch (open?.kind) {
      case _Kind.paragraph:
        open!.text += '\n${line.trim()}';
      case _Kind.item when line.startsWith(RegExp(r'\s')):
        open!.text += ' ${line.trim()}';
      default:
        blocks.add(open = _Block(_Kind.paragraph, line.trim()));
    }
  }
  if (fence != null && code.isNotEmpty) {
    blocks.add(_Block(_Kind.code, code.join('\n')));
  }
  return blocks;
}

final _inline = RegExp(
  r'\\([\\`*_{}\[\]()#+\-.!>~|])' // 1: an escaped character
  r'|`([^`]+)`' // 2: code
  r'|!?\[([^\]]+)\]\(<?([^)\s>]+)>?(?:\s+"[^"]*")?\)' // 3, 4: a link or image
  r'|<(https?://[^>\s]+)>' // 5: an autolink
  r'|\*\*(.+?)\*\*|__(.+?)__' // 6, 7: bold
  r'|\*(?!\s)(.+?)(?<!\s)\*' // 8: italic
  r'|~~(.+?)~~', // 9: struck through
);

class _Inline {
  _Inline({
    required this.colors,
    required this.recognizers,
    required this.onOpen,
  });

  final WhisperColors colors;
  final List<TapGestureRecognizer> recognizers;
  final void Function(Uri uri) onOpen;

  /// [link] goes on every piece: a tap only reaches the innermost span.
  List<InlineSpan> spans(
    String text, [
    TextStyle style = const TextStyle(),
    TapGestureRecognizer? link,
  ]) {
    final out = <InlineSpan>[];
    var cursor = 0;
    for (final match in _inline.allMatches(text)) {
      if (match.start > cursor) {
        out.addAll(_plain(text.substring(cursor, match.start), style, link));
      }
      cursor = match.end;
      final escaped = match.group(1);
      final code = match.group(2);
      final label = match.group(3);
      final auto = match.group(5);
      final bold = match.group(6) ?? match.group(7);
      final italic = match.group(8);
      final struck = match.group(9);
      if (escaped != null) {
        out.add(_leaf(escaped, style, link));
      } else if (code != null) {
        final mono = style.copyWith(
          fontFamily: WhisperMono.family,
          fontFamilyFallback: WhisperMono.fallback,
          backgroundColor: colors.fill,
        );
        out.add(_leaf(code, mono, link));
      } else if (label != null) {
        final uri = link == null ? _web(match.group(4)!) : null;
        out.addAll(
          uri == null ? spans(label, style, link) : _link(label, uri, style),
        );
      } else if (auto != null) {
        final uri = link == null ? _web(auto) : null;
        out.addAll(
          uri == null ? [_leaf(auto, style, link)] : _link(auto, uri, style),
        );
      } else if (bold != null) {
        out.addAll(
          spans(bold, style.copyWith(fontWeight: FontWeight.w600), link),
        );
      } else if (italic != null) {
        out.addAll(
          spans(italic, style.copyWith(fontStyle: FontStyle.italic), link),
        );
      } else if (struck != null) {
        final through = style.copyWith(decoration: TextDecoration.lineThrough);
        out.addAll(spans(struck, through, link));
      }
    }
    if (cursor < text.length) {
      out.addAll(_plain(text.substring(cursor), style, link));
    }
    return out;
  }

  /// Bare addresses are links on GitHub too.
  List<InlineSpan> _plain(
    String text,
    TextStyle style,
    TapGestureRecognizer? link,
  ) {
    if (link != null) return [_leaf(text, style, link)];
    return [
      for (final segment in parseMessageLinks(text))
        if (segment.uri case final uri?)
          ..._link(segment.text, uri, style)
        else
          _leaf(segment.text, style, null),
    ];
  }

  List<InlineSpan> _link(String label, Uri uri, TextStyle style) {
    final recognizer = TapGestureRecognizer()..onTap = () => onOpen(uri);
    recognizers.add(recognizer);
    return spans(label, style.copyWith(color: colors.accentText), recognizer);
  }

  static TextSpan _leaf(
    String text,
    TextStyle style,
    TapGestureRecognizer? link,
  ) => TextSpan(
    text: text,
    style: style,
    recognizer: link,
    mouseCursor: link == null ? MouseCursor.defer : SystemMouseCursors.click,
  );

  static Uri? _web(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    return uri;
  }
}
