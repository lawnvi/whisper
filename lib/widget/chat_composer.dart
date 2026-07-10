import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';

sealed class PendingClipboardDraft {
  const PendingClipboardDraft();
}

final class PendingClipboardTextDraft extends PendingClipboardDraft {
  const PendingClipboardTextDraft(this.text);

  final String text;
}

final class PendingClipboardImageDraft extends PendingClipboardDraft {
  const PendingClipboardImageDraft(this.image);

  final ClipboardImageDraft image;
}

final class PendingClipboardFilesDraft extends PendingClipboardDraft {
  const PendingClipboardFilesDraft(this.files);

  final List<ClipboardFileDraft> files;
}

final class ClipboardDraftGeneration {
  int _current = 0;

  int start() => ++_current;

  void invalidate() {
    _current++;
  }

  bool isCurrent(int generation) => generation == _current;
}

final class ChatComposerSendGate {
  bool _isInFlight = false;

  bool get isInFlight => _isInFlight;

  Future<bool> run(Future<void> Function() action) async {
    if (_isInFlight) {
      return false;
    }
    _isInFlight = true;
    try {
      await action();
      return true;
    } finally {
      _isInFlight = false;
    }
  }
}

typedef ClipboardFilesReader = Future<List<ClipboardFileDraft>> Function();
typedef ClipboardImageReader = Future<ClipboardImageDraft?> Function();
typedef ClipboardTextReader = Future<String?> Function();

Future<PendingClipboardDraft?> detectPendingClipboardDraft({
  required ClipboardFilesReader readFiles,
  required ClipboardImageReader readImage,
  required ClipboardTextReader readText,
  bool Function()? isCurrent,
  bool trimText = true,
}) async {
  bool stillCurrent() => isCurrent?.call() ?? true;

  if (!stillCurrent()) {
    return null;
  }
  final files = await readFiles();
  if (!stillCurrent()) {
    return null;
  }
  if (files.isNotEmpty) {
    return PendingClipboardFilesDraft(files);
  }

  final image = await readImage();
  if (!stillCurrent()) {
    return null;
  }
  if (image != null) {
    return PendingClipboardImageDraft(image);
  }

  final text = await readText();
  if (!stillCurrent() || text == null || text.trim().isEmpty) {
    return null;
  }
  return PendingClipboardTextDraft(trimText ? text.trimRight() : text);
}

