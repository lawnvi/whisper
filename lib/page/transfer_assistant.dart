import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/theme/app_theme.dart';

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
  final Set<int> _mutatingFavoriteIds = <int>{};

  Timer? _searchDebounce;
  String _query = '';
  List<TextMessageSearchResult> _messages = <TextMessageSearchResult>[];
  List<FavoriteTextData> _favorites = <FavoriteTextData>[];
  bool _loading = true;
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
    if (showProgress && mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final messageFuture = widget.database.searchTextMessagesForPeer(
        widget.peerId,
        query: _query,
        limit: _isSearching ? 500 : 50,
      );
      final favoriteFuture = _isSearching
          ? Future<List<FavoriteTextData>>.value(const <FavoriteTextData>[])
          : widget.database.fetchFavoriteTextsForPeer(
              widget.peerId,
              limit: 500,
            );
      final messages = await messageFuture;
      final favorites = await favoriteFuture;
      if (!mounted || generation != _requestGeneration) {
        return;
      }
      setState(() {
        _messages = messages;
        _favorites = favorites;
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
    final l10n = AppLocalizations.of(context)!;
    try {
      await widget.copyText(text);
      if (mounted) {
        _showSnackBar(l10n.transferAssistantCopied);
      }
      return true;
    } catch (_) {
      if (mounted) {
        _showSnackBar(l10n.transferAssistantCopyFailed);
      }
      return false;
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    return Scaffold(
      backgroundColor: palette.surfaceCanvas,
      appBar: AppBar(
        backgroundColor: palette.surfaceCanvas,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.transferAssistantTitle),
            if (widget.peerName.isNotEmpty)
              Text(
                widget.peerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: context.whisperPalette.textMuted,
                ),
              ),
          ],
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WhisperUi.settingsMaxWidth,
            ),
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: SizedBox(
                    height: 48,
                    child: TextField(
                      key: transferAssistantSearchFieldKey,
                      controller: _searchController,
                      onChanged: _onSearchChanged,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: l10n.transferAssistantSearchHint,
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          color: palette.textMuted,
                        ),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: l10n.transferAssistantClearSearch,
                                onPressed: () {
                                  _searchController.clear();
                                  _onSearchChanged('');
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                        filled: true,
                        fillColor: palette.surfaceElevated,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                        border: _searchBorder(palette.borderSubtle),
                        enabledBorder: _searchBorder(palette.borderSubtle),
                        focusedBorder: _searchBorder(colorScheme.primary),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 2,
                  child: _loading
                      ? LinearProgressIndicator(
                          color: colorScheme.primary,
                          backgroundColor: Colors.transparent,
                        )
                      : null,
                ),
                Expanded(child: _buildContent(l10n)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  OutlineInputBorder _searchBorder(Color color) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: color),
    );
  }

  Widget _buildSectionSurface(List<Widget> tiles) {
    final palette = context.whisperPalette;
    final children = <Widget>[];
    for (var index = 0; index < tiles.length; index++) {
      if (index > 0) {
        children.add(
          Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: palette.borderSubtle,
          ),
        );
      }
      children.add(tiles[index]);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(children: children),
      ),
    );
  }

  Widget _buildContent(AppLocalizations l10n) {
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.search_off,
                size: 40,
                color: context.whisperPalette.textMuted,
              ),
              const SizedBox(height: 12),
              Text(l10n.transferAssistantLoadFailed),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => unawaited(_load()),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading && _messages.isEmpty && _favorites.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return _isSearching ? _buildSearchResults(l10n) : _buildOverview(l10n);
  }

  Widget _buildSearchResults(AppLocalizations l10n) {
    if (_messages.isEmpty) {
      return _EmptyState(
        icon: Icons.manage_search,
        message: l10n.transferAssistantNoResults,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
      children: <Widget>[
        _SectionHeader(l10n.transferAssistantSearchResults),
        _buildSectionSurface(
          _messages
              .map((result) => _buildMessageTile(result, l10n))
              .toList(growable: false),
        ),
      ],
    );
  }

  Widget _buildOverview(AppLocalizations l10n) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
      children: <Widget>[
        _SectionHeader(l10n.transferAssistantFavorites),
        _buildSectionSurface(
          _favorites.isEmpty
              ? <Widget>[_SectionEmpty(l10n.transferAssistantNoFavorites)]
              : _favorites
                    .map((favorite) => _buildFavoriteTile(favorite, l10n))
                    .toList(growable: false),
        ),
        const SizedBox(height: 6),
        _SectionHeader(l10n.transferAssistantRecent),
        _buildSectionSurface(
          _messages.isEmpty
              ? <Widget>[_SectionEmpty(l10n.transferAssistantNoRecent)]
              : _messages
                    .map((result) => _buildMessageTile(result, l10n))
                    .toList(growable: false),
        ),
      ],
    );
  }

  Widget _buildMessageTile(
    TextMessageSearchResult result,
    AppLocalizations l10n,
  ) {
    final message = result.message;
    final isIncoming = message.sender == widget.peerId;
    final isMutating = _mutatingFavoriteIds.contains(message.id);
    return _AssistantTextTile(
      title: message.content ?? '',
      metadata: <Widget>[
        Icon(
          isIncoming ? Icons.south_west_rounded : Icons.north_east_rounded,
          size: 14,
        ),
        Text(
          isIncoming
              ? l10n.transferAssistantIncoming
              : l10n.transferAssistantOutgoing,
        ),
        Text(_formatTimestamp(message.timestamp)),
      ],
      actions: <Widget>[
        _AnimatedCopyButton(
          buttonKey: transferAssistantMessageCopyKey(message.id),
          tooltip: l10n.transferAssistantCopy,
          onCopy: () => _copy(message.content ?? ''),
        ),
        IconButton(
          key: transferAssistantMessageFavoriteKey(message.id),
          tooltip: result.isFavorite
              ? l10n.transferAssistantUnfavorite
              : l10n.transferAssistantFavorite,
          onPressed: isMutating
              ? null
              : () => unawaited(_toggleMessageFavorite(result)),
          icon: Icon(
            result.isFavorite ? Icons.star : Icons.star_border,
            color: result.isFavorite
                ? Theme.of(context).colorScheme.tertiary
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildFavoriteTile(FavoriteTextData favorite, AppLocalizations l10n) {
    final isMutating = _mutatingFavoriteIds.contains(favorite.sourceMessageId);
    return _AssistantTextTile(
      title: favorite.content,
      metadata: <Widget>[Text(_formatTimestamp(favorite.sourceTimestamp))],
      actions: <Widget>[
        _AnimatedCopyButton(
          buttonKey: transferAssistantFavoriteCopyKey(favorite.sourceMessageId),
          tooltip: l10n.transferAssistantCopy,
          onCopy: () => _copy(favorite.content),
        ),
        IconButton(
          key: transferAssistantFavoriteRemoveKey(favorite.sourceMessageId),
          tooltip: l10n.transferAssistantUnfavorite,
          onPressed: isMutating
              ? null
              : () => unawaited(_removeFavorite(favorite)),
          icon: Icon(Icons.star, color: Theme.of(context).colorScheme.tertiary),
        ),
      ],
    );
  }

  String _formatTimestamp(int timestamp) {
    if (timestamp <= 0) {
      return '';
    }
    final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return DateFormat.yMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).add_Hm().format(dateTime);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: context.whisperPalette.textMuted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _AssistantTextTile extends StatelessWidget {
  const _AssistantTextTile({
    required this.title,
    required this.metadata,
    required this.actions,
  });

  final String title;
  final List<Widget> metadata;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 7),
                IconTheme(
                  data: IconThemeData(color: palette.textMuted, size: 14),
                  child: DefaultTextStyle.merge(
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: palette.textMuted),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: metadata,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Row(mainAxisSize: MainAxisSize.min, children: actions),
        ],
      ),
    );
  }
}

class _AnimatedCopyButton extends StatefulWidget {
  const _AnimatedCopyButton({
    required this.buttonKey,
    required this.tooltip,
    required this.onCopy,
  });

  final Key buttonKey;
  final String tooltip;
  final Future<bool> Function() onCopy;

  @override
  State<_AnimatedCopyButton> createState() => _AnimatedCopyButtonState();
}

class _AnimatedCopyButtonState extends State<_AnimatedCopyButton> {
  Timer? _resetTimer;
  bool _copying = false;
  bool _copied = false;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleCopy() async {
    if (_copying) {
      return;
    }
    setState(() => _copying = true);
    final copied = await widget.onCopy();
    if (!mounted) {
      return;
    }
    if (!copied) {
      setState(() => _copying = false);
      return;
    }
    HapticFeedback.selectionClick();
    _resetTimer?.cancel();
    setState(() {
      _copying = false;
      _copied = true;
    });
    _resetTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 40,
      child: IconButton(
        key: widget.buttonKey,
        tooltip: widget.tooltip,
        onPressed: _copying ? null : _handleCopy,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          reverseDuration: const Duration(milliseconds: 140),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: animation, child: child),
          ),
          child: Icon(
            _copied ? Icons.check_rounded : Icons.copy_outlined,
            key: ValueKey<bool>(_copied),
            color: _copied ? colorScheme.primary : null,
          ),
        ),
      ),
    );
  }
}

class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: context.whisperPalette.textMuted,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: context.whisperPalette.textMuted),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: context.whisperPalette.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
