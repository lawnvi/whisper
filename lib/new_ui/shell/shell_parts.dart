import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:whisper/helper/device_form_factor.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';
import 'package:window_manager/window_manager.dart';

/// What [device] looks like, tablets by what they said about themselves.
DeviceKind deviceKindOf(DeviceData device) => deviceKindFor(
  device.platform,
  name: device.name,
  tablet: DeviceFormFactors.shared.isTablet(device.uid),
);

/// A device's kind and wallpaper.
DeviceArt deviceArtFor(
  DeviceData device, {
  required double size,
  DeviceArtState state = DeviceArtState.normal,
  bool paired = true,
}) {
  // By pairing order, so reordering the list does not repaint anyone.
  final wall = paired
      ? DeviceWallpaper.forPairingOrder(device.id)
      : DeviceWallpaper.unpaired;
  return DeviceArt(
    kind: deviceKindOf(device),
    wallpaper: wall,
    size: size,
    state: state,
  );
}

/// What the touch shell does for back, set while it is on screen.
VoidCallback? shellBackHandler;

/// Leaves the page this is in. A tab of a device is the first page of the
/// content area's navigator, so back from it is for the shell to decide: the
/// card it came from, or the list.
Future<void> shellMaybePop(BuildContext context) async {
  final handler = shellBackHandler;
  if (handler != null && (ModalRoute.of(context)?.isFirst ?? false)) {
    handler();
    return;
  }
  await Navigator.of(context).maybePop();
}

/// Where a window sent to a device flies to: that device's row in the sidebar.
abstract final class ShellFlyTargets {
  static final Map<String, GlobalKey> _rows = {};

  static GlobalKey keyFor(String peerId) =>
      _rows.putIfAbsent(peerId, GlobalKey.new);

  static GlobalKey? rowOf(String peerId) => _rows[peerId];
}

/// The height of a toolbar, in which blank space moves the window. That area
/// sits behind the controls: around them, its double tap would hold their taps
/// back by 300 ms.
class ToolbarBand extends StatelessWidget {
  const ToolbarBand({super.key, required this.child});

  final Widget child;

  static const double height = 52;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Stack(
      fit: StackFit.expand,
      children: [
        const DragToMoveArea(child: SizedBox.expand()),
        child,
      ],
    ),
  );
}

/// `.iconbtn`: 28, 48 on a phone. Hover and press come from [Pressable].
class ShellIconButton extends StatelessWidget {
  const ShellIconButton({
    super.key,
    required this.glyph,
    required this.label,
    required this.onTap,
    this.iconSize = 16,
    this.weight = 1.6,
    this.color,
    this.active = false,
    this.selected = false,
    this.pressed = false,
    this.touch = false,
  });

  final WhisperGlyph glyph;
  final String label;
  final VoidCallback? onTap;
  final double iconSize, weight;
  final Color? color;

  /// Running right now: the icon is in the accent colour.
  final bool active;

  /// What it opens is open: `selected` behind it.
  final bool selected;

