import 'package:flutter/material.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// The settings' groups and rows (docs/design/surfaces.md「设置」). The rest
/// of what they are laid out with is in settings_controls.dart, which also
/// exports this.

/// Whether the rows around here are for a finger, and whether they are on the
/// phone's one long page or in the desktop's panel.
class SettingsScope extends InheritedWidget {
  const SettingsScope({
    super.key,
    required this.touch,
    required this.page,
    required super.child,
  });

  /// Text and targets for a finger.
  final bool touch;

  /// The phone's page: groups have lines and a shadow, and a slider gets a line
  /// of its own. The desktop's panel has neither.
  final bool page;

  static SettingsScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsScope>()!;

  /// The text sizes for the rows around here.
  static WhisperType typeOf(BuildContext context) =>
      WhisperType(touch: of(context).touch);

  @override
  bool updateShouldNotify(SettingsScope old) =>
      touch != old.touch || page != old.page;
}

/// The theme's body style has Material's letter spacing, which spreads Chinese
/// out, and puts the extra line height above the text instead of around it.
/// Everything in the settings is under this.
class SettingsTextStyle extends StatelessWidget {
  const SettingsTextStyle({super.key, required this.child});

  static const style = TextStyle(
    letterSpacing: 0,
    leadingDistribution: TextLeadingDistribution.even,
  );

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      DefaultTextStyle.merge(style: style, child: child);
}

/// A colour that follows the pointer: [hover] under it, [press] while down.
/// Springs, so it never jumps. What a touch screen does not have, it never
/// shows.
class SettingsHighlight extends StatefulWidget {
  const SettingsHighlight({
    super.key,
    required this.child,
    this.base,
    this.hover,
    this.press,
    this.radius = 0,
  });

  final Widget child;
  final Color? base, hover, press;
  final double radius;

  @override
  State<SettingsHighlight> createState() => _SettingsHighlightState();
}

class _SettingsHighlightState extends State<SettingsHighlight> {
  bool _hovered = false, _down = false;

  void _setDown(bool down) {
    if (down != _down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Listener(
      onPointerDown: (_) => _setDown(true),
      onPointerUp: (_) => _setDown(false),
      onPointerCancel: (_) => _setDown(false),
      child: SpringBuilder(
        value: _hovered ? 1 : 0,
        spring: WhisperSprings.snappy,
        animateWhenReduced: true,
        child: widget.child,
        builder: (context, h, child) => SpringBuilder(
          value: _down ? 1 : 0,
          spring: WhisperSprings.snappy,
          animateWhenReduced: true,
          child: child,
          builder: (context, p, child) {
            final hover = widget.hover ?? widget.base;
            final over = Color.lerp(widget.base, hover, h.clamp(0.0, 1.0));
            final color = widget.press == null
                ? over
                : Color.lerp(over, widget.press, p.clamp(0.0, 1.0));
            return DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(widget.radius),
              ),
              child: child,
            );
          },
        ),
      ),
    ),
  );
}

/// The white paper the rows sit on. In the panel it has no lines and no shadow;
/// on the page lines start where the text starts.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final page = SettingsScope.of(context).page;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(WhisperRadius.m),
    );
    final rows = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, child) in children.indexed)
          SettingsRowLine(show: page && i > 0, child: child),
      ],
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: c.group,
        shape: shape,
        shadows: page ? WhisperShadow.e1(Theme.of(context).brightness) : null,
      ),
      // A pressed or hovered row must not reach past the corners.
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: page
            ? rows
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: rows,
              ),
      ),
    );
  }
}

/// Each row draws its own line, so a row that turns out to have nothing to show
/// leaves no doubled line behind.
class SettingsRowLine extends InheritedWidget {
  const SettingsRowLine({super.key, required this.show, required super.child});

  final bool show;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsRowLine>()?.show ??
      false;

  @override
  bool updateShouldNotify(SettingsRowLine old) => show != old.show;
}

