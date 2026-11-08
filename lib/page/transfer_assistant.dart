import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show BoxWidthStyle;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

const Key transferAssistantSearchFieldKey = ValueKey<String>(
  'transfer-assistant-search',
);

Key transferAssistantMessageFavoriteKey(int messageId) =>
    ValueKey<String>('transfer-assistant-message-favorite-$messageId');

Key transferAssistantFavoriteRemoveKey(int sourceMessageId) =>
    ValueKey<String>('transfer-assistant-favorite-remove-$sourceMessageId');

Key transferAssistantMessageCopyKey(int messageId) =>
    ValueKey<String>('transfer-assistant-message-copy-$messageId');

Key transferAssistantFavoriteCopyKey(int sourceMessageId) =>
    ValueKey<String>('transfer-assistant-favorite-copy-$sourceMessageId');

Future<void> _copyTextToClipboard(String text) {
  return Clipboard.setData(ClipboardData(text: text));
}

/// Over the window on the desktop, where a page would hide everything else.
Future<void> showChatSearchSheet(
  BuildContext context, {
  required String peerId,
  String query = '',
}) => showShellSheet<void>(
  context,
  width: 520,
  scrolls: false,
  builder: (context) => LayoutBuilder(
    builder: (context, constraints) => SizedBox(
      height: math.min(600, constraints.maxHeight),
      child: TransferAssistantScreen(
        peerId: peerId,
        initialQuery: query,
        inSheet: true,
      ),
    ),
  ),
);

class TransferAssistantScreen extends StatefulWidget {
  TransferAssistantScreen({
    super.key,
    required this.peerId,
    this.initialQuery = '',
    this.inSheet = false,
    LocalDatabase? database,
    Future<void> Function(String)? copyText,
  }) : database = database ?? LocalDatabase(),
       copyText = copyText ?? _copyTextToClipboard;

  final String peerId;

  /// What to search for from the start: a result picked in the palette.
  final String initialQuery;

  /// In [showChatSearchSheet]: pointer sizes, and a title of its own.
  final bool inSheet;
  final LocalDatabase database;
  final Future<void> Function(String) copyText;

  @override
  State<TransferAssistantScreen> createState() =>
      _TransferAssistantScreenState();
}