  /// A toggle that is on: accent on `fill`, like the info button.
  final bool pressed;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final dimension = touch ? 48.0 : 28.0;
    final tint = pressed || active ? c.accent : (color ?? c.ink2);
    final background = pressed ? c.fill : (selected ? c.selected : null);
    return Tooltip(
      message: label,
      child: Pressable(
        onTap: onTap,
        radius: WhisperRadius.xs,
        label: label,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(WhisperRadius.xs),
          ),
          child: SizedBox.square(
            dimension: dimension,
            child: Center(
              child: WhisperIcon(
                glyph,
                size: iconSize,
                weight: weight,
                color: tint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum ShellButtonKind { normal, primary, quiet, danger }

/// What goes beside the tabs goes in the same kind of capsule: the same height,
/// the same fill, and for what is open the same raised thumb. Without a capsule
/// the icons look like they belong to something else. 48 to hit on touch.
class ShellToolCapsule extends StatelessWidget {
  const ShellToolCapsule({
    super.key,
    required this.children,
    this.touch = false,
  });

  final List<Widget> children;
  final bool touch;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Positioned(
        left: 0,
        right: 0,
        child: Container(
          height: touch ? 36 : 30,
          decoration: BoxDecoration(
            color: context.wc.fill,
            borderRadius: BorderRadius.circular(WhisperRadius.capsule),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ],
  );
}

class ShellToolCapsuleItem extends StatelessWidget {
  const ShellToolCapsuleItem({
    super.key,
    required this.glyph,
    required this.label,
    required this.onTap,
    this.color,
    this.selected = false,
    this.busy = false,
    this.touch = false,
    this.iconSize,
    this.weight = 1.6,
  });

  final WhisperGlyph glyph;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final bool selected, busy, touch;
  final double? iconSize;
  final double weight;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final inner = touch ? 32.0 : 26.0;
    final size = iconSize ?? (touch ? 19.0 : 15.0);
    return Tooltip(
      message: label,
      child: Pressable(
        onTap: busy ? null : onTap,
        radius: WhisperRadius.capsule,
        scale: .92,
        label: label,
        child: SizedBox(
          width: touch ? 40 : 30,
          height: touch ? 48 : 30,
          child: Center(
            child: Container(
              width: touch ? 38 : 28,
              height: inner,
              alignment: Alignment.center,
              decoration: selected
                  ? BoxDecoration(
                      color: c.raised,
                      borderRadius: BorderRadius.circular(
                        WhisperRadius.capsule,
                      ),
                      boxShadow: WhisperShadow.e1(Theme.of(context).brightness),
                    )
                  : null,
              child: busy
                  ? SizedBox.square(
                      dimension: size - 2,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color ?? c.ink2,
                      ),
                    )
                  : WhisperIcon(
                      glyph,
                      size: size,
                      weight: weight,
                      color: color ?? c.ink2,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.btn`: 28 high, 36 when large, 44 and 48 on a phone.
class ShellButton extends StatelessWidget {
  const ShellButton({
    super.key,
    required this.label,
    required this.onTap,
    this.kind = ShellButtonKind.normal,
    this.large = false,
    this.touch = false,
    this.glyph,
    this.color,
  });

  final String label;
  final VoidCallback? onTap;
  final ShellButtonKind kind;
  final bool large, touch;
  final WhisperGlyph? glyph;

  /// Only for a quiet button with a meaning of its own: 删除 in `bad`.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: touch);
    final height = touch ? (large ? 48.0 : 44.0) : (large ? 36.0 : 28.0);
    final background = switch (kind) {
      ShellButtonKind.normal => c.fill,
      ShellButtonKind.primary => c.accent,
      ShellButtonKind.quiet => Colors.transparent,
      ShellButtonKind.danger => c.bad,
    };
    final foreground = switch (kind) {
      ShellButtonKind.normal => c.ink,
      ShellButtonKind.primary || ShellButtonKind.danger => c.onAccent,
      ShellButtonKind.quiet => color ?? c.accent,
    };
    return Opacity(
      opacity: onTap == null ? .5 : 1,
      child: Pressable(
        onTap: onTap,
        radius: WhisperRadius.capsule,
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: large ? 20 : 13),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(WhisperRadius.capsule),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            // In the middle when something stretches the button.
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (glyph != null) ...[
                WhisperIcon(glyph!, size: 13, color: foreground),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: large ? type.body : type.note,
                  fontWeight: FontWeight.w500,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The filled button of a page with one thing to do.
class ShellFilledButton extends StatelessWidget {
  const ShellFilledButton({
    super.key,
    required this.label,
    required this.onTap,
    this.touch = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool touch;

  @override
  Widget build(BuildContext context) => ShellButton(
    label: label,
    onTap: onTap,
    kind: ShellButtonKind.primary,
    large: true,
    touch: touch,
  );
}

/// `.sw`: 38 by 22, the knob widens while pressed. 48 of touch target on a phone.
class ShellSwitch extends StatefulWidget {
  const ShellSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.touch = false,
  });

  final bool value, touch;
  final ValueChanged<bool>? onChanged;
  final String label;

  @override
  State<ShellSwitch> createState() => _ShellSwitchState();
}

class _ShellSwitchState extends State<ShellSwitch> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final enabled = widget.onChanged != null;
    final value = widget.value;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: widget.label,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : .5,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: enabled ? () => widget.onChanged!(!value) : null,
          child: Padding(
            padding: widget.touch
                ? const EdgeInsets.symmetric(horizontal: 5, vertical: 13)
                : EdgeInsets.zero,
            child: SpringBuilder(
              value: value ? 1 : 0,
              spring: WhisperSprings.snappy,
              builder: (context, t, _) {
                final width = _down ? 22.0 : 18.0;
                return Container(
                  width: 38,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Color.lerp(c.fill2, c.accent, t.clamp(0, 1)),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        left: 2 + (34 - width) * t.clamp(0, 1),
                        top: 2,
                        width: width,
                        height: 18,
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.all(Radius.circular(9)),
                            boxShadow: WhisperShadow.knob,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// `.group`: rows on one surface, with inset hairlines between them.
class ShellGroup extends StatelessWidget {
  const ShellGroup({
    super.key,
    required this.children,
    this.inset = 12,
    this.flat = false,
  });

  final List<Widget> children;
  final double inset;

  /// On a surface that is raised already, as in a sheet.
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final hairline = 1 / MediaQuery.devicePixelRatioOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: flat ? c.fill : c.group,
        borderRadius: BorderRadius.circular(WhisperRadius.m),
        boxShadow: flat ? null : WhisperShadow.e1(Theme.of(context).brightness),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WhisperRadius.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, child) in children.indexed) ...[
              if (i > 0)
                Padding(
                  padding: EdgeInsets.only(left: inset),
                  child: SizedBox(
                    height: hairline,
                    child: ColoredBox(color: c.sep),
                  ),
                ),
              child,
            ],
          ],
        ),
      ),
    );
  }
}

/// `.row`: 40 high, 48 on a phone. Text on the left, whatever goes on the right.
class ShellRow extends StatelessWidget {
  const ShellRow({
    super.key,
    required this.label,
    this.trailing,
    this.onTap,
    this.touch = false,
    this.dim = false,
    this.color,
    this.chevron = false,
  });

  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool touch, dim, chevron;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: touch);
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: touch ? 48 : 40),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: type.body,
                  height: 1.3,
                  color: color ?? c.ink,
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 10), trailing!],
            if (chevron) ...[
              const SizedBox(width: 10),
              WhisperIcon(
                WhisperGlyph.right,
                size: 13,
                weight: 2,
                color: c.ink3,
              ),
            ],
          ],
        ),
      ),
    );
    return Opacity(
      opacity: dim ? .5 : 1,
      child: onTap == null
          ? row
          : Pressable(onTap: onTap, radius: 0, scale: 1, child: row),
    );
  }
}

/// `.glabel`: the small heading over a group.
class ShellGroupLabel extends StatelessWidget {
  const ShellGroupLabel(this.text, {super.key, this.touch = false});

  final String text;
  final bool touch;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: WhisperType(touch: touch).note,
        fontWeight: FontWeight.w500,
        color: context.wc.ink2,
      ),
    ),
  );
}

/// `.sheet`: one thing to read or decide over a dim window, 380 wide.
Future<T?> showShellSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double width = 380,
  bool scrolls = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: context.wc.scrim,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 20,
          vertical: WhisperWindow.sheetGap / 2,
        ),
        child: SpringBuilder(
          from: .96,
          value: 1,
          spring: WhisperSprings.smooth,
          builder: (context, s, child) =>
              Transform.scale(scale: s, child: child),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.wc.raised,
                borderRadius: BorderRadius.circular(WhisperRadius.l),
                boxShadow: WhisperShadow.e3(Theme.of(context).brightness),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(WhisperRadius.l),
                child: Material(
                  type: MaterialType.transparency,
                  child: scrolls
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: builder(context),
                        )
                      : builder(context),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// What a tall sheet holds, for `showShellSheet(scrolls: false)`: in a short
/// window the content scrolls and its buttons stay in reach.
class ShellSheetBody extends StatelessWidget {
  const ShellSheetBody({
    super.key,
    required this.content,
    required this.actions,
  });

  final Widget content, actions;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
          child: content,
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: actions,
      ),
    ],
  );
}

/// The toolbar and body of a page that is not about one device, with the
/// `tint` canvas behind it.
class ShellPlaceFrame extends StatelessWidget {
  const ShellPlaceFrame({
    super.key,
    required this.title,
    required this.rightInset,
    required this.child,
    this.end,
    this.titleKey,
    this.controlsKey,
  });

  final String title;
  final double rightInset;
  final Widget child;
  final Widget? end;
  final GlobalKey? titleKey, controlsKey;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    return SpringBuilder(
      from: 0,
      value: 1,
      spring: WhisperSprings.smooth,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, 5 * (1 - t)),
          child: child,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ToolbarBand(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 12 + rightInset, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        key: titleKey,
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
                  if (end case final end?)
                    KeyedSubtree(key: controlsKey, child: end),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A page of the phone's stack: back, a title, and the page on `canvas`.
class ShellPlacePage extends StatelessWidget {
  const ShellPlacePage({
    super.key,
    required this.title,
    required this.child,
    this.end,
  });

  final String title;
  final Widget child;
  final Widget? end;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    return Scaffold(
      backgroundColor: c.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 50,
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  ShellIconButton(
                    glyph: WhisperGlyph.back,
                    iconSize: 20,
                    weight: 2,
                    touch: true,
                    color: c.accent,
                    label: context.shellL10n.back,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 2),
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
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// A device that cannot show this page yet: art, one line, one action.
class ShellDeviceState extends StatelessWidget {
  const ShellDeviceState({
    super.key,
    required this.art,
    required this.title,
    required this.body,
    this.action,
    this.touch = false,
  });

  final Widget art;
  final String title;
  final String body;
  final Widget? action;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: touch);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            art,
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: type.title,
                fontWeight: FontWeight.w600,
                color: c.ink,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: type.body, color: c.ink2),
              ),
            ),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

/// A date for a narrow column: 今天, 昨天, 10月30日, or with the year when it is
/// not this one. A column of 76 has no room for the time.
String shellShortDate(BuildContext context, int ms, {DateTime? now}) {
  final l10n = context.shellL10n;
  final locale = Localizations.localeOf(context).toLanguageTag();
  final value = DateTime.fromMillisecondsSinceEpoch(ms);
  final today = now ?? DateTime.now();
  final days = DateTime(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime(value.year, value.month, value.day)).inDays;
  if (days == 0) return l10n.shellToday;
  if (days == 1) return l10n.shellYesterday;
  return value.year == today.year
      ? DateFormat.Md(locale).format(value)
      : DateFormat.yMd(locale).format(value);
}

extension ShellL10n on BuildContext {
  AppLocalizations get shellL10n => AppLocalizations.of(this)!;
}
