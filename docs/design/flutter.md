# Flutter 实现配方

这些代码已经放进 `lib/theme/whisper_ui.dart`，测试在 `test/whisper_ui_test.dart`（第 0 步），在 Flutter 3.41.7 上过了 `flutter analyze` 和测试。**以后以代码为准，这里是说明和来历。** 覆盖的行为：弹簧改目标保留速度、液体滑块拉伸后归位、切分页不重建页面且不丢内部状态、页面第一次显示才创建、切换途中再切不跳变、减少动态效果时只淡入淡出、依次升起每次重放、回车和空格能触发、滑块命中区够大、进度满了高光停止、路由推拉、气泡贴着最长一行、设备顺序、窗口按钮、尺寸类和折叠姿态。**但还没有放到真实页面里，手感要在真机上再调。**

文件头：

```dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui'
    show DisplayFeature, DisplayFeatureState, DisplayFeatureType, ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
```

规则见 [`DESIGN.md`](../../DESIGN.md)，每个界面怎么用见 [`surfaces.md`](surfaces.md)。

## Token

注册到主题：`ThemeData(extensions: const [WhisperColors.light])`，取用：`context.wc.accent`。

```dart
/// All colors of the design language. Values come from DESIGN.md.
@immutable
class WhisperColors extends ThemeExtension<WhisperColors> {
  const WhisperColors({
    required this.canvas,
    required this.content,
    required this.group,
    required this.raised,
    required this.bubble,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.ink2Glass,
    required this.accent,
    required this.onAccent,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.sep,
    required this.fill,
    required this.fill2,
    required this.selected,
    required this.sidebarSolid,
    required this.sidebarSelected,
    required this.sidebarVeil,
    required this.scrim,
  });

  static const light = WhisperColors(
    canvas: Color(0xFFF5F5F7),
    content: Color(0xFFFFFFFF),
    group: Color(0xFFFFFFFF),
    raised: Color(0xFFFFFFFF),
    bubble: Color(0xFFF2F2F7),
    ink: Color(0xFF1D1D1F),
    ink2: Color(0xFF6E6E73),
    ink3: Color(0xFF86868B),
    ink2Glass: Color(0xFF515156),
    accent: Color(0xFF007AFF),
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF1F7A36),
    warn: Color(0xFFC93400),
    bad: Color(0xFFD70015),
    sep: Color(0x1A3C3C43),
    fill: Color(0x1A787880),
    fill2: Color(0x2E787880),
    selected: Color(0x12000000),
    sidebarSolid: Color(0xFFEFEFF3),
    sidebarSelected: Color(0x9EFFFFFF),
    sidebarVeil: Color(0x9EFFFFFF),
    scrim: Color(0x3D000000),
  );

  static const dark = WhisperColors(
    canvas: Color(0xFF000000),
    content: Color(0xFF1C1C1E),
    group: Color(0xFF1C1C1E),
    raised: Color(0xFF2C2C2E),
    bubble: Color(0xFF2C2C2E),
    ink: Color(0xFFF5F5F7),
    ink2: Color(0xFFA1A1A6),
    ink3: Color(0xFF8E8E93),
    ink2Glass: Color(0xFFC0C0C6),
    accent: Color(0xFF0A84FF),
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF30D158),
    warn: Color(0xFFFFB340),
    bad: Color(0xFFFF6961),
    sep: Color(0x24EBEBF5),
    fill: Color(0x3D787880),
    fill2: Color(0x5C787880),
    selected: Color(0x1AFFFFFF),
    sidebarSolid: Color(0xFF252528),
    sidebarSelected: Color(0x1FFFFFFF),
    sidebarVeil: Color(0x00FFFFFF),
    scrim: Color(0x75000000),
  );

  final Color canvas, content, group, raised, bubble;
  final Color ink, ink2, ink3, ink2Glass;
  final Color accent, onAccent;
  final Color ok, warn, bad;
  final Color sep, fill, fill2, selected;

  /// The sidebar where the system gives no material: Linux and Windows 10.
  final Color sidebarSolid;

  /// The raised selection behind the current sidebar row.
  final Color sidebarSelected;

  /// Over the macOS material, which goes grey on a dark wallpaper.
  final Color sidebarVeil;

  /// Behind a panel.
  final Color scrim;

  @override
  WhisperColors copyWith({Color? accent}) => WhisperColors(
    canvas: canvas,
    content: content,
    group: group,
    raised: raised,
    bubble: bubble,
    ink: ink,
    ink2: ink2,
    ink3: ink3,
    ink2Glass: ink2Glass,
    accent: accent ?? this.accent,
    onAccent: onAccent,
    ok: ok,
    warn: warn,
    bad: bad,
    sep: sep,
    fill: fill,
    fill2: fill2,
    selected: selected,
    sidebarSolid: sidebarSolid,
    sidebarSelected: sidebarSelected,
    sidebarVeil: sidebarVeil,
    scrim: scrim,
  );

  @override
  WhisperColors lerp(WhisperColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return WhisperColors(
      canvas: l(canvas, other.canvas),
      content: l(content, other.content),
      group: l(group, other.group),
      raised: l(raised, other.raised),
      bubble: l(bubble, other.bubble),
      ink: l(ink, other.ink),
      ink2: l(ink2, other.ink2),
      ink3: l(ink3, other.ink3),
      ink2Glass: l(ink2Glass, other.ink2Glass),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      ok: l(ok, other.ok),
      warn: l(warn, other.warn),
      bad: l(bad, other.bad),
      sep: l(sep, other.sep),
      fill: l(fill, other.fill),
      fill2: l(fill2, other.fill2),
      selected: l(selected, other.selected),
      sidebarSolid: l(sidebarSolid, other.sidebarSolid),
      sidebarSelected: l(sidebarSelected, other.sidebarSelected),
      sidebarVeil: l(sidebarVeil, other.sidebarVeil),
      scrim: l(scrim, other.scrim),
    );
  }
}

extension WhisperTheme on BuildContext {
  WhisperColors get wc => Theme.of(this).extension<WhisperColors>()!;
}

abstract final class WhisperRadius {
  static const xs = 6.0, s = 10.0, m = 14.0, l = 20.0, bubble = 18.0, composer = 26.0, tray = 24.0, appIcon = 12.0, thumbBar = 3.0, capsule = 999.0, sheetTop = 30.0, sheetBottom = 46.0, viewfinderMark = 12.0;
}

/// Six roles, two densities. Touch follows the platform, not the size class.
class WhisperType {
  const WhisperType({required this.touch});

  final bool touch;

  double get large => touch ? 32 : 26;
  double get title => touch ? 22 : 20;
  double get head => touch ? 17 : 15;
  double get body => touch ? 16 : 14;
  double get note => touch ? 14 : 12;
  double get tiny => touch ? 12 : 11;
}

abstract final class WhisperShadow {
  static List<BoxShadow> e1(Brightness b) => b == Brightness.light
      ? const [
          BoxShadow(color: Color(0x0D000000), blurRadius: 3, offset: Offset(0, 1)),
        ]
      : const [
          BoxShadow(color: Color(0x4D000000), blurRadius: 2, offset: Offset(0, 1)),
          BoxShadow(color: Color(0x0FFFFFFF), spreadRadius: .5),
        ];

  static List<BoxShadow> e2(Brightness b) => b == Brightness.light
      ? const [
          BoxShadow(color: Color(0x24000000), blurRadius: 28, offset: Offset(0, 8)),
          BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 1)),
          BoxShadow(color: Color(0x14000000), spreadRadius: .5),
        ]
      : const [
          BoxShadow(color: Color(0x80000000), blurRadius: 28, offset: Offset(0, 8)),
          BoxShadow(color: Color(0x66000000), blurRadius: 4, offset: Offset(0, 1)),
          BoxShadow(color: Color(0x1AFFFFFF), spreadRadius: .5),
        ];

  static List<BoxShadow> e3(Brightness b) => b == Brightness.light
      ? const [
          BoxShadow(color: Color(0x52101830), blurRadius: 80, offset: Offset(0, 32)),
          BoxShadow(color: Color(0x24101830), blurRadius: 24, offset: Offset(0, 8)),
          BoxShadow(color: Color(0x33000000), spreadRadius: .5),
        ]
      : const [
          BoxShadow(color: Color(0x9E000000), blurRadius: 80, offset: Offset(0, 32)),
          BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
          BoxShadow(color: Color(0x24FFFFFF), spreadRadius: .5),
        ];
}
```

## 弹簧

`SpringBuilder` 替代 `AnimatedContainer`、`AnimatedPositioned` 这类隐式动画。**曲线动画中途改目标时速度归零，所以连续操作会顿一下**，这就是现在 `easeOutBack` 的问题。

