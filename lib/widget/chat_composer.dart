import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show BoxWidthStyle;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/memory_bounded_image.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/context_menu_region.dart';
import 'package:whisper/widget/screenshot_controls.dart';
import 'package:whisper/widget/subtle_motion.dart';

class ChatComposer extends StatelessWidget {
  static const desktopContainerKey = ValueKey(
    'chat-composer-desktop-container',
  );
  static const desktopInputRegionKey = ValueKey(
    'chat-composer-desktop-input-region',
  );
  static const attachmentButtonKey = ValueKey('chat-composer-attachment');
  static const clipboardButtonKey = ValueKey('chat-composer-clipboard');
  static const sendButtonKey = ValueKey('chat-composer-send');
  static const clipboardImagePreviewKey = ValueKey(
    'chat-composer-clipboard-image-preview',
  );
  static const clipboardImageRemoveButtonKey = ValueKey(
    'chat-composer-clipboard-image-remove',
  );
  static const clipboardFilesPreviewKey = ValueKey(
    'chat-composer-clipboard-files-preview',
  );
  static const clipboardFilesRemoveButtonKey = ValueKey(
    'chat-composer-clipboard-files-remove',
  );

  final bool clipboardEnabled;
  final bool canSend;
  final bool isInputEmpty;
  final bool isLoading;
  final bool isDesktopStyle;
  final Map<String, bool> keyPressedMap;
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<ClipboardImageDraft> pendingClipboardImages;
  final List<ClipboardFileDraft> pendingClipboardFiles;
  final Future<void> Function() onPickFiles;

  /// When set on a desktop layout, the attachment button offers a folder
  /// beside files.
  final Future<void> Function()? onPickFolder;
  final Future<void> Function() onSendClipboard;
  final Future<bool> Function(String text) onSendText;
  final Future<String?> Function()? onPasteClipboard;
  final Future<void> Function()? onSendClipboardFiles;
  final VoidCallback? onClearClipboardFiles;
  final Future<void> Function()? onSendClipboardImages;
  final ValueChanged<int>? onRemoveClipboardImage;

  /// Marks up a picture waiting to be sent.
  final ValueChanged<int>? onEditClipboardImage;

  /// 发给 iMac, or 连接 iMac 后可以发送 with a button to do so.
  final String? composerHint, disabledHint;

  /// Sends the clipboard and says whether it went, for the button to show it.
  final Future<bool> Function()? onSyncClipboard;

