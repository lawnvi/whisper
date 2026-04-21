import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/l10n/app_localizations.dart';

class ChatComposer extends StatelessWidget {
  static const desktopContainerKey =
      ValueKey('chat-composer-desktop-container');
  static const attachmentButtonKey = ValueKey('chat-composer-attachment');
  static const clipboardButtonKey = ValueKey('chat-composer-clipboard');
  static const sendButtonKey = ValueKey('chat-composer-send');

  final bool clipboardEnabled;
  final bool canSend;
  final bool isInputEmpty;
  final bool isLoading;
  final bool isLocalhost;
  final bool isDesktopStyle;
  final Map<String, bool> keyPressedMap;
  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function() onPickFiles;
  final Future<void> Function() onSendClipboard;
  final Future<void> Function(String text) onSendText;

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
    required this.onSendClipboard,
    required this.onSendText,
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
    final onSurfaceMuted = colorScheme.onSurface.withValues(alpha: 0.52);
    return Container(
      key: desktopContainerKey,
      margin: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      padding: const EdgeInsets.fromLTRB(20, 14, 18, 14),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.72),
        ),
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
              cursorColor: colorScheme.primary,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 16,
                height: 1.45,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: canSend
                    ? (AppLocalizations.of(context)?.sendTips ?? '发点什么...')
                    : (AppLocalizations.of(context)?.connectToSend ??
                        '连接后即可发送消息'),
                hintStyle: TextStyle(
                  color: onSurfaceMuted,
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
    final onSurfaceMuted = colorScheme.onSurface.withValues(alpha: 0.5);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      decoration: BoxDecoration(
        color: colorScheme.surface,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 14, 16, 12),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.55),
          ),
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
                cursorColor: colorScheme.primary,
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
                  border: InputBorder.none,
                  hintText: canSend
                      ? (AppLocalizations.of(context)?.sendTips ?? '发点什么...')
                      : (AppLocalizations.of(context)?.connectToSend ??
                          '连接后即可发送消息'),
                  hintStyle: TextStyle(
                    color: onSurfaceMuted,
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
    return IconButton(
      key: key,
      onPressed: enabled ? () => onPressed() : null,
      style: IconButton.styleFrom(
        minimumSize: Size(buttonSize, buttonSize),
        maximumSize: Size(buttonSize, buttonSize),
        backgroundColor: outlined
            ? (enabled
                ? colorScheme.surface.withValues(alpha: 0.92)
                : colorScheme.surfaceContainerHighest.withValues(alpha: 0.45))
            : Colors.transparent,
        foregroundColor:
            enabled ? colorScheme.onSurfaceVariant : colorScheme.outline,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(outlined ? 16 : buttonSize / 2),
          side: outlined
              ? BorderSide(color: colorScheme.outlineVariant)
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

  Widget _buildPrimaryActionButton(
    BuildContext context, {
    required ColorScheme colorScheme,
    required double buttonSize,
    required double iconSize,
  }) {
    final showsAttachmentAction = _showsAttachmentAction;
    final enabled =
        canSend && !isLoading && (showsAttachmentAction || _hasDraftText);
    final backgroundColor = showsAttachmentAction
        ? Colors.transparent
        : (enabled ? colorScheme.primary : colorScheme.surfaceContainerHighest);
    final foregroundColor = showsAttachmentAction
        ? (enabled ? colorScheme.onSurfaceVariant : colorScheme.outline)
        : (enabled ? colorScheme.onPrimary : colorScheme.outline);
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
                color:
                    enabled ? colorScheme.primary : colorScheme.outlineVariant,
              ),
        splashFactory: NoSplash.splashFactory,
        overlayColor: Colors.transparent,
      ),
      icon: isLoading
          ? SizedBox(
              width: iconSize,
              height: iconSize,
              child: CupertinoActivityIndicator(
                color: showsAttachmentAction
                    ? colorScheme.primary
                    : colorScheme.onPrimary,
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

  bool get _showsAttachmentAction => !isLocalhost && !_hasDraftText;

  Future<void> _handlePrimaryAction() async {
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
        final nextText = controller.text.trimRight();
        if (nextText.trim().isNotEmpty) {
          onSendText(nextText);
          controller.clear();
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }
}
