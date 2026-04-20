import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/l10n/app_localizations.dart';

class ChatComposer extends StatelessWidget {
  final bool clipboardEnabled;
  final bool isInputEmpty;
  final bool isLoading;
  final bool isLocalhost;
  final Map<String, bool> keyPressedMap;
  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function() onPickFiles;
  final Future<void> Function() onSendClipboard;
  final Future<void> Function(String text) onSendText;

  const ChatComposer({
    super.key,
    required this.clipboardEnabled,
    required this.isInputEmpty,
    required this.isLoading,
    required this.isLocalhost,
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

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
      ),
      child: Row(
        children: [
          if (clipboardEnabled)
            CupertinoButton(
              padding: const EdgeInsets.fromLTRB(0, 6, 6, 6),
              onPressed: onSendClipboard,
              child: Icon(
                Icons.copy,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 50),
          Expanded(
            child: KeyboardListener(
              focusNode: focusNode,
              onKeyEvent: (KeyEvent event) async {
                if (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
                    event.logicalKey == LogicalKeyboardKey.shiftRight) {
                  keyPressedMap[LogicalKeyboardKey.shift.keyLabel] =
                      event is KeyDownEvent;
                } else if (event.logicalKey == LogicalKeyboardKey.enter) {
                  keyPressedMap[LogicalKeyboardKey.enter.keyLabel] =
                      event is KeyDownEvent;
                  if (event is KeyDownEvent &&
                      (keyPressedMap[LogicalKeyboardKey.shift.keyLabel] !=
                              true ||
                          isMobile())) {
                    final nextText = controller.text.trimRight();
                    if (nextText.isNotEmpty) {
                      await onSendText(nextText);
                      controller.text = "";
                    }
                  }
                }
              },
              child: CupertinoTextField(
                controller: controller,
                cursorColor: colorScheme.primary,
                autofocus: isDesktop(),
                autocorrect: true,
                maxLines: isMobile() ? 5 : 20,
                minLines: 1,
                placeholder:
                    AppLocalizations.of(context)?.sendTips ?? '发点什么...',
                style: TextStyle(color: colorScheme.onSurface),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  border: Border.all(
                    color: colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(18),
                ),
                onChanged: (value) {
                  if (value == "\n" &&
                      keyPressedMap[LogicalKeyboardKey.shift.keyLabel] !=
                          true) {
                    controller.text = "";
                  }
                },
              ),
            ),
          ),
          if (isLoading) const SizedBox(width: 12),
          isLoading
              ? const Center(child: CupertinoActivityIndicator())
              : CupertinoButton(
                  padding: const EdgeInsets.fromLTRB(6, 6, 0, 6),
                  onPressed: () async {
                    if (!isLocalhost && controller.text.isEmpty) {
                      await onPickFiles();
                    } else {
                      await onSendText(controller.text);
                      controller.text = "";
                    }
                  },
                  child: Icon(
                    !isLocalhost && isInputEmpty ? Icons.add : Icons.send,
                    color: colorScheme.primary,
                  ),
                ),
          if (isLoading) const SizedBox(width: 12),
        ],
      ),
    );
  }
}
