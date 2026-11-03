import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/state/message_deletion.dart';
import 'package:whisper/widget/message_deletion_dialog.dart';
import 'package:whisper/widget/context_menu_region.dart';
import 'package:whisper/widget/subtle_motion.dart';

/// Room under the newest message: at least the usual, more when the composer is
/// taller than one line or sits above a phone's gesture bar.
double chatListBottomInset({
  required double? composerHeight,
  required bool touch,
}) {
  final usual = touch ? 92.0 : 84.0;
  if (composerHeight == null) return usual;
  final floatsAt = touch ? 24.0 : 16.0;
  return math.max(usual, composerHeight + floatsAt + 12);
}

class ChatMessageList extends StatefulWidget {
  final Widget Function(MessageData message, bool isOpponent) buildFileMessage;
  final Widget Function(
    MessageData message,
    bool isOpponent,
    Widget? trailingAction,
  )
  buildTextMessage;
  final ScrollController controller;
  final GlobalKey<AnimatedListState> listKey;
  final List<MessageData> messages;
  final void Function(String path) onOpenContainingFolder;
  final void Function(MessageData message) onOpenFile;
  final void Function(String content) onCopyText;
  final Future<void> Function(MessageData message)? onCopyFile;
  final Future<void> Function(MessageData message, {bool deleteFile})
  onDeleteMessage;
  final Future<void> Function(List<MessageData> messages, {bool deleteFiles})
  onDeleteMessages;
  final ValueChanged<bool>? onSelectionModeChanged;
  final String? selfUid;

