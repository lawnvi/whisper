import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/theme/app_theme.dart';

const Key transferAssistantSearchFieldKey =
    ValueKey<String>('transfer-assistant-search');

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
  })  : database = database ?? LocalDatabase(),
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

  Future<void> _copy(String text) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await widget.copyText(text);
      if (mounted) {
        _showSnackBar(l10n.transferAssistantCopied);
      }
    } catch (_) {
      if (mounted) {
        _showSnackBar(l10n.transferAssistantCopyFailed);
      }
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
    return Scaffold(
      appBar: AppBar(
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
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: TextField(
              key: transferAssistantSearchFieldKey,
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.transferAssistantSearchHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l10n.transferAssistantClearSearch,
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                        icon: const Icon(Icons.clear),
                      ),
              ),
            ),
          ),
          SizedBox(
            height: 2,
            child: _loading ? const LinearProgressIndicator() : null,
          ),
          Expanded(child: _buildContent(l10n)),
        ],
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
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _messages.length + 1,
      separatorBuilder: (context, index) => index == 0
          ? const SizedBox.shrink()
          : const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _SectionHeader(l10n.transferAssistantSearchResults);
        }
        return _buildMessageTile(_messages[index - 1], l10n);
      },
    );
  }

  Widget _buildOverview(AppLocalizations l10n) {
    final children = <Widget>[
      _SectionHeader(l10n.transferAssistantFavorites),
      if (_favorites.isEmpty)
        _SectionEmpty(l10n.transferAssistantNoFavorites)
      else
        for (final favorite in _favorites) ...<Widget>[
          _buildFavoriteTile(favorite, l10n),
          const Divider(height: 1, indent: 16, endIndent: 16),
        ],
      const SizedBox(height: 8),
      _SectionHeader(l10n.transferAssistantRecent),
      if (_messages.isEmpty)
        _SectionEmpty(l10n.transferAssistantNoRecent)
      else
        for (final result in _messages) ...<Widget>[
          _buildMessageTile(result, l10n),
          const Divider(height: 1, indent: 16, endIndent: 16),
        ],
      const SizedBox(height: 24),
    ];
    return ListView(children: children);
  }

  Widget _buildMessageTile(
    TextMessageSearchResult result,
    AppLocalizations l10n,
  ) {
    final message = result.message;
    final isIncoming = message.sender == widget.peerId;
    final isMutating = _mutatingFavoriteIds.contains(message.id);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      title: Text(
        message.content ?? '',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: <Widget>[
            Text(
              isIncoming
                  ? l10n.transferAssistantIncoming
                  : l10n.transferAssistantOutgoing,
            ),
            const SizedBox(width: 12),
            Text(_formatTimestamp(message.timestamp)),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            key: transferAssistantMessageCopyKey(message.id),
            tooltip: l10n.transferAssistantCopy,
            onPressed: () => unawaited(_copy(message.content ?? '')),
            icon: const Icon(Icons.copy_outlined),
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
      ),
    );
  }

  Widget _buildFavoriteTile(
    FavoriteTextData favorite,
    AppLocalizations l10n,
  ) {
    final isMutating = _mutatingFavoriteIds.contains(favorite.sourceMessageId);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      title: Text(
        favorite.content,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(_formatTimestamp(favorite.sourceTimestamp)),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            key: transferAssistantFavoriteCopyKey(favorite.sourceMessageId),
            tooltip: l10n.transferAssistantCopy,
            onPressed: () => unawaited(_copy(favorite.content)),
            icon: const Icon(Icons.copy_outlined),
          ),
          IconButton(
            key: transferAssistantFavoriteRemoveKey(favorite.sourceMessageId),
            tooltip: l10n.transferAssistantUnfavorite,
            onPressed:
                isMutating ? null : () => unawaited(_removeFavorite(favorite)),
            icon: Icon(
              Icons.star,
              color: Theme.of(context).colorScheme.tertiary,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(int timestamp) {
    if (timestamp <= 0) {
      return '';
    }
    final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return DateFormat.yMd(Localizations.localeOf(context).toLanguageTag())
        .add_Hm()
        .format(dateTime);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
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