class ChatComposer extends StatelessWidget {
  static const desktopContainerKey =
      ValueKey('chat-composer-desktop-container');
  static const attachmentButtonKey = ValueKey('chat-composer-attachment');
  static const clipboardButtonKey = ValueKey('chat-composer-clipboard');
  static const sendButtonKey = ValueKey('chat-composer-send');
  static const clipboardTextPreviewKey =
      ValueKey('chat-composer-clipboard-text-preview');
  static const clipboardImagePreviewKey =
      ValueKey('chat-composer-clipboard-image-preview');
  static const clipboardFilesPreviewKey =
      ValueKey('chat-composer-clipboard-files-preview');
  static const clipboardRemoveButtonKey =
      ValueKey('chat-composer-clipboard-remove');
  static const clipboardImageRemoveButtonKey = clipboardRemoveButtonKey;
  static const clipboardFilesRemoveButtonKey = clipboardRemoveButtonKey;

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
    required this.onPickFiles,
    required this.onPreviewClipboard,
    required this.onSendClipboardDraft,
    required this.onClearClipboardDraft,
    required this.onSendText,
    required this.onPasteClipboard,
    this.pendingClipboardDraft,
  });

  final bool clipboardEnabled;
  final bool canSend;
  final bool isInputEmpty;
  final bool isLoading;
  final bool isLocalhost;
  final bool isDesktopStyle;
  final Map<String, bool> keyPressedMap;
  final TextEditingController controller;
  final FocusNode focusNode;
  final PendingClipboardDraft? pendingClipboardDraft;
  final Future<void> Function() onPickFiles;
  final Future<void> Function() onPreviewClipboard;
  final Future<void> Function() onSendClipboardDraft;
  final VoidCallback onClearClipboardDraft;
  final Future<void> Function(String text) onSendText;
  final Future<String?> Function() onPasteClipboard;

  @override
  Widget build(BuildContext context) {
    if (isDesktopStyle) {
      return _buildDesktopComposer(context);
    }
    return _buildMobileComposer(context);
  }

  Widget _buildDesktopComposer(BuildContext context) {
    final palette = context.whisperPalette;
    return Container(
      key: desktopContainerKey,
      margin: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: _buildComposerContents(context, maxLines: 5),
    );
  }

  Widget _buildMobileComposer(BuildContext context) {
    final palette = context.whisperPalette;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
          decoration: BoxDecoration(
            color: palette.surfaceElevated,
            borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
            border: Border.all(color: palette.borderSubtle),
          ),
          child: _buildComposerContents(context, maxLines: 6),
        ),
      ),
    );
  }

  Widget _buildComposerContents(
    BuildContext context, {
    required int maxLines,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_hasClipboardDraft) ...[
          _buildClipboardPreview(context),
          const SizedBox(height: 8),
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
            maxLines: maxLines,
            autofocus: isDesktop(),
            autocorrect: true,
            cursorColor: colorScheme.primary,
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
              hintText: canSend ? l10n.sendTips : l10n.connectToSend,
              hintStyle: TextStyle(color: palette.textMuted, fontSize: 16),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (clipboardEnabled)
              _buildUtilityActionButton(
                context,
                key: clipboardButtonKey,
                icon: Icons.content_copy_rounded,
                tooltip: l10n.menuClipboard,
                enabled: canSend && !isLoading,
                onPressed: onPreviewClipboard,
              ),
            const Spacer(),
            _buildPrimaryActionButton(context),
          ],
        ),
      ],
    );
  }

  Widget _buildUtilityActionButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required Future<void> Function() onPressed,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: enabled ? () => unawaited(onPressed()) : null,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(WhisperUi.minInteractiveSize),
        maximumSize: const Size.square(WhisperUi.minInteractiveSize),
        backgroundColor: Colors.transparent,
        foregroundColor:
            enabled ? colorScheme.onSurfaceVariant : colorScheme.outline,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
        ),
        padding: EdgeInsets.zero,
        elevation: 0,
      ),
      icon: Icon(icon, size: 19),
    );
  }

  Widget _buildClipboardPreview(BuildContext context) {
    final draft = pendingClipboardDraft!;
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final Key previewKey;
    final Widget leading;
    final Widget details;

    switch (draft) {
      case PendingClipboardTextDraft(:final text):
        previewKey = const ValueKey('chat-composer-clipboard-text-container');
        leading = Icon(
          Icons.text_snippet_outlined,
          color: colorScheme.primary,
          size: 22,
        );
        details = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              text,
              key: clipboardTextPreviewKey,
              maxLines: 3,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 13,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              l10n.clipboardPreviewTextCount(text.runes.length),
              style: TextStyle(color: palette.textMuted, fontSize: 12),
            ),
          ],
        );
      case PendingClipboardImageDraft(:final image):
        previewKey = clipboardImagePreviewKey;
        leading = ClipRRect(
          borderRadius: BorderRadius.circular(WhisperUi.radiusMedium),
          child: Image.memory(
            image.bytes,
            width: WhisperUi.minInteractiveSize,
            height: WhisperUi.minInteractiveSize,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => ColoredBox(
              color: palette.surfaceMuted,
              child: const SizedBox.square(
                dimension: WhisperUi.minInteractiveSize,
                child: Icon(Icons.image_outlined, size: 20),
              ),
            ),
          ),
        );
        details = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.clipboardPreviewImage,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              l10n.clipboardPreviewImageDetails(
                image.fileName,
                _formatBytes(image.size),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textMuted, fontSize: 12),
            ),
          ],
        );
      case PendingClipboardFilesDraft(:final files):
        final first = files.first;
        final totalSize = files.fold<int>(0, (sum, file) => sum + file.size);
        previewKey = clipboardFilesPreviewKey;
        leading = SizedBox.square(
          dimension: WhisperUi.minInteractiveSize,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(WhisperUi.radiusMedium),
            ),
            child: Icon(
              Icons.insert_drive_file_outlined,
              color: colorScheme.primary,
              size: 22,
            ),
          ),
        );
        details = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.clipboardPreviewFiles(files.length),
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              l10n.clipboardPreviewFilesDetails(
                first.fileName,
                files.length,
                _formatBytes(totalSize),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textMuted, fontSize: 12),
            ),
          ],
        );
    }

    return Semantics(
      container: true,
      label: l10n.clipboardPreviewTitle,
      child: Container(
        key: previewKey,
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
        decoration: BoxDecoration(
          color: palette.surfaceMuted.withValues(alpha: 0.56),
          borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
          border: Border.all(color: palette.borderSubtle),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 10),
            Expanded(child: details),
            IconButton(
              key: clipboardRemoveButtonKey,
              tooltip: l10n.clipboardPreviewRemove,
              onPressed: onClearClipboardDraft,
              style: IconButton.styleFrom(
                minimumSize: const Size.square(WhisperUi.minInteractiveSize),
                maximumSize: const Size.square(WhisperUi.minInteractiveSize),
                foregroundColor: colorScheme.onSurfaceVariant,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
                ),
                padding: EdgeInsets.zero,
                elevation: 0,
              ),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrimaryActionButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final showsAttachmentAction = _showsAttachmentAction;
    final enabled = canSend &&
        !isLoading &&
        (showsAttachmentAction || _hasDraftText || _hasClipboardDraft);
    return IconButton(
      key: showsAttachmentAction ? attachmentButtonKey : sendButtonKey,
      tooltip: showsAttachmentAction
          ? l10n.menuSendFile
          : (_hasClipboardDraft ? l10n.clipboardPreviewSend : l10n.sendTips),
      onPressed: enabled ? () => unawaited(_handlePrimaryAction()) : null,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(WhisperUi.minInteractiveSize),
        maximumSize: const Size.square(WhisperUi.minInteractiveSize),
        backgroundColor: showsAttachmentAction
            ? Colors.transparent
            : (enabled ? colorScheme.primary : palette.surfaceMuted),
        foregroundColor: showsAttachmentAction
            ? (enabled ? colorScheme.onSurfaceVariant : colorScheme.outline)
            : (enabled ? colorScheme.onPrimary : colorScheme.outline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
        ),
        side: showsAttachmentAction
            ? BorderSide.none
            : BorderSide(
                color: enabled ? colorScheme.primary : palette.borderSubtle,
              ),
        padding: EdgeInsets.zero,
        elevation: 0,
      ),
      icon: isLoading
          ? const SizedBox.square(
              dimension: 20,
              child: CupertinoActivityIndicator(),
            )
          : Icon(
              showsAttachmentAction
                  ? Icons.add_rounded
                  : Icons.arrow_upward_rounded,
              size: 20,
            ),
    );
  }

  bool get _hasDraftText => !isInputEmpty && controller.text.trim().isNotEmpty;

  bool get _hasClipboardDraft => pendingClipboardDraft != null;

  bool get _showsAttachmentAction =>
      !isLocalhost && !_hasDraftText && !_hasClipboardDraft;

  Future<void> _handlePrimaryAction() async {
    if (_hasClipboardDraft) {
      await onSendClipboardDraft();
      return;
    }
    if (_showsAttachmentAction) {
      await onPickFiles();
      return;
    }

    final nextText = controller.text.trimRight();
    if (nextText.trim().isEmpty) {
      return;
    }
    await onSendText(nextText);
    controller.clear();
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (!canSend) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      onClearClipboardDraft();
      return _hasClipboardDraft
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
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
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final shiftPressed =
          keyPressedMap[LogicalKeyboardKey.shift.keyLabel] == true ||
              HardwareKeyboard.instance.isShiftPressed;
      if (shiftPressed) {
        return KeyEventResult.ignored;
      }
      if (event is KeyRepeatEvent || isLoading) {
        return KeyEventResult.handled;
      }
      if (_hasClipboardDraft) {
        unawaited(onSendClipboardDraft());
        return KeyEventResult.handled;
      }
      final nextText = controller.text.trimRight();
      if (nextText.trim().isNotEmpty) {
        unawaited(onSendText(nextText));
        controller.clear();
      }
      return KeyEventResult.handled;
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
    final text = await onPasteClipboard();
    if (text == null || text.isEmpty) {
      return;
    }
    _insertTextAtSelection(text);
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
    controller.value = TextEditingValue(
      text: originalText.replaceRange(start, end, text),
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
