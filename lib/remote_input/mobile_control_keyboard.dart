import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/remote_input/mobile_input_controller.dart';
import 'package:whisper/theme/app_theme.dart';

/// Physical key semantics, using the same symbol positions as the desktop map.
const mobileControlSymbols = <String, (String, bool)>{
  '!': ('digit1', true),
  '@': ('digit2', true),
  '#': ('digit3', true),
  r'$': ('digit4', true),
  '%': ('digit5', true),
  '^': ('digit6', true),
  '&': ('digit7', true),
  '*': ('digit8', true),
  '(': ('digit9', true),
  ')': ('digit0', true),
  '-': ('minus', false),
  '_': ('minus', true),
  '=': ('equal', false),
  '+': ('equal', true),
  '[': ('bracketLeft', false),
  ']': ('bracketRight', false),
  '{': ('bracketLeft', true),
  '}': ('bracketRight', true),
  '\\': ('backslash', false),
  '|': ('backslash', true),
  ';': ('semicolon', false),
  ':': ('semicolon', true),
  "'": ('quote', false),
  '"': ('quote', true),
  ',': ('comma', false),
  '.': ('period', false),
  '<': ('comma', true),
  '>': ('period', true),
  '/': ('slash', false),
  '?': ('slash', true),
  '`': ('backquote', false),
  '~': ('backquote', true),
};

class MobileControlKeyboard extends StatelessWidget {
  const MobileControlKeyboard({
    super.key,
    required this.controller,
    required this.enabled,
    required this.targetPlatform,
    required this.page,
    required this.onPageChanged,
  });

  final MobileInputController controller;
  final bool enabled;
  final String targetPlatform;
  // 0: letters, 1: numbers/symbols, 2: more symbols, 3: function/navigation.
  final int page;
  final ValueChanged<int> onPageChanged;

