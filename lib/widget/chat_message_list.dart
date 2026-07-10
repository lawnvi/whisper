import 'dart:io';

import 'package:flutter/material.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/chat_message_groups.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_empty_state.dart';
import 'package:whisper/widget/context_menu_region.dart';

Widget buildChatTextSelectionToolbar(
  BuildContext context,
  EditableTextState editableTextState, {
  required String copyMessageLabel,
  required String deleteMessageLabel,
  required VoidCallback onCopyMessage,
  required VoidCallback onDeleteMessage,
}) {
  final buttonItems = <ContextMenuButtonItem>[
    ...editableTextState.contextMenuButtonItems,
    ContextMenuButtonItem(
      label: copyMessageLabel,
      onPressed: () {
        editableTextState.hideToolbar();
        onCopyMessage();
      },
    ),
    ContextMenuButtonItem(
      label: deleteMessageLabel,
      onPressed: () {
        editableTextState.hideToolbar();
        onDeleteMessage();
      },
    ),
  ];
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: buttonItems,
  );
}

class ChatMessageList extends StatefulWidget {
  const ChatMessageList({
    super.key,
    required this.buildFileMessage,
    required this.buildTextMessage,
    required this.controller,
    required this.listKey,
    required this.messages,
    required this.onOpenContainingFolder,
    required this.onOpenFile,
    required this.onCopyText,
    required this.onDeleteMessage,
    required this.selfUid,
    required this.isConnected,
    required this.messageText,
    this.isMobileLayout,
  });

  final Widget Function(MessageData message, bool isOpponent) buildFileMessage;
  final Widget Function(MessageData message, bool isOpponent) buildTextMessage;
  final ScrollController controller;
  final GlobalKey<AnimatedListState> listKey;
  final List<MessageData> messages;
  final void Function(String path) onOpenContainingFolder;
  final void Function(String path) onOpenFile;
  final void Function(String content) onCopyText;
  final Future<void> Function(MessageData message, {bool deleteFile})
      onDeleteMessage;
  final String? selfUid;
  final bool isConnected;
  final String Function(MessageData message) messageText;
  final bool? isMobileLayout;

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  static const double _desktopMetadataWidth = 176;

  String? _hoveredMessageId;
  String? _focusedMessageId;

  bool get _isMobileLayout => widget.isMobileLayout ?? isMobile();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (widget.messages.isEmpty) {
      return AppEmptyState(
        icon: Icons.forum_outlined,
        title: l10n.emptyConversationTitle,
        body: widget.isConnected
            ? l10n.emptyConversationConnectedBody
            : l10n.emptyConversationDisconnectedBody,
      );
    }
    final groups = groupChatMessages(widget.messages);

