import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_data.dart';
import 'package:whisper/new_ui/shell/shell_device_page.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_phone.dart';
import 'package:whisper/new_ui/shell/shell_window_chrome.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// How pages in the content area are told apart.
abstract final class ShellRoutes {
  /// Settings and connecting a device: not about one device, so the sidebar lets
  /// go. Beside a sidebar there is no back, the way out is a device in it.
  static const top = 'shell/top';

  /// The control page: the one page the tabletop posture changes.
  static const control = 'shell/control';
}

/// What the rest of the app asks of the touch shell, which owns the content
/// area's navigator. Not attached on a desktop, where these pages open as they
/// always have.
abstract final class ShellContent {
  static _ShellTouchState? _shell;

  static bool get attached => _shell != null;

  /// Opens a page that is not about one device in the content area. Replaces
  /// any such page already open.
  static Future<T?> pushTop<T>(WidgetBuilder builder) =>
      _shell!._pushTop<T>(builder);

  /// A page further in: it has a back arrow, and goes where the device is.
  static Future<T?> push<T>(Route<T> route) => _shell!._push<T>(route);

  /// Shows the selected device, leaving anything opened over it.
  static void showDevice() => _shell?._showDevice();

  /// The list, in the compact size class: a device that is gone.
  static void showList() => _shell?._showList();
}

/// A page's back arrow, except on a top page beside a sidebar: leaving it means
/// tapping a device, as DESIGN.md「平板和折叠屏」says.
bool shellPageShowsBack(BuildContext context) =>
    WhisperLayout.of(context).compact ||
    ModalRoute.of(context)?.settings.name != ShellRoutes.top;

/// DESIGN.md「平板和折叠屏」: one tree for a phone's stack and a tablet's sidebar,
/// because a foldable is both. Only the geometry changes with the window, so the
/// device, its tab, the draft and the scroll position stay where they are. Below
/// 600 the list and the content are two pages that slide; above it they sit side
/// by side.
class ShellTouch extends StatefulWidget {
  const ShellTouch({
    super.key,
    required this.data,
    required this.actions,
    required this.order,
    required this.layout,
    required this.size,
  });

  final ShellData data;
  final ShellActions actions;
  final List<String> order;
  final WhisperLayout layout;
  final Size size;

  @override
  State<ShellTouch> createState() => _ShellTouchState();
}

class _ShellTouchState extends State<ShellTouch> with TickerProviderStateMixin {
  static const _cardWidth = 320.0;
  static const _cardGap = 10.0;

  final _nav = GlobalKey<NavigatorState>();
  late final _stack = _ContentObserver(_stackChanged);
  final _titleKey = GlobalKey(), _controlsKey = GlobalKey();
  final Map<String, int> _tabByPeer = {};

  /// Compact: the content is showing over the list. Beside a sidebar it always
  /// is, so that folding does not move anything.
  late bool _detail = !widget.layout.compact;

  /// Compact: the content was opened from the list for a page on top of it, so
  /// when that page goes, the list is what is left.
  bool _fromList = false;

  /// The device's page exists. On a phone it goes when the list comes back, as
  /// a page popped off a stack does: nothing may read messages behind the list.
  late bool _deviceAlive = !widget.layout.compact;

  /// The device whose card is open. Only that one: choosing another closes it.
  String? _cardPeerId;

  bool get _cardOpen =>
      _cardPeerId != null && _cardPeerId == widget.data.selectedPeerId;

  /// How far a finger has pulled the card to the right.
  late final AnimationController _cardDrag = AnimationController.unbounded(
    vsync: this,
  );

  /// Compact: the card left for a tab of its, so it goes out to the left, and
  /// back from that tab comes back to it.
  bool _leftForTab = false;
  DeviceData? _cardShown;