  const ChatComposer({
    super.key,
    required this.clipboardEnabled,
    required this.canSend,
    required this.isInputEmpty,
    required this.isLoading,
    required this.isDesktopStyle,
    required this.keyPressedMap,
    required this.controller,
    required this.focusNode,
    this.pendingClipboardImages = const <ClipboardImageDraft>[],
    this.pendingClipboardFiles = const <ClipboardFileDraft>[],
    required this.onPickFiles,
    this.onPickFolder,
    required this.onSendClipboard,
    required this.onSendText,
    this.onPasteClipboard,
    this.onSendClipboardFiles,
    this.onClearClipboardFiles,
    this.onSendClipboardImages,
    this.onRemoveClipboardImage,
    this.onEditClipboardImage,
    this.composerHint,
    this.disabledHint,
    this.onSyncClipboard,
  });

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        if (isDesktopStyle && canSend && onPasteClipboard != null)
          PasteTextIntent: CallbackAction<PasteTextIntent>(
            onInvoke: (_) {
              unawaited(_handlePasteShortcut());
              return null;
            },
          ),
      },
      child: _buildCapsule(context),
    );
  }

  /// surfaces.md「输入框」: glass floating over the conversation, growing upward.
  /// With a pointer it is a small card whose last line is a toolbar; on a phone
  /// a capsule, where the room belongs to the keyboard.
  Widget _buildCapsule(BuildContext context) {
    final c = context.wc;
    final touch = !isDesktopStyle;
    final type = WhisperType(touch: touch);
    final hasPreview =
        _showsClipboardFilesPreview || _showsClipboardImagesPreview;
    final disabled = !canSend;
    // Nothing written in the box. A screen reader still says what it is for.
    final field = Semantics(
      label: disabled ? disabledHint : composerHint,
      child: Focus(
        onKeyEvent: (_, event) => _handleKeyEvent(event),
        child: TextField(
          key: const ValueKey('chat-composer-textfield'),
          controller: controller,
          focusNode: focusNode,
          enabled: canSend,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          minLines: touch ? 1 : 2,
          maxLines: touch ? 5 : 6,
          selectionWidthStyle: BoxWidthStyle.tight,
          autofocus: isDesktop(),
          autocorrect: true,
          cursorColor: c.accent,
          style: TextStyle(color: c.ink, fontSize: type.body, height: 1.35),
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
          ),
        ),
      ),
    );
    // As tall as the buttons on one line, so that they are level.
    final fieldPadding = touch ? 8.0 : 4.5;
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: touch ? 38 : 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                touch ? 16 : 12,
                fieldPadding,
                4,
                fieldPadding,
              ),
              child: field,
            ),
          ),
          if (!disabled) ...[
            // Only while there is nothing to send. Once there is, the words get
            // the room and the one button left stays at the bottom right, as in
            // any messaging app: nothing jumps, and nothing is empty above it.
            AnimatedSize(
              duration: whisperMotionDuration(context),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomRight,
              child: _showsAttachmentAction
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (clipboardEnabled) ...[
                          _ClipboardButton(
                            key: clipboardButtonKey,
                            label:
                                AppLocalizations.of(context)?.menuClipboard ??
                                '',
                            touch: touch,
                            send: isLoading
                                ? null
                                : onSyncClipboard ??
                                      () async {
                                        await onSendClipboard();
                                        return true;
                                      },
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (isDesktop()) ...[
                          const ScreenshotButton(capsule: true),
                          const SizedBox(width: 4),
                        ],
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
            _buildCapsuleSend(context, touch),
          ],
        ],
      ),
    );
    final radius = touch
        ? (hasPreview ? WhisperRadius.composer - 5 : WhisperRadius.composer)
        : WhisperRadius.l;
    final shadows = WhisperShadow.e2(Theme.of(context).brightness);
    Widget lifted(Widget child) => touch
        ? DecoratedBox(
            key: desktopContainerKey,
            decoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(radius),
              ),
              shadows: shadows,
            ),
            child: child,
          )
        // This much glass would go grey over a shadow drawn under it as well.
        : CustomPaint(
            key: desktopContainerKey,
            painter: WhisperOutsideShadow(shadows: shadows, radius: radius),
            child: child,
          );
    return lifted(
      WhisperGlass(
        kind: GlassKind.control,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: AnimatedSize(
            duration: whisperMotionDuration(context),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasPreview)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                    child: _showsClipboardFilesPreview
                        ? _buildClipboardFilesPreview(context)
                        : _buildClipboardImagesPreview(context),
                  ),
                if (touch)
                  row
                else ...[
                  // The whole card is for writing, not only the text itself.
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: focusNode.requestFocus,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 7, 6, 8),
                      child: field,
                    ),
                  ),
                  _buildToolbar(context),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The card's last line. Everything has its place whatever is written above
  /// it: what makes something to send is on the left, what sends on the right.
  Widget _buildToolbar(BuildContext context) {
    final c = context.wc;
    final localizations = AppLocalizations.of(context);
    final ready =
        _hasDraftText ||
        _showsClipboardFilesPreview ||
        _showsClipboardImagesPreview;
    return Row(
      children: [
        if (isDesktop()) const ScreenshotButton(capsule: true),
        if (clipboardEnabled) ...[
          const SizedBox(width: 2),
          _ClipboardButton(
            key: clipboardButtonKey,
            label: localizations?.menuClipboard ?? '',
            touch: false,
            send: isLoading
                ? null
                : onSyncClipboard ??
                      () async {
                        await onSendClipboard();
                        return true;
                      },
          ),
        ],
        const Spacer(),
        Builder(
          builder: (buttonContext) => Pressable(
            key: attachmentButtonKey,
            onTap: isLoading ? null : () => _handleAttach(buttonContext),
            radius: WhisperRadius.capsule,
            label: localizations?.attachFile,
            child: SizedBox.square(
              dimension: 28,
              child: Center(
                child: WhisperIcon(
                  WhisperGlyph.plus,
                  size: 17,
                  color: c.ink2Glass,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Pressable(
          key: sendButtonKey,
          onTap: isLoading || !ready ? null : () => _handleSend(),
          radius: WhisperRadius.capsule,
          scale: .94,
          label: localizations?.confirm,
          child: AnimatedContainer(
            duration: whisperMotionDuration(context),
            curve: Curves.easeOutCubic,
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: ready ? c.accent : c.fill,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: WhisperIcon(
                WhisperGlyph.up,
                size: 15,
                weight: 2.2,
                color: ready ? c.onAccent : c.ink3,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// `+` while there is nothing to send, an arrow once there is. The icons cross
  /// over, turning a quarter.
  Widget _buildCapsuleSend(BuildContext context, bool touch) {
    final c = context.wc;
    final attach = _showsAttachmentAction;
    final size = touch ? 38.0 : 28.0;
    return Builder(
      builder: (buttonContext) => Pressable(
        key: attach ? attachmentButtonKey : sendButtonKey,
        onTap: isLoading ? null : () => _handlePrimaryAction(buttonContext),
        radius: WhisperRadius.capsule,
        scale: .94,
        label: attach
            ? AppLocalizations.of(context)?.attachFile
            : AppLocalizations.of(context)?.confirm,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: attach ? c.fill : c.accent,
            shape: BoxShape.circle,
          ),
          child: SpringBuilder(
            value: attach ? 0 : 1,
            spring: WhisperSprings.snappy,
            builder: (context, t, _) => Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: (1 - t).clamp(0, 1),
                  child: Transform.scale(
                    scale: 1 - .5 * t.clamp(0, 1),
                    child: Transform.rotate(
                      angle: t * math.pi / 2,
                      child: WhisperIcon(
                        WhisperGlyph.plus,
                        size: 16,
                        weight: 2,
                        color: c.ink,
                      ),
                    ),
                  ),
                ),
                Opacity(
                  opacity: t.clamp(0, 1),
                  child: Transform.scale(
                    scale: .5 + .5 * t.clamp(0, 1),
                    child: Transform.rotate(
                      angle: (t - 1) * math.pi / 2,
                      child: WhisperIcon(
                        WhisperGlyph.up,
                        size: 15,
                        weight: 2.2,
                        color: c.onAccent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildClipboardImagesPreview(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.wc;
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        key: clipboardImagePreviewKey,
        spacing: 12,
        runSpacing: 12,
        children: [
          for (var index = 0; index < pendingClipboardImages.length; index++)
            SizedBox(
              key: ValueKey<String>('clipboard-image-preview-$index'),
              width: 88,
              height: 88,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Pressable(
                        onTap: onEditClipboardImage == null
                            ? null
                            : () => onEditClipboardImage!(index),
                        scale: 1,
                        label: AppLocalizations.of(context)?.screenshotMarkUp,
                        child: _buildClipboardImage(
                          context,
                          pendingClipboardImages[index],
                          colorScheme,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: -5,
                    right: -5,
                    child: IconButton(
                      key: index == 0
                          ? clipboardImageRemoveButtonKey
                          : ValueKey<String>(
                              'chat-composer-clipboard-image-remove-$index',
                            ),
                      tooltip: AppLocalizations.of(context)?.delete ?? 'Delete',
                      onPressed: () => onRemoveClipboardImage?.call(index),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(30, 30),
                        maximumSize: const Size(30, 30),
                        backgroundColor: colorScheme.surface,
                        foregroundColor: colorScheme.onSurface,
                        side: BorderSide(color: palette.sep),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        elevation: 2,
                        shadowColor: Radix.blackA4,
                      ),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildClipboardImage(
    BuildContext context,
    ClipboardImageDraft draft,
    ColorScheme colorScheme,
  ) {
    Widget errorBuilder(
      BuildContext context,
      Object error,
      StackTrace? stackTrace,
    ) => ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.image_outlined,
          color: colorScheme.onSurfaceVariant,
          size: 24,
        ),
      ),
    );

    final extent = (88 * MediaQuery.devicePixelRatioOf(context)).ceil();
    return Image(
      image: CoverResizeImage(
        draft.bytes.isEmpty
            ? MemoryBoundedFileImage(File(draft.path))
            : MemoryBoundedMemoryImage(draft.bytes),
        extent: extent,
      ),
      fit: BoxFit.cover,
      errorBuilder: errorBuilder,
    );
  }

  Widget _buildClipboardFilesPreview(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.wc;
    final files = pendingClipboardFiles;
    final first = files.first;
    final totalSize = files.fold<int>(
      0,
      (previous, draft) => previous + draft.size,
    );
    final l10n = AppLocalizations.of(context);
    final countLabel =
        l10n?.clipboardFilesCount(files.length) ??
        (files.length == 1 ? '1 file' : '${files.length} files');
    return Container(
      key: clipboardFilesPreviewKey,
      padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.fill.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.sep),
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
                  style: TextStyle(color: palette.ink2, fontSize: 12),
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

  bool get _hasDraftText => !isInputEmpty && controller.text.trim().isNotEmpty;

  bool get _showsClipboardFilesPreview =>
      isDesktopStyle && pendingClipboardFiles.isNotEmpty;

  bool get _showsClipboardImagesPreview =>
      isDesktopStyle &&
      pendingClipboardImages.isNotEmpty &&
      !_showsClipboardFilesPreview;

  bool get _canSendPendingClipboardFiles =>
      _showsClipboardFilesPreview && onSendClipboardFiles != null;

  bool get _canSendPendingClipboardImages =>
      _showsClipboardImagesPreview && onSendClipboardImages != null;

  bool get _showsAttachmentAction =>
      !_hasDraftText &&
      !_showsClipboardFilesPreview &&
      !_showsClipboardImagesPreview;

  Future<void> _handlePrimaryAction(BuildContext context) async {
    if (_showsAttachmentAction) {
      await _handleAttach(context);
      return;
    }
    await _handleSend();
  }

  Future<void> _handleAttach(BuildContext context) async {
    final pickFolder = onPickFolder;
    final button = context.findRenderObject();
    if (!isDesktopStyle ||
        pickFolder == null ||
        button is! RenderBox ||
        !button.hasSize) {
      await onPickFiles();
      return;
    }
    final localizations = AppLocalizations.of(context);
    await showWhisperActionMenu(
      context,
      anchor: button.localToGlobal(Offset.zero) & button.size,
      above: true,
      items: <ContextMenuActionItem>[
        ContextMenuActionItem(
          label: localizations?.attachFile ?? 'File',
          icon: Icons.insert_drive_file_outlined,
          onSelected: () => unawaited(onPickFiles()),
        ),
        ContextMenuActionItem(
          label: localizations?.attachFolder ?? 'Folder',
          icon: Icons.folder_outlined,
          onSelected: () => unawaited(pickFolder()),
        ),
      ],
    );
  }

  Future<void> _handleSend() async {
    if (_canSendPendingClipboardFiles) {
      await onSendClipboardFiles!();
      return;
    }
    if (_canSendPendingClipboardImages) {
      await onSendClipboardImages!();
      return;
    }
    final snapshot = controller.value;
    final nextText = snapshot.text.trim();
    if (nextText.isEmpty) {
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
    if (_canDeleteClipboardImage(event)) {
      if (event is KeyDownEvent) {
        onRemoveClipboardImage!(pendingClipboardImages.length - 1);
      }
      // Holding Delete must not remove the entire image queue in one press.
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
        event.logicalKey == LogicalKeyboardKey.shiftRight) {
      keyPressedMap[LogicalKeyboardKey.shift.keyLabel] = event is KeyDownEvent;
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      keyPressedMap[LogicalKeyboardKey.enter.keyLabel] = event is KeyDownEvent;
      if (_hasActiveComposition) {
        return KeyEventResult.ignored;
      }
      if (event is KeyDownEvent &&
          (keyPressedMap[LogicalKeyboardKey.shift.keyLabel] != true ||
              isMobile())) {
        if (_canSendPendingClipboardFiles) {
          unawaited(onSendClipboardFiles!());
          return KeyEventResult.handled;
        }
        if (_canSendPendingClipboardImages) {
          unawaited(onSendClipboardImages!());
          return KeyEventResult.handled;
        }
        if (isLoading) {
          return KeyEventResult.handled;
        }
        final snapshot = controller.value;
        final nextText = snapshot.text.trim();
        if (nextText.isNotEmpty) {
          unawaited(_sendTextSnapshot(snapshot, nextText));
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  bool _canDeleteClipboardImage(KeyEvent event) {
    if (!isDesktopStyle ||
        isLoading ||
        !_showsClipboardImagesPreview ||
        onRemoveClipboardImage == null ||
        controller.text.isNotEmpty ||
        _hasActiveComposition ||
        (event.logicalKey != LogicalKeyboardKey.backspace &&
            event.logicalKey != LogicalKeyboardKey.delete)) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    return !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
  }

  bool get _hasActiveComposition {
    final composing = controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
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

  Future<void> _sendTextSnapshot(TextEditingValue snapshot, String text) async {
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

/// Sends the clipboard. The other device's clipboard changes where nobody here
/// can see it, so the button itself says that it went: a tick, for a moment.
class _ClipboardButton extends StatefulWidget {
  const _ClipboardButton({
    super.key,
    required this.label,
    required this.touch,
    required this.send,
  });

  final String label;
  final bool touch;
  final Future<bool> Function()? send;

  @override
  State<_ClipboardButton> createState() => _ClipboardButtonState();
}

class _ClipboardButtonState extends State<_ClipboardButton> {
  bool _sent = false;
  bool _busy = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _tap() async {
    final send = widget.send;
    if (send == null || _busy) return;
    _busy = true;
    final sent = await send();
    _busy = false;
    if (!sent || !mounted) return;
    if (widget.touch) unawaited(HapticFeedback.lightImpact());
    setState(() => _sent = true);
    _reset?.cancel();
    _reset = Timer(WhisperLoops.doneHold, () {
      if (mounted) setState(() => _sent = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    return Pressable(
      onTap: widget.send == null ? null : () => unawaited(_tap()),
      radius: WhisperRadius.capsule,
      label: widget.label,
      child: SizedBox.square(
        dimension: widget.touch ? 38 : 28,
        child: Center(
          child: AnimatedSwitcher(
            duration: whisperMotionDuration(context),
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: Tween(begin: .6, end: 1.0).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: _sent
                ? WhisperIcon(
                    key: const ValueKey('sent'),
                    WhisperGlyph.check,
                    size: 17,
                    weight: 2.2,
                    color: c.ok,
                  )
                : WhisperIcon(
                    key: const ValueKey('clip'),
                    WhisperGlyph.clip,
                    size: 17,
                    color: c.ink2Glass,
                  ),
          ),
        ),
      ),
    );
  }
}
