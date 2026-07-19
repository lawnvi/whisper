import 'dart:io';

import 'package:flutter/material.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_dialogs.dart';
import 'package:whisper/widget/context_menu_region.dart';

class ChatMessageList extends StatefulWidget {
  final Widget Function(MessageData message, bool isOpponent) buildFileMessage;
  final Widget Function(MessageData message, bool isOpponent) buildTextMessage;
  final ScrollController controller;
  final GlobalKey<AnimatedListState> listKey;
  final List<MessageData> messages;
  final void Function(String path) onOpenContainingFolder;
  final void Function(MessageData message) onOpenFile;
  final void Function(String content) onCopyText;
  final Future<void> Function(MessageData message, {bool deleteFile})
  onDeleteMessage;
  final Future<void> Function(List<MessageData> messages) onDeleteMessages;
  final ValueChanged<bool>? onSelectionModeChanged;
  final String? selfUid;

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
    required this.onDeleteMessages,
    this.onSelectionModeChanged,
    required this.selfUid,
  });

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  final Set<int> _selectedMessageIds = <int>{};
  bool _selectionMode = false;
  bool _deleting = false;

  void _setSelectionMode(bool active) {
    if (_selectionMode == active) {
      return;
    }
    setState(() {
      _selectionMode = active;
      if (!active) {
        _selectedMessageIds.clear();
      }
    });
    widget.onSelectionModeChanged?.call(active);
  }

  void _startSelection(MessageData message) {
    setState(() {
      _selectionMode = true;
      _selectedMessageIds.add(message.id);
    });
    widget.onSelectionModeChanged?.call(true);
  }

  void _toggleSelection(MessageData message) {
    setState(() {
      if (!_selectedMessageIds.add(message.id)) {
        _selectedMessageIds.remove(message.id);
      }
    });
    if (_selectedMessageIds.isEmpty) {
      _setSelectionMode(false);
    }
  }

  void _selectAll() {
    setState(() {
      _selectedMessageIds.addAll(widget.messages.map((message) => message.id));
    });
  }

  Future<void> _deleteSelectedMessages() async {
    if (_deleting || _selectedMessageIds.isEmpty) {
      return;
    }
    final selectedMessages = widget.messages
        .where((message) => _selectedMessageIds.contains(message.id))
        .toList(growable: false);
    if (selectedMessages.isEmpty) {
      _setSelectionMode(false);
      return;
    }

    final localizations = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title:
          localizations?.deleteSelectedMessagesTitle(selectedMessages.length) ??
          '删除 ${selectedMessages.length} 条消息',
      description:
          localizations?.deleteSelectedMessagesDesc ?? '将删除所选聊天记录，本地文件会保留。',
      confirmButtonText: localizations?.delete ?? '删除',
      cancelButtonText: localizations?.cancel ?? '取消',
      isDestructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }

    setState(() => _deleting = true);
    try {
      await widget.onDeleteMessages(selectedMessages);
      if (mounted) {
        _setSelectionMode(false);
      }
    } finally {
      if (mounted) {
        setState(() => _deleting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: AnimatedList(
              key: widget.listKey,
              controller: widget.controller,
              initialItemCount: widget.messages.length,
              reverse: true,
              shrinkWrap: true,
              itemBuilder: _buildMessage,
            ),
          ),
        ),
        if (_selectionMode) _buildSelectionToolbar(context),
      ],
    );
  }

  Widget _buildMessage(
    BuildContext context,
    int index,
    Animation<double> animation,
  ) {
    final message = widget.messages[index];
    final isOpponent = message.receiver == widget.selfUid;
    final isFile = message.type == MessageEnum.File;
    final isSelected = _selectedMessageIds.contains(message.id);
    final colorScheme = Theme.of(context).colorScheme;

    return FadeTransition(
      opacity: animation,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_selectionMode)
              SizedBox(
                width: 42,
                height: 42,
                child: Center(
                  child: Checkbox(
                    key: ValueKey('message-selection-${message.id}'),
                    value: isSelected,
                    shape: const CircleBorder(),
                    side: BorderSide(color: colorScheme.outline),
                    onChanged: (_) => _toggleSelection(message),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: isOpponent
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.end,
                children: [
                  Container(
                    alignment: isOpponent
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    child: ContextMenuRegion(
                      items: _selectionMode
                          ? const <ContextMenuActionItem>[]
                          : _buildMessageActions(
                              context,
                              message,
                              isOpponent: isOpponent,
                              isFile: isFile,
                            ),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (_selectionMode) {
                            _toggleSelection(message);
                          } else if (isFile) {
                            widget.onOpenFile(message);
                          }
                        },
                        child: isFile
                            ? widget.buildFileMessage(message, isOpponent)
                            : widget.buildTextMessage(message, isOpponent),
                      ),
                    ),
                  ),
                  SizedBox(height: isMobile() ? 1.5 : 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.type == MessageEnum.Text && isOpponent)
                        _buildCopyButton(context, message),
                      if (message.type == MessageEnum.Text && isOpponent)
                        SizedBox(width: isMobile() ? 3 : 5),
                      Text(
                        formatTimestamp(message.timestamp),
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.8,
                          ),
                          fontSize: 12,
                        ),
                      ),
                      if (message.type == MessageEnum.Text && !isOpponent)
                        SizedBox(width: isMobile() ? 3 : 5),
                      if (message.type == MessageEnum.Text && !isOpponent)
                        _buildCopyButton(context, message),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<ContextMenuActionItem> _buildMessageActions(
    BuildContext context,
    MessageData message, {
    required bool isOpponent,
    required bool isFile,
  }) {
    final localizations = AppLocalizations.of(context);
    return [
      if (!isFile)
        ContextMenuActionItem(
          label: localizations?.copyMessage ?? '复制消息',
          icon: Icons.content_copy_rounded,
          onSelected: () {
            if (message.content?.isNotEmpty == true) {
              widget.onCopyText(message.content!);
            }
          },
        ),
      ContextMenuActionItem(
        label: localizations?.selectMessages ?? '多选',
        icon: Icons.checklist_rounded,
        onSelected: () => _startSelection(message),
      ),
      if (!isFile)
        ContextMenuActionItem(
          label: localizations?.delete ?? '删除',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onSelected: () => widget.onDeleteMessage(message),
        ),
      if (isFile && (isOpponent || isDesktop()))
        ContextMenuActionItem(
          label: localizations?.open ?? '打开',
          icon: Icons.open_in_new_rounded,
          onSelected: () => widget.onOpenFile(message),
        ),
      if (isFile && (isOpponent || isDesktop()))
        ContextMenuActionItem(
          label:
              (Platform.isMacOS
                  ? localizations?.openInFinder
                  : localizations?.openInDir) ??
              '所在文件夹',
          icon: Icons.folder_open_rounded,
          onSelected: () => widget.onOpenContainingFolder(message.path),
        ),
      if (isFile && isOpponent)
        ContextMenuActionItem(
          label:
              '${localizations?.delete ?? '删除'} (${localizations?.keepFile ?? '保留文件'})',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onSelected: () => widget.onDeleteMessage(message),
        ),
      if (isFile && isOpponent)
        ContextMenuActionItem(
          label:
              '${localizations?.delete ?? '删除'} (${localizations?.deleteFile ?? '删除文件'})',
          icon: Icons.delete_forever_outlined,
          destructive: true,
          onSelected: () => widget.onDeleteMessage(message, deleteFile: true),
        ),
      if (isFile && !isOpponent)
        ContextMenuActionItem(
          label: localizations?.delete ?? '删除',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onSelected: () => widget.onDeleteMessage(message),
        ),
    ];
  }

  Widget _buildSelectionToolbar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final localizations = AppLocalizations.of(context);
    final allSelected = _selectedMessageIds.length == widget.messages.length;

    return Material(
      key: const ValueKey('message-selection-toolbar'),
      color: palette.surfaceElevated,
      child: SafeArea(
        top: false,
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: palette.borderSubtle)),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: localizations?.cancel ?? '取消',
                onPressed: _deleting ? null : () => _setSelectionMode(false),
                icon: const Icon(Icons.close_rounded),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  localizations?.selectedMessageCount(
                        _selectedMessageIds.length,
                      ) ??
                      '已选 ${_selectedMessageIds.length} 条',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: localizations?.selectAll ?? '全选',
                onPressed: _deleting || allSelected ? null : _selectAll,
                icon: const Icon(Icons.done_all_rounded),
              ),
              IconButton(
                key: const ValueKey('delete-selected-messages'),
                tooltip: localizations?.delete ?? '删除',
                onPressed: _deleting ? null : _deleteSelectedMessages,
                color: palette.danger,
                icon: _deleting
                    ? SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: palette.danger,
                        ),
                      )
                    : const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCopyButton(BuildContext context, MessageData message) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints(
        minWidth: isMobile() ? 18 : 20,
        minHeight: isMobile() ? 18 : 20,
      ),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      icon: Icon(
        Icons.content_copy_rounded,
        size: isMobile() ? 14 : 15,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
      ),
      onPressed: () {
        if (message.content?.isNotEmpty == true) {
          widget.onCopyText(message.content!);
        }
      },
    );
  }
}
