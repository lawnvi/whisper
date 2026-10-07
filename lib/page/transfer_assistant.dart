import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/theme/app_theme.dart';

const Key transferAssistantSearchFieldKey = ValueKey<String>(
  'transfer-assistant-search',
);

const Key transferAssistantFavoritesFilterKey = ValueKey<String>(
  'transfer-assistant-favorites-filter',
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

class TransferAssistantScreen extends StatefulWidget {
  TransferAssistantScreen({
    super.key,
    required this.peerId,
    required this.peerName,
    LocalDatabase? database,
    Future<void> Function(String)? copyText,
  }) : database = database ?? LocalDatabase(),
       copyText = copyText ?? _copyTextToClipboard;

  final String peerId;
  final String peerName;
  final LocalDatabase database;
  final Future<void> Function(String) copyText;

  @override
  State<TransferAssistantScreen> createState() =>
      _TransferAssistantScreenState();
}

class _TransferAssistantScreenState extends State<TransferAssistantScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
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

  bool get _isSearching => _query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    unawaited(_load(showProgress: false));
  }

  @override
  void dispose() {
    _requestGeneration++;
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
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
        _showSnackBar(
          AppLocalizations.of(context)!.transferAssistantFavoriteFailed,
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
        _showSnackBar(
          AppLocalizations.of(context)!.transferAssistantFavoriteFailed,
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

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    return Scaffold(
      backgroundColor: palette.surfaceCanvas,
      appBar: AppBar(
        backgroundColor: palette.surfaceCanvas,
        leading: MediaQuery.withNoTextScaling(
          child: CupertinoNavigationBarBackButton(
            previousPageTitle: '',
            onPressed: () => Navigator.of(context).maybePop(),
            color: theme.colorScheme.onSurface,
          ),
        ),
        toolbarHeight: math.max(
          kToolbarHeight,
          MediaQuery.textScalerOf(context).scale(20) +
              MediaQuery.textScalerOf(context).scale(14) +
              8,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.transferAssistantTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (widget.peerName.isNotEmpty)
              Text(
                widget.peerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                ),
              ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WhisperUi.settingsMaxWidth,
            ),
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    key: transferAssistantSearchFieldKey,
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: _onSearchChanged,
                    onSubmitted: (_) => _searchFocus.unfocus(),
                    onTapOutside: (_) => _searchFocus.unfocus(),
                    textInputAction: TextInputAction.search,
                    style: theme.textTheme.bodyLarge,
                    decoration: InputDecoration(
                      hintText: l10n.transferAssistantSearchHint,
                      hintStyle: TextStyle(color: palette.textMuted),
                      prefixIcon: Icon(
                        CupertinoIcons.search,
                        size: 20,
                        color: palette.textMuted,
                      ),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: l10n.transferAssistantClearSearch,
                              onPressed: _clearSearch,
                              icon: const Icon(
                                CupertinoIcons.xmark_circle_fill,
                                size: 19,
                              ),
                              color: palette.textMuted,
                            ),
                      filled: true,
                      fillColor: palette.surfaceElevated,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      border: _searchBorder(),
                      enabledBorder: _searchBorder(),
                      focusedBorder: _searchBorder(
                        theme.colorScheme.primary.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _isSearching
                              ? l10n.transferAssistantSearchResults
                              : _favoritesOnly
                              ? l10n.transferAssistantFavorites
                              : l10n.transferAssistantRecent,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: palette.textMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: FilterChip(
                            key: transferAssistantFavoritesFilterKey,
                            label: Text(
                              l10n.transferAssistantFavorites,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            avatar: _AnimatedHistoryIcon(
                              icon: _favoritesOnly
                                  ? Icons.star_rounded
                                  : Icons.star_border_rounded,
                              size: 16,
                              color: _favoritesOnly
                                  ? theme.colorScheme.primary
                                  : palette.textMuted,
                            ),
                            selected: _favoritesOnly,
                            showCheckmark: false,
                            onSelected: _setFavoritesOnly,
                            backgroundColor: palette.surfaceElevated,
                            selectedColor: theme.colorScheme.primary.withValues(
                              alpha: 0.1,
                            ),
                            labelStyle: theme.textTheme.labelLarge?.copyWith(
                              color: _favoritesOnly
                                  ? theme.colorScheme.primary
                                  : palette.textMuted,
                            ),
                            side: BorderSide.none,
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 2,
                  child: _loading
                      ? LinearProgressIndicator(
                          color: theme.colorScheme.primary,
                          backgroundColor: Colors.transparent,
                        )
                      : null,
                ),
                Expanded(
                  child: _HistoryResultsTransition(
                    loading: _loading,
                    child: _buildContent(l10n),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  OutlineInputBorder _searchBorder([Color? color]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(16),
    borderSide: color == null ? BorderSide.none : BorderSide(color: color),
  );

  Widget _buildContent(AppLocalizations l10n) {
    if (_loadError != null) {
      return _EmptyState(
        icon: CupertinoIcons.exclamationmark_circle,
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
    final messages = _messages;
    final isSearching = query.isNotEmpty;
    final favorites = _favorites
        .where(
          (item) => item.content.toLowerCase().contains(query.toLowerCase()),
        )
        .toList(growable: false);
    final count = favoritesOnly ? favorites.length : messages.length;
    if (count == 0) {
      return _EmptyState(
        key: ValueKey<(bool, String)>((favoritesOnly, query)),
        icon: isSearching
            ? CupertinoIcons.search
            : favoritesOnly
            ? Icons.star_border_rounded
            : CupertinoIcons.chat_bubble_text,
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
    return ListView.builder(
      key: ValueKey<(bool, String)>((favoritesOnly, query)),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: count,
      itemBuilder: (context, index) {
        final radius = BorderRadius.vertical(
          top: index == 0 ? const Radius.circular(18) : Radius.zero,
          bottom: index == count - 1 ? const Radius.circular(18) : Radius.zero,
        );
        return Material(
          key: ValueKey<int>(
            favoritesOnly
                ? favorites[index].sourceMessageId
                : messages[index].message.id,
          ),
          color: context.whisperPalette.surfaceElevated,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: <Widget>[
              if (favoritesOnly)
                _buildFavoriteTile(favorites[index], query)
              else
                _buildMessageTile(messages[index], l10n, query),
              if (index < count - 1)
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: context.whisperPalette.borderSubtle.withValues(
                    alpha: 0.6,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessageTile(
    TextMessageSearchResult result,
    AppLocalizations l10n,
    String query,
  ) {
    final message = result.message;
    final direction = message.sender == widget.peerId
        ? l10n.transferAssistantIncoming
        : l10n.transferAssistantOutgoing;
    final metadata = '$direction · ${_formatTimestamp(message.timestamp)}';
    return _HistoryTextTile(
      text: message.content ?? '',
      query: query,
      metadata: metadata,
      isFavorite: result.isFavorite,
      copyKey: transferAssistantMessageCopyKey(message.id),
      onCopy: () => _copy(message.content ?? ''),
      favoriteKey: transferAssistantMessageFavoriteKey(message.id),
      onFavorite: _mutatingFavoriteIds.contains(message.id)
          ? null
          : () => unawaited(_toggleMessageFavorite(result)),
    );
  }

  Widget _buildFavoriteTile(FavoriteTextData favorite, String query) {
    final metadata = _formatTimestamp(favorite.sourceTimestamp);
    return _HistoryTextTile(
      text: favorite.content,
      query: query,
      metadata: metadata,
      isFavorite: true,
      copyKey: transferAssistantFavoriteCopyKey(favorite.sourceMessageId),
      onCopy: () => _copy(favorite.content),
      favoriteKey: transferAssistantFavoriteRemoveKey(favorite.sourceMessageId),
      onFavorite: _mutatingFavoriteIds.contains(favorite.sourceMessageId)
          ? null
          : () => unawaited(_removeFavorite(favorite)),
    );
  }

  String _formatTimestamp(int timestamp) {
    if (timestamp <= 0) {
      return '';
    }
    return DateFormat.yMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).add_Hm().format(DateTime.fromMillisecondsSinceEpoch(timestamp * 1000));
  }
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

class _AnimatedHistoryIcon extends StatelessWidget {
  const _AnimatedHistoryIcon({
    required this.icon,
    required this.color,
    this.size = 20,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox.square(
      dimension: size,
      child: AnimatedSwitcher(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.86, end: 1).animate(animation),
            child: child,
          ),
        ),
        child: Icon(
          icon,
          key: ValueKey<IconData>(icon),
          size: size,
          color: color,
        ),
      ),
    );
  }
}

class _HistoryTextTile extends StatefulWidget {
  const _HistoryTextTile({
    required this.text,
    required this.query,
    required this.metadata,
    required this.isFavorite,
    required this.copyKey,
    required this.favoriteKey,
    required this.onCopy,
    required this.onFavorite,
  });

  final String text;
  final String query;
  final String metadata;
  final bool isFavorite;
  final Key copyKey;
  final Key favoriteKey;
  final Future<bool> Function() onCopy;
  final VoidCallback? onFavorite;

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
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final style = theme.textTheme.bodyLarge!.copyWith(height: 1.4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, constraints) {
              final painter = TextPainter(
                text: TextSpan(text: widget.text, style: style),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
                maxLines: 2,
              )..layout(maxWidth: constraints.maxWidth);
              final canExpand = painter.didExceedMaxLines;
              painter.dispose();
              final showFullText = _expanded || !canExpand;
              final toggleLabel = _expanded
                  ? l10n.transferAssistantCollapseMessage
                  : l10n.transferAssistantExpandMessage;
              final content = showFullText
                  ? SelectableText.rich(
                      _highlightText(
                        widget.text,
                        widget.query,
                        theme.colorScheme,
                      ),
                      style: style,
                    )
                  : Semantics(
                      button: true,
                      hint: toggleLabel,
                      child: InkWell(
                        onTap: _toggleExpanded,
                        child: Text.rich(
                          _highlightedPreview(
                            widget.text,
                            widget.query,
                            theme.colorScheme,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                    );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: MediaQuery.disableAnimationsOf(context)
                        ? content
                        : AnimatedSize(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeInOutCubic,
                            alignment: Alignment.topLeft,
                            child: content,
                          ),
                  ),
                  if (canExpand)
                    IconButton(
                      tooltip: toggleLabel,
                      onPressed: _toggleExpanded,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      iconSize: 18,
                      color: palette.textMuted,
                      icon: AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        curve: Curves.easeInOutCubic,
                        child: const Icon(Icons.expand_more_rounded),
                      ),
                    ),
                ],
              );
            },
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.metadata,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _AnimatedCopyButton(
                buttonKey: widget.copyKey,
                onCopy: widget.onCopy,
              ),
              IconButton(
                key: widget.favoriteKey,
                tooltip: widget.isFavorite
                    ? l10n.transferAssistantUnfavorite
                    : l10n.transferAssistantFavorite,
                onPressed: widget.onFavorite,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                iconSize: 20,
                color: widget.isFavorite
                    ? theme.colorScheme.primary
                    : palette.textMuted,
                icon: _AnimatedHistoryIcon(
                  icon: widget.isFavorite
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  color: widget.isFavorite
                      ? theme.colorScheme.primary
                      : palette.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

TextSpan _highlightedPreview(String text, String query, ColorScheme colors) {
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
  return _highlightText(preview, query, colors);
}

TextSpan _highlightText(String text, String query, ColorScheme colors) {
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
        style: TextStyle(
          color: colors.primary,
          backgroundColor: colors.primary.withValues(alpha: 0.1),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    offset = match.end;
  }
  spans.add(TextSpan(text: text.substring(offset)));
  return TextSpan(children: spans);
}

class _AnimatedCopyButton extends StatefulWidget {
  const _AnimatedCopyButton({required this.buttonKey, required this.onCopy});

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
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final tooltip = _copied
        ? l10n.transferAssistantCopied
        : _copyFailed
        ? l10n.transferAssistantCopyFailed
        : l10n.transferAssistantCopy;
    return Semantics(
      liveRegion: true,
      value: _copied || _copyFailed ? tooltip : null,
      child: SizedBox.square(
        dimension: 48,
        child: IconButton(
          key: widget.buttonKey,
          tooltip: tooltip,
          onPressed: _copying ? null : _handleCopy,
          style: IconButton.styleFrom(foregroundColor: palette.textMuted),
          icon: _AnimatedHistoryIcon(
            icon: _copied
                ? Icons.check_rounded
                : _copyFailed
                ? Icons.error_outline_rounded
                : Icons.content_copy_rounded,
            color: _copied
                ? palette.trusted
                : _copyFailed
                ? colorScheme.error
                : palette.textMuted,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: 36, color: palette.textMuted),
                const SizedBox(height: 16),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: palette.textMuted),
                ),
                if (actionLabel != null) ...<Widget>[
                  const SizedBox(height: 8),
                  TextButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