```dart
/// response is seconds; mass is 1.
SpringDescription whisperSpring(double response, double dampingRatio) {
  final k = math.pow(2 * math.pi / response, 2).toDouble();
  return SpringDescription(
    mass: 1,
    stiffness: k,
    damping: 2 * dampingRatio * math.sqrt(k),
  );
}

abstract final class WhisperSprings {
  static final follow = whisperSpring(.15, 1);
  static final snappy = whisperSpring(.28, .9);
  static final smooth = whisperSpring(.42, .86);
  static final expressive = whisperSpring(.5, .72);
  static final liquidLead = whisperSpring(.24, .8);
  static final liquidTrail = whisperSpring(.44, .9);
}

/// Animates a double toward [value] with a spring. Changing [value] mid-flight
/// keeps the current velocity, which a Curve-based animation cannot do. This
/// replaces AnimatedContainer, AnimatedPositioned and friends.
///
/// With reduced motion it jumps, unless [animateWhenReduced] is set for a value
/// that only drives opacity.
class SpringBuilder extends StatefulWidget {
  const SpringBuilder({
    super.key,
    required this.value,
    required this.builder,
    this.spring,
    this.child,
    this.from,
    this.animateWhenReduced = false,
  });

  final double value;

  /// Start here and animate to [value] on first build. Without it the first
  /// build sits at [value].
  final double? from;
  final SpringDescription? spring;
  final ValueWidgetBuilder<double> builder;
  final Widget? child;
  final bool animateWhenReduced;

  @override
  State<SpringBuilder> createState() => _SpringBuilderState();
}

class _SpringBuilderState extends State<SpringBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: widget.from ?? widget.value,
  );
  bool _started = false;

  void _go() {
    if (!widget.animateWhenReduced && MediaQuery.disableAnimationsOf(context)) {
      _c.value = widget.value;
      return;
    }
    _c.animateWith(
      SpringSimulation(
        widget.spring ?? WhisperSprings.smooth,
        _c.value,
        widget.value,
        _c.velocity,
        snapToEnd: true,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.from != null && widget.from != widget.value) _go();
  }

  @override
  void didUpdateWidget(SpringBuilder old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) _go();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (context, child) => widget.builder(context, _c.value, child),
  );
}
```

## 按压反馈

```dart
/// Every tappable thing shrinks a little and springs back, and works from the
/// keyboard: Tab focuses, Enter or Space activates, focus draws a ring.
/// Use scale .97 for buttons and rows, .92 for round toggles, 1 for segments.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.scale = .97,
    this.radius = 8,
    this.selected,
    this.label,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale, radius;
  final bool? selected;

  /// Required when the child is only an icon.
  final String? label;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false, _focused = false;

  void _set(bool v) {
    if (widget.onTap != null && v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: SystemMouseCursors.basic,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _set(true),
          onTapUp: (_) => _set(false),
          onTapCancel: () => _set(false),
          onTap: widget.onTap,
          child: SpringBuilder(
            value: _down ? widget.scale : 1,
            spring: WhisperSprings.snappy,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.radius),
                border: _focused
                    ? Border.all(
                        color: context.wc.accent.withValues(alpha: .45),
                        width: 3,
                        strokeAlign: BorderSide.strokeAlignOutside,
                      )
                    : null,
              ),
              child: widget.child,
            ),
            builder: (context, s, child) =>
                Transform.scale(scale: s, child: child),
          ),
        ),
      ),
    );
  }
}
```

## 分页：液体滑块

```dart
/// The segmented control. The edge moving toward the target uses a fast
/// spring and the other edge a slow one, so the thumb stretches, thins and
/// settles. Use it for the tabs (对话 / 文件 / 应用), channels and appearance.
class LiquidSegmented<T> extends StatefulWidget {
  const LiquidSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.height = 30,
    this.padding = 2,
    this.fontSize = 12,
    this.expand = false,
  });

  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final double height, padding, fontSize;

  /// Equal widths filling the parent, as on the phone's connect page.
  final bool expand;

  @override
  State<LiquidSegmented<T>> createState() => _LiquidSegmentedState<T>();
}

class _LiquidSegmentedState<T> extends State<LiquidSegmented<T>> {
  final Map<T, GlobalKey> _keys = {};
  final GlobalKey _stack = GlobalKey();
  Rect? _target;
  bool _right = true;

  void _measure() {
    final box = _stack.currentContext?.findRenderObject() as RenderBox?;
    final seg =
        _keys[widget.selected]?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || seg == null) return;
    final rect = seg.localToGlobal(Offset.zero, ancestor: box) & seg.size;
    if (rect == _target) return;
    setState(() {
      _right = _target == null || rect.left >= _target!.left;
      _target = rect;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measure();
    });
    final row = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        for (final e in widget.segments.entries)
          () {
            final cell = KeyedSubtree(
              key: _keys.putIfAbsent(e.key, GlobalKey.new),
              child: Pressable(
                scale: 1,
                radius: widget.height / 2,
                selected: e.key == widget.selected,
                onTap: () => widget.onChanged(e.key),
                child: Container(
                  height: widget.height - widget.padding * 2,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  child: Text(
                    e.value,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: widget.fontSize,
                      fontWeight: FontWeight.w500,
                      color: c.ink,
                    ),
                  ),
                ),
              ),
            );
            return widget.expand ? Expanded(child: cell) : cell;
          }(),
      ],
    );
    final t = _target;
    return Container(
      padding: EdgeInsets.all(widget.padding),
      decoration: ShapeDecoration(color: c.fill, shape: const StadiumBorder()),
      child: Stack(
        key: _stack,
        children: [
          if (t != null)
            SpringBuilder(
              value: t.left,
              spring: _right ? WhisperSprings.liquidTrail : WhisperSprings.liquidLead,
              builder: (context, left, _) => SpringBuilder(
                value: t.right,
                spring: _right ? WhisperSprings.liquidLead : WhisperSprings.liquidTrail,
                builder: (context, right, _) {
                  final width = math.max(0.0, right - left);
                  final stretch = math.max(1.0, width / math.max(1.0, t.width));
                  return Positioned(
                    left: left,
                    top: 0,
                    bottom: 0,
                    width: width,
                    child: Transform.scale(
                      scaleY: 1 / (1 + (stretch - 1) * .28),
                      child: DecoratedBox(
                        key: const ValueKey('liquid-thumb'),
                        decoration: ShapeDecoration(
                          color: c.raised,
                          shape: const StadiumBorder(),
                          shadows: const [
                            BoxShadow(color: Color(0x24000000), blurRadius: 2, offset: Offset(0, 1)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          row,
        ],
      ),
    );
  }
}
```

尺寸：主分页高 30（内边距 2，字号 `note`）；外观高 26（内边距 2，字号 `tiny`，手机 34）；声道高 36（内边距 3，字号 `note`）；连接设备高 36（`expand: true`）。

## 分页内容切换和依次升起

```dart
/// Content of the tabs. Each page has its own spring, so switching again
/// mid-flight keeps the speed, and the widget tree around a page never changes,
/// so its state survives.
///
/// A page is built the first time it is shown, not before: RemoteFilesPage
/// asks the other device for access as soon as it mounts.
class WhisperTabView extends StatefulWidget {
  const WhisperTabView({
    super.key,
    required this.index,
    required this.itemBuilder,
    required this.itemCount,
    this.blur = true,
  });

  final int index, itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Turn off where blur drops frames. Direction stays.
  final bool blur;

  @override
  State<WhisperTabView> createState() => _WhisperTabViewState();
}

class _WhisperTabViewState extends State<WhisperTabView> {
  late final int _first = widget.index;
  late final Set<int> _visited = {widget.index};
  late final Map<int, int> _entries = {widget.index: 0};

  /// Which side each page leaves to and comes from.
  final Map<int, double> _side = {};

  @override
  void didUpdateWidget(WhisperTabView old) {
    super.didUpdateWidget(old);
    if (widget.index == old.index) return;
    _visited.add(widget.index);
    _entries[widget.index] = (_entries[widget.index] ?? 0) + 1;
    for (final i in _visited) {
      if (i != widget.index) _side[i] = i < widget.index ? -1 : 1;
    }
    _side[widget.index] = widget.index > old.index ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final i in _visited.toList()..sort())
          KeyedSubtree(
            key: ValueKey(i),
            child: SpringBuilder(
              value: i == widget.index ? 1 : 0,
              from: i == _first ? null : 0,
              animateWhenReduced: true,
              child: _TabEntry(
                entry: _entries[i] ?? 0,
                child: Builder(
                  builder: (context) => widget.itemBuilder(context, i),
                ),
              ),
              builder: (context, raw, child) {
                final current = i == widget.index;
                final p = raw.clamp(0.0, 1.0);
                final side = _side[i] ?? 0;
                final motion = reduced ? 0.0 : 1.0;
                final from = current ? .985 : .97;
                final sigma = widget.blur ? 10 * (1 - p) * motion : 0.0;
                // Same widgets in every state: only the values change.
                return Offstage(
                  offstage: !current && p <= .001,
                  child: TickerMode(
                    enabled: current || p > .001,
                    child: IgnorePointer(
                      ignoring: !current,
                      child: Opacity(
                        opacity: p,
                        child: ImageFiltered(
                          enabled: sigma > .01,
                          imageFilter: ImageFilter.blur(
                            sigmaX: sigma,
                            sigmaY: sigma,
                          ),
                          child: FractionalTranslation(
                            translation: Offset(side * .09 * (1 - p) * motion, 0),
                            child: Transform.scale(
                              scale: 1 - (1 - from) * (1 - p) * motion,
                              child: child,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _TabEntry extends InheritedWidget {
  const _TabEntry({required this.entry, required super.child});

  final int entry;

  @override
  bool updateShouldNotify(_TabEntry old) => entry != old.entry;
}

/// New rows and icons rise one after another each time the tab is entered.
/// Delay is 24 ms per index; animate at most 16 items.
class RiseIn extends StatefulWidget {
  const RiseIn({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<RiseIn> {
  bool _in = false;
  bool _jump = false;
  int? _entry;
  Timer? _t;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final entry =
        context.dependOnInheritedWidgetOfExactType<_TabEntry>()?.entry ?? 0;
    if (entry == _entry) return;
    _entry = entry;
    _t?.cancel();
    // Back to the start at once, without animating down.
    _jump = true;
    _in = false;
    _t = Timer(Duration(milliseconds: 24 * math.min(widget.index, 16)), () {
      if (mounted) {
        setState(() {
          _jump = false;
          _in = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SpringBuilder(
    key: ValueKey(_jump ? 'start-$_entry' : 'run-$_entry'),
    value: _in ? 1 : 0,
    child: widget.child,
    builder: (context, t, child) => _RiseFrame(t: t, child: child!),
  );
}

class _RiseFrame extends StatelessWidget {
  const _RiseFrame({required this.t, required this.child});

  final double t;
  final Widget child;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: t.clamp(0.0, 1.0),
    child: Transform.translate(
      offset: Offset(0, 12 * (1 - t)),
      child: Transform.scale(scale: .98 + .02 * t, child: child),
    ),
  );
}

/// Phone page stack: the new page pushes in from the right, the old one backs
/// off 26% to the left, driven by the smooth spring. Use for every phone page,
/// including the first: a route only backs off if it is a WhisperPageRoute too.
class WhisperPageRoute<T> extends PageRoute<T> {
  WhisperPageRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;
  @override
  bool get opaque => true;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 700);

  @override
  Simulation createSimulation({required bool forward}) => SpringSimulation(
    WhisperSprings.smooth,
    controller!.value,
    forward ? 1 : 0,
    controller!.velocity,
    snapToEnd: true,
  );

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    return SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(animation),
      child: SlideTransition(
        position: Tween(begin: Offset.zero, end: const Offset(-.26, 0)).animate(secondaryAnimation),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            boxShadow: [BoxShadow(color: Color(0x1A000000), blurRadius: 32, offset: Offset(-12, 0))],
          ),
          child: child,
        ),
      ),
    );
  }
}
```