  /// The sidebar arriving when a fold opens. Nothing else animates then.
  late final AnimationController _unfold = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    ShellContent._shell = this;
    shellBackHandler = _back;
  }

  void _back() => unawaited(_goBack());

  @override
  void dispose() {
    if (ShellContent._shell == this) {
      ShellContent._shell = null;
      shellBackHandler = null;
    }
    shellIslandPlacement.value = null;
    _unfold.dispose();
    _cardDrag.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ShellTouch old) {
    super.didUpdateWidget(old);
    if (old.layout.compact != widget.layout.compact) {
      _foldChanged(widget.layout.compact);
    }
    // Another device: its card does not come back with the first one.
    if (widget.data.selectedPeerId != _cardPeerId) _cardPeerId = null;
    // A device that went away takes its page with it.
    if (widget.layout.compact &&
        _detail &&
        widget.data.selected == null &&
        _stack.routes.isEmpty) {
      _detail = false;
      _cardPeerId = null;
    }
  }

  void _foldChanged(bool compact) {
    _leftForTab = false;
    _fromList = false;
    _deviceAlive = true;
    _detail = true;
    if (compact) return;
    if (MediaQuery.disableAnimationsOf(context)) return;
    _unfold.value = 0;
    unawaited(
      _unfold.animateWith(
        SpringSimulation(WhisperSprings.smooth, 0, 1, 0, snapToEnd: true),
      ),
    );
  }

  void _stackChanged() {
    if (!mounted) return;
    setState(() {
      if (_stack.routes.isNotEmpty) return;
      if (_fromList && widget.layout.compact) _detail = false;
      _fromList = false;
    });
  }

  // ------------------------------------------------------------- navigation

  bool get _canGoBack =>
      _stack.routes.isNotEmpty ||
      _cardOpen ||
      (widget.layout.compact && _detail);

  Future<T?> _pushTop<T>(WidgetBuilder builder) {
    final nav = _nav.currentState!;
    nav.popUntil((route) => route.isFirst);
    _openFromList();
    return nav.push<T>(
      ShellTopRoute<T>(builder: builder, onCompactBack: _leaveTop),
    );
  }

  Future<T?> _push<T>(Route<T> route) {
    _openFromList();
    return _nav.currentState!.push<T>(route);
  }

  void _openFromList() {
    if (_detail) return;
    setState(() {
      _detail = true;
      _fromList = true;
    });
  }

  void _showDevice() {
    _nav.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _detail = true;
      _fromList = false;
      _deviceAlive = true;
      _leftForTab = false;
      if (widget.layout.compact) {
        _cardPeerId = null;
        final selected = widget.data.selectedPeerId;
        if (selected != null) _tabByPeer[selected] = 0;
      }
    });
  }

  void _showList() {
    if (!widget.layout.compact) return;
    setState(() {
      _detail = false;
      _cardPeerId = null;
    });
  }

  void _select(String uid) {
    widget.actions.select(uid);
    _showDevice();
  }

  /// Compact: the list slides back, with the top page still on it.
  void _leaveTop() => setState(() => _detail = false);

  Future<void> _goBack() async {
    final nav = _nav.currentState;
    // A page further in, or one with its own way back, like a folder.
    if (nav != null && await nav.maybePop()) return;
    if (!mounted) return;
    if (_cardOpen) {
      _closeCard();
      return;
    }
    final selected = widget.data.selectedPeerId;
    if (_leftForTab && selected != null) {
      _openCard(selected, tab: 0);
      return;
    }
    if (widget.layout.compact && _detail) setState(() => _detail = false);
  }

  /// The slide to the list has landed: what was on the page goes with it.
  void _landedOnList() {
    if (!mounted || _detail || !widget.layout.compact) return;
    _nav.currentState?.popUntil((route) => route.isFirst);
    if (_deviceAlive) setState(() => _deviceAlive = false);
  }

  void _measureIsland() {
    if (!mounted) return;
    final layout = widget.layout;
    if (layout.compact) {
      shellIslandPlacement.value = null;
      return;
    }
    double? edge(GlobalKey key, {required bool right}) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return null;
      final origin = box.localToGlobal(Offset.zero);
      return right ? origin.dx + box.size.width : origin.dx;
    }

    final onDevice = _stack.routes.isEmpty;
    shellIslandPlacement.value = ShellIslandPlacement(
      titleRight: onDevice ? edge(_titleKey, right: true) ?? 0 : 0,
      controlsLeft: onDevice
          ? edge(_controlsKey, right: false) ?? double.infinity
          : double.infinity,
    );
  }

  void _openCard(String uid, {int? tab}) {
    _cardDrag.value = 0;
    setState(() {
      if (tab != null) _tabByPeer[uid] = tab;
      _leftForTab = false;
      _cardPeerId = uid;
    });
  }

  void _closeCard() => setState(() {
    _cardPeerId = null;
    _leftForTab = false;
  });

  void _dragCardEnd(DragEndDetails details) {
    final fling = (details.primaryVelocity ?? 0) > 500;
    if (fling || _cardDrag.value > _cardWidth * .3) {
      _closeCard();
      return;
    }
    unawaited(
      _cardDrag.animateWith(
        SpringSimulation(
          WhisperSprings.snappy,
          _cardDrag.value,
          0,
          details.primaryVelocity ?? 0,
          snapToEnd: true,
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ build

  /// The tabletop posture's control page is a laptop: nothing beside it.
  double get _sidebarWidth =>
      widget.layout.posture == WhisperPosture.tabletop &&
          _stack.top?.settings.name == ShellRoutes.control
      ? 0
      : widget.layout.sidebarWidth;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureIsland());
    final c = context.wc;
    final layout = widget.layout;
    final compact = layout.compact;
    final size = widget.size;
    final sidebar = _sidebarWidth;
    final list = ShellPhoneList(
      data: widget.data,
      actions: widget.actions,
      order: widget.order,
      sidebar: !compact,
      // Lets go on a page that is not about one device.
      selectedPeerId: !compact && !_stack.hasTop
          ? widget.data.selectedPeerId
          : null,
      onSelect: _select,
    );
    final content = ClipRect(
      child: MediaQuery.removePadding(
        context: context,
        // The sidebar has the left edge of the screen.
        removeLeft: !compact && sidebar > 0,
        child: Navigator(
          key: _nav,
          observers: [_stack],
          pages: [_RootPage(child: _root(context))],
          onDidRemovePage: (_) {},
        ),
      ),
    );
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_goBack());
      },
      child: Scaffold(
        backgroundColor: compact ? c.content : c.sidebarSolid,
        // Inputs are in the content. A keyboard does not move the list.
        resizeToAvoidBottomInset: false,
        body: SpringBuilder(
          value: _detail ? 1 : 0,
          spring: WhisperSprings.smooth,
          builder: (context, x, _) {
            if (compact && !_detail && x < .002) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _landedOnList(),
              );
            }
            final covered = compact && x > .998;
            final hidden = compact && x < .002;
            return Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: compact ? size.width : sidebar,
                  child: Offstage(
                    offstage: covered || (!compact && sidebar == 0),
                    child: FractionalTranslation(
                      translation: Offset(compact ? -.28 * x : 0, 0),
                      child: AnimatedBuilder(
                        animation: _unfold,
                        child: list,
                        builder: (context, child) => Opacity(
                          opacity: _unfold.value.clamp(0, 1),
                          child: FractionalTranslation(
                            translation: Offset(-.22 * (1 - _unfold.value), 0),
                            child: child,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: compact ? 0 : sidebar,
                  top: 0,
                  right: 0,
                  bottom: 0,
                  child: Offstage(
                    offstage: hidden,
                    child: FractionalTranslation(
                      translation: Offset(compact ? 1 - x : 0, 0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: c.content,
                          border: !compact && sidebar > 0
                              ? Border(
                                  left: BorderSide(
                                    color: c.sep,
                                    width:
                                        1 /
                                        MediaQuery.devicePixelRatioOf(context),
                                  ),
                                )
                              : null,
                          boxShadow: compact && !covered
                              ? const [
                                  BoxShadow(
                                    color: Color(0x1A000000),
                                    blurRadius: 32,
                                    offset: Offset(-12, 0),
                                  ),
                                ]
                              : null,
                        ),
                        child: content,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The device, with its card, under whatever the navigator puts over it: a
  /// page opened from here covers the card too, and it is there when they leave.
  Widget _root(BuildContext context) {
    final c = context.wc;
    final session = widget.data.selected;
    if (session == null || !_deviceAlive) {
      return ColoredBox(color: c.content, child: const SizedBox.expand());
    }
    final layout = widget.layout;
    final device = session.device;
    final uid = device.uid;
    if (_cardOpen) _cardShown = device;
    final compact = layout.compact;
    final tab = _tabByPeer[uid] ?? 0;
    final page = ShellDevicePage(
      key: ValueKey(uid),
      session: session,
      actions: widget.actions,
      paired: widget.data.isPaired(device),
      connecting: widget.data.factsFor(session).connecting,
      tab: tab,
      onTab: (i) => setState(() => _tabByPeer[uid] = i),
      cardOpen: _cardOpen,
      onToggleCard: () => _cardOpen ? _closeCard() : _openCard(uid),
      rightInset: 0,
      touch: true,
      compact: compact,
      onBack: () => unawaited(_goBack()),
      titleKey: _titleKey,
      controlsKey: _controlsKey,
    );
    return Material(
      color: c.content,
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          children: [
            Positioned.fill(child: page),
            SpringBuilder(
              value: _cardOpen ? 1 : 0,
              spring: WhisperSprings.smooth,
              builder: (context, x, _) => _cardShown == null || x <= .004
                  ? const SizedBox.shrink()
                  : _card(context, _cardShown!, x, box.biggest),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, DeviceData device, double x, Size box) {
    final layout = widget.layout;
    void openTab(int tab) => setState(() {
      _tabByPeer[device.uid] = tab;
      _cardPeerId = null;
      _leftForTab = true;
    });
    final build = widget.actions.buildTouchCard;
    Widget content({required bool page}) => build == null
        ? widget.actions.buildCard(context, device, _closeCard)
        : build(
            context,
            device,
            page: page,
            onClose: _closeCard,
            onOpenTab: openTab,
          );
    if (layout.compact) {
      return Positioned.fill(
        child: FractionalTranslation(
          translation: Offset((1 - x) * (_leftForTab ? -1 : 1), 0),
          child: content(page: true),
        ),
      );
    }
    final top = MediaQuery.paddingOf(context).top + 10;
    final t = x.clamp(0.0, 1.0);
    // Off the right edge, far enough that its shadow goes with it.
    const travel = _cardWidth + _cardGap + 24;
    return Positioned(
      top: top,
      right: _cardGap,
      width: _cardWidth,
      child: AnimatedBuilder(
        animation: _cardDrag,
        builder: (context, child) {
          final drag = math.max(0.0, _cardDrag.value);
          return Transform.translate(
            offset: Offset(drag + (1 - t) * (travel - drag), 0),
            child: child,
          );
        },
        child: TapRegion(
          onTapOutside: (_) {
            if (_cardOpen &&
                !Navigator.of(context, rootNavigator: true).canPop()) {
              _closeCard();
            }
          },
          // A finger pulls it back to the right. Up and down is its own scroll.
          child: GestureDetector(
            onHorizontalDragUpdate: (details) => _cardDrag.value = math.max(
              0,
              _cardDrag.value + details.delta.dx,
            ),
            onHorizontalDragEnd: _dragCardEnd,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.height - top - 10),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(WhisperRadius.l),
                  boxShadow: WhisperShadow.e2(Theme.of(context).brightness),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(WhisperRadius.l),
                  child: content(page: false),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the content area's navigator has over the device.
class _ContentObserver extends NavigatorObserver {
  _ContentObserver(this.onChange);

  /// Told after the navigator's update.
  final VoidCallback onChange;

  final List<Route<dynamic>> _all = [];

  /// Without the device itself.
  List<Route<dynamic>> get routes =>
      _all.length <= 1 ? const [] : _all.sublist(1);

  Route<dynamic>? get top => routes.isEmpty ? null : routes.last;

  bool get hasTop =>
      routes.any((route) => route.settings.name == ShellRoutes.top);

  // A navigator tells this in the middle of its own update.
  void _changed() => scheduleMicrotask(onChange);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _all.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _all.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _all.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _all.indexOf(oldRoute);
    if (at >= 0 && newRoute != null) _all[at] = newRoute;
    _changed();
  }
}

/// The content's first page, rebuilt with the shell.
class _RootPage extends Page<void> {
  const _RootPage({required this.child}) : super(key: const ValueKey('device'));

  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => _RootRoute(this);
}

class _RootRoute extends PageRoute<void> {
  _RootRoute(_RootPage page) : super(settings: page);

  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;
  @override
  bool get opaque => true;
  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => (settings as _RootPage).child;
}

/// A page that is not about one device. It does not slide: in the compact size
/// class the content it is in does, beside a sidebar it fades in where the device
/// was, as a place does on a desktop.
class ShellTopRoute<T> extends PageRoute<T> {
  ShellTopRoute({required this.builder, required this.onCompactBack})
    : super(settings: const RouteSettings(name: ShellRoutes.top));

  final WidgetBuilder builder;

  /// Compact: back is the list, not what is under this page.
  final VoidCallback onCompactBack;

  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;
  @override
  bool get opaque => true;
  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Builder(
    builder: (context) {
      final compact = WhisperLayout.of(context).compact;
      return PopScope<T>(
        canPop: !compact,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) onCompactBack();
        },
        child: compact
            ? builder(context)
            : SpringBuilder(
                from: 0,
                value: 1,
                spring: WhisperSprings.smooth,
                child: builder(context),
                builder: (context, t, child) =>
                    Opacity(opacity: t.clamp(0, 1), child: child),
              ),
      );
    },
  );
}
