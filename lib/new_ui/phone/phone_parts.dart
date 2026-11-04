import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';

/// `.win[data-size=compact] .tb`: back, the title, what the page keeps at the
/// right. 50 high, the back arrow pulled 8 toward the title.
class PhonePageBar extends StatelessWidget {
  const PhonePageBar({
    super.key,
    required this.title,
    this.end,
    this.onBack,
    this.back = true,
  });

  final String title;
  final Widget? end;

  /// A page opened from a sidebar has none: the way out is a device in it.
  final bool back;

  /// Instead of leaving the page.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    return SizedBox(
      height: 50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            if (back)
              ShellIconButton(
                glyph: WhisperGlyph.back,
                iconSize: 20,
                weight: 2,
                touch: true,
                color: c.ink,
                label: context.shellL10n.back,
                onTap: onBack ?? () => shellMaybePop(context),
              )
            else
              const SizedBox(width: 16),
            Expanded(
              // `margin-right: -8` on the arrow, `padding-left: 6` on the title.
              child: Transform.translate(
                offset: Offset(back ? -2 : 0, 0),
                child: Text(
                  title,
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
            ),
            ?end,
          ],
        ),
      ),
    );
  }
}

/// `.tb-end .iconbtn`: plain ink like the words beside it, 48 to hit. Accent is
/// for what a tap does something special, not for finding your way around.
class PhoneBarButton extends StatelessWidget {
  const PhoneBarButton({
    super.key,
    required this.glyph,
    required this.label,
    required this.onTap,
    this.iconSize = 20,
    this.weight = 1.6,
  });

  final WhisperGlyph glyph;
  final String label;
  final VoidCallback? onTap;
  final double iconSize, weight;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    radius: WhisperRadius.xs,
    label: label,
    child: SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: WhisperIcon(
          glyph,
          size: iconSize,
          weight: weight,
          color: context.wc.ink,
        ),
      ),
    ),
  );
}

/// A page of the phone's stack. [background] is `content` where the page is one
/// list, `canvas` where groups sit on it.
class PhonePage extends StatelessWidget {
  const PhonePage({
    super.key,
    required this.title,
    required this.child,
    this.end,
    this.onBack,
    this.background,
    this.resizeToAvoidBottomInset = true,
    this.bar = true,
    this.back = true,
  });

  final String title;
  final Widget child;
  final Widget? end;
  final VoidCallback? onBack;
  final Color? background;
  final bool resizeToAvoidBottomInset;

  /// False where a toolbar is already above the page: a tab beside a sidebar.
  /// Then [end] has a row of its own.
  final bool bar;

  /// See [PhonePageBar.back].
  final bool back;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: background ?? context.wc.canvas,
    resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    body: SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (bar)
            PhonePageBar(title: title, end: end, onBack: onBack, back: back)
          else if (end case final end?)
            Align(alignment: Alignment.centerRight, child: end),
          Expanded(child: child),
        ],
      ),
    ),
  );
}

/// `.search` on touch: 44 to look at, 48 to hit. With [onClear], a × once there
/// is something to clear.
class PhoneSearchField extends StatefulWidget {
  const PhoneSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.fieldKey = const ValueKey('apps-search'),
    this.onClear,
    this.clearLabel,
    this.touch = true,
    this.radius = WhisperRadius.s,
  });

  final bool touch;
  final double radius;

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final Key fieldKey;
  final VoidCallback? onClear;
  final String? clearLabel;

  @override
  State<PhoneSearchField> createState() => _PhoneSearchFieldState();
}

