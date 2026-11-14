import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

import 'settings_rows.dart';

/// Text and numbers. With a pointer they are edited where they stand: Enter or
/// losing focus keeps what was typed, if it is valid; Esc puts back what was
/// there. On a phone the list only shows the value, and the row opens a page
/// for it, as the system's settings do for a device's name.
class SettingsFieldRow extends StatefulWidget {
  const SettingsFieldRow({
    super.key,
    required this.title,
    required this.value,
    required this.validate,
    required this.onCommit,
    required this.onInvalid,
    this.keyboardType,
    this.inputFormatters,
    this.hint,
  });

  final String title, value;

  /// Under the field on a phone's page: what the value is for.
  final String? hint;

  /// Why [String] cannot be used, or null when it can.
  final String? Function(String text) validate;
  final Future<void> Function(String text) onCommit;
  final ValueChanged<String> onInvalid;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<SettingsFieldRow> createState() => _SettingsFieldRowState();
}

class _SettingsFieldRowState extends State<SettingsFieldRow> {
  late final _controller = TextEditingController(text: widget.value);
  late final _focus = FocusNode(onKeyEvent: _onKey);
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(SettingsFieldRow old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    // Closing the page or changing section is losing focus too.
    if (_focus.hasFocus) _commit();
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() {});
    if (!_focus.hasFocus) _commit();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    // Handled on the way up too, or Esc would go on to close the panel.
    if (event is KeyDownEvent) {
      _controller.text = widget.value;
      node.unfocus();
    }
    return KeyEventResult.handled;
  }

  void _commit() {
    final text = _controller.text.trim();
    if (text == widget.value) {
      _controller.text = widget.value;
      return;
    }
    final problem = widget.validate(text);
    if (problem != null) {
      _controller.text = widget.value;
      widget.onInvalid(problem);
      return;
    }
    _controller.text = text;
    unawaited(widget.onCommit(text));
  }

  void _openPage() {
    unawaited(
      Navigator.of(context).push(
        WhisperPageRoute<void>(
          builder: (_) => _SettingsFieldPage(
            title: widget.title,
            value: widget.value,
            hint: widget.hint,
            validate: widget.validate,
            onCommit: widget.onCommit,
            keyboardType: widget.keyboardType,
            inputFormatters: widget.inputFormatters,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (SettingsScope.of(context).touch) {
      return SettingsRow(
        title: widget.title,
        fillTrailing: true,
        onTap: _openPage,
        trailing: SettingsDisclosure(value: widget.value),
      );
    }
    final c = context.wc;
    final type = SettingsScope.typeOf(context);
    final focused = _focus.hasFocus;
    const none = InputBorder.none;
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      textAlign: TextAlign.end,
      textInputAction: TextInputAction.done,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      cursorColor: c.accent,
      cursorWidth: 1.5,
      style: SettingsTextStyle.style.copyWith(
        fontSize: type.body,
        height: 1.3,
        color: focused ? c.ink : c.ink2,
      ),
      decoration: const InputDecoration(
        isCollapsed: true,
        filled: false,
        border: none,
        enabledBorder: none,
        focusedBorder: none,
        disabledBorder: none,
        contentPadding: EdgeInsets.zero,
      ),
      onSubmitted: (_) => _focus.unfocus(),
    );
    return Semantics(
      container: true,
      textField: true,
      label: widget.title,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          // The row is the target, as a label is for its input.
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _focus.requestFocus,
          child: SettingsRow(
            title: widget.title,
            fillTrailing: true,
            trailing: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: SpringBuilder(
                  value: _hovered || focused ? 1 : 0,
                  spring: WhisperSprings.snappy,
                  animateWhenReduced: true,
                  child: field,
                  builder: (context, t, child) => Container(
                    constraints: const BoxConstraints(minHeight: 28),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    transform: Matrix4.translationValues(8, 0, 0),
                    alignment: Alignment.centerRight,
                    decoration: BoxDecoration(
                      color: Color.lerp(null, c.fill, t.clamp(0.0, 1.0)),
                      borderRadius: BorderRadius.circular(WhisperRadius.xs),
                      border: focused
                          ? Border.all(
                              color: c.accent.withValues(alpha: .35),
                              width: 3,
                              strokeAlign: BorderSide.strokeAlignOutside,
                            )
                          : null,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One value on a phone: its field, a way to clear it, and 完成 at the top, which
/// only lights up for something that can be kept. Going back keeps nothing.
class _SettingsFieldPage extends StatefulWidget {
  const _SettingsFieldPage({
    required this.title,
    required this.value,
    required this.validate,
    required this.onCommit,
    this.hint,
    this.keyboardType,
    this.inputFormatters,
  });

  final String title, value;
  final String? hint;
  final String? Function(String text) validate;
  final Future<void> Function(String text) onCommit;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<_SettingsFieldPage> createState() => _SettingsFieldPageState();
}

class _SettingsFieldPageState extends State<_SettingsFieldPage> {
  late final _controller = TextEditingController(text: widget.value)
    ..selection = TextSelection.collapsed(offset: widget.value.length);
  var _saving = false;

  String get _text => _controller.text.trim();

  /// Nothing typed yet is not a mistake: 完成 just stays off.
  String? get _problem => _text.isEmpty ? null : widget.validate(_text);

  bool get _canSave =>
      !_saving && _text.isNotEmpty && _text != widget.value && _problem == null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _leave() => unawaited(Navigator.of(context).maybePop());

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onCommit(_text);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (mounted) _leave();
  }

  void _submit() {
    if (_canSave) {
      unawaited(_save());
    } else if (_text == widget.value) {
      _leave();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final l10n = AppLocalizations.of(context)!;
    const none = InputBorder.none;
    return Scaffold(
      backgroundColor: c.canvas,
      body: SafeArea(
        bottom: false,
        child: SettingsScope(
          touch: true,
          page: true,
          child: SettingsTextStyle(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final problem = _problem;
                final note = problem ?? widget.hint;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: SizedBox(
                        height: 50,
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 46),
                              child: Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: type.head,
                                  height: 1.25,
                                  fontWeight: FontWeight.w600,
                                  color: c.ink,
                                ),
                              ),
                            ),
                            Pressable(
                              radius: WhisperRadius.capsule,
                              label: l10n.back,
                              onTap: _leave,
                              child: SizedBox.square(
                                dimension: 48,
                                child: Center(
                                  child: WhisperIcon(
                                    WhisperGlyph.back,
                                    size: 20,
                                    weight: 2,
                                    color: c.ink,
                                  ),
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: ShellButton(
                                label: l10n.shellDone,
                                kind: ShellButtonKind.quiet,
                                touch: true,
                                large: true,
                                inset: 12,
                                onTap: _canSave
                                    ? () => unawaited(_save())
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 620),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SettingsGroup(
                                  children: [
                                    SettingsRowFrame(
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Semantics(
                                              label: widget.title,
                                              child: TextField(
                                                controller: _controller,
                                                autofocus: true,
                                                textInputAction:
                                                    TextInputAction.done,
                                                keyboardType:
                                                    widget.keyboardType,
                                                inputFormatters:
                                                    widget.inputFormatters,
                                                cursorColor: c.accent,
                                                style: SettingsTextStyle.style
                                                    .copyWith(
                                                      fontSize: type.body,
                                                      height: 1.3,
                                                      color: c.ink,
                                                    ),
                                                decoration:
                                                    const InputDecoration(
                                                      isCollapsed: true,
                                                      filled: false,
                                                      border: none,
                                                      enabledBorder: none,
                                                      focusedBorder: none,
                                                      disabledBorder: none,
                                                      contentPadding:
                                                          EdgeInsets.zero,
                                                    ),
                                                // The keyboard stays until there
                                                // is somewhere to go.
                                                onEditingComplete: () {},
                                                onSubmitted: (_) => _submit(),
                                              ),
                                            ),
                                          ),
                                          Visibility(
                                            visible:
                                                _controller.text.isNotEmpty,
                                            maintainSize: true,
                                            maintainAnimation: true,
                                            maintainState: true,
                                            // The glyph ends where a row's
                                            // arrow and values end.
                                            child: Transform.translate(
                                              offset: const Offset(9, 0),
                                              child: Pressable(
                                                radius: WhisperRadius.capsule,
                                                label: MaterialLocalizations.of(
                                                  context,
                                                ).clearButtonTooltip,
                                                onTap: _controller.clear,
                                                child: SizedBox.square(
                                                  dimension: 36,
                                                  child: Center(
                                                    child: Icon(
                                                      Icons.cancel,
                                                      size: 18,
                                                      color: c.ink3,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                if (note != null)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      8,
                                      12,
                                      0,
                                    ),
                                    child: Text(
                                      note,
                                      style: TextStyle(
                                        fontSize: type.note,
                                        height: 1.35,
                                        color: problem != null ? c.bad : c.ink2,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