class _TopLine extends CustomPainter {
  const _TopLine({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(
        SettingsRowFrame.pageInset,
        0,
        size.width - SettingsRowFrame.pageInset,
        width,
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_TopLine old) => old.color != color || old.width != width;
}

/// The height, the padding and the line every row shares.
class SettingsRowFrame extends StatelessWidget {
  const SettingsRowFrame({
    super.key,
    required this.child,
    this.minHeight,
    this.vertical,
    this.inset,
  });

  /// How far in rows start: on the phone's page, and in the desktop's panel.
  static const pageInset = 12.0, panelInset = 14.0;

  final Widget child;
  final double? minHeight, vertical, inset;

  @override
  Widget build(BuildContext context) {
    final scope = SettingsScope.of(context);
    final frame = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: minHeight ?? (scope.touch ? 48 : 44),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: inset ?? (scope.page ? pageInset : panelInset),
          vertical: vertical ?? (scope.touch ? 0 : 6),
        ),
        child: child,
      ),
    );
    if (!SettingsRowLine.of(context)) return frame;
    return CustomPaint(
      foregroundPainter: _TopLine(
        color: context.wc.sep,
        width: 1 / MediaQuery.devicePixelRatioOf(context),
      ),
      child: frame,
    );
  }
}

/// A title, and maybe a line under it. Never squeezed out of a row: long ones
/// wrap, because a setting's name is what the row is.
class SettingsRowTitle extends StatelessWidget {
  const SettingsRowTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.color,
    this.pathSubtitle = false,
  });

  final String title;
  final String? subtitle;

  /// The title's, `ink` unless given.
  final Color? color;

  /// [subtitle] is a path, kept to one line by losing its start.
  final bool pathSubtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = SettingsScope.typeOf(context);
    return Padding(
      // On a touch row the frame has no padding of its own: its controls need
      // the whole height. Text that wraps still should not touch the edges.
      padding: EdgeInsets.symmetric(
        vertical: SettingsScope.of(context).touch ? 4 : 0,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: type.body,
              height: 1.3,
              color: color ?? c.ink,
            ),
          ),
          if (subtitle case final subtitle? when subtitle.isNotEmpty)
            pathSubtitle
                ? SettingsPathText(subtitle)
                : Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: type.note,
                      height: 1.3,
                      color: c.ink2,
                    ),
                  ),
        ],
      ),
    );
  }
}

/// A row in a group. [trailing] stays beside the title and is never wider than
/// it can be: past 60% it has to give way, so a value can ellipsize and a
/// control cannot overflow.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.titleColor,
    this.pathSubtitle = false,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.fillTrailing = false,
    this.stackWhenTight = false,
    this.minHeight,
    this.inset,
    this.below,
    this.semanticLabel,
  });

  final String title;
  final String? subtitle;

  /// An icon before the title, in a column of 28.
  final Widget? leading;
  final Color? titleColor;
  final bool pathSubtitle;
  final Widget? trailing;

  /// The whole row does this, like a button.
  final VoidCallback? onTap, onLongPress;

  /// The title takes what it needs and [trailing] the rest: an inline field, a
  /// path.
  final bool fillTrailing;

  /// A control that cannot get narrower, like a segmented one, goes under the
  /// title when it does not fit beside it.
  final bool stackWhenTight;

  final double? minHeight, inset;

  /// Under the row, full width: a progress bar.
  final Widget? below;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final scope = SettingsScope.of(context);
    Widget heading = SettingsRowTitle(
      title: title,
      subtitle: subtitle,
      color: titleColor,
      pathSubtitle: pathSubtitle,
    );
    if (leading case final leading?) {
      heading = Row(
        children: [
          SizedBox(width: 28, child: Center(child: leading)),
          const SizedBox(width: 10),
          Expanded(child: heading),
        ],
      );
    }
    final Widget content;
    if (trailing == null) {
      content = Align(alignment: Alignment.centerLeft, child: heading);
    } else if (stackWhenTight) {
      // Align: an OverflowBar centres on its own height, not the row's.
      content = Align(
        child: OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          overflowAlignment: OverflowBarAlignment.end,
          spacing: 10,
          overflowSpacing: 4,
          children: [heading, trailing!],
        ),
      );
    } else {
      content = LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            if (fillTrailing)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * .5),
                child: heading,
              )
            else
              Expanded(child: heading),
            const SizedBox(width: 10),
            if (fillTrailing)
              Expanded(child: trailing!)
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * .6),
                child: trailing!,
              ),
          ],
        ),
      );
    }
    Widget row = SettingsRowFrame(
      minHeight: minHeight,
      inset: inset,
      child: content,
    );
    if (below != null) {
      row = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [row, below!],
      );
    }
    if (onTap == null && onLongPress == null) return row;
    row = Pressable(
      scale: 1,
      radius: scope.page ? 0 : WhisperRadius.xs,
      label: semanticLabel,
      onTap: onTap,
      child: SettingsHighlight(
        hover: scope.touch ? null : c.fill,
        press: scope.touch ? c.fill : c.fill2,
        child: row,
      ),
    );
    return onLongPress == null
        ? row
        : GestureDetector(onLongPress: onLongPress, child: row);
  }
}