class _PhoneSearchFieldState extends State<PhoneSearchField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: widget.touch);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _focus.requestFocus,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.radius > WhisperRadius.s ? 14 : 11,
              vertical: widget.touch ? 10 : 7,
            ),
            child: Row(
              children: [
                WhisperIcon(WhisperGlyph.search, size: 15, color: c.ink2),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: widget.fieldKey,
                    controller: widget.controller,
                    focusNode: _focus,
                    onChanged: widget.onChanged,
                    onTapOutside: (_) => _focus.unfocus(),
                    textInputAction: TextInputAction.search,
                    cursorColor: c.accent,
                    style: TextStyle(fontSize: type.body, color: c.ink),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      filled: false,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: widget.hint,
                      hintStyle: TextStyle(fontSize: type.body, color: c.ink3),
                    ),
                  ),
                ),
                if (widget.onClear != null)
                  ValueListenableBuilder(
                    valueListenable: widget.controller,
                    builder: (context, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : Tooltip(
                            message: widget.clearLabel ?? '',
                            child: Pressable(
                              onTap: widget.onClear,
                              radius: WhisperRadius.xs,
                              label: widget.clearLabel,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: WhisperIcon(
                                  WhisperGlyph.x,
                                  size: 15,
                                  color: c.ink2,
                                ),
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
}

enum PhoneButtonKind { normal, primary, quiet, danger }

/// `.btn` at touch size: 44 high, 48 when large, 16 at each side. Its label
/// gives way before it pushes out of a narrow row.
class PhoneButton extends StatelessWidget {
  const PhoneButton({
    super.key,
    required this.label,
    required this.onTap,
    this.kind = PhoneButtonKind.normal,
    this.large = false,
    this.glyph,
    this.color,
    this.stretch = false,
  });

  final String label;
  final VoidCallback? onTap;
  final PhoneButtonKind kind;
  final bool large;
  final WhisperGlyph? glyph;

  /// A quiet button with a meaning of its own: 删除 in `bad`.
  final Color? color;

  /// `align-self: stretch`, as under the address form.
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final background = switch (kind) {
      PhoneButtonKind.normal => c.fill,
      PhoneButtonKind.primary => c.accent,
      PhoneButtonKind.quiet => Colors.transparent,
      PhoneButtonKind.danger => c.badSolid,
    };
    final foreground = switch (kind) {
      PhoneButtonKind.normal => color ?? c.ink,
      PhoneButtonKind.primary || PhoneButtonKind.danger => c.onAccent,
      PhoneButtonKind.quiet => color ?? c.accentText,
    };
    return Opacity(
      opacity: onTap == null ? .5 : 1,
      child: Pressable(
        onTap: onTap,
        radius: WhisperRadius.capsule,
        // 44 to look at and 48 to hit: what is added is the same colour as what
        // is behind it, there for a finger.
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: large ? 0 : 2),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: large ? 48 : 44),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(WhisperRadius.capsule),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Row(
                  mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (glyph != null) ...[
                      WhisperIcon(glyph!, size: 14, color: foreground),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: large ? type.body : type.note,
                          fontWeight: FontWeight.w500,
                          color: foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.popb` at touch size: 34 to look at, 48 to hit, which is the location
/// button in files.
class PhonePopButton extends StatelessWidget {
  const PhonePopButton({
    super.key,
    required this.label,
    required this.onTap,
    this.maxLabelWidth = 150,
  });

  final String label;
  final VoidCallback? onTap;
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    return Pressable(
      onTap: onTap,
      radius: WhisperRadius.s,
      scale: 1,
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Center(
          widthFactor: 1,
          child: Container(
            constraints: const BoxConstraints(minHeight: 34),
            padding: const EdgeInsets.fromLTRB(11, 0, 8, 0),
            decoration: BoxDecoration(
              color: c.fill,
              borderRadius: BorderRadius.circular(WhisperRadius.s),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxLabelWidth),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.note,
                        fontWeight: FontWeight.w500,
                        color: c.ink2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                WhisperIcon(
                  WhisperGlyph.updown,
                  size: 12,
                  weight: 2,
                  color: c.ink2,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of a group with a label and a code: an address, a fingerprint.
class PhoneInfoRow extends StatelessWidget {
  const PhoneInfoRow({super.key, required this.label, required this.value});

  final String label, value;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: type.body,
                  height: 1.3,
                  color: c.ink,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: phoneCode(color: c.ink2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `code`: the prototype's small monospaced text.
TextStyle phoneCode({required Color color}) => TextStyle(
  fontFamily: WhisperMono.family,
  fontFamilyFallback: WhisperMono.fallback,
  fontSize: WhisperSizes.code,
  height: 1.4,
  color: color,
);

/// `.field`: a label, its input and, when the input is wrong, why.
class ShellField extends StatefulWidget {
  const ShellField({
    super.key,
    required this.label,
    required this.controller,
    this.focusNode,
    this.error,
    this.fieldKey,
    this.keyboardType,
    this.inputFormatters,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.autofocus = false,
    this.hint,
    this.touch = true,
    this.obscure = false,
    this.showLabel,
    this.hideLabel,
  });

  final String label;
  final String? error, hint;

  /// With both, an [obscure] field has an eye that shows what was typed.
  final String? showLabel, hideLabel;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final Key? fieldKey;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted, onChanged;
  final bool autofocus, touch, obscure;

  @override
  State<ShellField> createState() => _ShellFieldState();
}

class _ShellFieldState extends State<ShellField> {
  late FocusNode _focus = widget.focusNode ?? FocusNode();
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
  }

  @override
  void didUpdateWidget(ShellField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      _focus.removeListener(_changed);
      if (old.focusNode == null) _focus.dispose();
      _focus = widget.focusNode ?? FocusNode();
      _focus.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: widget.touch);
    final error = widget.error;
    // The label is part of what can be tapped: an input of 44 reaches 48 with it.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _focus.requestFocus,
          child: Text(
            widget.label,
            style: TextStyle(fontSize: type.note, height: 1.4, color: c.ink2),
          ),
        ),
        const SizedBox(height: 5),
        Container(
          constraints: BoxConstraints(minHeight: widget.touch ? 44 : 34),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(WhisperRadius.s),
            // Outside the field only: a shadow would show through its fill.
            border: _focus.hasFocus
                ? Border.all(
                    color: c.accent.withValues(alpha: .45),
                    width: 3,
                    strokeAlign: BorderSide.strokeAlignOutside,
                  )
                : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: widget.fieldKey,
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  obscureText: widget.obscure && !_revealed,
                  keyboardType: widget.keyboardType,
                  inputFormatters: widget.inputFormatters,
                  textInputAction: widget.textInputAction,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: widget.onSubmitted,
                  onChanged: widget.onChanged,
                  cursorColor: c.accent,
                  // Every border by name: a theme's would come through otherwise.
                  decoration: InputDecoration(
                    isCollapsed: true,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    hintText: widget.hint,
                    hintStyle: TextStyle(fontSize: type.body, color: c.ink3),
                  ),
                  style: TextStyle(fontSize: type.body, color: c.ink),
                ),
              ),
              if (widget.obscure &&
                  widget.showLabel != null &&
                  widget.hideLabel != null)
                Tooltip(
                  message: _revealed ? widget.hideLabel! : widget.showLabel!,
                  child: Pressable(
                    onTap: () => setState(() => _revealed = !_revealed),
                    radius: WhisperRadius.xs,
                    label: _revealed ? widget.hideLabel : widget.showLabel,
                    scale: 1,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
                      child: WhisperIcon(
                        // What it is now: shut while hidden, open while shown.
                        _revealed ? WhisperGlyph.eye : WhisperGlyph.eyeOff,
                        size: 18,
                        weight: 1.4,
                        color: c.ink2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 5),
          Text(
            error,
            style: TextStyle(fontSize: type.note, height: 1.3, color: c.bad),
          ),
        ],
      ],
    );
  }
}

/// `.float-bar`: rises from the bottom when there is a selection. A row that
/// does not fit scrolls sideways inside its capsule.
class PhoneFloatBar extends StatelessWidget {
  const PhoneFloatBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    const shape = StadiumBorder();
    return SpringBuilder(
      from: 0,
      value: 1,
      spring: WhisperSprings.smooth,
      animateWhenReduced: true,
      builder: (context, t, child) {
        final p = t.clamp(0.0, 1.0);
        return Opacity(
          opacity: p,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - t)),
            child: Transform.scale(scale: .94 + .06 * t, child: child),
          ),
        );
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.max(0.0, MediaQuery.sizeOf(context).width - 16),
        ),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: shape,
            shadows: WhisperShadow.e2(brightness),
          ),
          child: WhisperGlass(
            kind: GlassKind.control,
            shape: shape,
            child: CustomPaint(
              foregroundPainter: _CapsuleHighlight(
                WhisperShadow.highlight(brightness),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                // 5 all round to look at: the buttons bring 2 of their own.
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, child) in children.indexed) ...[
                      if (i > 0) const SizedBox(width: 2),
                      child,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The hairline along the top of a capsule of glass.
class _CapsuleHighlight extends CustomPainter {
  const _CapsuleHighlight(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.height / 2;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, radius / 2));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(.25),
        Radius.circular(radius),
      ),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = .5,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CapsuleHighlight old) => old.color != color;
}

/// `.win[data-size=compact] .sheet`: from the bottom edge, at most 86% of the
/// screen, with a grab handle and the page's own canvas.
Future<T?> showPhoneSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<T>(
    WhisperModalRoute<T>(
      scrim: context.wc.scrim,
      style: WhisperModalStyle.adaptive,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (sheetContext) => PhoneSheetFrame(child: builder(sheetContext)),
    ),
  );
}

/// The frame of a phone's sheet, without its route.
class PhoneSheetFrame extends StatelessWidget {
  const PhoneSheetFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final media = MediaQuery.of(context);
    final height = media.size.height - media.viewInsets.bottom;
    // 弹层 are bottom sheets in the compact size class and centred beside a
    // sidebar, and one that is open changes when the device folds.
    if (!WhisperLayout.of(context).compact) {
      return Center(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            WhisperWindow.sheetGap / 2,
            20,
            WhisperWindow.sheetGap / 2 + media.viewInsets.bottom,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: c.raised,
                borderRadius: BorderRadius.circular(WhisperRadius.l),
                boxShadow: WhisperShadow.e3(Theme.of(context).brightness),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(WhisperRadius.l),
                child: Material(
                  type: MaterialType.transparency,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height * .86),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.canvas,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(WhisperRadius.sheetTop),
                bottom: Radius.circular(WhisperRadius.sheetBottom),
              ),
              boxShadow: WhisperShadow.e3(Theme.of(context).brightness),
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(WhisperRadius.sheetTop),
                bottom: Radius.circular(WhisperRadius.sheetBottom),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    10,
                    16,
                    30 + media.padding.bottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          key: const ValueKey('phone-sheet-grab'),
                          width: 36,
                          height: 5,
                          decoration: BoxDecoration(
                            color: c.fill2,
                            borderRadius: BorderRadius.circular(
                              WhisperRadius.thumbBar,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      child,
                    ],
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

/// `.sheet h3`.
class PhoneSheetTitle extends StatelessWidget {
  const PhoneSheetTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    const type = WhisperType(touch: true);
    return Text(
      text,
      style: TextStyle(
        fontSize: type.head,
        fontWeight: FontWeight.w600,
        color: context.wc.ink,
      ),
    );
  }
}
