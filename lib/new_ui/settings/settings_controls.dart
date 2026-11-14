import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/helper/screenshot_shortcut.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

import 'settings_menu.dart';
import 'settings_rows.dart';

export 'settings_field.dart';
export 'settings_menu.dart';
export 'settings_rows.dart';

/// What the settings are laid out with (docs/design/surfaces.md「设置」). None
/// of this knows about any one setting: lib/page/settings.dart says what is in
/// each row and what it does.

/// The small button of a settings row; light unless [filled].
class SettingsButton extends StatelessWidget {
  const SettingsButton({
    super.key,
    required this.label,
    required this.onTap,
    this.filled = false,
    this.large = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool filled, large;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final scope = SettingsScope.of(context);
    final type = SettingsScope.typeOf(context);
    final height = scope.touch ? (large ? 48.0 : 44.0) : (large ? 36.0 : 28.0);
    final inset = scope.touch ? 16.0 : (large ? 20.0 : 13.0);
    return Pressable(
      onTap: onTap,
      radius: WhisperRadius.capsule,
      child: SettingsHighlight(
        base: filled ? c.accent : c.fill,
        hover: filled ? c.accent : c.fill2,
        press: filled ? c.accent : c.fill2,
        radius: WhisperRadius.capsule,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: large ? type.body : type.note,
                  fontWeight: FontWeight.w500,
                  color: filled ? c.onAccent : c.ink,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 2 or 3 choices. On a touch screen the visible control is 34 high and its
/// target is the row's height: taps in the bands above and below it pick the
/// segment they are over.
class SettingsSegmented<T> extends StatefulWidget {
  const SettingsSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  State<SettingsSegmented<T>> createState() => _SettingsSegmentedState<T>();
}

class _SettingsSegmentedState<T> extends State<SettingsSegmented<T>> {
  final _keys = <T, GlobalKey>{};

  void _tapBand(TapUpDetails details) {
    for (final entry in _keys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final left = box.localToGlobal(Offset.zero).dx;
      final right = box.localToGlobal(box.size.topRight(Offset.zero)).dx;
      if (details.globalPosition.dx >= left &&
          details.globalPosition.dx <= right) {
        widget.onChanged(entry.key);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final touch = SettingsScope.of(context).touch;
    final type = SettingsScope.typeOf(context);
    final fontSize = touch ? type.note : type.tiny;
    // The cells have a fixed height: with large text they have to grow with it.
    final lineHeight = MediaQuery.textScalerOf(context).scale(fontSize) * 1.5;
    final segmented = LiquidSegmented<T>(
      segments: widget.segments,
      selected: widget.selected,
      onChanged: widget.onChanged,
      labelKeys: _keys,
      height: math.max(touch ? 34 : 26, lineHeight + 8),
      fontSize: fontSize,
      minSegmentWidth: touch ? 40 : 32,
      segmentPadding: 9,
    );
    // Very large text on a narrow screen: smaller beats cut off.
    final fitted = FittedBox(fit: BoxFit.scaleDown, child: segmented);
    if (!touch) return fitted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _tapBand,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: fitted,
      ),
    );
  }
}

/// One thing a [SettingsPopupButton] offers.
@immutable
/// A continuous number: slider and value. In the panel on one line, on the
/// phone's page with a line of its own for the slider, so it can be wide.
class SettingsSliderRow extends StatelessWidget {
  const SettingsSliderRow({
    super.key,
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
    this.hint,
  });

  final String title, valueLabel;
  final String? hint;
  final double value, min, max;
  final int divisions;
  final ValueChanged<double> onChanged, onChangeEnd;

  static const _maxWidth = 240.0, _minWidth = 120.0, _valueWidth = 38.0;

  double _sliderWidth(BuildContext context, double row) {
    final painter = TextPainter(
      text: TextSpan(
        text: title,
        style: SettingsTextStyle.style.copyWith(
          fontSize: SettingsScope.typeOf(context).body,
          height: 1.3,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final titleWidth = painter.width;
    painter.dispose();
    return (row - titleWidth - 10).clamp(_minWidth, _maxWidth);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final scope = SettingsScope.of(context);
    final type = SettingsScope.typeOf(context);
    final label = Text(
      valueLabel,
      textAlign: TextAlign.end,
      maxLines: 1,
      style: TextStyle(
        fontSize: type.note,
        color: c.ink2,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final slider = Semantics(
      label: title,
      child: SliderTheme(
        data: whisperSliderTheme(context, touch: scope.touch),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
          semanticFormatterCallback: (_) => valueLabel,
        ),
      ),
    );
    if (scope.page) {
      return SettingsRowFrame(
        vertical: 8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: type.body,
                      height: 1.3,
                      color: c.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                label,
              ],
            ),
            const SizedBox(height: 4),
            _TallTarget(visible: 32, target: 48, child: slider),
            const SizedBox(height: 2),
            if (hint != null)
              Text(
                hint!,
                style: TextStyle(
                  fontSize: type.tiny,
                  height: 1.4,
                  color: c.ink2,
                ),
              ),
          ],
        ),
      );
    }
    return SettingsRowFrame(
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            Expanded(child: SettingsRowTitle(title: title)),
            const SizedBox(width: 10),
            SizedBox(
              width: _sliderWidth(context, box.maxWidth),
              child: Row(
                children: [
                  Expanded(child: slider),
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: _valueWidth),
                    child: label,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Takes [visible] of the layout and answers to taps over [target]: a thin
/// control on a touch screen, whose neighbours should not move away from it.
/// Only for what sits inside a parent tall enough to reach it.
class _TallTarget extends SingleChildRenderObjectWidget {
  const _TallTarget({
    required this.visible,
    required this.target,
    required super.child,
  });

  final double visible, target;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTallTarget(visible, target);

  @override
  void updateRenderObject(BuildContext context, _RenderTallTarget object) {
    object
      ..visible = visible
      ..target = target
      ..markNeedsLayout();
  }
}

class _RenderTallTarget extends RenderShiftedBox {
  _RenderTallTarget(this.visible, this.target) : super(null);

  double visible, target;

  @override
  void performLayout() {
    child!.layout(
      BoxConstraints.tightFor(width: constraints.maxWidth, height: target),
    );
    size = constraints.constrain(Size(constraints.maxWidth, visible));
    (child!.parentData! as BoxParentData).offset = Offset(
      0,
      (visible - target) / 2,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!hitTestChildren(result, position: position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}

/// A row that comes and goes, for example with the switch above it. Its height
/// springs with it, so the rows below slide instead of jumping.
class SettingsCollapse extends StatelessWidget {
  const SettingsCollapse({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => SpringBuilder(
    value: visible ? 1 : 0,
    builder: (context, t, _) {
      final open = t.clamp(0.0, 1.0);
      if (!visible && open <= .001) return const SizedBox.shrink();
      return ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: open,
          child: Opacity(opacity: open, child: child),
        ),
      );
    },
  );
}

/// A shortcut: a button that records the next combination pressed. Esc gives
/// up. Global shortcuts wait meanwhile, so pressing the current one records it
/// instead of taking a screenshot.
class SettingsShortcutButton extends StatefulWidget {
  const SettingsShortcutButton({
    super.key,
    required this.controller,
    required this.title,
    required this.onError,
  });

  final DesktopScreenshotController controller;
  final String title;
  final ValueChanged<String> onError;

  @override
  State<SettingsShortcutButton> createState() => _SettingsShortcutButtonState();
}

class _SettingsShortcutButtonState extends State<SettingsShortcutButton> {
  // Keys go through focus and not HardwareKeyboard's handlers, which the focus
  // system does not stop for: Esc would give up and close the panel as well.
  late final _focus = FocusNode(onKeyEvent: _onKey, skipTraversal: true);
  bool _recording = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _end();
    });
  }

  void _begin() {
    if (_recording || widget.controller.configuring) return;
    widget.controller.shortcutsPaused = true;
    _focus.requestFocus();
    setState(() => _recording = true);
  }

  void _end() {
    if (!_recording) return;
    _recording = false;
    widget.controller.shortcutsPaused = false;
    _focus.unfocus();
    if (mounted) setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_recording) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) _end();
      return KeyEventResult.handled;
    }
    final candidate = ScreenshotShortcut.fromKeyEvent(event);
    if (candidate != null) {
      _end();
      unawaited(_apply(candidate));
    }
    return KeyEventResult.handled;
  }

  Future<void> _apply(ScreenshotShortcut candidate) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await widget.controller.configure(candidate, enabled: true);
    } on PlatformException catch (error) {
      widget.onError(
        error.code == 'shortcut-invalid'
            ? l10n.screenshotShortcutInvalid
            : l10n.screenshotShortcutFailed,
      );
    } catch (_) {
      widget.onError(l10n.screenshotShortcutFailed);
    }
  }

  @override
  void dispose() {
    _recording = false;
    widget.controller.shortcutsPaused = false;
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = SettingsScope.typeOf(context);
    final touch = SettingsScope.of(context).touch;
    final l10n = AppLocalizations.of(context)!;
    final text = _recording
        ? l10n.shellSettingsPressShortcut
        : widget.controller.shortcutLabel;
    final button = Pressable(
      radius: WhisperRadius.s,
      label: '${widget.title}, $text',
      onTap: _recording ? _end : _begin,
      child: SettingsHighlight(
        base: _recording ? c.accent : c.fill,
        hover: _recording ? c.accent : c.fill2,
        radius: WhisperRadius.s,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: touch ? 34 : 28, minWidth: 76),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: type.note,
                  fontWeight: FontWeight.w500,
                  color: _recording ? c.onAccent : c.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Focus(focusNode: _focus, child: button);
  }
}

/// Status and one action for something a setting cannot just switch: a system
/// service, a desktop helper. The hint wraps under the title; the state never
/// does.
class SettingsServiceRow extends StatelessWidget {
  const SettingsServiceRow({
    super.key,
    required this.title,
    this.hint,
    required this.status,
    this.action,
    this.onAction,
    this.extra,
    this.onTap,
  });

  final String title, status;
  final String? hint;
  final String? action;
  final VoidCallback? onAction;

  /// One more control at the end of the row.
  final Widget? extra;

  /// The row itself, when there is nothing to press but something to read.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => SettingsRow(
    title: title,
    subtitle: hint,
    minHeight: 58,
    onTap: onTap,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const SizedBox(width: 8),
        Flexible(child: SettingsValue(status)),
        if (action != null) ...[
          const SizedBox(width: 18),
          SettingsButton(label: action!, onTap: onAction),
        ],
        if (extra != null) ...[const SizedBox(width: 10), extra!],
      ],
    ),
  );
}

/// The coloured tile of a section.
class SettingsTile extends StatelessWidget {
  const SettingsTile({super.key, required this.glyph, required this.color});

  /// Null is this computer's laptop, drawn a little larger, as it has no
  /// outline to fill the tile with.
  final WhisperGlyph? glyph;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 22,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(WhisperRadius.xs),
      ),
      child: CustomPaint(
        foregroundPainter: const SettingsGlassEdge(
          radius: WhisperRadius.xs,
          color: WhisperSettingsIcons.highlight,
        ),
        child: Center(
          child: glyph == null
              ? DeviceGlyph(
                  kind: DeviceKind.laptop,
                  color: context.wc.onAccent,
                  size: 16,
                )
              : WhisperIcon(
                  glyph!,
                  size: 13,
                  weight: 1.9,
                  color: context.wc.onAccent,
                ),
        ),
      ),
    ),
  );
}