class _TransferAssistantScreenState extends State<TransferAssistantScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Set<int> _mutatingFavoriteIds = <int>{};

  Timer? _searchDebounce;
  String _query = '';
  String _loadedQuery = '';
  bool _loadedFavoritesOnly = false;
  bool _hasLoaded = false;
  List<TextMessageSearchResult> _messages = <TextMessageSearchResult>[];
  List<FavoriteTextData> _favorites = <FavoriteTextData>[];
  bool _loading = true;
  bool _favoritesOnly = false;
  Object? _loadError;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _searchController.text = widget.initialQuery;
    _query = widget.initialQuery.trim();
    unawaited(_load(showProgress: false));
  }

  @override
  void dispose() {
    _requestGeneration++;
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _requestGeneration++;
    setState(() {
      _query = value.trim();
      _loading = true;
      _loadError = null;
    });
    _searchDebounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_load(showProgress: false)),
    );
  }

  Future<void> _load({bool showProgress = true}) async {
    final generation = ++_requestGeneration;
    final favoritesOnly = _favoritesOnly;
    final query = _query;
    if (showProgress && mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final messages = favoritesOnly
          ? const <TextMessageSearchResult>[]
          : await widget.database.searchTextMessagesForPeer(
              widget.peerId,
              query: query,
              limit: query.isNotEmpty ? 500 : 50,
            );
      final favorites = !favoritesOnly
          ? const <FavoriteTextData>[]
          : await widget.database.fetchFavoriteTextsForPeer(
              widget.peerId,
              limit: 500,
            );
      if (!mounted || generation != _requestGeneration) {
        return;
      }
      setState(() {
        _messages = messages;
        _favorites = favorites;
        _loadedQuery = query;
        _loadedFavoritesOnly = favoritesOnly;
        _hasLoaded = true;
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) {
        return;
      }
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  Future<void> _toggleMessageFavorite(TextMessageSearchResult result) async {
    final messageId = result.message.id;
    if (_mutatingFavoriteIds.contains(messageId)) {
      return;
    }
    setState(() {
      _mutatingFavoriteIds.add(messageId);
      _messages = _messages
          .map(
            (item) => item.message.id == messageId
                ? item.copyWith(isFavorite: !result.isFavorite)
                : item,
          )
          .toList(growable: false);
    });
    try {
      if (result.isFavorite) {
        await widget.database.unfavoriteTextMessage(messageId);
      } else {
        await widget.database.favoriteTextMessage(
          result.message,
          peerUid: widget.peerId,
        );
      }
      await _load(showProgress: false);
    } catch (_) {
      await _load(showProgress: false);
      if (mounted) {
        showAppToast(
          AppLocalizations.of(context)!.transferAssistantFavoriteFailed,
          tone: AppToastTone.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _mutatingFavoriteIds.remove(messageId));
      }
    }
  }

  Future<void> _removeFavorite(FavoriteTextData favorite) async {
    final sourceMessageId = favorite.sourceMessageId;
    if (_mutatingFavoriteIds.contains(sourceMessageId)) {
      return;
    }
    setState(() {
      _mutatingFavoriteIds.add(sourceMessageId);
      _favorites = _favorites
          .where((item) => item.sourceMessageId != sourceMessageId)
          .toList(growable: false);
      _messages = _messages
          .map(
            (item) => item.message.id == sourceMessageId
                ? item.copyWith(isFavorite: false)
                : item,
          )
          .toList(growable: false);
    });
    try {
      await widget.database.unfavoriteTextMessage(sourceMessageId);
      await _load(showProgress: false);
    } catch (_) {
      await _load(showProgress: false);
      if (mounted) {
        showAppToast(
          AppLocalizations.of(context)!.transferAssistantFavoriteFailed,
          tone: AppToastTone.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _mutatingFavoriteIds.remove(sourceMessageId));
      }
    }
  }

  Future<bool> _copy(String text) async {
    try {
      await widget.copyText(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _setFavoritesOnly(bool selected) {
    _searchDebounce?.cancel();
    setState(() => _favoritesOnly = selected);
    unawaited(_load());
  }

  void _clearSearch() {
    _searchController.clear();
    _onSearchChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = context.wc;
    final inSheet = widget.inSheet;
    final type = WhisperType(touch: !inSheet);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (inSheet)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.transferAssistantTitle,
                    style: TextStyle(
                      fontSize: type.head,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                ),
                ShellIconButton(
                  glyph: WhisperGlyph.x,
                  label: l10n.shellDone,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: PhoneSearchField(
            fieldKey: transferAssistantSearchFieldKey,
            controller: _searchController,
            hint: l10n.transferAssistantSearchHint,
            onChanged: _onSearchChanged,
            onClear: _clearSearch,
            clearLabel: l10n.transferAssistantClearSearch,
            touch: !inSheet,
            radius: WhisperRadius.capsule,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: LiquidSegmented<bool>(
            segments: {
              false: l10n.transferAssistantAllMessages,
              true: l10n.transferAssistantFavorites,
            },
            selected: _favoritesOnly,
            onChanged: _setFavoritesOnly,
            expand: true,
            height: inSheet ? 30 : 36,
            fontSize: type.note,
            hitExtend: inSheet ? 0 : 6,
          ),
        ),
        Expanded(
          child: _HistoryResultsTransition(
            loading: _loading,
            child: _buildContent(l10n),
          ),
        ),
      ],
    );
    if (inSheet) {
      return Material(type: MaterialType.transparency, child: body);
    }
    return PhonePage(
      title: l10n.transferAssistantTitle,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: WhisperUi.settingsMaxWidth,
          ),
          child: body,
        ),
      ),
    );
  }

  Widget _buildContent(AppLocalizations l10n) {
    if (_loadError != null) {
      return _EmptyState(
        touch: !widget.inSheet,
        glyph: WhisperGlyph.warn,
        message: l10n.transferAssistantLoadFailed,
        actionLabel: l10n.retry,
        onAction: () => unawaited(_load()),
      );
    }
    if (!_hasLoaded) {
      return const SizedBox.expand();
    }
    // Keep the last result and its highlight while a new query is pending.
    final query = _loadedQuery;
    final favoritesOnly = _loadedFavoritesOnly;
    final isSearching = query.isNotEmpty;
    final rows = favoritesOnly
        ? [
            for (final favorite in _favorites)
              if (favorite.content.toLowerCase().contains(query.toLowerCase()))
                _favoriteRow(favorite, query),
          ]
        : [for (final result in _messages) _messageRow(result, l10n, query)];
    if (rows.isEmpty) {
      return _EmptyState(
        key: ValueKey<(bool, String)>((favoritesOnly, query)),
        touch: !widget.inSheet,
        glyph: isSearching
            ? WhisperGlyph.search
            : favoritesOnly
            ? WhisperGlyph.star
            : WhisperGlyph.chat,
        message: isSearching
            ? l10n.transferAssistantNoResults
            : favoritesOnly
            ? l10n.transferAssistantNoFavorites
            : l10n.transferAssistantNoRecent,
        actionLabel: isSearching
            ? l10n.transferAssistantClearSearch
            : favoritesOnly
            ? l10n.transferAssistantAllMessages
            : null,
        onAction: isSearching
            ? _clearSearch
            : favoritesOnly
            ? () => _setFavoritesOnly(false)
            : null,
      );
    }
    // In the order they came, so a day stays together even if a clock jumped.
    final byDay = <String, List<_HistoryRowData>>{};
    for (final row in rows) {
      (byDay[_dayLabel(row.timestamp, l10n)] ??= []).add(row);
    }
    final days = byDay.entries.toList(growable: false);
    return ListView.builder(
      key: ValueKey<(bool, String)>((favoritesOnly, query)),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: days.length,
      itemBuilder: (context, index) {
        final MapEntry(key: day, value: inDay) = days[index];
        return Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (day.isNotEmpty) ShellGroupLabel(day, touch: !widget.inSheet),
              ShellGroup(
                inset: 14,
                flat: widget.inSheet,
                children: [
                  for (final row in inDay)
                    _HistoryTextTile(
                      key: ValueKey<int>(row.id),
                      data: row,
                      query: query,
                      touch: !widget.inSheet,
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  _HistoryRowData _messageRow(
    TextMessageSearchResult result,
    AppLocalizations l10n,
    String query,
  ) {
    final message = result.message;
    final direction = message.sender == widget.peerId
        ? l10n.transferAssistantIncoming
        : l10n.transferAssistantOutgoing;
    final time = _formatTime(message.timestamp);
    return _HistoryRowData(
      id: message.id,
      text: message.content ?? '',
      metadata: time.isEmpty ? direction : '$direction · $time',
      timestamp: message.timestamp,
      isFavorite: result.isFavorite,
      copyKey: transferAssistantMessageCopyKey(message.id),
      onCopy: () => _copy(message.content ?? ''),
      favoriteKey: transferAssistantMessageFavoriteKey(message.id),
      onFavorite: _mutatingFavoriteIds.contains(message.id)
          ? null
          : () => unawaited(_toggleMessageFavorite(result)),
    );
  }

  _HistoryRowData _favoriteRow(FavoriteTextData favorite, String query) {
    return _HistoryRowData(
      id: favorite.sourceMessageId,
      text: favorite.content,
      metadata: _formatTime(favorite.sourceTimestamp),
      timestamp: favorite.sourceTimestamp,
      isFavorite: true,
      copyKey: transferAssistantFavoriteCopyKey(favorite.sourceMessageId),
      onCopy: () => _copy(favorite.content),
      favoriteKey: transferAssistantFavoriteRemoveKey(favorite.sourceMessageId),
      onFavorite: _mutatingFavoriteIds.contains(favorite.sourceMessageId)
          ? null
          : () => unawaited(_removeFavorite(favorite)),
    );
  }

  String _formatTime(int timestamp) {
    if (timestamp <= 0) return '';
    return DateFormat.Hm(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(DateTime.fromMillisecondsSinceEpoch(timestamp * 1000));
  }

  String _dayLabel(int timestamp, AppLocalizations l10n) {
    if (timestamp <= 0) return '';
    final at = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(at.year, at.month, at.day)).inDays;
    if (days == 0) return l10n.shellToday;
    if (days == 1) return l10n.shellYesterday;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return (at.year == now.year
            ? DateFormat.MMMEd(locale)
            : DateFormat.yMMMEd(locale))
        .format(at);
  }
}

/// One message or saved text, the way a row shows it.
class _HistoryRowData {
  const _HistoryRowData({
    required this.id,
    required this.text,
    required this.metadata,
    required this.timestamp,
    required this.isFavorite,
    required this.copyKey,
    required this.favoriteKey,
    required this.onCopy,
    required this.onFavorite,
  });

  final int id;
  final String text, metadata;
  final int timestamp;
  final bool isFavorite;
  final Key copyKey, favoriteKey;
  final Future<bool> Function() onCopy;
  final VoidCallback? onFavorite;
}

class _HistoryResultsTransition extends StatelessWidget {
  const _HistoryResultsTransition({required this.loading, required this.child});

  final bool loading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      ignoring: loading,
      child: ExcludeFocus(
        excluding: loading,
        child: ExcludeSemantics(
          excluding: loading,
          child: AnimatedOpacity(
            opacity: loading ? 0.6 : 1,
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 120),
            child: AnimatedSwitcher(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  // Fading results are visual only; never activate stale actions.
                  for (final outgoing in previous)
                    IgnorePointer(
                      child: ExcludeFocus(
                        child: ExcludeSemantics(child: outgoing),
                      ),
                    ),
                  if (current != null) current,
                ],
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A small icon button at the end of a row: wide enough for a thumb, not as tall
/// as a line of its own.
class _RowAction extends StatelessWidget {
  const _RowAction({
    super.key,
    required this.glyph,
    required this.label,
    required this.onTap,
    this.color,
    this.filled = false,
    this.turns = 0,
    this.touch = true,
  });

  final bool touch;
  final WhisperGlyph glyph;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final bool filled;
  final double turns;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Tooltip(
      message: label,
      child: Pressable(
        onTap: onTap,
        radius: WhisperRadius.xs,
        label: label,
        child: SizedBox(
          width: touch ? 44 : 30,
          height: touch ? 40 : 28,
          child: Center(
            child: AnimatedRotation(
              turns: turns,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeInOutCubic,
              child: AnimatedSwitcher(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(
                      begin: 0.86,
                      end: 1,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: WhisperIcon(
                  glyph,
                  key: ValueKey<(WhisperGlyph, bool)>((glyph, filled)),
                  size: touch ? 17 : 15,
                  filled: filled,
                  color: color ?? context.wc.ink2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryTextTile extends StatefulWidget {
  const _HistoryTextTile({
    super.key,
    required this.data,
    required this.query,
    this.touch = true,
  });

  final _HistoryRowData data;
  final String query;
  final bool touch;

  @override
  State<_HistoryTextTile> createState() => _HistoryTextTileState();
}

class _HistoryTextTileState extends State<_HistoryTextTile> {
  bool _expanded = false;

  void _toggleExpanded() {
    FocusScope.of(context).unfocus();
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    final touch = widget.touch;
    final type = WhisperType(touch: touch);
    final data = widget.data;
    final style = TextStyle(fontSize: type.body, height: 1.4, color: c.ink);
    return Padding(
      padding: EdgeInsets.fromLTRB(14, touch ? 11 : 9, 4, touch ? 2 : 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(text: data.text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 2,
          )..layout(maxWidth: constraints.maxWidth - 10);
          final canExpand = painter.didExceedMaxLines;
          painter.dispose();
          final showFullText = _expanded || !canExpand;
          final toggleLabel = _expanded
              ? l10n.transferAssistantCollapseMessage
              : l10n.transferAssistantExpandMessage;
          final content = showFullText
              ? SelectableText.rich(
                  _highlightText(data.text, widget.query, c),
                  style: style,
                  selectionWidthStyle: BoxWidthStyle.tight,
                )
              : Semantics(
                  button: true,
                  hint: toggleLabel,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleExpanded,
                    child: Text.rich(
                      _highlightedPreview(data.text, widget.query, c),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: MediaQuery.disableAnimationsOf(context)
                    ? content
                    : AnimatedSize(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeInOutCubic,
                        alignment: Alignment.topLeft,
                        child: content,
                      ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      data.metadata,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: type.note, color: c.ink2),
                    ),
                  ),
                  if (canExpand)
                    _RowAction(
                      glyph: WhisperGlyph.right,
                      label: toggleLabel,
                      onTap: _toggleExpanded,
                      turns: _expanded ? .75 : .25,
                      touch: touch,
                    ),
                  _AnimatedCopyButton(
                    buttonKey: data.copyKey,
                    onCopy: data.onCopy,
                    touch: touch,
                  ),
                  _RowAction(
                    key: data.favoriteKey,
                    glyph: WhisperGlyph.star,
                    label: data.isFavorite
                        ? l10n.transferAssistantUnfavorite
                        : l10n.transferAssistantFavorite,
                    onTap: data.onFavorite,
                    filled: data.isFavorite,
                    color: data.isFavorite ? c.accent : null,
                    touch: touch,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

TextSpan _highlightedPreview(String text, String query, WhisperColors c) {
  var preview = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final pattern = query.isEmpty
      ? null
      : RegExp(RegExp.escape(query), caseSensitive: false);
  final firstMatch = pattern?.firstMatch(preview);
  // A distant hit should be visible without opening the full message.
  if (firstMatch != null && firstMatch.start > 60) {
    preview = '…${preview.substring(firstMatch.start)}';
  }
  final characters = preview.characters;
  preview = characters.take(220).toString();
  if (characters.length > 220) {
    preview += '…';
  }
  return _highlightText(preview, query, c);
}

TextSpan _highlightText(String text, String query, WhisperColors c) {
  if (query.isEmpty) {
    return TextSpan(text: text);
  }
  final pattern = RegExp(RegExp.escape(query), caseSensitive: false);
  final spans = <InlineSpan>[];
  var offset = 0;
  for (final match in pattern.allMatches(text)) {
    spans.add(TextSpan(text: text.substring(offset, match.start)));
    spans.add(
      TextSpan(
        text: text.substring(match.start, match.end),
        style: TextStyle(color: c.onTint, backgroundColor: c.tintActive),
      ),
    );
    offset = match.end;
  }
  spans.add(TextSpan(text: text.substring(offset)));
  return TextSpan(children: spans);
}

class _AnimatedCopyButton extends StatefulWidget {
  const _AnimatedCopyButton({
    required this.buttonKey,
    required this.onCopy,
    this.touch = true,
  });

  final bool touch;
  final Key buttonKey;
  final Future<bool> Function() onCopy;

  @override
  State<_AnimatedCopyButton> createState() => _AnimatedCopyButtonState();
}

class _AnimatedCopyButtonState extends State<_AnimatedCopyButton> {
  Timer? _resetTimer;
  bool _copying = false;
  bool _copied = false;
  bool _copyFailed = false;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleCopy() async {
    if (_copying) {
      return;
    }
    _resetTimer?.cancel();
    setState(() => _copying = true);
    final copied = await widget.onCopy();
    if (!mounted) {
      return;
    }
    if (copied) {
      unawaited(HapticFeedback.selectionClick());
    }
    setState(() {
      _copying = false;
      _copied = copied;
      _copyFailed = !copied;
    });
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _copied = false;
          _copyFailed = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = context.wc;
    final label = _copied
        ? l10n.transferAssistantCopied
        : _copyFailed
        ? l10n.transferAssistantCopyFailed
        : l10n.transferAssistantCopy;
    return Semantics(
      liveRegion: true,
      value: _copied || _copyFailed ? label : null,
      child: _RowAction(
        key: widget.buttonKey,
        glyph: _copied
            ? WhisperGlyph.check
            : _copyFailed
            ? WhisperGlyph.warn
            : WhisperGlyph.copy,
        label: label,
        onTap: _copying ? null : _handleCopy,
        touch: widget.touch,
        color: _copied
            ? c.accentText
            : _copyFailed
            ? c.bad
            : null,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    super.key,
    required this.glyph,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.touch = true,
  });

  final bool touch;
  final WhisperGlyph glyph;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: touch);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight * .7),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                WhisperIcon(glyph, size: 28, color: c.ink3),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: type.body, color: c.ink2),
                ),
                if (actionLabel != null) ...[
                  const SizedBox(height: 8),
                  touch
                      ? PhoneButton(
                          label: actionLabel!,
                          onTap: onAction,
                          kind: PhoneButtonKind.quiet,
                        )
                      : ShellButton(
                          label: actionLabel!,
                          onTap: onAction,
                          kind: ShellButtonKind.quiet,
                        ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
