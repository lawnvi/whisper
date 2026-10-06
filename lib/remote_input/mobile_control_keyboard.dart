import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:whisper/remote_input/mobile_input_controller.dart';
import 'package:whisper/theme/app_theme.dart';

class MobileControlKeyboard extends StatelessWidget {
  const MobileControlKeyboard({
    super.key,
    required this.controller,
    required this.enabled,
    required this.targetPlatform,
    required this.page,
  });

  final MobileInputController controller;
  final bool enabled;
  final String targetPlatform;
  final int page;

  bool get _macTarget => targetPlatform.toLowerCase().contains('mac');
  String get _metaLabel => _macTarget
      ? 'Cmd'
      : targetPlatform.toLowerCase().contains('win')
      ? 'Win'
      : 'Super';

  @override
  Widget build(BuildContext context) {
    // Keep 12 columns in landscape. Less-used punctuation shares the Fn page.
    final rows = <List<(String, String)>>[
      if (page == 0) ...[
        [
          ('escape', 'Esc'),
          for (final v in '1234567890'.split('')) ('digit$v', v),
          ('backspace', '⌫'),
        ],
        [
          ('tab', 'Tab'),
          for (final v in 'QWERTYUIOP'.split('')) ('key$v', v),
          ('backslash', '\\'),
        ],
        [
          ('capsLock', 'Caps'),
          for (final v in 'ASDFGHJKL'.split('')) ('key$v', v),
          ('enter', 'Enter'),
        ],
        [
          ('shift', 'Shift'),
          for (final v in 'ZXCVBNM'.split('')) ('key$v', v),
          ('comma', ','),
          ('period', '.'),
          ('slash', '/'),
        ],
      ] else ...[
        [for (var i = 1; i <= 12; i++) ('f$i', 'F$i')],
        [
          ('home', 'Home'),
          ('end', 'End'),
          ('pageUp', 'PgUp'),
          ('pageDown', 'PgDn'),
          ('delete', 'Delete'),
        ],
        [
          ('backquote', '`'),
          ('minus', '-'),
          ('equal', '='),
          ('bracketLeft', '['),
          ('bracketRight', ']'),
          ('semicolon', ';'),
          ('quote', "'"),
        ],
      ],
      [
        ('meta', _metaLabel),
        ('control', 'Ctrl'),
        ('alt', _macTarget ? 'Opt' : 'Alt'),
        if (page == 1) ('shift', 'Shift'),
        ('space', 'Space'),
        ('arrowLeft', '←'),
        ('arrowDown', '↓'),
        ('arrowUp', '↑'),
        ('arrowRight', '→'),
      ],
    ];
    double weight(String key) => switch (key) {
      'capsLock' => 1.25,
      'enter' => 1.75,
      'shift' => 1.75,
      'space' => 3.25,
      'meta' || 'control' || 'alt' => 1.1,
      _ => 1,
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final width = math.max(
          620.0 * math.max(1, scale),
          constraints.maxWidth - 16,
        );
        final keyHeight = math.max(
          48.0 * math.max(1, scale),
          math.min(
            56.0,
            (constraints.maxHeight - 16 - (rows.length - 1) * 4) / rows.length,
          ),
        );
        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(
              key: ValueKey('keyboard-$page'),
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Column(
                  children: [
                    for (
                      var rowIndex = 0;
                      rowIndex < rows.length;
                      rowIndex++
                    ) ...[
                      if (rowIndex > 0) const SizedBox(height: 4),
                      SizedBox(
                        height: keyHeight,
                        child: Row(
                          children: [
                            for (
                              var index = 0;
                              index < rows[rowIndex].length;
                              index++
                            ) ...[
                              if (index > 0) const SizedBox(width: 4),
                              Expanded(
                                flex: (weight(rows[rowIndex][index].$1) * 100)
                                    .round(),
                                child: _keyboardKey(
                                  context,
                                  rows[rowIndex][index].$1,
                                  rows[rowIndex][index].$2,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _keyboardKey(BuildContext context, String semantic, String label) {
    final modifier = switch (semantic) {
      'meta' => _macTarget ? 'Command' : _metaLabel,
      'control' => 'Control',
      'alt' => _macTarget ? 'Option' : 'Alt',
      'shift' => 'Shift',
      _ => null,
    };
    return SizedBox(
      key: ValueKey('mobile-key-$semantic'),
      child: modifier == null
          ? _VirtualKey(
              label: label,
              enabled: enabled,
              onTap: () => controller.key(semantic),
              repeat: semantic.startsWith('arrow') || semantic == 'backspace',
              onRepeatStart: () =>
                  controller.beginRepeat(semantic, immediate: true),
              onRepeatStop: controller.cancelRepeat,
            )
          : Tooltip(
              message: modifier,
              child: Semantics(
                label: modifier,
                selected: controller.modifiers.contains(semantic),
                child: OutlinedButton(
                  onPressed: enabled
                      ? () => controller.toggleModifier(semantic)
                      : null,
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    backgroundColor: controller.modifiers.contains(semantic)
                        ? Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.12)
                        : context.whisperPalette.surfaceElevated,
                    side: BorderSide(
                      color: controller.modifiers.contains(semantic)
                          ? Theme.of(context).colorScheme.primary
                          : context.whisperPalette.borderSubtle,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _VirtualKey extends StatefulWidget {
  const _VirtualKey({
    required this.label,
    required this.enabled,
    required this.onTap,
    required this.repeat,
    required this.onRepeatStart,
    required this.onRepeatStop,
  });
  final String label;
  final bool enabled, repeat;
  final VoidCallback onTap, onRepeatStart, onRepeatStop;
  @override
  State<_VirtualKey> createState() => _VirtualKeyState();
}

class _VirtualKeyState extends State<_VirtualKey> {
  void _cancel() {
    widget.onRepeatStop();
  }

  @override
  void didUpdateWidget(covariant _VirtualKey oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _cancel();
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    gestures: widget.enabled && widget.repeat
        ? <Type, GestureRecognizerFactory>{
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    duration: MobileInputController.keyRepeatDelay,
                  ),
                  (recognizer) {
                    recognizer.onLongPressStart = (_) {
                      widget.onRepeatStart();
                    };
                    recognizer.onLongPressEnd = (_) {
                      _cancel();
                    };
                    recognizer.onLongPressCancel = _cancel;
                  },
                ),
          }
        : const <Type, GestureRecognizerFactory>{},
    child: OutlinedButton(
      onPressed: widget.enabled ? widget.onTap : null,
      style: OutlinedButton.styleFrom(
        padding: EdgeInsets.zero,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        backgroundColor: context.whisperPalette.surfaceElevated,
        side: BorderSide(color: context.whisperPalette.borderSubtle),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(widget.label),
    ),
  );
}
