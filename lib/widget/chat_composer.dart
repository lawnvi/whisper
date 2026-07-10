import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';

class ChatComposer extends StatelessWidget {
  static const desktopContainerKey =
      ValueKey('chat-composer-desktop-container');
  static const attachmentButtonKey = ValueKey('chat-composer-attachment');
  static const clipboardButtonKey = ValueKey('chat-composer-clipboard');
  static const sendButtonKey = ValueKey('chat-composer-send');
  static const clipboardImagePreviewKey =
      ValueKey('chat-composer-clipboard-image-preview');
  static const clipboardImageRemoveButtonKey =
      ValueKey('chat-composer-clipboard-image-remove');
  static const clipboardFilesPreviewKey =
      ValueKey('chat-composer-clipboard-files-preview');
  static const clipboardFilesRemoveButtonKey =
      ValueKey('chat-composer-clipboard-files-remove');

  final bool clipboardEnabled;
  final bool canSend;
  final bool isInputEmpty;
  final bool isLoading;
  final bool isLocalhost;
  final bool isDesktopStyle;
  final Map<String, bool> keyPressedMap;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ClipboardImageDraft? pendingClipboardImage;
  final List<ClipboardFileDraft> pendingClipboardFiles;
  final Future<void> Function() onPickFiles;
  final Future<void> Function() onSendClipboard;
  final Future<bool> Function(String text) onSendText;
  final Future<String?> Function()? onPasteClipboard;
  final Future<void> Function()? onSendClipboardFiles;
  final VoidCallback? onClearClipboardFiles;
  final Future<void> Function()? onSendClipboardImage;
  final VoidCallback? onClearClipboardImage;