  /// How tall the floating composer is now, with what is under it: a long draft
  /// must not cover the newest messages. Null until it has been measured.
  final double? composerHeight;

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
    this.onCopyFile,
    required this.onDeleteMessage,
    required this.onDeleteMessages,
    this.onSelectionModeChanged,
    required this.selfUid,
    this.composerHeight,
  });

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  final Set<int> _selectedMessageIds = <int>{};
  Timer? _copyResetTimer;
  int? _copiedMessageId;
  bool _selectionMode = false;
  bool _deleting = false;
  bool _confirmingDeletion = false;
  final FocusNode _selectionFocus = FocusNode(debugLabel: 'message selection');

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    FocusManager.instance.removeEarlyKeyEventHandler(_handleSelectionKey);
    _selectionFocus.dispose();
    super.dispose();
  }

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
    if (isDesktop()) {
      if (active) {
        FocusManager.instance.addEarlyKeyEventHandler(_handleSelectionKey);
      } else {
        FocusManager.instance.removeEarlyKeyEventHandler(_handleSelectionKey);
      }
    }
    widget.onSelectionModeChanged?.call(active);
  }

  KeyEventResult _handleSelectionKey(KeyEvent event) {
    // Multi-select is a workspace mode even when search or message text has focus.
    // Overlaid menus/dialogs and other pages retain their own Escape behavior.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _selectionMode &&
        !_deleting &&
        !_confirmingDeletion &&
        TickerMode.of(context) &&
        ModalRoute.of(context)?.isCurrent != false) {
      _setSelectionMode(false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _startSelection(MessageData message) {
    setState(() {
      _selectedMessageIds.add(message.id);
    });
    _setSelectionMode(true);
    _selectionFocus.requestFocus();
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

    await _confirmDeletion(selectedMessages, selection: true);
  }

  Future<void> _confirmDeletion(
    List<MessageData> messages, {
    bool selection = false,
  }) async {
    if (_deleting || _confirmingDeletion) return;
    _confirmingDeletion = true;
    try {
      final hasReceivedFiles = messages.any(
        (message) => canDeleteReceivedMessageFile(message, widget.selfUid),
      );
      final deleteFiles = await showMessageDeletionDialog(
        context,
        count: messages.length,
        hasReceivedFiles: hasReceivedFiles,
      );
      if (deleteFiles == null || !mounted) return;
      setState(() => _deleting = true);
      if (selection) {
        await widget.onDeleteMessages(messages, deleteFiles: deleteFiles);
      } else {
        await widget.onDeleteMessage(messages.single, deleteFile: deleteFiles);
      }
      if (mounted && selection) _setSelectionMode(false);
    } on Object {
      if (mounted) {
        showAppToast(
          AppLocalizations.of(context)?.messageDeleteFailed ?? '删除未完成，请重试。',
          tone: AppToastTone.error,
        );
      }
    } finally {
      _confirmingDeletion = false;
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final touch = !isDesktop();
    Widget messageList = AnimatedList(
      key: widget.listKey,
      controller: widget.controller,
      initialItemCount: widget.messages.length,
      // Under the floating composer, which the last message must clear.
      padding: whisperNewUi
          ? EdgeInsets.fromLTRB(
              touch ? 12 : 16,
              8,
              touch ? 12 : 16,
              chatListBottomInset(
                composerHeight: widget.composerHeight,
                touch: touch,
              ),
            )
          : const EdgeInsets.only(bottom: 12),
      reverse: true,
      shrinkWrap: true,
      itemBuilder: _buildMessage,
    );
    if (isDesktop()) {
      messageList = ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: messageList,
      );
    }

    if (whisperNewUi) {
      return Focus(
        focusNode: _selectionFocus,
        onKeyEvent: (_, event) => _handleSelectionKey(event),
        child: Stack(
          children: [
            Positioned.fill(
              child: Align(alignment: Alignment.topCenter, child: messageList),
            ),
            if (_selectionMode)
              Positioned(
                left: 0,
                right: 0,
                bottom:
                    (touch ? 24 : 16) + MediaQuery.paddingOf(context).bottom,
                child: Center(child: _buildSelectionCapsule(context)),
              ),
          ],
        ),
      );
    }
    return Focus(
      focusNode: _selectionFocus,
      onKeyEvent: (_, event) => _handleSelectionKey(event),
      child: Column(
        children: [
          Expanded(
            child: Align(alignment: Alignment.topCenter, child: messageList),
          ),
          WhisperAnimatedReveal(
            visible: _selectionMode,
            child: _selectionMode ? _buildSelectionToolbar(context) : null,
          ),
        ],
      ),
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
    final showTimestamp = shouldShowChatTimestamp(widget.messages, index);

    final older = index + 1 < widget.messages.length
        ? widget.messages[index + 1]
        : null;
    final sameSender = older != null && older.sender == message.sender;
    Widget rise(Widget child) => whisperNewUi && !animation.isCompleted
        ? _RiseFromComposer(child: child)
        : FadeTransition(opacity: animation, child: child);
    return rise(
      Padding(
        padding: whisperNewUi
            ? EdgeInsets.only(top: sameSender ? 6 : 12)
            : const EdgeInsets.fromLTRB(14, 5, 14, 5),
        child: Column(
          children: [
            if (showTimestamp)
              Padding(
                padding: whisperNewUi
                    ? const EdgeInsets.only(top: 14, bottom: 8)
                    : const EdgeInsets.only(top: 5, bottom: 10),
                child: Text(
                  formatChatTimestamp(context, message.timestamp),
                  key: ValueKey<String>('message-time-${message.id}'),
                  style: whisperNewUi
                      ? TextStyle(
                          color: context.wc.ink2,
                          fontSize: WhisperType(touch: !isDesktop()).tiny,
                        )
                      : TextStyle(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.72,
                          ),
                          fontSize: 12,
                        ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WhisperAnimatedReveal(
                  axis: Axis.horizontal,
                  visible: _selectionMode,
                  child: _selectionMode
                      ? SizedBox(
                          width: 42,
                          height: 42,
                          child: Center(
                            child: Checkbox(
                              key: ValueKey('message-selection-${message.id}'),
                              value: isSelected,
                              shape: const CircleBorder(),
                              side: BorderSide(color: colorScheme.outline),
                              onChanged: _deleting
                                  ? null
                                  : (_) => _toggleSelection(message),
                            ),
                          ),
                        )
                      : null,
                ),
                Expanded(
                  child: Container(
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
                      child: LayoutBuilder(
                        builder: (context, constraints) => ConstrainedBox(
                          key: ValueKey('message-bubble-${message.id}'),
                          constraints: BoxConstraints(
                            maxWidth: whisperNewUi
                                ? newBubbleMaxWidth(
                                    available: constraints.maxWidth,
                                    isFile: isFile,
                                    compact:
                                        !isDesktop() &&
                                        WhisperLayout.of(context).compact,
                                    body: WhisperType(touch: !isDesktop()).body,
                                  )
                                : isFile
                                ? math.min(
                                    isDesktop() ? 300.0 : 360.0,
                                    constraints.maxWidth *
                                        (isDesktop() ? 0.6 : 0.618),
                                  )
                                : constraints.maxWidth *
                                      (isDesktop() ? 0.6 : 0.78),
                          ),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (_deleting) return;
                              if (_selectionMode) {
                                _toggleSelection(message);
                              } else if (isFile) {
                                widget.onOpenFile(message);
                              }
                            },
                            child: isFile
                                ? widget.buildFileMessage(message, isOpponent)
                                : widget.buildTextMessage(
                                    message,
                                    isOpponent,
                                    // Copying is in the message's menu.
                                    whisperNewUi ||
                                            _selectionMode ||
                                            message.type != MessageEnum.Text
                                        ? null
                                        : _buildCopyButton(context, message),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
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
              _copyMessage(message);
            }
          },
        ),
      if (isFile && isDesktop() && widget.onCopyFile != null)
        ContextMenuActionItem(
          label: localizations?.copyFile ?? '复制文件',
          icon: Icons.file_copy_outlined,
          onSelected: () => unawaited(widget.onCopyFile!(message)),
        ),
      ContextMenuActionItem(
        label: localizations?.selectMessages ?? '多选',
        icon: Icons.checklist_rounded,
        onSelected: () => _startSelection(message),
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
      ContextMenuActionItem(
        label: localizations?.delete ?? '删除',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        onSelected: () => unawaited(_confirmDeletion([message])),
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

  /// Where the composer was, in the same glass: what to do with the selection.
  Widget _buildSelectionCapsule(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    final type = WhisperType(touch: !isDesktop());
    final allSelected = _selectedMessageIds.length == widget.messages.length;
    Widget action(
      String label,
      VoidCallback? onTap, {
      Color? color,
      Key? key,
    }) => Pressable(
      key: key,
      onTap: onTap,
      radius: WhisperRadius.capsule,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: isDesktop() ? 28 : 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: type.body,
                color: onTap == null ? c.ink3 : (color ?? c.ink),
              ),
            ),
          ),
        ),
      ),
    );
    return DecoratedBox(
      key: const ValueKey('message-selection-toolbar'),
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        shadows: WhisperShadow.e2(Theme.of(context).brightness),
      ),
      child: WhisperGlass(
        kind: GlassKind.control,
        shape: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  l10n.selectedMessageCount(_selectedMessageIds.length),
                  style: TextStyle(
                    fontSize: type.body,
                    fontWeight: FontWeight.w500,
                    color: c.ink,
                  ),
                ),
              ),
              action(
                l10n.selectAll,
                _deleting || allSelected ? null : _selectAll,
              ),
              action(
                l10n.delete,
                _deleting ? null : _deleteSelectedMessages,
                color: c.bad,
                key: const ValueKey('delete-selected-messages'),
              ),
              action(
                l10n.cancel,
                _deleting ? null : () => _setSelectionMode(false),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCopyButton(BuildContext context, MessageData message) {
    final colorScheme = Theme.of(context).colorScheme;
    final copied = _copiedMessageId == message.id;
    return Padding(
      padding: EdgeInsets.only(bottom: isMobile() ? 1 : 2),
      child: IconButton(
        key: ValueKey<String>('message-copy-${message.id}'),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          fixedSize: Size.square(isMobile() ? 20 : 18),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        constraints: BoxConstraints(
          minWidth: isMobile() ? 20 : 18,
          minHeight: isMobile() ? 20 : 18,
        ),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          reverseDuration: const Duration(milliseconds: 140),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: animation, child: child),
          ),
          child: Icon(
            copied ? Icons.check_rounded : Icons.content_copy_rounded,
            key: ValueKey<bool>(copied),
            size: isMobile() ? 13 : 14,
            color: copied
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
          ),
        ),
        onPressed: () {
          if (message.content?.isNotEmpty == true) {
            _copyMessage(message);
          }
        },
      ),
    );
  }

  void _copyMessage(MessageData message) {
    final content = message.content;
    if (content == null || content.isEmpty) {
      return;
    }
    widget.onCopyText(content);
    HapticFeedback.selectionClick();
    _copyResetTimer?.cancel();
    setState(() => _copiedMessageId = message.id);
    _copyResetTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted && _copiedMessageId == message.id) {
        setState(() => _copiedMessageId = null);
      }
    });
  }
}

/// DESIGN: a pointer's bubble goes up to 72% and 30 characters, a phone's to
/// 80%; a file card up to 276 and 82%.
double newBubbleMaxWidth({
  required double available,
  required bool isFile,
  required bool compact,
  required double body,
}) {
  if (isFile) return math.min(276, available * .82);
  return math.min(available * (compact ? .8 : .72), body * 30);
}

/// `.in`: a new message comes up from where the composer is, from 26 below and
/// a little smaller, growing out of the bottom right.
class _RiseFromComposer extends StatelessWidget {
  const _RiseFromComposer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SpringBuilder(
    from: 0,
    value: 1,
    spring: WhisperSprings.smooth,
    child: child,
    builder: (context, t, child) => Opacity(
      opacity: t.clamp(0, 1),
      child: Transform.translate(
        offset: Offset(0, 26 * (1 - t)),
        child: Transform.scale(
          scale: .9 + .1 * t,
          alignment: Alignment.bottomRight,
          child: child,
        ),
      ),
    ),
  );
}

const Duration chatTimestampClusterGap = Duration(minutes: 5);

bool shouldShowChatTimestamp(List<MessageData> messages, int index) {
  if (index < 0 || index >= messages.length) {
    return false;
  }
  if (messages.length == 1 || index == messages.length - 1) {
    return true;
  }
  final timestamp = messages[index].timestamp;
  final olderTimestamp = messages[index + 1].timestamp;
  return timestamp - olderTimestamp >= chatTimestampClusterGap.inSeconds;
}

String formatChatTimestamp(
  BuildContext context,
  int timestamp, {
  DateTime? now,
}) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  final value = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  final current = now ?? DateTime.now();
  final valueDay = DateTime(value.year, value.month, value.day);
  final currentDay = DateTime(current.year, current.month, current.day);
  final dayDifference = currentDay.difference(valueDay).inDays;
  final time = DateFormat.Hm(locale).format(value);
  if (dayDifference == 0) {
    return time;
  }
  if (dayDifference == 1) {
    return AppLocalizations.of(context)!.chatTimestampYesterday(time);
  }
  if (dayDifference > 1 && dayDifference < 7) {
    return '${DateFormat.E(locale).format(value)} $time';
  }
  final date = value.year == current.year
      ? DateFormat.Md(locale).format(value)
      : DateFormat.yMd(locale).format(value);
  return '$date $time';
}
