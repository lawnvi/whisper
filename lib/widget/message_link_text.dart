import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class MessageLinkSegment {
  const MessageLinkSegment.text(this.text) : uri = null;

  const MessageLinkSegment.link(this.text, this.uri);

  final String text;
  final Uri? uri;

  bool get isLink => uri != null;
}

final RegExp _messageLinkPattern = RegExp(
  r'(?:https?://|www\.)'
  r'[A-Za-z0-9._~:/?#\[\]@!$&()*+,;=%-]+',
  caseSensitive: false,
);
final RegExp _embeddedLinkPrefixPattern = RegExp(r'[A-Za-z0-9_@]');

const Set<String> _trailingLinkPunctuation = <String>{
  '.',
  ',',
  '!',
  '?',
  ';',
  ':',
  '\'',
  '\u2019',
  '\u201d',
};

const Map<String, String> _closingLinkPairs = <String, String>{
  ')': '(',
  ']': '[',
  '}': '{',
};

List<MessageLinkSegment> parseMessageLinks(String text) {
  if (text.isEmpty) {
    return const <MessageLinkSegment>[];
  }
  final segments = <MessageLinkSegment>[];
  var cursor = 0;
  for (final match in _messageLinkPattern.allMatches(text)) {
    if (!_hasLinkBoundary(text, match.start)) {
      continue;
    }
    final matched = match.group(0)!;
    final displayText = _trimLinkSuffix(matched);
    final uri = _messageLinkUri(displayText);
    if (uri == null) {
      continue;
    }
    if (match.start > cursor) {
      segments.add(
        MessageLinkSegment.text(text.substring(cursor, match.start)),
      );
    }
    segments.add(MessageLinkSegment.link(displayText, uri));
    cursor = match.start + displayText.length;
  }
  if (cursor < text.length) {
    segments.add(MessageLinkSegment.text(text.substring(cursor)));
  }
  return segments;
}

bool _hasLinkBoundary(String text, int start) {
  if (start == 0) {
    return true;
  }
  final previous = text.substring(start - 1, start);
  return !_embeddedLinkPrefixPattern.hasMatch(previous);
}

String _trimLinkSuffix(String value) {
  var result = value;
  while (result.isNotEmpty) {
    final trailing = result.substring(result.length - 1);
    if (_trailingLinkPunctuation.contains(trailing)) {
      result = result.substring(0, result.length - 1);
      continue;
    }
    final opening = _closingLinkPairs[trailing];
    if (opening != null &&
        _countCharacter(result, trailing) > _countCharacter(result, opening)) {
      result = result.substring(0, result.length - 1);
      continue;
    }
    break;
  }
  return result;
}

int _countCharacter(String value, String character) {
  return character.allMatches(value).length;
}

Uri? _messageLinkUri(String value) {
  if (value.isEmpty) {
    return null;
  }
  final normalized = value.toLowerCase().startsWith('www.')
      ? 'https://$value'
      : value;
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

class MessageLinkText extends StatefulWidget {
  const MessageLinkText({
    super.key,
    required this.text,
    required this.style,
    required this.linkStyle,
    required this.onOpen,
    this.linksEnabled = true,
    this.textAlign = TextAlign.left,
  });

  final String text;
  final TextStyle style;
  final TextStyle linkStyle;
  final Future<void> Function(Uri uri) onOpen;
  final bool linksEnabled;
  final TextAlign textAlign;

  @override
  State<MessageLinkText> createState() => _MessageLinkTextState();
}

class _MessageLinkTextState extends State<MessageLinkText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

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
    final segments = widget.linksEnabled
        ? parseMessageLinks(widget.text)
        : <MessageLinkSegment>[MessageLinkSegment.text(widget.text)];
    return SelectableText.rich(
      TextSpan(
        style: widget.style,
        children: segments
            .map((segment) {
              final uri = segment.uri;
              if (uri == null) {
                return TextSpan(text: segment.text);
              }
              final recognizer = TapGestureRecognizer()
                ..onTap = () => unawaited(widget.onOpen(uri));
              _recognizers.add(recognizer);
              return TextSpan(
                text: segment.text,
                style: widget.linkStyle,
                recognizer: recognizer,
                mouseCursor: SystemMouseCursors.click,
              );
            })
            .toList(growable: false),
      ),
      textAlign: widget.textAlign,
      contextMenuBuilder: (context, editableTextState) {
        return AdaptiveTextSelectionToolbar(
          anchors: editableTextState.contextMenuAnchors,
          children: const <Widget>[],
        );
      },
    );
  }
}