切到文件或应用时，给前 16 个行或图标包 `RiseIn`，每次进入都会重放。隐藏的页面一直留着，它们的动画靠 `TickerMode` 停（已经包好）。

## 滑块和进度

全部滑块用同一个主题，**不用 Material 默认样式**。`touch` 为真时命中区 48，否则 28。值是连续的数才用滑块，范围见 `surfaces.md`「设置」。手机上标题和数值一行，滑块单独铺满一行。

```dart
/// Capsule thumb, 26 × 18 (30 × 18 on touch), grows while dragged.
class CapsuleThumbShape extends SliderComponentShape {
  const CapsuleThumbShape({this.width = 26, this.height = 18});

  final double width, height;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size(width, height);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final a = activationAnimation.value;
    final rect = Rect.fromCenter(
      center: center,
      width: width * (1 + .16 * a),
      height: height * (1 + .1 * a),
    );
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
    final canvas = context.canvas;
    canvas.drawRRect(
      rr.shift(const Offset(0, 1)),
      Paint()
        ..color = const Color(0x42000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawRRect(rr, Paint()..color = const Color(0xFFFFFFFF));
  }
}

/// The overlay is invisible: it only makes the hit area 48 on touch, 28 with a
/// pointer. Padding is horizontal so the track lines up with the row's text.
SliderThemeData whisperSliderTheme(BuildContext context, {bool touch = false}) {
  final c = context.wc;
  final thumb = touch ? 30.0 : 26.0;
  return SliderTheme.of(context).copyWith(
    trackHeight: 6,
    activeTrackColor: c.accent,
    inactiveTrackColor: c.fill2,
    thumbColor: const Color(0xFFFFFFFF),
    overlayColor: const Color(0x00000000),
    thumbShape: CapsuleThumbShape(width: thumb),
    overlayShape: RoundSliderOverlayShape(overlayRadius: touch ? 24 : 14),
    trackShape: WhisperSliderTrackShape(thumbWidth: thumb),
    tickMarkShape: SliderTickMarkShape.noTickMark,
    showValueIndicator: ShowValueIndicator.never,
    padding: EdgeInsets.symmetric(horizontal: thumb / 2),
  );
}

/// Progress: a 4 high bar. The fill follows a spring, and a soft highlight
/// passes over it only while it is running, not when full or with reduced motion.
class WhisperProgressBar extends StatefulWidget {
  const WhisperProgressBar({super.key, required this.value});

  final double value;

  @override
  State<WhisperProgressBar> createState() => _WhisperProgressBarState();
}

class _WhisperProgressBarState extends State<WhisperProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  bool get _running => widget.value < 1;

  void _sync() {
    final run = _running && !MediaQuery.disableAnimationsOf(context);
    if (run && !_sheen.isAnimating) _sheen.repeat();
    if (!run && _sheen.isAnimating) _sheen.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(WhisperProgressBar old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _sheen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 4,
        child: ColoredBox(
          color: c.fill2,
          child: SpringBuilder(
            value: widget.value.clamp(0.0, 1.0),
            builder: (context, v, _) => FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: v.clamp(0.0, 1.0),
              child: ColoredBox(
                color: c.accent,
                child: !_sheen.isAnimating
                    ? null
                    : AnimatedBuilder(
                        animation: _sheen,
                        builder: (context, _) => FractionalTranslation(
                          translation: Offset(-1 + 2 * _sheen.value, 0),
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Color(0x00FFFFFF),
                                  Color(0x80FFFFFF),
                                  Color(0x00FFFFFF),
                                ],
                              ),
                            ),
                          ),
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
```

进度环（灵动岛、托盘）：`CustomPaint` 画，直径 20，粗 2.5，圆头，从 12 点钟方向顺时针，底环白 24%（玻璃上是 `fill2`）。

## 玻璃

```dart
enum GlassKind { sidebar, control, panel }

/// Glass inside the window shows the window's own content, so it blurs on every
/// platform (DESIGN.md「平台」). Set this false once, at startup, where the GPU
/// cannot keep up: glass then falls back to the opaque canvas.
bool whisperGlassBlurs = true;

/// A saturation matrix, as CSS `saturate()`.
List<double> _saturate(double s) {
  const r = .2126, g = .7152, b = .0722;
  final i = 1 - s;
  return [
    i * r + s, i * g, i * b, 0, 0,
    i * r, i * g + s, i * b, 0, 0,
    i * r, i * g, i * b + s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

class WhisperGlass extends StatelessWidget {
  const WhisperGlass({
    super.key,
    required this.kind,
    required this.child,
    this.shape = const RoundedSuperellipseBorder(),
  });

  final GlassKind kind;
  final Widget child;
  final ShapeBorder shape;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (tint, sigma, sat) = switch ((kind, dark)) {
      (GlassKind.sidebar, false) => (const Color(0xA8EEEEF3), 44.0, 1.8),
      (GlassKind.sidebar, true) => (const Color(0x9E26262A), 44.0, 1.8),
      (GlassKind.control, false) => (const Color(0xB8FFFFFF), 30.0, 1.8),
      (GlassKind.control, true) => (const Color(0xAD3A3A3C), 30.0, 1.8),
      (GlassKind.panel, false) => (const Color(0xBDF6F6F9), 44.0, 1.9),
      (GlassKind.panel, true) => (const Color(0xB8242428), 44.0, 1.9),
    };
    final blurs = whisperGlassBlurs;
    final surface = DecoratedBox(
      // No blur: fall back to the opaque canvas so text stays readable.
      decoration: ShapeDecoration(
        color: blurs ? tint : context.wc.canvas,
        shape: shape,
      ),
      child: child,
    );
    if (!blurs) return surface;
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ImageFilter.compose(
          outer: ColorFilter.matrix(_saturate(sat)),
          inner: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        ),
        child: surface,
      ),
    );
  }
}
```

**玻璃要透出东西才像玻璃**。侧栏要透出桌面，需要透明窗口和系统材质，见下面「隐藏标题栏和云母」。控制层和面板的顶边加高光：一层 0.5 的 `Border(top: ...)`，浅色白 80%，深色白 14%。

## 气泡

```dart
/// A message bubble hugs its text, also after wrapping. Without
/// TextWidthBasis.longestLine a wrapped Text fills the maximum width.
class WhisperBubble extends StatelessWidget {
  const WhisperBubble({
    super.key,
    required this.text,
    required this.mine,
    required this.touch,
  });

  final String text;
  final bool mine, touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final body = WhisperType(touch: touch).body;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: LayoutBuilder(
        builder: (context, box) => ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: touch
                ? box.maxWidth * .8
                : math.min(box.maxWidth * .72, body * 30),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: mine ? c.accent : c.bubble,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              child: Text(
                text,
                textWidthBasis: TextWidthBasis.longestLine,
                style: TextStyle(
                  fontSize: body,
                  height: 1.45,
                  color: mine ? c.onAccent : c.ink,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

真实的消息文字在 `lib/widget/message_link_text.dart`，用 `SelectableText.rich`，它也有 `textWidthBasis` 参数。

## 设备顺序

```dart
enum DevicePresence { connected, nearby, away }