  bool get _macTarget => targetPlatform.toLowerCase().contains('mac');
  String get _metaLabel => _macTarget
      ? 'Cmd'
      : targetPlatform.toLowerCase().contains('win')
      ? 'Win'
      : 'Super';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    List<(String, String)> letters(String value) => [
      for (final v in value.split('')) ('key$v', v),
    ];
    List<(String, String)> symbols(String value) => [
      for (final v in value.split('')) (v, v),
    ];
    final rows = <List<(String, String)>>[
      [
        ('meta', _metaLabel),
        ('control', 'Ctrl'),
        ('alt', _macTarget ? 'Opt' : 'Alt'),
        if (page == 3) ('shift', '⇧'),
        ('fnPage', page == 3 ? 'ABC' : 'Fn'),
      ],
      [
        ('escape', 'Esc'),
        ('tab', 'Tab'),
        ('arrowLeft', '←'),
        ('arrowDown', '↓'),
        ('arrowUp', '↑'),
        ('arrowRight', '→'),
      ],
      if (page == 0) ...[
        letters('QWERTYUIOP'),
        letters('ASDFGHJKL'),
        [('shift', '⇧'), ...letters('ZXCVBNM'), ('backspace', '⌫')],
      ] else if (page == 3) ...[
        [for (var i = 1; i <= 6; i++) ('f$i', 'F$i')],
        [for (var i = 7; i <= 12; i++) ('f$i', 'F$i')],
        [
          ('capsLock', 'Caps'),
          ('home', 'Home'),
          ('end', 'End'),
          ('pageUp', 'PgUp'),
          ('pageDown', 'PgDn'),
          ('delete', 'Del'),
        ],
      ] else if (page == 1) ...[
        [for (final v in '1234567890'.split('')) ('digit$v', v)],
        symbols(r'@#$_&-+()/'),
        [('morePage', '#+='), ...symbols('*"\':;!?'), ('backspace', '⌫')],
      ] else ...[
        symbols('[]{}<>=%^\\'),
        symbols('~`|:;&+-/*'),
        [('morePage', '123'), ...symbols(r'@#$_()?'), ('backspace', '⌫')],
      ],
      [
        ('symbolPage', page == 0 ? '123' : 'ABC'),
        (',', ','),
        ('space', l10n.mobileControlSpace),
        ('.', '.'),
        ('enter', l10n.mobileControlEnter),
      ],
    ];
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, constraints) {
        final keyHeight = math.max(52.0, 40 * scale);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var row = 0; row < rows.length; row++) ...[
              if (row > 0) SizedBox(height: row == 2 ? 12 : 6),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: page == 0 && row == 3
                      ? constraints.maxWidth * .05
                      : 0,
                ),
                child: SizedBox(
                  height: keyHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var col = 0; col < rows[row].length; col++) ...[
                        if (col > 0) SizedBox(width: row < 2 ? 4 : 3),
                        Expanded(
                          flex: switch (rows[row][col].$1) {
                            'space' => 400,
                            'enter' => 200,
                            'symbolPage' => 150,
                            'shift' ||
                            'backspace' ||
                            'morePage' when row == 4 => 150,
                            _ => 100,
                          },
                          child: _key(
                            context,
                            rows[row][col].$1,
                            rows[row][col].$2,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _key(BuildContext context, String semantic, String label) {
    final l10n = AppLocalizations.of(context)!;
    final nextPage = switch (semantic) {
      'fnPage' => page == 3 ? 0 : 3,
      'symbolPage' => page == 0 ? 1 : 0,
      'morePage' => page == 1 ? 2 : 1,
      _ => null,
    };
    final modifier = switch (semantic) {
      'meta' => _macTarget ? 'Command' : _metaLabel,
      'control' => 'Control',
      'alt' => _macTarget ? 'Option' : 'Alt',
      'shift' => 'Shift',
      _ => null,
    };
    final selected =
        modifier != null && controller.modifiers.contains(semantic);
    final symbol = mobileControlSymbols[semantic];
    final keyLabel =
        semantic.startsWith('key') && !controller.modifiers.contains('shift')
        ? label.toLowerCase()
        : label;
    final tooltip = nextPage != null
        ? switch (semantic) {
            'fnPage' =>
              page == 3
                  ? l10n.mobileControlMainKeys
                  : l10n.mobileControlFunctionKeys,
            'symbolPage' =>
              page == 0
                  ? l10n.mobileControlSymbols
                  : l10n.mobileControlMainKeys,
            _ => l10n.mobileControlMoreSymbols,
          }
        : modifier;
    final style = OutlinedButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: TextStyle(fontSize: label.length > 1 ? 12 : 16),
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      backgroundColor: selected || nextPage != null
          ? Theme.of(context).colorScheme.primary.withValues(alpha: .12)
          : context.whisperPalette.surfaceElevated,
      side: BorderSide(
        color: selected
            ? Theme.of(context).colorScheme.primary
            : context.whisperPalette.borderSubtle,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    );
    final text = Text(keyLabel, maxLines: 1, overflow: TextOverflow.ellipsis);
    Widget result = SizedBox(
      key: ValueKey('mobile-key-$semantic'),
      child: nextPage != null || modifier != null
          ? Semantics(
              selected: selected,
              child: OutlinedButton(
                style: style,
                onPressed: nextPage != null
                    ? () => onPageChanged(nextPage)
                    : enabled
                    ? () => controller.toggleModifier(semantic)
                    : null,
                child: text,
              ),
            )
          : _VirtualKey(
              label: keyLabel,
              style: style,
              enabled: enabled,
              onTap: () => controller.key(
                symbol?.$1 ?? semantic,
                shift:
                    symbol?.$2 ?? (semantic.startsWith('digit') ? false : null),
              ),
              repeat: semantic.startsWith('arrow') || semantic == 'backspace',
              onRepeatStart: () =>
                  controller.beginRepeat(semantic, immediate: true),
              onRepeatStop: controller.cancelRepeat,
            ),
    );
    if (tooltip != null) result = Tooltip(message: tooltip, child: result);
    return result;
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
    required this.style,
  });
  final String label;
  final ButtonStyle style;
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
      style: widget.style,
      child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );
}