/// A section in the panel's list. The selection fades across: the rows do not
/// move, so there is nothing for it to travel with.
class SettingsNavItem extends StatelessWidget {
  const SettingsNavItem({
    super.key,
    required this.title,
    required this.glyph,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final WhisperGlyph? glyph;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = SettingsScope.typeOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Pressable(
        scale: 1,
        radius: WhisperRadius.m,
        selected: selected,
        onTap: onTap,
        child: SettingsHighlight(
          base: selected ? c.selected : null,
          hover: selected ? c.selected : c.fill,
          radius: WhisperRadius.m,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                children: [
                  SettingsTile(glyph: glyph, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: type.body,
                        height: 1.3,
                        fontWeight: selected
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: c.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The panel's way out, top right.
class SettingsCloseButton extends StatelessWidget {
  const SettingsCloseButton({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    return Tooltip(
      message: label,
      child: Pressable(
        radius: WhisperRadius.xs,
        label: label,
        onTap: onTap,
        child: SettingsHighlight(
          hover: c.fill,
          press: c.fill2,
          radius: WhisperRadius.xs,
          child: SizedBox.square(
            dimension: 28,
            child: Center(
              child: WhisperIcon(
                WhisperGlyph.x,
                size: 14,
                weight: 2,
                color: c.ink2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The about panel: what this is, which version, where to find out more. A
/// sheet on a phone, a panel elsewhere.
class SettingsAboutSheet extends StatelessWidget {
  const SettingsAboutSheet({
    super.key,
    required this.icon,
    required this.name,
    required this.description,
    required this.version,
    required this.links,
    required this.doneLabel,
  });

  final Widget icon;
  final String name, description, version, doneLabel;

  /// Label and action, in order.
  final List<(String, VoidCallback)> links;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final scope = SettingsScope.of(context);
    final type = SettingsScope.typeOf(context);
    final brightness = Theme.of(context).brightness;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: icon),
        const SizedBox(height: 8),
        Text(
          name,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: type.title,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: type.note, color: c.ink2),
        ),
        const SizedBox(height: 4),
        Text(
          version,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: type.note, color: c.ink2),
        ),
        const SizedBox(height: 14),
        DecoratedBox(
          decoration: ShapeDecoration(
            color: scope.page ? c.group : c.fill,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(WhisperRadius.m),
            ),
            shadows: scope.page ? WhisperShadow.e1(brightness) : null,
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(WhisperRadius.m),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, (label, open)) in links.indexed)
                  SettingsRowLine(
                    show: scope.page && i > 0,
                    child: SettingsRow(
                      title: label,
                      onTap: open,
                      minHeight: scope.touch ? 48 : 40,
                      inset: SettingsRowFrame.pageInset,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: SettingsButton(
            filled: true,
            label: doneLabel,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    );
    if (scope.page) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: c.canvas,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(WhisperRadius.l),
            ),
          ),
          child: SettingsTextStyle(
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: SizedBox(
                        width: 36,
                        height: 5,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: c.fill2,
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    content,
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: c.raised,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(WhisperRadius.l),
              ),
              shadows: WhisperShadow.e3(brightness),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: SettingsTextStyle(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