/// The device list has one order. Getting worse never moves a row: a device
/// that goes offline stays where it is, and its slot still counts as its old
/// rank. Getting better moves it up, to just below its new rank's rows. A new
/// device goes in the same way, so it never pushes down a connected row.
class StableDeviceOrder {
  final List<String> _order = [];

  /// The best rank each row has been placed at.
  final Map<String, int> _placed = {};

  static int _rank(DevicePresence p) => switch (p) {
    DevicePresence.connected => 0,
    DevicePresence.nearby => 1,
    DevicePresence.away => 2,
  };

  void _insert(String id, int rank) {
    _order.remove(id);
    _placed[id] = rank;
    final at = _order.indexWhere((other) => _placed[other]! > rank);
    _order.insert(at < 0 ? _order.length : at, id);
  }

  List<String> apply(Map<String, DevicePresence> devices) {
    _order.removeWhere((id) => !devices.containsKey(id));
    _placed.removeWhere((id, _) => !devices.containsKey(id));
    for (final r in [0, 1, 2]) {
      for (final id in devices.keys) {
        if (_rank(devices[id]!) != r) continue;
        final placed = _placed[id];
        if (placed == null || r < placed) _insert(id, r);
      }
    }
    return List.unmodifiable(_order);
  }
}
```

## 窗口按钮

规则见 `surfaces.md`「窗口外壳」。macOS 不用它，红绿灯系统自己画。放在外壳 `Stack` 的最后一层，比遮罩和灵动岛都高。工具栏的右内边距用 `12 + WindowButtons.widthOf(style, layout.right.length)`。按钮的动作接 `windowManager.minimize`、`maximize`、`unmaximize`、`close`。拖动窗口用 `window_manager` 的 `DragToMoveArea`，它已经带双击最大化。

```dart
enum WindowButton { minimize, maximize, close }

enum WindowButtonStyle { windows, gnome, kde }

/// Which buttons go on which side. macOS has none: AppKit draws its own.
@immutable
class WindowButtonLayout {
  const WindowButtonLayout({this.left = const [], this.right = const []});

  static const windows = WindowButtonLayout(
    right: [WindowButton.minimize, WindowButton.maximize, WindowButton.close],
  );

  /// GTK's `gtk-decoration-layout`, like `:minimize,maximize,close` or
  /// `close,minimize,maximize:` or `appmenu:close`. Unknown names are skipped.
  factory WindowButtonLayout.parse(String value) {
    List<WindowButton> side(String names) => [
      for (final name in names.split(','))
        for (final button in WindowButton.values)
          if (button.name == name.trim()) button,
    ];
    final at = value.indexOf(':');
    return at < 0
        ? WindowButtonLayout(right: side(value))
        : WindowButtonLayout(
            left: side(value.substring(0, at)),
            right: side(value.substring(at + 1)),
          );
  }

  final List<WindowButton> left, right;
}

/// The window buttons Flutter draws once the system title bar is hidden.
/// Lay them over everything, scrims included, as the system's own would be.
class WindowButtons extends StatelessWidget {
  const WindowButtons({
    super.key,
    required this.buttons,
    required this.style,
    required this.maximized,
    required this.onPressed,
    required this.label,
  });

  final List<WindowButton> buttons;
  final WindowButtonStyle style;
  final bool maximized;
  final ValueChanged<WindowButton> onPressed;

  /// Localized name. `maximized` is passed so maximize can read 还原.
  final String Function(WindowButton button, bool maximized) label;

  /// How far a toolbar has to stay clear of the buttons.
  /// Where the buttons end, from the window's top.
  static double heightOf(WindowButtonStyle style) => switch (style) {
    WindowButtonStyle.windows => 32.0,
    WindowButtonStyle.gnome || WindowButtonStyle.kde => 38.0,
  };