    return Align(
      alignment: Alignment.topCenter,
      child: AnimatedList(
        key: widget.listKey,
        controller: widget.controller,
        initialItemCount: widget.messages.length,
        reverse: true,
        shrinkWrap: true,
        itemBuilder: (context, index, animation) {
          if (index < 0 || index >= widget.messages.length) {
            return const SizedBox.shrink();
          }
          final group = groups.firstWhere(
            (candidate) => candidate.containsIndex(index),
          );
          return _buildAnimatedMessage(
            context,
            message: widget.messages[index],
            index: index,
            group: group,
            animation: animation,
          );
        },
      ),
    );
  }

  Widget _buildAnimatedMessage(
    BuildContext context, {
    required MessageData message,
    required int index,
    required ChatMessageGroup group,
    required Animation<double> animation,
  }) {
    final messageId = _messageId(message, index);
    final isOpponent = message.receiver == widget.selfUid;
    final isFile = message.type == MessageEnum.File;
    final isGroupTail = group.tailIndex == index;
    final isActive =
        _hoveredMessageId == messageId || _focusedMessageId == messageId;
    final sharesOlderBoundary = index < group.endIndex;
    final sharesNewerBoundary = index > group.startIndex;
    final verticalPadding = EdgeInsets.only(
      top: sharesOlderBoundary ? 2 : 6,
      bottom: sharesNewerBoundary ? 2 : 6,
    );

    final messageBody = isFile
        ? ContextMenuRegion(
            items: _fileContextMenuItems(
              context,
              message,
              isOpponent: isOpponent,
            ),
            child: GestureDetector(
              onTap: () => widget.onOpenFile(message.path),
              child: widget.buildFileMessage(message, isOpponent),
            ),
          )
        : widget.buildTextMessage(message, isOpponent);
    final item = _isMobileLayout
        ? _buildMobileMessage(
            context,
            message: message,
            isOpponent: isOpponent,
            showTimestamp: isGroupTail,
            messageBody: messageBody,
          )
        : _buildDesktopMessage(
            context,
            message: message,
            isOpponent: isOpponent,
            isFile: isFile,
            isActive: isActive,
            showTimestamp: isGroupTail || isActive,
            messageBody: messageBody,
          );

    return FadeTransition(
      opacity: animation,
      child: KeyedSubtree(
        key: ValueKey<String>('chat-message-item-$messageId'),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            14,
            verticalPadding.top,
            14,
            verticalPadding.bottom,
          ),
          child: Focus(
            canRequestFocus: !_isMobileLayout,
            onFocusChange: (focused) {
              _updateFocusedMessage(messageId, focused);
            },
            child: Builder(
              builder: (focusContext) => Listener(
                onPointerDown: _isMobileLayout
                    ? null
                    : (_) => Focus.of(focusContext).requestFocus(),
                child: MouseRegion(
                  onEnter: _isMobileLayout
                      ? null
                      : (_) => _updateHoveredMessage(messageId, true),
                  onExit: _isMobileLayout
                      ? null
                      : (_) => _updateHoveredMessage(messageId, false),
                  child: item,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopMessage(
    BuildContext context, {
    required MessageData message,
    required bool isOpponent,
    required bool isFile,
    required bool isActive,
    required bool showTimestamp,
    required Widget messageBody,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final metadataWidth =
            compact ? WhisperUi.minInteractiveSize : _desktopMetadataWidth;
        final metadata = _buildDesktopMetadata(
          context,
          message: message,
          isOpponent: isOpponent,
          showCopy:
              isActive && !isFile && widget.messageText(message).isNotEmpty,
          showTimestamp: !compact && showTimestamp,
          width: metadataWidth,
        );
        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment:
              isOpponent ? MainAxisAlignment.start : MainAxisAlignment.end,
          children: isOpponent
              ? <Widget>[
                  Flexible(fit: FlexFit.loose, child: messageBody),
                  metadata,
                ]
              : <Widget>[
                  metadata,
                  Flexible(fit: FlexFit.loose, child: messageBody),
                ],
        );
        if (!compact || !showTimestamp) {
          return row;
        }
        return Column(
          crossAxisAlignment:
              isOpponent ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          children: <Widget>[
            row,
            const SizedBox(height: 2),
            _buildTimestamp(context, message),
          ],
        );
      },
    );
  }

  Widget _buildDesktopMetadata(
    BuildContext context, {
    required MessageData message,
    required bool isOpponent,
    required bool showCopy,
    required bool showTimestamp,
    required double width,
  }) {
    final copySlot = SizedBox.square(
      dimension: WhisperUi.minInteractiveSize,
      child: showCopy
          ? _buildCopyButton(
              context,
              message,
              widget.messageText(message),
            )
          : null,
    );
    final timestampSlot = width > WhisperUi.minInteractiveSize
        ? SizedBox(
            width: width - WhisperUi.minInteractiveSize,
            child: showTimestamp
                ? _buildTimestamp(
                    context,
                    message,
                    multiline: true,
                  )
                : null,
          )
        : null;
    return SizedBox(
      key: ValueKey<String>(
        'chat-message-metadata-${_messageId(message, 0)}',
      ),
      width: width,
      child: Row(
        mainAxisAlignment:
            isOpponent ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: isOpponent
            ? <Widget>[copySlot, if (timestampSlot != null) timestampSlot]
            : <Widget>[if (timestampSlot != null) timestampSlot, copySlot],
      ),
    );
  }

  Widget _buildMobileMessage(
    BuildContext context, {
    required MessageData message,
    required bool isOpponent,
    required bool showTimestamp,
    required Widget messageBody,
  }) {
    return Column(
      crossAxisAlignment:
          isOpponent ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: <Widget>[
        messageBody,
        if (showTimestamp) ...<Widget>[
          const SizedBox(height: 2),
          _buildTimestamp(context, message),
        ],
      ],
    );
  }

  Widget _buildTimestamp(
    BuildContext context,
    MessageData message, {
    bool multiline = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final timestamp = formatTimestamp(message.timestamp);
    return Text(
      multiline ? timestamp.replaceFirst(' ', '\n') : timestamp,
      key: ValueKey<String>(
        'chat-message-timestamp-${_messageId(message, 0)}',
      ),
      maxLines: multiline ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
        fontSize: 11,
        height: 1.2,
      ),
    );
  }

  Widget _buildCopyButton(
    BuildContext context,
    MessageData message,
    String content,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      key: ValueKey<String>(
        'chat-message-copy-${_messageId(message, 0)}',
      ),
      constraints: const BoxConstraints.tightFor(
        width: WhisperUi.minInteractiveSize,
        height: WhisperUi.minInteractiveSize,
      ),
      padding: EdgeInsets.zero,
      tooltip: l10n.copyMessage,
      icon: Icon(
        Icons.content_copy_rounded,
        size: 18,
        color: colorScheme.onSurfaceVariant,
      ),
      onPressed: () => widget.onCopyText(content),
    );
  }

  List<ContextMenuActionItem> _fileContextMenuItems(
    BuildContext context,
    MessageData message, {
    required bool isOpponent,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return <ContextMenuActionItem>[
      if (isOpponent || isDesktop())
        ContextMenuActionItem(
          label: l10n.open,
          onSelected: () => widget.onOpenFile(message.path),
        ),
      if (isOpponent || isDesktop())
        ContextMenuActionItem(
          label: Platform.isMacOS ? l10n.openInFinder : l10n.openInDir,
          onSelected: () => widget.onOpenContainingFolder(message.path),
        ),
      if (isOpponent)
        ContextMenuActionItem(
          label: '${l10n.delete} (${l10n.keepFile})',
          onSelected: () => widget.onDeleteMessage(message),
        ),
      if (isOpponent)
        ContextMenuActionItem(
          label: '${l10n.delete} (${l10n.deleteFile})',
          onSelected: () => widget.onDeleteMessage(message, deleteFile: true),
        ),
      if (!isOpponent)
        ContextMenuActionItem(
          label: l10n.delete,
          onSelected: () => widget.onDeleteMessage(message),
        ),
    ];
  }

  String _messageId(MessageData message, int fallbackIndex) {
    if (message.uuid.isNotEmpty) {
      return message.uuid;
    }
    if (message.id > 0) {
      return 'id-${message.id}';
    }
    return 'index-$fallbackIndex';
  }

  void _updateHoveredMessage(String messageId, bool hovered) {
    final next = hovered
        ? messageId
        : (_hoveredMessageId == messageId ? null : _hoveredMessageId);
    if (next == _hoveredMessageId || !mounted) {
      return;
    }
    setState(() => _hoveredMessageId = next);
  }

  void _updateFocusedMessage(String messageId, bool focused) {
    final next = focused
        ? messageId
        : (_focusedMessageId == messageId ? null : _focusedMessageId);
    if (next == _focusedMessageId || !mounted) {
      return;
    }
    setState(() => _focusedMessageId = next);
  }
}