  const ChatComposer({
    super.key,
    required this.clipboardEnabled,
    required this.canSend,
    required this.isInputEmpty,
    required this.isLoading,
    required this.isLocalhost,
    required this.isDesktopStyle,
    required this.keyPressedMap,
    required this.controller,
    required this.focusNode,
    this.pendingClipboardImage,
    this.pendingClipboardFiles = const <ClipboardFileDraft>[],
    required this.onPickFiles,
    required this.onSendClipboard,
    required this.onSendText,
    this.onPasteClipboard,
    this.onSendClipboardFiles,
    this.onClearClipboardFiles,
    this.onSendClipboardImage,
    this.onClearClipboardImage,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (isDesktopStyle) {
      return _buildDesktopComposer(context, colorScheme);
    }

    return _buildMobileComposer(context, colorScheme);
  }

  Widget _buildDesktopComposer(
    BuildContext context,
    ColorScheme colorScheme,
  ) {
    final palette = context.whisperPalette;
    final accentColor = colorScheme.primary;
    final containerColor = palette.surfaceElevated;
    final borderColor = palette.borderSubtle;
    return Container(
      key: desktopContainerKey,
      margin: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      padding: const EdgeInsets.fromLTRB(20, 14, 18, 14),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: colorScheme.brightness == Brightness.dark ? 0.18 : 0.05,
            ),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_showsClipboardFilesPreview) ...[
            _buildClipboardFilesPreview(context),
            const SizedBox(height: 10),
          ],
          if (_showsClipboardImagePreview) ...[
            _buildClipboardImagePreview(context),
            const SizedBox(height: 10),
          ],
          Focus(
            onKeyEvent: (_, event) => _handleKeyEvent(event),
            child: TextField(
              key: const ValueKey('chat-composer-textfield'),
              controller: controller,
              focusNode: focusNode,
              enabled: canSend,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: 1,
              maxLines: 5,
              autofocus: isDesktop(),
              autocorrect: true,
              cursorColor: accentColor,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 16,
                height: 1.45,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                isDense: true,
                filled: false,
                fillColor: Colors.transparent,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: canSend
                    ? (AppLocalizations.of(context)?.sendTips ?? '发点什么...')
                    : (AppLocalizations.of(context)?.connectToSend ??
                        '连接后即可发送消息'),
                hintStyle: TextStyle(
                  color: palette.textMuted,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (clipboardEnabled)
                _buildUtilityActionButton(
                  context,
                  key: clipboardButtonKey,
                  icon: Icons.content_copy_rounded,
                  enabled: canSend && !isLoading,
                  onPressed: onSendClipboard,
                  buttonSize: 26,
                  iconSize: 15,
                  outlined: false,
                ),
              const Spacer(),
              _buildPrimaryActionButton(
                context,
                colorScheme: colorScheme,
                buttonSize: 48,
                iconSize: 20,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMobileComposer(
    BuildContext context,
    ColorScheme colorScheme,
  ) {
    final palette = context.whisperPalette;
    final accentColor = colorScheme.primary;
    final outerContainerColor = colorScheme.surface;
    final containerColor = palette.surfaceElevated;
    final borderColor = palette.borderSubtle;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      decoration: BoxDecoration(
        color: outerContainerColor,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 14, 16, 12),
        decoration: BoxDecoration(
          color: containerColor,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: colorScheme.brightness == Brightness.dark ? 0.12 : 0.05,
              ),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Focus(
              onKeyEvent: (_, event) => _handleKeyEvent(event),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                enabled: canSend,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                cursorColor: accentColor,
                autofocus: isDesktop(),
                autocorrect: true,
                minLines: 1,
                maxLines: 6,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 16,
                  height: 1.42,
                ),
                decoration: InputDecoration(
                  isCollapsed: true,
                  isDense: true,
                  filled: false,
                  fillColor: Colors.transparent,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: canSend
                      ? (AppLocalizations.of(context)?.sendTips ?? '发点什么...')
                      : (AppLocalizations.of(context)?.connectToSend ??
                          '连接后即可发送消息'),
                  hintStyle: TextStyle(
                    color: palette.textMuted,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (clipboardEnabled)
                  _buildUtilityActionButton(
                    context,
                    key: clipboardButtonKey,
                    icon: Icons.content_copy_rounded,
                    enabled: canSend && !isLoading,
                    onPressed: onSendClipboard,
                    buttonSize: 28,
                    iconSize: 18,
                    outlined: false,
                  ),
                const Spacer(),
                _buildPrimaryActionButton(
                  context,
                  colorScheme: colorScheme,
                  buttonSize: 42,
                  iconSize: 20,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUtilityActionButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required bool enabled,
    required Future<void> Function() onPressed,
    required double buttonSize,
    required double iconSize,
    required bool outlined,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final outlinedBorderColor = palette.borderSubtle;
    final disabledFillColor = palette.surfaceMuted;
    return IconButton(
      key: key,
      onPressed: enabled ? () => onPressed() : null,
      style: IconButton.styleFrom(
        minimumSize: Size(buttonSize, buttonSize),
        maximumSize: Size(buttonSize, buttonSize),
        backgroundColor: outlined
            ? (enabled
                ? palette.surfaceElevated
                : disabledFillColor.withValues(alpha: 0.65))
            : Colors.transparent,
        foregroundColor:
            enabled ? colorScheme.onSurfaceVariant : colorScheme.outline,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(outlined ? 16 : buttonSize / 2),
          side: outlined
              ? BorderSide(color: outlinedBorderColor)
              : BorderSide.none,
        ),
        padding: EdgeInsets.zero,
        elevation: 0,
        splashFactory: NoSplash.splashFactory,
        overlayColor: Colors.transparent,
      ),
      icon: Icon(icon, size: iconSize),
    );
  }

  Widget _buildClipboardImagePreview(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final draft = pendingClipboardImage!;
    return Container(
      key: clipboardImagePreviewKey,
      padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              draft.bytes,
              width: 44,
              height: 44,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                width: 44,
                height: 44,
                color: colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: Icon(
                  Icons.image_outlined,
                  color: colorScheme.onSurfaceVariant,
                  size: 20,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  draft.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _formatBytes(draft.size),
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: clipboardImageRemoveButtonKey,
            tooltip: AppLocalizations.of(context)?.delete ?? 'Delete',
            onPressed: onClearClipboardImage,
            style: IconButton.styleFrom(
              minimumSize: const Size(32, 32),
              maximumSize: const Size(32, 32),
              foregroundColor: colorScheme.onSurfaceVariant,
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              splashFactory: NoSplash.splashFactory,
              overlayColor: Colors.transparent,
            ),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildClipboardFilesPreview(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final files = pendingClipboardFiles;
    final first = files.first;
    final totalSize =
        files.fold<int>(0, (previous, draft) => previous + draft.size);
    final l10n = AppLocalizations.of(context);
    final countLabel = l10n?.clipboardFilesCount(files.length) ??
        (files.length == 1 ? '1 file' : '${files.length} files');
    return Container(
      key: clipboardFilesPreviewKey,
      padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.insert_drive_file_outlined,
              color: colorScheme.primary,
              size: 22,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  first.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$countLabel · ${_formatBytes(totalSize)}',
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: clipboardFilesRemoveButtonKey,
            tooltip: AppLocalizations.of(context)?.delete ?? 'Delete',
            onPressed: onClearClipboardFiles,
            style: IconButton.styleFrom(
              minimumSize: const Size(32, 32),
              maximumSize: const Size(32, 32),
              foregroundColor: colorScheme.onSurfaceVariant,
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              splashFactory: NoSplash.splashFactory,
              overlayColor: Colors.transparent,
            ),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryActionButton(
    BuildContext context, {
    required ColorScheme colorScheme,
    required double buttonSize,
    required double iconSize,
  }) {
    final palette = context.whisperPalette;
    final accentColor = colorScheme.primary;
    final disabledBorderColor = palette.borderSubtle;
    final showsAttachmentAction = _showsAttachmentAction;
    final enabled = canSend &&
        !isLoading &&
        (showsAttachmentAction ||
            _hasDraftText ||
            _canSendPendingClipboardFiles ||
            _canSendPendingClipboardImage);
    final backgroundColor = showsAttachmentAction
        ? Colors.transparent
        : (enabled ? accentColor : palette.surfaceMuted);
    final foregroundColor = showsAttachmentAction
        ? (enabled ? colorScheme.onSurfaceVariant : colorScheme.outline)
        : (enabled ? Colors.white : colorScheme.outline);
    return IconButton(
      key: showsAttachmentAction ? attachmentButtonKey : sendButtonKey,
      onPressed: enabled ? _handlePrimaryAction : null,
      style: IconButton.styleFrom(
        minimumSize: Size(buttonSize, buttonSize),
        maximumSize: Size(buttonSize, buttonSize),
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        shape: const CircleBorder(),
        padding: EdgeInsets.zero,
        elevation: 0,
        side: showsAttachmentAction
            ? BorderSide.none
            : BorderSide(
                color: enabled ? accentColor : disabledBorderColor,
              ),
        splashFactory: NoSplash.splashFactory,
        overlayColor: Colors.transparent,
      ),
      icon: isLoading
          ? SizedBox(
              width: iconSize,
              height: iconSize,
              child: CupertinoActivityIndicator(
                color: showsAttachmentAction ? accentColor : Colors.white,
              ),
            )
          : Icon(
              showsAttachmentAction
                  ? Icons.add_rounded
                  : Icons.arrow_upward_rounded,
              size: iconSize,
            ),
    );
  }

  bool get _hasDraftText => !isInputEmpty && controller.text.trim().isNotEmpty;

  bool get _showsClipboardFilesPreview =>
      isDesktopStyle && pendingClipboardFiles.isNotEmpty;

  bool get _showsClipboardImagePreview =>
      isDesktopStyle &&
      pendingClipboardImage != null &&
      !_showsClipboardFilesPreview;

  bool get _canSendPendingClipboardFiles =>
      _showsClipboardFilesPreview && onSendClipboardFiles != null;

  bool get _canSendPendingClipboardImage =>
      _showsClipboardImagePreview && onSendClipboardImage != null;

  bool get _showsAttachmentAction =>
      !isLocalhost &&
      !_hasDraftText &&
      !_showsClipboardFilesPreview &&
      !_showsClipboardImagePreview;

  Future<void> _handlePrimaryAction() async {
    if (_canSendPendingClipboardFiles) {
      await onSendClipboardFiles!();
      return;
    }
    if (_canSendPendingClipboardImage) {
      await onSendClipboardImage!();
      return;
    }
    if (_showsAttachmentAction) {
      await onPickFiles();
      return;
    }

    final snapshot = controller.value;
    final nextText = snapshot.text.trimRight();
    if (nextText.trim().isEmpty) {
      return;
    }
    await _sendTextSnapshot(snapshot, nextText);
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (!canSend) {
      return KeyEventResult.ignored;
    }
    if (_isPasteShortcut(event)) {
      unawaited(_handlePasteShortcut());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
        event.logicalKey == LogicalKeyboardKey.shiftRight) {
      keyPressedMap[LogicalKeyboardKey.shift.keyLabel] = event is KeyDownEvent;
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      keyPressedMap[LogicalKeyboardKey.enter.keyLabel] = event is KeyDownEvent;
      if (event is KeyDownEvent &&
          (keyPressedMap[LogicalKeyboardKey.shift.keyLabel] != true ||
              isMobile())) {
        if (_canSendPendingClipboardFiles) {
          unawaited(onSendClipboardFiles!());
          return KeyEventResult.handled;
        }
        if (_canSendPendingClipboardImage) {
          unawaited(onSendClipboardImage!());
          return KeyEventResult.handled;
        }
        if (isLoading) {
          return KeyEventResult.handled;
        }
        final snapshot = controller.value;
        final nextText = snapshot.text.trimRight();
        if (nextText.trim().isNotEmpty) {
          unawaited(_sendTextSnapshot(snapshot, nextText));
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  bool _isPasteShortcut(KeyEvent event) {
    if (!isDesktopStyle ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyV) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isControlPressed || keyboard.isMetaPressed;
  }

  Future<void> _handlePasteShortcut() async {
    final text = await onPasteClipboard?.call();
    if (text == null || text.isEmpty) {
      return;
    }
    _insertTextAtSelection(text);
  }

  Future<void> _sendTextSnapshot(
    TextEditingValue snapshot,
    String text,
  ) async {
    try {
      final sent = await onSendText(text);
      if (sent && controller.text == snapshot.text) {
        controller.clear();
      }
    } catch (_) {
      // The owner reports the failure; leaving the snapshot enables retry.
    }
  }

  void _insertTextAtSelection(String text) {
    final selection = controller.selection;
    final originalText = controller.text;
    final start = selection.isValid
        ? math.min(selection.start, selection.end)
        : originalText.length;
    final end = selection.isValid
        ? math.max(selection.start, selection.end)
        : originalText.length;
    final nextText = originalText.replaceRange(start, end, text);
    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(kb >= 10 ? 0 : 1)} KB';
    }
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
  }
}