/// A row that is a switch. The whole row flips it, as it always has here.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.leading,
    this.pathSubtitle = false,
    this.minHeight,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool pathSubtitle;
  final double? minHeight;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: subtitle == null ? title : '$title, $subtitle',
      enabled: onChanged != null,
      toggled: value,
      onTap: onChanged == null ? null : () => onChanged(!value),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onChanged == null ? null : () => onChanged(!value),
        child: SettingsRow(
          title: title,
          subtitle: subtitle,
          leading: leading,
          pathSubtitle: pathSubtitle,
          minHeight: minHeight,
          trailing: Align(
            alignment: Alignment.centerRight,
            widthFactor: 1,
            child: WhisperSwitch(
              value: value,
              onChanged: onChanged,
              label: title,
            ),
          ),
        ),
      ),
    );
  }
}

/// What a row reads now, quiet, on the right.
class SettingsValue extends StatelessWidget {
  const SettingsValue(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.end,
    style: TextStyle(
      fontSize: SettingsScope.typeOf(context).body,
      height: 1.3,
      fontWeight: color == null ? FontWeight.w400 : FontWeight.w500,
      color: color ?? context.wc.ink2,
    ),
  );
}

/// A value and the arrow to where it is changed.
class SettingsDisclosure extends StatelessWidget {
  const SettingsDisclosure({super.key, this.value});

  final String? value;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      if (value != null && value!.isNotEmpty) ...[
        Flexible(child: SettingsValue(value!)),
        const SizedBox(width: 10),
      ],
      // The stroke sits inside its box: moved over, it ends where a switch ends.
      Transform.translate(
        offset: const Offset(3, 0),
        child: WhisperIcon(
          WhisperGlyph.right,
          size: 13,
          weight: 2,
          color: context.wc.ink3,
        ),
      ),
    ],
  );
}

/// A path that does not fit loses its start: the end is the part that says
/// where the files go.
class SettingsPathText extends StatelessWidget {
  const SettingsPathText(this.path, {super.key});

  final String path;

  @override
  Widget build(BuildContext context) {
    final style = SettingsTextStyle.style.copyWith(
      fontSize: SettingsScope.typeOf(context).note,
      color: context.wc.ink2,
    );
    return LayoutBuilder(
      builder: (context, box) {
        final direction = Directionality.of(context);
        final scaler = MediaQuery.textScalerOf(context);
        double widthOf(String text) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width;
        }

        var shown = path;
        if (widthOf(path) > box.maxWidth) {
          var low = 0, high = path.length;
          while (low < high) {
            final drop = (low + high) ~/ 2;
            if (widthOf('…${path.substring(drop)}') <= box.maxWidth) {
              high = drop;
            } else {
              low = drop + 1;
            }
          }
          shown = '…${path.substring(low)}';
        }
        return Text(shown, maxLines: 1, softWrap: false, style: style);
      },
    );
  }
}

/// The small label over a group on the phone's page.
class SettingsGroupLabel extends StatelessWidget {
  const SettingsGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: SettingsScope.typeOf(context).note,
        fontWeight: FontWeight.w500,
        color: context.wc.ink2,
      ),
    ),
  );
}