  static double widthOf(WindowButtonStyle style, int count) {
    if (count == 0) return 0;
    return switch (style) {
      WindowButtonStyle.windows => 46.0 * count,
      WindowButtonStyle.gnome => 32.0 * count + 16,
      WindowButtonStyle.kde => 28.0 * count + 20,
    };
  }

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final button in buttons)
          _WindowButton(
            button: button,
            style: style,
            maximized: maximized,
            label: label(button, maximized),
            onPressed: () => onPressed(button),
          ),
      ],
    );
    // The pads keep the 24 circles on the toolbar's midline, 26 from the top.
    return switch (style) {
      WindowButtonStyle.windows => row,
      WindowButtonStyle.gnome => Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
        child: row,
      ),
      WindowButtonStyle.kde => Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 0),
        child: row,
      ),
    };
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.button,
    required this.style,
    required this.maximized,
    required this.label,
    required this.onPressed,
  });

  final WindowButton button;
  final WindowButtonStyle style;
  final bool maximized;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final isClose = widget.button == WindowButton.close;
    final Color? fill;
    var ink = c.ink;
    switch (widget.style) {
      case WindowButtonStyle.windows:
        fill = !_hover
            ? null
            : isClose
            ? (_down ? const Color(0xFFB02A1C) : const Color(0xFFC42B1C))
            : (_down ? c.fill2 : c.fill);
        if (_hover && isClose) ink = Colors.white;
      case WindowButtonStyle.gnome:
        fill = _down ? c.ink3 : (_hover ? c.fill2 : c.fill);
      case WindowButtonStyle.kde:
        fill = !_hover ? null : (isClose ? const Color(0xFFDA4453) : c.fill2);
        if (_hover && isClose) ink = Colors.white;
    }
    final isWindows = widget.style == WindowButtonStyle.windows;
    // The system's buttons are not in the Tab order: Alt+Space, Alt+F4 and the
    // desktop's own shortcuts do that job.
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onPressed,
      child: Tooltip(
        message: widget.label,
        excludeFromSemantics: true,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() {
            _hover = false;
            _down = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTapDown: (_) => setState(() => _down = true),
            onTapCancel: () => setState(() => _down = false),
            onTapUp: (_) => setState(() => _down = false),
            onTap: widget.onPressed,
            // On Linux the circle is 24 but the target is larger, like the
            // desktop's own buttons: 32 with a gap of 8, 28 with a gap of 4.
            child: SizedBox(
              width: isWindows
                  ? 46
                  : (widget.style == WindowButtonStyle.gnome ? 32 : 28),
              height: isWindows
                  ? 32
                  : (widget.style == WindowButtonStyle.gnome ? 32 : 28),
              child: Center(
                child: Container(
                  width: isWindows ? 46 : 24,
                  height: isWindows ? 32 : 24,
                  decoration: BoxDecoration(
                    color: fill,
                    shape: isWindows ? BoxShape.rectangle : BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: CustomPaint(
                    size: Size.square(isWindows ? 11 : 14),
                    painter: _WindowGlyph(
                      widget.button,
                      widget.style,
                      widget.maximized,
                      ink,
                    ),
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

class _WindowGlyph extends CustomPainter {
  const _WindowGlyph(this.button, this.style, this.maximized, this.color);

  final WindowButton button;
  final WindowButtonStyle style;
  final bool maximized;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final windows = style == WindowButtonStyle.windows;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = windows ? 1 : 1.5;
    final path = Path();
    void line(double a, double b, double c, double d) => path
      ..moveTo(a, b)
      ..lineTo(c, d);
    void box(double l, double t, double w, double h, double r) =>
        path.addRRect(RRect.fromLTRBR(l, t, l + w, t + h, Radius.circular(r)));
    switch ((button, style)) {
      case (WindowButton.close, WindowButtonStyle.windows):
        line(1, 1, 10, 10);
        line(10, 1, 1, 10);
      case (WindowButton.close, _):
        line(3.5, 3.5, 10.5, 10.5);
        line(10.5, 3.5, 3.5, 10.5);
      case (WindowButton.minimize, WindowButtonStyle.windows):
        line(1, 5.5, 10, 5.5);
      case (WindowButton.minimize, WindowButtonStyle.gnome):
        line(3, 11, 11, 11);
      case (WindowButton.minimize, WindowButtonStyle.kde):
        line(3, 5.5, 7, 9.5);
        line(7, 9.5, 11, 5.5);
      case (WindowButton.maximize, WindowButtonStyle.windows):
        if (maximized) {
          box(1, 3, 7, 7, 1.2);
          path
            ..moveTo(3, 1)
            ..lineTo(9, 1)
            ..quadraticBezierTo(10, 1, 10, 2)
            ..lineTo(10, 8);
        } else {
          box(1, 1, 9, 9, 1.5);
        }
      case (WindowButton.maximize, WindowButtonStyle.gnome):
        if (maximized) {
          box(3, 5, 6, 6, 1);
          path
            ..moveTo(5.5, 3)
            ..lineTo(10, 3)
            ..quadraticBezierTo(11, 3, 11, 4)
            ..lineTo(11, 8.5);
        } else {
          box(3.5, 3.5, 7, 7, 1);
        }
      case (WindowButton.maximize, WindowButtonStyle.kde):
        if (maximized) {
          path
            ..moveTo(7, 2.5)
            ..lineTo(11.5, 7)
            ..lineTo(7, 11.5)
            ..lineTo(2.5, 7)
            ..close();
        } else {
          line(3, 9, 7, 5);
          line(7, 5, 11, 9);
        }
    }
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_WindowGlyph old) =>
      old.button != button ||
      old.style != style ||
      old.maximized != maximized ||
      old.color != color;
}
```

## 隐藏标题栏和云母

**接口在 `lib/theme/whisper_window.dart`（`WhisperWindow`），都是新界面开关打开后才调用。验证结果见 `migration.md` 第 1 步。**

**拖动区放在控件后面，不要包住控件。** `DragToMoveArea` 带双击手势，包住分页胶囊时每次点按都要多等 300 毫秒。工具栏用 `Stack`：底层铺满 `DragToMoveArea`，控件放在上层，空白处自然落到底层。

### macOS

`enableWindowMaterial`（`macos/Runner/MainFlutterWindow.swift`）把 `NSVisualEffectView`（`.sidebar`、`.behindWindow`）放在透明的 Flutter 视图下面，并把红绿灯摆到距边 16、工具栏中线上。AppKit 重排标题栏时（切主题就会）只把容器的 frame 改回默认，按钮留在原处，红绿灯就跑到窗口顶边外。所以要监听容器的 `frameDidChangeNotification` 再摆一次，不能只在缩放时摆。

**工具栏这一条的点击默认到不了 Flutter**：AppKit 把标题栏区域留给移动窗口，即使它已经透明。第 1 步实测，点 y=26 时 `hitTest` 返回 FlutterView，Flutter 却什么也收不到；只在处理点击的那一刻关掉 `isMovable` 也没用，它要等到下一轮事件循环才生效。所以开着材质时窗口一直 `isMovable = false`，只有 `performDrag` 期间打开。最上面约 4 像素留给系统缩放窗口。

### Windows

**这段在 Windows 11（build 26100，150% 缩放）上真实跑过**，用不带插件的 Flutter 3.44.9 release 工程。结果在 `windows-real-mica-light.jpg`、`windows-real-mica-dark.jpg`：透明的 Flutter 能透出云母，系统给的 8 圆角、细边框、阴影都在，`BackdropFilter` 能模糊窗口内部的内容。

加到 `windows/runner/window_theme_plugin.cpp` 的 `SetBrightness` 里，亮暗一变就要重新设：

```cpp
// Flutter 的透明区域透出系统背景。window_manager 的 setTitleBarStyle 会把
// margins 重置成 0，所以这段要在它之后调用。
MARGINS margins = {-1, -1, -1, -1};
DwmExtendFrameIntoClientArea(window_, &margins);
// DWMWA_SYSTEMBACKDROP_TYPE = 38，DWMSBT_MAINWINDOW（云母）= 2。
// Windows 10 和 22H2 之前的版本返回失败，把结果告诉 Dart，侧栏改画 sidebar-solid。
int backdrop = 2;
const HRESULT hr = DwmSetWindowAttribute(window_, 38, &backdrop, sizeof(backdrop));
```

Dart 这边：

```dart
const WindowOptions(
  titleBarStyle: TitleBarStyle.hidden,
  windowButtonVisibility: false,
  backgroundColor: Colors.transparent,
);
// 侧栏不画底色，Scaffold 和 MaterialApp 的底色也要透明。内容区自己画 content。
// 云母时次要文字用 ink2-glass。SetBrightness 现在还会设 DWMWA_CAPTION_COLOR，隐藏标题栏后可以去掉。
```

**还没验证的**（这台机器没开开发者模式，带插件的 Windows 工程建不了符号链接，所以 `window_manager` 这部分没跑）：和 `window_manager` 一起用时的顺序；上边缘能不能拖动缩放；最大化时有没有被裁掉一圈（`window_manager` 的 `adjustNCCALCSIZE` 应该处理了）；悬停最大化按钮时的贴靠布局。贴靠布局要在原生层给 `WM_NCHITTEST` 返回 `HTMAXBUTTON`，Flutter 的子窗口又会先收到鼠标，**可能做不到，做不到就告诉用户**，Win+Z 还能用。

### Linux

**这台 Mac 上只对着 GTK 头文件做过语法检查（`GDK_WINDOWING_X11` 分支没有覆盖），没有真正编译和运行过。** 下面是读 `window_manager` 源码后的做法，已经写进 `linux/my_application.cc`。runner 比 Dart 先跑，看不到 `--dart-define`，所以新界面要同时设环境变量：`WHISPER_NEW_UI=1 flutter run -d linux --dart-define=WHISPER_NEW_UI=true`。不设时和旧界面完全一样。

```c
// linux/my_application.cc
// 现在只有 GNOME 和 Wayland 用 header bar。其他情况 window_manager 隐藏标题栏时会
// gtk_window_set_decorated(false)，阴影和边缘缩放都没了。改成一律用 header bar，
// 隐藏时 window_manager 只是把它设成不可见，GTK 的客户端装饰还在。
// 只在 WHISPER_NEW_UI=1 时，其他情况保持原来的判断。
gboolean use_header_bar = TRUE;

// 读按钮布局，通过 MethodChannel 给 Dart，再喂给 WindowButtonLayout.parse。
// 还要连 notify::gtk-decoration-layout，用户改了设置要跟着变。
gchar* layout = nullptr;
g_object_get(gtk_settings_get_default(), "gtk-decoration-layout", &layout, nullptr);
```

要在真机上看：GTK3 的客户端装饰下，Flutter 的 GL 视图会不会把圆角盖成方的。盖掉的话 Linux 就用方角，不用硬做。KDE 上要看和 Breeze 的阴影是否协调。

## 布局

尺寸类、密度和折叠姿态放在一起算，界面里只读这个结果。规则见 `DESIGN.md`「平板和折叠屏」。

```dart
enum WhisperSizeClass { compact, regular, expanded }

enum WhisperPosture { flat, book, tabletop }

/// The layout of the window right now. Everything here comes from the window
/// and how the device is held, never from which device it is: an iPad in Split
/// View is compact, a folded phone is compact, the same phone open is regular.
@immutable
class WhisperLayout {
  const WhisperLayout({
    required this.sizeClass,
    required this.touch,
    required this.shortHeight,
    required this.posture,
    required this.sidebarWidth,
    this.foldX,
    this.foldY,
  });

  final WhisperSizeClass sizeClass;

  /// Density and hit targets. A phone, tablet or foldable is touch at any
  /// width; a desktop window is pointer at any width.
  final bool touch;

  /// Under 600 tall: a wide foldable on its side, or any window with the
  /// keyboard up. Sheets and the control page rearrange, nothing else does.
  final bool shortHeight;

  final WhisperPosture posture;

  /// 0 in the compact class, where there is no sidebar.
  final double sidebarWidth;

  /// Left edge of a half-opened vertical fold, in window coordinates.
  final double? foldX;

  /// Top edge of a half-opened horizontal fold, in window coordinates.
  final double? foldY;

  bool get compact => sizeClass == WhisperSizeClass.compact;

  static const regularWidth = 600.0;
  static const expandedWidth = 1000.0;
  static const shortHeightLimit = 600.0;
  static const pointerSidebar = 252.0;
  static const touchSidebarMin = 240.0;
  static const touchSidebarMax = 300.0;

  /// For tests, and sample entries looking at the other density.
  @visibleForTesting
  static bool? debugTouchOverride;

  /// `Platform` and not `defaultTargetPlatform`, which says android in every
  /// `flutter test`: this agrees with `isDesktop()` on the host running it.
  static bool get touchPlatform =>
      debugTouchOverride ?? (Platform.isIOS || Platform.isAndroid);

  static WhisperLayout of(BuildContext context) => resolve(
    size: MediaQuery.sizeOf(context),
    touch: touchPlatform,
    features: MediaQuery.displayFeaturesOf(context),
  );

  static WhisperLayout resolve({
    required Size size,
    required bool touch,
    List<DisplayFeature> features = const [],
  }) {
    final sizeClass = size.width < regularWidth
        ? WhisperSizeClass.compact
        : size.width < expandedWidth
        ? WhisperSizeClass.regular
        : WhisperSizeClass.expanded;

    // A flat fold is just a screen. Only a half-opened one changes the layout,
    // and only one inside this window (not the other half of a split screen).
    var posture = WhisperPosture.flat;
    double? foldX, foldY;
    final window = Offset.zero & size;
    for (final f in features) {
      final isFold =
          f.type == DisplayFeatureType.fold ||
          f.type == DisplayFeatureType.hinge;
      if (!isFold || f.state != DisplayFeatureState.postureHalfOpened) continue;
      if (!window.overlaps(f.bounds.inflate(1))) continue;
      if (f.bounds.height >= f.bounds.width) {
        posture = WhisperPosture.book;
        foldX = f.bounds.left;
      } else {
        posture = WhisperPosture.tabletop;
        foldY = f.bounds.top;
      }
      break;
    }

    final double sidebarWidth;
    if (sizeClass == WhisperSizeClass.compact) {
      sidebarWidth = 0;
    } else if (posture == WhisperPosture.book) {
      sidebarWidth = foldX!;
    } else if (touch) {
      sidebarWidth = (size.width * .32).clamp(touchSidebarMin, touchSidebarMax);
    } else {
      sidebarWidth = pointerSidebar;
    }

    return WhisperLayout(
      sizeClass: sizeClass,
      touch: touch,
      shortHeight: size.height < shortHeightLimit,
      posture: posture,
      sidebarWidth: sidebarWidth,
      foldX: foldX,
      foldY: foldY,
    );
  }
}
```

折痕从 `MediaQuery.displayFeaturesOf` 来，安卓才有；iOS 没有这个数据，一直是 `flat`，只按宽度排。折叠或者旋转时 `MediaQuery` 变化，`build` 重新跑，靠稳定的 `key` 留住页面状态，不要在这时换路由。

## 没有配方的部分

**状态变化不重建。** 这是动效能放出来的前提。同一个控件要留在树里的同一位置，用稳定的 `key`，不要因为状态变化换 `key` 或换父节点。开关用 `SpringBuilder` 驱动滑块位置。

**开关**：`WhisperSwitch`。38×22，滑块 18（距边 2），开时 `accent`，关时 `fill2`。滑块位置走 `snappy`，按住时滑块变宽到 22。

**弹层和菜单**：`WhisperModalRoute`，走 `smooth`，中途可以关。弹层从 0.94 淡入，遮罩是 `scrim`；触控是底部弹层（`bottomSheet`）；菜单（`menu`）没有遮罩，从按钮长出来：缩放 0.92、上移 6。

**设置分区的彩色小图标**：`WhisperSettingsIcons`，底色从上到下压暗 22%，顶边一条 0.5 的白色高光，深浅色一样。连接用 `accent`。

**圆形勾选**：22，未选 1.5 的 `ink3` 描边，选中 `accent` 底白勾。

**按钮**：胶囊，高 28，左右 13，`note` 中等；`lg` 高 36，左右 20，`body`；触控分别高 44 和 48。填充 `accent` 白字，浅色 `fill` `ink`，无底 `accent`，破坏 `bad` 白字。

**分隔线**：`CustomPaint` 或 `Container(height: 1 / devicePixelRatio)`，不要用 `Divider` 的默认样式，它太粗太深。

**侧栏的选中底**：一个元素，放在设备列表的 `Stack` 底层，用 `SpringBuilder` 驱动它的 `top` 和高度，走 `snappy`，切设备时滑过去。用每行的 `GlobalKey` 量位置。进共享页时淡出，回来时直接到位再淡入，不从别处飞过来。底色 `sidebarSelected`，圆角 `s`，投影 `0 1 3 黑 8%`（深色 30%），加 0.5 的细轮廓和 `highlight`。

**页面栈**（手机）：用上面的 `WhisperPageRoute`，首页也要用它，旧页才会后退。

**共享页的控件**：`lib/new_ui/share/share_parts.dart`（工具栏、开关、圆形勾选、按钮、内缩分组、菜单）。屏幕块的颜色和投影是 `WhisperScreens`，开关滑块的投影是 `whisperKnobShadow`，声波的周期是 `WhisperLoops.wave`，这些值在 `DESIGN.md` 文件头。声道分段用 `LiquidSegmented` 的 `minSegmentWidth: 42`。

**手机页面的控件**：`lib/new_ui/phone/phone_parts.dart`（页面顶栏 `PhonePage`、`PhoneButton`、`PhonePopButton`、`PhoneField`、胶囊 `PhoneFloatBar`、底部弹层 `showPhoneSheet`）和 `panel_menu.dart`（`.menu`：`showPanelMenu`，`touch` 时每行 48）。`ShellButton` 触控时内边距是 13，按钮要和原型一样的 16 用 `PhoneButton`。取景框的颜色是 `WhisperViewfinder`，扫描线的周期是 `WhisperLoops.scan`，等宽字用 `WhisperMono` 和 `WhisperSizes.code`，这些值在 `DESIGN.md` 文件头。

**设备选取器**：`lib/new_ui/picker/device_picker.dart` 的 `showDevicePicker`，桌面是按钮上的 `panel` 菜单，手机是底部弹层，什么都没得选时用 toast 说明。快捷发送是 `quick_send_sheet.dart` 的 `QuickSendPicker`：点设备就发，`稍后` 留到以后。

**内阴影**：Flutter 没有 `inset`。把比形状大一圈的矩形挖掉形状，裁到形状里，再用 `MaskFilter.blur` 画，见 `lib/new_ui/input/shell_input_page.dart` 的 `_CanvasInset`。

## 设备图

写实的设备图是质感的主要来源之一。代码在 `lib/theme/whisper_device_art.dart`（`DeviceArt`、`DeviceWallpaper`、`deviceKindFor`），和原型 `art()` 的对照图是 `test/goldens/new_ui/device_art_light.png`。几何以 100 为基准宽度：

| 设备 | 几何 |
|---|---|
| 显示器（视口 100×86） | 机身 `(2,2,96,66)` 圆角 5，金属渐变；黑框 `(2,2,96,55)`；屏幕 `(4.5,4.5,91,50)` 圆角 2.5，壁纸；支架梯形 `(40,66)-(60,66)-(62.5,79)-(37.5,79)`；底座 `(31,78,38,3)` |
| 笔记本（视口 100×66） | 黑框 `(13,2,74,51)` 圆角 4；屏幕 `(15.5,4.5,69,46)` 圆角 2，壁纸；底座梯形从 `(3,54)` 到 `(97,54)` 向下收到 `(6,62)-(94,62)`，金属渐变；凹槽 `(42,54,16,2.5)` |
| 平板（视口 76×100） | 机身 `(1,1,74,98)` 圆角 7，`#2B2B2E`；屏幕 `(4.5,4.5,67,91)` 圆角 3.5，壁纸 |
| 手机（视口 56×100） | 机身 `(1,1,54,98)` 圆角 11，`#2B2B2E`；屏幕 `(4,4,48,92)` 圆角 8，壁纸；灵动岛 `(20,8,16,4.5)`，黑 |

金属渐变从上到下 `#EEEEF2` 到 `#B9B9C1`。壁纸是 `DESIGN.md` 文件头的 `wallpapers`，从左上到右下的线性渐变。设备类型来自现有的 `platformIcon` 判断。

**设备选取器用线条图标**（`DeviceGlyph`，视口 32，描边 2，圆头圆角）。设备列表不用它，用写实设备图，见 `DESIGN.md`「设备是实物」。几何：显示器 `rect(3,5,26,17,r2.5)` 加支架，笔记本 `rect(6.5,7,19,14,r2)` 加底线，手机 `rect(11,3,10,26,r2.5)` 加听筒线。

## 附：测试

把这些测试放进 `test/whisper_ui_test.dart`，它们就是上面说的 32 项。

```dart
import 'dart:ui'
    show
        DisplayFeature,
        DisplayFeatureState,
        DisplayFeatureType,
        PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/whisper_ui.dart';

Widget app(Widget child, {Brightness b = Brightness.light}) => MaterialApp(
  theme: ThemeData(
    brightness: b,
    extensions: [b == Brightness.light ? WhisperColors.light : WhisperColors.dark],
  ),
  home: Scaffold(body: child),
);

class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.onInit});
  final VoidCallback onInit;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final _c = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => TextField(controller: _c);
}

void main() {
  test('spring numbers match DESIGN.md', () {
    expect(WhisperSprings.smooth.stiffness, closeTo(224, 1));
    expect(WhisperSprings.smooth.damping, closeTo(25.7, .1));
    expect(WhisperSprings.snappy.stiffness, closeTo(504, 1));
    expect(WhisperSprings.snappy.damping, closeTo(40.4, .1));
    expect(WhisperSprings.expressive.stiffness, closeTo(158, 1));
    expect(WhisperSprings.follow.stiffness, closeTo(1755, 1));
  });

  testWidgets('SpringBuilder keeps its speed when the target changes', (t) async {
    final seen = <double>[];
    Widget at(double v) => app(
      SpringBuilder(
        value: v,
        builder: (context, x, _) {
          seen.add(x);
          return const SizedBox();
        },
      ),
    );
    await t.pumpWidget(at(0));
    await t.pumpWidget(at(100));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    final before = seen.last;
    final speed = seen.last - seen[seen.length - 2];
    expect(speed, greaterThan(0));
    await t.pumpWidget(at(-100));
    await t.pump(const Duration(milliseconds: 16));
    // Retargeting backwards: momentum still carries it forward for a moment.
    expect(seen.last, greaterThan(before));
    await t.pumpAndSettle();
    expect(seen.last, closeTo(-100, .01));
  });

  testWidgets('reduced motion jumps', (t) async {
    double last = 0;
    Widget at(double v) => MaterialApp(
      theme: ThemeData(extensions: const [WhisperColors.light]),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: SpringBuilder(
          value: v,
          builder: (context, x, _) {
            last = x;
            return const SizedBox();
          },
        ),
      ),
    );
    await t.pumpWidget(at(0));
    await t.pumpWidget(at(50));
    await t.pump();
    expect(last, 50);
  });

  testWidgets('liquid thumb stretches on the way and settles on the target', (t) async {
    var sel = 'a';
    late StateSetter set;
    await t.pumpWidget(
      app(
        Center(
          child: StatefulBuilder(
            builder: (context, s) {
              set = s;
              return LiquidSegmented<String>(
                segments: const {'a': '对话', 'b': '文件', 'c': '应用'},
                selected: sel,
                onChanged: (v) => s(() => sel = v),
              );
            },
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    final thumb = find.byKey(const ValueKey('liquid-thumb'));
    final w0 = t.getSize(thumb).width;
    final x0 = t.getRect(thumb).left;
    set(() => sel = 'c');
    await t.pump();
    await t.pump();
    var widest = 0.0;
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 16));
      final w = t.getRect(thumb).width;
      if (w > widest) widest = w;
    }
    expect(widest, greaterThan(w0 + 6));
    await t.pumpAndSettle();
    expect(t.getRect(thumb).left, greaterThan(x0 + 20));
    expect(t.getSize(thumb).width, closeTo(w0, 1));
    expect(find.bySemanticsLabel('应用'), findsOneWidget);
  });

  testWidgets('tab view: state survives, pages build lazily, both move', (t) async {
    var aInits = 0, bInits = 0;
    Widget at(int i) => app(
      SizedBox(
        width: 400,
        height: 300,
        child: WhisperTabView(
          index: i,
          itemCount: 3,
          blur: false,
          itemBuilder: (context, n) => _Probe(
            key: ValueKey('page$n'),
            onInit: () => n == 0 ? aInits++ : bInits++,
          ),
        ),
      ),
    );
    await t.pumpWidget(at(0));
    expect(aInits, 1);
    expect(bInits, 0, reason: 'page 1 is not built before it is shown');
    await t.enterText(find.byType(TextField), '草稿');
    await t.pumpWidget(at(1));
    await t.pump(const Duration(milliseconds: 60));
    expect(bInits, 1);
    expect(find.byKey(const ValueKey('page0'), skipOffstage: false), findsOneWidget);
    final x = t.getTopLeft(find.byKey(const ValueKey('page1'))).dx;
    expect(x, greaterThan(0), reason: 'new page comes from the right');
    expect(t.getTopLeft(find.byKey(const ValueKey('page0'))).dx, lessThan(0), reason: 'old page leaves left');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('page0')), findsNothing, reason: 'offstage once settled');
    await t.pumpWidget(at(0));
    await t.pumpAndSettle();
    expect(aInits, 1, reason: 'not rebuilt');
    expect(t.widget<TextField>(find.byType(TextField)).controller?.text ?? '', '草稿');
    expect(find.text('草稿'), findsOneWidget);
  });

  testWidgets('tab view: switching mid-flight does not snap', (t) async {
    Widget at(int i) => app(
      SizedBox(
        width: 400,
        height: 300,
        child: WhisperTabView(
          index: i,
          itemCount: 2,
          blur: false,
          itemBuilder: (context, n) => Text('p$n', key: ValueKey('p$n')),
        ),
      ),
    );
    await t.pumpWidget(at(0));
    await t.pumpWidget(at(1));
    await t.pump(const Duration(milliseconds: 120));
    final mid = t.widget<Opacity>(find.ancestor(of: find.byKey(const ValueKey('p1')), matching: find.byType(Opacity)).first).opacity;
    expect(mid, greaterThan(.1));
    expect(mid, lessThan(1));
    await t.pumpWidget(at(0));
    await t.pump(const Duration(milliseconds: 16));
    final after = t.widget<Opacity>(find.ancestor(of: find.byKey(const ValueKey('p1'), skipOffstage: false), matching: find.byType(Opacity)).first).opacity;
    expect((after - mid).abs(), lessThan(.2), reason: 'continues from where it was');
    await t.pumpAndSettle();
  });

  testWidgets('tab view: reduced motion only fades', (t) async {
    Widget at(int i) => MaterialApp(
      theme: ThemeData(extensions: const [WhisperColors.light]),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: WhisperTabView(
          index: i,
          itemCount: 2,
          itemBuilder: (context, n) => Text('p$n', key: ValueKey('p$n')),
        ),
      ),
    );
    await t.pumpWidget(at(0));
    final x0 = t.getTopLeft(find.byKey(const ValueKey('p0'))).dx;
    await t.pumpWidget(at(1));
    await t.pump(const Duration(milliseconds: 60));
    expect(t.getTopLeft(find.byKey(const ValueKey('p1'))).dx, x0, reason: 'no movement');
    final o = t.widget<Opacity>(find.ancestor(of: find.byKey(const ValueKey('p1')), matching: find.byType(Opacity)).first).opacity;
    expect(o, lessThan(1), reason: 'still fades');
    await t.pumpAndSettle();
  });

  testWidgets('RiseIn replays each time the tab is entered', (t) async {
    Widget at(int i) => app(
      WhisperTabView(
        index: i,
        itemCount: 2,
        blur: false,
        itemBuilder: (context, n) => n == 1
            ? const RiseIn(index: 0, child: Text('row', key: ValueKey('row')))
            : const SizedBox(),
      ),
    );
    await t.pumpWidget(at(0));
    await t.pumpWidget(at(1));
    await t.pumpAndSettle();
    await t.pumpWidget(at(0));
    await t.pumpAndSettle();
    await t.pumpWidget(at(1));
    await t.pump();
    final o = t.widget<Opacity>(find.ancestor(of: find.byKey(const ValueKey('row')), matching: find.byType(Opacity)).first).opacity;
    expect(o, lessThan(.5), reason: 'starts again from hidden');
    await t.pumpAndSettle();
    expect(t.widget<Opacity>(find.ancestor(of: find.byKey(const ValueKey('row')), matching: find.byType(Opacity)).first).opacity, 1);
  });

  testWidgets('keyboard: segments and pressables activate with Enter', (t) async {
    var sel = 'a';
    var tapped = 0;
    await t.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, s) => Column(
            children: [
              LiquidSegmented<String>(
                segments: const {'a': '对话', 'b': '文件'},
                selected: sel,
                onChanged: (v) => s(() => sel = v),
              ),
              Pressable(onTap: () => tapped++, label: '按钮', child: const SizedBox(width: 40, height: 40)),
            ],
          ),
        ),
      ),
    );
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(sel, 'b');
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump();
    expect(tapped, 1);
    await t.pumpAndSettle();
  });

  testWidgets('slider has a real hit area', (t) async {
    for (final (touch, min) in [(true, 48.0), (false, 28.0)]) {
      await t.pumpWidget(
        app(
          Builder(
            builder: (context) => SliderTheme(
              data: whisperSliderTheme(context, touch: touch),
              child: Slider(value: 1.5, min: 1, max: 3, onChanged: (_) {}),
            ),
          ),
        ),
      );
      expect(t.getSize(find.byType(Slider)).height, greaterThanOrEqualTo(min));
    }
  });

  testWidgets('progress highlight stops at 100%', (t) async {
    Widget at(double v) => app(SizedBox(width: 200, child: WhisperProgressBar(value: v)));
    await t.pumpWidget(at(.4));
    expect(t.hasRunningAnimations, isTrue);
    await t.pumpWidget(at(1));
    await t.pumpAndSettle();
    expect(t.hasRunningAnimations, isFalse);
  });

  testWidgets('page route: pushes with a spring and pops', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: ThemeData(extensions: const [WhisperColors.light]),
        onGenerateRoute: (_) => WhisperPageRoute(builder: (_) => const Scaffold(body: Text('root', key: ValueKey('root')))),
      ),
    );
    await t.pumpAndSettle();
    nav.currentState!.push(WhisperPageRoute(builder: (_) => const Scaffold(body: Text('next', key: ValueKey('next')))));
    await t.pump();
    await t.pump(const Duration(milliseconds: 80));
    expect(t.getTopLeft(find.byKey(const ValueKey('next'))).dx, greaterThan(0));
    expect(t.getTopLeft(find.byKey(const ValueKey('root'))).dx, lessThan(0), reason: 'old page backs off');
    await t.pumpAndSettle();
    expect(t.getTopLeft(find.byKey(const ValueKey('next'))).dx, 0);
    nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('next')), findsNothing);
  });

  testWidgets('bubble hugs its longest line after wrapping', (t) async {
    await t.pumpWidget(
      app(
        const SizedBox(
          width: 900,
          child: Column(
            children: [
              WhisperBubble(key: ValueKey('s'), text: '好', mine: true, touch: false),
              WhisperBubble(
                key: ValueKey('l'),
                text: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbb',
                mine: false,
                touch: false,
              ),
            ],
          ),
        ),
      ),
    );
    final short = t.getSize(find.descendant(of: find.byKey(const ValueKey('s')), matching: find.byType(DecoratedBox)).first);
    expect(short.width, lessThan(60));
    final long = t.getSize(find.descendant(of: find.byKey(const ValueKey('l')), matching: find.byType(DecoratedBox)).first);
    expect(long.height, greaterThan(40), reason: 'wraps');
    expect(long.width, lessThan(14 * 30), reason: 'smaller than the cap: hugs the longest line');
  });

  testWidgets('slider, progress, pressable and glass build in both themes', (t) async {
    for (final b in Brightness.values) {
      await t.pumpWidget(
        app(
          Builder(
            builder: (context) => Column(
              children: [
                SliderTheme(
                  data: whisperSliderTheme(context),
                  child: Slider(value: 1.5, min: 1, max: 3, onChanged: (_) {}),
                ),
                const SizedBox(width: 200, child: WhisperProgressBar(value: .4)),
                Pressable(onTap: () {}, child: const Text('按钮')),
                const WhisperGlass(kind: GlassKind.panel, child: Text('玻璃')),
                const RiseIn(index: 2, child: Text('行')),
              ],
            ),
          ),
          b: b,
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(t.takeException(), isNull);
    }
    await t.pumpWidget(const SizedBox());
  });

  test('order: nearby above away, offline keeps its place, new goes above away', () {
    final o = StableDeviceOrder();
    final first = o.apply({
      'old1': DevicePresence.away,
      'old2': DevicePresence.away,
      'near': DevicePresence.nearby,
      'on': DevicePresence.connected,
    });
    expect(first, ['on', 'near', 'old1', 'old2']);
    final off = o.apply({
      'old1': DevicePresence.away,
      'old2': DevicePresence.away,
      'near': DevicePresence.nearby,
      'on': DevicePresence.away,
    });
    expect(off, ['on', 'near', 'old1', 'old2'], reason: 'going offline moves nothing');
    final added = o.apply({
      'old1': DevicePresence.away,
      'old2': DevicePresence.away,
      'near': DevicePresence.nearby,
      'on': DevicePresence.away,
      'new': DevicePresence.nearby,
    });
    expect(added, ['on', 'near', 'new', 'old1', 'old2'], reason: 'does not push down a row above it');
  });

  test('order: starting offline, a device that connects moves up', () {
    final o = StableDeviceOrder();
    expect(o.apply({'a': DevicePresence.away, 'b': DevicePresence.away}), ['a', 'b']);
    expect(o.apply({'a': DevicePresence.away, 'b': DevicePresence.connected}), ['b', 'a']);
    expect(o.apply({'a': DevicePresence.connected, 'b': DevicePresence.connected}), ['b', 'a']);
    expect(o.apply({'a': DevicePresence.connected, 'b': DevicePresence.away}), ['b', 'a']);
    expect(o.apply({'a': DevicePresence.connected}), ['a']);
  });

  test('spring types exist', () {
    expect(WhisperSprings.smooth, isA<SpringDescription>());
  });

  group('window buttons', () {
    test('reads the GTK layout', () {
      final stock = WindowButtonLayout.parse('appmenu:close');
      expect(stock.left, isEmpty);
      expect(stock.right, [WindowButton.close]);
      final ubuntu = WindowButtonLayout.parse(':minimize,maximize,close');
      expect(ubuntu.right, WindowButton.values);
      final left = WindowButtonLayout.parse('close,minimize,maximize:');
      expect(left.left, [
        WindowButton.close,
        WindowButton.minimize,
        WindowButton.maximize,
      ]);
      expect(left.right, isEmpty);
    });

    testWidgets('Windows buttons are 138 by 32 and report what was pressed', (
      t,
    ) async {
      final pressed = <WindowButton>[];
      await t.pumpWidget(
        app(
          Align(
            alignment: Alignment.topRight,
            child: WindowButtons(
              buttons: WindowButtonLayout.windows.right,
              style: WindowButtonStyle.windows,
              maximized: false,
              onPressed: pressed.add,
              label: (b, m) => b.name,
            ),
          ),
        ),
      );
      expect(t.getSize(find.byType(WindowButtons)), const Size(138, 32));
      expect(WindowButtons.widthOf(WindowButtonStyle.windows, 3), 138);
      await t.tap(find.bySemanticsLabel('close'));
      expect(pressed, [WindowButton.close]);
    });

    testWidgets('close turns red under the pointer, maximize changes its name', (
      t,
    ) async {
      Widget build(bool maximized) => app(
        WindowButtons(
          buttons: WindowButton.values,
          style: WindowButtonStyle.windows,
          maximized: maximized,
          onPressed: (_) {},
          label: (b, m) =>
              b == WindowButton.maximize && m ? 'restore' : b.name,
        ),
      );
      await t.pumpWidget(build(false));
      expect(find.bySemanticsLabel('maximize'), findsOneWidget);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: t.getCenter(find.bySemanticsLabel('close')),
      );
      await t.pump();
      final box = t.widget<Container>(
        find
            .descendant(
              of: find.bySemanticsLabel('close'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (box.decoration! as BoxDecoration).color,
        const Color(0xFFC42B1C),
      );
      await mouse.removePointer();
      await t.pumpWidget(build(true));
      expect(find.bySemanticsLabel('restore'), findsOneWidget);
    });

    testWidgets('GNOME and KDE measure what the toolbar has to leave free', (
      t,
    ) async {
      for (final (style, count, width) in [
        (WindowButtonStyle.gnome, 3, 112.0),
        (WindowButtonStyle.gnome, 1, 48.0),
        (WindowButtonStyle.kde, 3, 104.0),
      ]) {
        await t.pumpWidget(
          app(
            Align(
              alignment: Alignment.topRight,
              child: WindowButtons(
                buttons: WindowButton.values.sublist(3 - count),
                style: style,
                maximized: false,
                onPressed: (_) {},
                label: (b, m) => b.name,
              ),
            ),
          ),
        );
        expect(t.getSize(find.byType(WindowButtons)).width, width);
        expect(WindowButtons.widthOf(style, count), width);
      }
    });
  });

  group('WhisperLayout', () {
    DisplayFeature fold(
      Rect bounds, {
      DisplayFeatureState state = DisplayFeatureState.postureHalfOpened,
      DisplayFeatureType type = DisplayFeatureType.fold,
    }) => DisplayFeature(bounds: bounds, type: type, state: state);

    test('the size class comes from the window width at both lines', () {
      WhisperSizeClass of(double w) =>
          WhisperLayout.resolve(size: Size(w, 800), touch: true).sizeClass;
      expect(of(599.9), WhisperSizeClass.compact);
      expect(of(600), WhisperSizeClass.regular);
      expect(of(999.9), WhisperSizeClass.regular);
      expect(of(1000), WhisperSizeClass.expanded);
    });

    test('every state of a tri-fold lands on one step of the same ladder', () {
      WhisperSizeClass of(double w) =>
          WhisperLayout.resolve(size: Size(w, 937), touch: true).sizeClass;
      expect(of(422), WhisperSizeClass.compact);
      expect(of(860), WhisperSizeClass.regular);
      expect(of(1337), WhisperSizeClass.expanded);
    });

    test('density does not follow width', () {
      final split = WhisperLayout.resolve(
        size: const Size(405, 820),
        touch: true,
      );
      expect(split.compact, isTrue);
      expect(split.touch, isTrue);
      final tablet = WhisperLayout.resolve(
        size: const Size(1180, 820),
        touch: true,
      );
      expect(tablet.compact, isFalse);
      expect(tablet.touch, isTrue);
      final desktop = WhisperLayout.resolve(
        size: const Size(1180, 820),
        touch: false,
      );
      expect(desktop.touch, isFalse);
    });

    test('the sidebar is clamped on touch and fixed with a pointer', () {
      double side(double w, bool touch) =>
          WhisperLayout.resolve(size: Size(w, 800), touch: touch).sidebarWidth;
      expect(side(500, true), 0);
      expect(side(640, true), 240);
      expect(side(820, true), closeTo(262.4, .01));
      expect(side(1337, true), 300);
      expect(side(1337, false), 252);
    });

    test('a flat fold changes nothing', () {
      final l = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [
          fold(
            const Rect.fromLTWH(452, 0, 0, 640),
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      );
      expect(l.posture, WhisperPosture.flat);
      expect(l.foldX, isNull);
      expect(l.sidebarWidth, closeTo(289.28, .01));
    });

    test('a half-opened vertical fold puts the sidebar edge on the fold', () {
      final l = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [fold(const Rect.fromLTWH(452, 0, 0, 640))],
      );
      expect(l.posture, WhisperPosture.book);
      expect(l.foldX, 452);
      expect(l.sidebarWidth, 452);
    });

    test('a half-opened horizontal fold is the tabletop posture', () {
      final l = WhisperLayout.resolve(
        size: const Size(640, 904),
        touch: true,
        features: [fold(const Rect.fromLTWH(0, 452, 640, 0))],
      );
      expect(l.posture, WhisperPosture.tabletop);
      expect(l.foldY, 452);
      expect(l.sidebarWidth, 240);
    });

    test('a hinge counts, a camera cutout does not', () {
      final hinge = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [
          fold(
            const Rect.fromLTWH(440, 0, 24, 640),
            type: DisplayFeatureType.hinge,
          ),
        ],
      );
      expect(hinge.posture, WhisperPosture.book);
      expect(hinge.foldX, 440);
      final cutout = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [
          fold(
            const Rect.fromLTWH(440, 0, 24, 30),
            type: DisplayFeatureType.cutout,
            state: DisplayFeatureState.unknown,
          ),
        ],
      );
      expect(cutout.posture, WhisperPosture.flat);
    });

    test('a fold outside this window is ignored', () {
      final l = WhisperLayout.resolve(
        size: const Size(400, 640),
        touch: true,
        features: [fold(const Rect.fromLTWH(452, 0, 0, 640))],
      );
      expect(l.posture, WhisperPosture.flat);
    });

    test('short height is its own axis', () {
      expect(
        WhisperLayout.resolve(
          size: const Size(857, 533),
          touch: true,
        ).shortHeight,
        isTrue,
      );
      expect(
        WhisperLayout.resolve(
          size: const Size(533, 857),
          touch: true,
        ).shortHeight,
        isFalse,
      );
    });

    testWidgets('of() reads the fold from MediaQuery', (tester) async {
      late WhisperLayout got;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(904, 640),
            displayFeatures: [fold(const Rect.fromLTWH(452, 0, 0, 640))],
          ),
          child: Builder(
            builder: (c) {
              got = WhisperLayout.of(c);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(got.posture, WhisperPosture.book);
      expect(got.sizeClass, WhisperSizeClass.regular);
    });
  });
}
```
