import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/helper/screenshot_shortcut.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_dialog.dart';

class ScreenshotButton extends StatelessWidget {
  const ScreenshotButton({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = DesktopScreenshotController.shared;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => IconButton(
        tooltip: AppLocalizations.of(context)?.screenshotCapture,
        onPressed: controller.capturing || controller.configuring
            ? null
            : () => unawaited(controller.capture()),
        icon: const Icon(Icons.crop_free_rounded, size: 18),
        style: IconButton.styleFrom(
          foregroundColor: context.whisperPalette.textMuted,
          minimumSize: const Size(36, 36),
          padding: const EdgeInsets.all(8),
        ),
      ),
    );
  }
}

Future<void> showScreenshotShortcutDialog(
  BuildContext context, {
  DesktopScreenshotController? screenshotController,
}) async {
  final controller = screenshotController ?? DesktopScreenshotController.shared;
  await controller.initialize(AppLocalizations.of(context)!.screenshotCapture);
  if (!context.mounted) return;
  controller.shortcutsPaused = true;
  try {
    await showWhisperDialog<void>(
      context,
      barrierDismissible: false,
      builder: (_) => _ScreenshotShortcutDialog(controller: controller),
    );
  } finally {
    controller.shortcutsPaused = false;
  }
}

class _ScreenshotShortcutDialog extends StatefulWidget {
  const _ScreenshotShortcutDialog({required this.controller});

  final DesktopScreenshotController controller;

  @override
  State<_ScreenshotShortcutDialog> createState() =>
      _ScreenshotShortcutDialogState();
}

class _ScreenshotShortcutDialogState extends State<_ScreenshotShortcutDialog> {
  late final _controller = widget.controller;
  final _focus = FocusNode();
  late ScreenshotShortcut _shortcut = _controller.shortcut;
  late bool _enabled = _controller.enabled;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_recordShortcut);
  }

  bool _recordShortcut(KeyEvent event) {
    if (!_focus.hasFocus ||
        !_enabled ||
        _saving ||
        event.logicalKey == LogicalKeyboardKey.tab ||
        event.logicalKey == LogicalKeyboardKey.escape) {
      return false;
    }
    final candidate = ScreenshotShortcut.fromKeyEvent(event);
    if (candidate != null) {
      setState(() {
        _shortcut = candidate;
        _error = null;
      });
    }
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_recordShortcut);
    _focus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _controller.configure(_shortcut, enabled: _enabled);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          final l10n = AppLocalizations.of(context)!;
          _error =
              error is PlatformException && error.code == 'shortcut-invalid'
              ? l10n.screenshotShortcutInvalid
              : l10n.screenshotShortcutFailed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.whisperPalette;
    return PopScope(
      canPop: !_saving,
      child: WhisperGlassDialog(
        title: Text(
          l10n.screenshotShortcutTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.screenshotShortcutDesc,
                style: TextStyle(color: palette.textMuted),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Text(l10n.screenshotShortcutEnabled)),
                  CupertinoSwitch(
                    value: _enabled,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _enabled = value),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Focus(
                focusNode: _focus,
                onFocusChange: (_) => setState(() {}),
                child: Semantics(
                  button: true,
                  label: l10n.screenshotShortcutRecord,
                  child: InkWell(
                    onTap: !_enabled || _saving ? null : _focus.requestFocus,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: palette.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _focus.hasFocus
                              ? Theme.of(context).colorScheme.primary
                              : palette.borderSubtle,
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            _shortcut.label(macOS: _controller.macOS),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: _enabled ? null : palette.textMuted,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            l10n.screenshotShortcutRecord,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.screenshotShortcutHint,
                style: TextStyle(color: palette.textMuted, fontSize: 12),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _shortcut = ScreenshotShortcut.defaultFor(
                            macOS: _controller.macOS,
                          );
                          _enabled = true;
                          _error = null;
                        }),
                  child: Text(l10n.screenshotShortcutReset),
                ),
              ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: palette.danger)),
            ],
          ),
        ),
        actions: [
          WhisperDialogButton(
            label: l10n.cancel,
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
          ),
          WhisperDialogButton(
            label: l10n.confirm,
            prominent: true,
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}
