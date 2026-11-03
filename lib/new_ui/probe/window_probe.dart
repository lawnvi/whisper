// Step 1 of docs/design/migration.md: does the design hold up in a real window?
// A throwaway screen behind WHISPER_NEW_UI with sample data, laid out to
// docs/design/surfaces.md. Step 2 replaces it with the real shell and deletes
// this folder, which is why its sample text does not go through ARB.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:whisper/new_ui/probe/tray_panel_probe.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';

/// Runs the checks by itself and writes the results, then stays open.
const bool _autorun = bool.fromEnvironment('WHISPER_PROBE_AUTORUN');

const _channel = MethodChannel('com.vireen.whisper/window_theme');

class _Device {
  const _Device(
    this.name,
    this.status,
    this.kind,
    this.wall, {
    this.state,
    this.live = false,
  });

  final String name, status;
  final DeviceKind kind;
  final DeviceWallpaper wall;
  final DeviceArtState? state;
  final bool live;
}

final _devices = [
  _Device(
    'iMac',
    'log.txt 59%',
    DeviceKind.desktop,
    DeviceWallpaper.forPairingOrder(0),
    live: true,
  ),
  _Device(
    'ThinkPad X1 Carbon 办公笔记本',
    'http://192.168.31.8:10003/k7qm',
    DeviceKind.laptop,
    DeviceWallpaper.forPairingOrder(1),
  ),
  _Device(
    'Xiaomi 16',
    '收到',
    DeviceKind.phone,
    DeviceWallpaper.forPairingOrder(2),
  ),
  const _Device(
    '2698b',
    '在附近 · 可以配对',
    DeviceKind.phone,
    DeviceWallpaper.unpaired,
  ),
  _Device(
    'Redmi Pad',
    '在附近',
    DeviceKind.phone,
    DeviceWallpaper.forPairingOrder(0),
    state: DeviceArtState.nearby,
  ),
  _Device(
    'Ubuntu',
    '离线 · 昨天 22:14',
    DeviceKind.laptop,
    DeviceWallpaper.forPairingOrder(3),
    state: DeviceArtState.offline,
  ),
  _Device(
    '办公室 PC',
    '离线 · 上周二',
    DeviceKind.laptop,
    DeviceWallpaper.forPairingOrder(1),
    state: DeviceArtState.offline,
  ),
  _Device(
    'Pixel 6',
    '离线 · 9月12日',
    DeviceKind.phone,
    DeviceWallpaper.forPairingOrder(2),
    state: DeviceArtState.offline,
  ),
];

const _messages = <(String, bool)>[
  ('发版说明改好了，帮我看一眼。主要动了挂载和共享链接两节，西语还没翻，你先看中文的就行。', false),
  ('不急', false),
  ('好', true),
];

class WindowProbe extends StatefulWidget {
  const WindowProbe({super.key, this.autorun = _autorun, this.tray = true});

  /// Runs the checks by itself and writes the results, then stays open.
  final bool autorun;

  /// Whether to put up a tray icon and try the tray panel.
  final bool tray;

  @override
  State<WindowProbe> createState() => _WindowProbeState();
}

class _WindowProbeState extends State<WindowProbe> with TrayListener {
  int _tab = 0;
  int _selected = 0;
  Brightness? _brightness;
  bool _maximized = false;
  final _chat = ScrollController();
  final _tabKeys = <int, GlobalKey>{};
  final _rowKeys = <int, GlobalKey>{};
  int _rowTaps = 0;
  bool _tabBlur = true;
  TrayPanelProbeHost? _panel;
  final _windowEvents = _WindowEvents();
  final _boundary = GlobalKey();
  final _pointerLog = <String>[];

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      windowManager.addListener(_windowEvents..onChange = _syncMaximized);
      if (widget.tray) unawaited(_setUpTray());
    }
    if (widget.autorun) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
    }
  }

  Future<void> _syncMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted && maximized != _maximized) {
      setState(() => _maximized = maximized);
    }
  }

  Future<void> _setUpTray() async {
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png',
      isTemplate: Platform.isMacOS,
      iconSize: 18,
    );
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Whisper'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit'),
        ],
      ),
    );
    trayManager.addListener(this);
    // surfaces.md「托盘」: Linux only has a menu.
    if (!Platform.isLinux) _panel = TrayPanelProbeHost();
  }

  @override
  void onTrayIconMouseDown() => unawaited(_panel?.toggle());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'quit') unawaited(windowManager.destroy());
  }

  @override
  void dispose() {
    windowManager.removeListener(_windowEvents);
    if (widget.tray) trayManager.removeListener(this);
    _chat.dispose();
    super.dispose();
  }

  // ---- Measuring ----------------------------------------------------------

  Future<void> _pause(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Offset? _centerOf(GlobalKey? key) {
    final box = key?.currentContext?.findRenderObject() as RenderBox?;
    return box?.localToGlobal(box.size.center(Offset.zero));
  }

  Future<Map<String, Object?>> _measure(
    String phase,
    Future<void> Function() action,
  ) async {
    final frames = <FrameTiming>[];
    void keep(List<FrameTiming> t) => frames.addAll(t);
    SchedulerBinding.instance.addTimingsCallback(keep);
    final watch = Stopwatch()..start();
    await action();
    await _pause(300);
    watch.stop();
    SchedulerBinding.instance.removeTimingsCallback(keep);
    List<double> ms(Duration Function(FrameTiming) of) =>
        frames.map((f) => of(f).inMicroseconds / 1000).toList()..sort();
    double pick(List<double> v, double q) =>
        v.isEmpty ? 0 : v[math.min(v.length - 1, (v.length * q).floor())];
    final build = ms((f) => f.buildDuration);
    final raster = ms((f) => f.rasterDuration);
    final total = ms((f) => f.totalSpan);
    String f1(double v) => v.toStringAsFixed(1);
    return {
      'phase': phase,
      'seconds': f1(watch.elapsedMilliseconds / 1000),
      'frames': frames.length,
      'buildP50': f1(pick(build, .5)),
      'buildP99': f1(pick(build, .99)),
      'rasterP50': f1(pick(raster, .5)),
      'rasterP99': f1(pick(raster, .99)),
      'rasterMax': f1(raster.isEmpty ? 0 : raster.last),
      'totalP50': f1(pick(total, .5)),
      'totalP99': f1(pick(total, .99)),
      'over16ms': total.where((v) => v > 16.67).length,
      'over33ms': total.where((v) => v > 33.34).length,
    };
  }

  Future<void> _switchTabs(int times) async {
    for (var i = 0; i < times; i++) {
      setState(() => _tab = (_tab + 1) % 3);
      await _pause(700);
    }
    setState(() => _tab = 0);
    await _pause(700);
  }

  Future<void> _scrollChat() async {
    if (!_chat.hasClients) return;
    final max = _chat.position.maxScrollExtent;
    for (var i = 0; i < 2; i++) {
      await _chat.animateTo(
        max,
        duration: const Duration(seconds: 2),
        curve: Curves.linear,
      );
      await _chat.animateTo(
        0,
        duration: const Duration(seconds: 2),
        curve: Curves.linear,
      );
    }
  }

  Future<void> _run() async {
    final out =
        Platform.environment['WHISPER_PROBE_OUT'] ?? Directory.systemTemp.path;
    final results = <String, Object?>{};
    void log(String line) => debugPrint('probe: $line');
    await _pause(1500);

    Future<void> captureFlutter(String name) async {
      final boundary =
          _boundary.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      final image = await boundary?.toImage(pixelRatio: 2);
      final data = await image?.toByteData(format: ui.ImageByteFormat.png);
      if (data != null) {
        File('$out/$name.png').writeAsBytesSync(data.buffer.asUint8List());
      }
    }

    Future<String> capture(String name) async {
      await captureFlutter('flutter-$name');
      if (!kDebugMode || !Platform.isMacOS) return 'skipped';
      final answer = await _channel.invokeMethod<String>(
        'debugCapture',
        '$out/$name.png',
      );
      log('capture $name: $answer');
      return answer ?? 'null';
    }

    if (kDebugMode && Platform.isMacOS) {
      results['window'] = await _channel.invokeMethod<Map>('debugWindowInfo');
      results['captureLight'] = await capture('real-light');
      // Clicks through AppKit, across the band the title bar normally owns.
      final clicks = <String, Object?>{};
      Future<void> click(
        String name,
        Offset? at,
        bool Function() happened,
      ) async {
        if (at == null) {
          clicks[name] = 'no target';
          return;
        }
        final hit = await _channel.invokeMethod<String>('debugHitTest', {
          'x': at.dx,
          'y': at.dy,
        });
        await _channel.invokeMethod<void>('debugClick', {
          'x': at.dx,
          'y': at.dy,
        });
        // The up comes 60 ms after the down. Then, well under the 300 ms a
        // double tap around it would hold it back:
        await _pause(210);
        clicks[name] = {
          'at': '${at.dx.round()},${at.dy.round()}',
          'view': hit,
          'after150ms': happened(),
        };
        await _pause(750);
        (clicks[name] as Map)['after900ms'] = happened();
        (clicks[name] as Map)['flutterSaw'] = _pointerLog.toList();
        _pointerLog.clear();
      }

      final before = _rowTaps;
      await click(
        'sidebar row',
        _centerOf(_rowKeys[2]),
        () => _rowTaps == before + 1,
      );
      await click(
        'tab in the toolbar',
        _centerOf(_tabKeys[1]),
        () => _tab == 1,
      );
      results['captureFiles'] = await capture('real-files');
      await click('another tab', _centerOf(_tabKeys[2]), () => _tab == 2);
      results['captureApps'] = await capture('real-apps');
      await click('back to chat', _centerOf(_tabKeys[0]), () => _tab == 0);
      setState(() => _selected = 0);
      await _pause(500);
      results['clicks'] = clicks;

      // Which heights swallow a click, and under which window settings?
      Future<Map<String, Object?>> ladder() async {
        final seen = <String, Object?>{};
        for (final y in const [2, 6, 14, 26, 30, 38, 46, 50, 54, 60, 80]) {
          _pointerLog.clear();
          await _channel.invokeMethod<void>('debugClick', {
            'x': 620.0,
            'y': y.toDouble(),
          });
          await _pause(160);
          seen['y=$y'] = _pointerLog.any((e) => e.startsWith('down'))
              ? (_pointerLog.any((e) => e.startsWith('up'))
                    ? 'down+up'
                    : 'down only')
              : 'nothing';
        }
        return seen;
      }

      results['ladder'] = await ladder();
      _pointerLog.clear();
    }

    log('measuring');
    results['idle'] = await _measure('idle', () => _pause(3000));
    // The first visits build the pages; after that it is the switch itself.
    results['tabsFirstVisits'] = await _measure(
      'tab switches, pages built',
      () => _switchTabs(3),
    );
    results['tabs'] = await _measure(
      'tab switches with blur',
      () => _switchTabs(12),
    );
    setState(() => _tabBlur = false);
    results['tabsNoBlur'] = await _measure(
      'tab switches without blur',
      () => _switchTabs(12),
    );
    setState(() => _tabBlur = true);
    results['scroll'] = await _measure(
      'chat scrolling under glass',
      _scrollChat,
    );
    if (Platform.isMacOS || Platform.isWindows) {
      await _channel
          .invokeMethod<void>('setWindowMaterialVisible', false)
          .catchError((Object _) {});
      results['scrollNoMaterial'] = await _measure(
        'same, material hidden',
        _scrollChat,
      );
      await _channel
          .invokeMethod<void>('setWindowMaterialVisible', true)
          .catchError((Object _) {});
    }
    if (Platform.isLinux) {
      results['windowButtons'] = {
        'layout':
            'left ${WhisperWindow.buttonLayout.value.left} '
            'right ${WhisperWindow.buttonLayout.value.right}',
        'style': WhisperWindow.buttonStyle.name,
        'desktop': Platform.environment['XDG_CURRENT_DESKTOP'],
        'session': Platform.environment['XDG_SESSION_TYPE'],
      };
      results['trayHost'] = await _statusNotifierHost();
    }
    final panel = _panel;
    if (panel != null) {
      try {
        results['trayPanel'] = await panel.measure();
      } on Object catch (error) {
        results['trayPanel'] = 'failed: $error';
      }
    }

    setState(() => _brightness = Brightness.dark);
    await WhisperWindow.applyBrightness(Brightness.dark);
    await _pause(900);
    results['captureDark'] = await capture('real-dark');
    if (kDebugMode && Platform.isMacOS) {
      // AppKit retiles the title bar for this: the lights must stay put.
      results['windowDark'] = await _channel.invokeMethod<Map>(
        'debugWindowInfo',
      );
    }
    setState(() => _brightness = Brightness.light);
    await WhisperWindow.applyBrightness(Brightness.light);

    final encoded = const JsonEncoder.withIndent('  ').convert(results);
    log('results\n$encoded');
    try {
      File('$out/probe-results.json').writeAsStringSync(encoded);
    } on Object catch (error) {
      log('could not write: $error');
    }
    log('done');
  }

  /// Without this service the tray icon never shows, and hiding to the tray
  /// would lose the window (surfaces.md「没有托盘的桌面」).
  Future<String> _statusNotifierHost() async {
    final client = DBusClient.session();
    try {
      final reply = await client.callMethod(
        destination: 'org.freedesktop.DBus',
        path: DBusObjectPath('/org/freedesktop/DBus'),
        interface: 'org.freedesktop.DBus',
        name: 'NameHasOwner',
        values: [const DBusString('org.kde.StatusNotifierWatcher')],
        replySignature: DBusSignature('b'),
      );
      return (reply.values.first as DBusBoolean).value
          ? 'org.kde.StatusNotifierWatcher is there'
          : 'no StatusNotifierWatcher: the tray icon will not show';
    } on Object catch (error) {
      return 'could not ask: $error';
    } finally {
      await client.close();
    }
  }

  // ---- The window ---------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = _brightness == null
        ? Theme.of(context)
        : (_brightness == Brightness.dark
              ? AppTheme.darkTheme
              : AppTheme.lightTheme);
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) => Listener(
          onPointerDown: (e) => _pointerLog.add(
            'down ${e.position.dx.round()},${e.position.dy.round()} kind=${e.kind.name}',
          ),
          onPointerUp: (e) => _pointerLog.add(
            'up ${e.position.dx.round()},${e.position.dy.round()}',
          ),
          onPointerCancel: (e) => _pointerLog.add('cancel'),
          child: RepaintBoundary(
            key: _boundary,
            child: MediaQuery.sizeOf(context).width < 600
                ? _phone(context)
                : _desktop(context),
          ),
        ),
      ),
    );
  }

  Widget _desktop(BuildContext context) {
    final c = context.wc;
    final mac = Platform.isMacOS;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ValueListenableBuilder<bool>(
        valueListenable: WhisperWindow.hasMaterial,
        builder: (context, material, _) => Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 252,
                  child: ColoredBox(
                    color: material
                        ? (mac ? c.sidebarVeil : Colors.transparent)
                        : c.sidebarSolid,
                    child: _sidebar(context, material),
                  ),
                ),
                _vLine(context),
                Expanded(
                  child: ColoredBox(color: c.content, child: _content(context)),
                ),
              ],
            ),
            if (!mac)
              ValueListenableBuilder<WindowButtonLayout>(
                valueListenable: WhisperWindow.buttonLayout,
                builder: (context, layout, _) => Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      child: _windowButtons(layout.left),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: _windowButtons(layout.right),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _windowButtons(List<WindowButton> buttons) => WindowButtons(
    buttons: buttons,
    style: WhisperWindow.buttonStyle,
    maximized: _maximized,
    onPressed: (button) => unawaited(switch (button) {
      WindowButton.minimize => windowManager.minimize(),
      WindowButton.maximize =>
        _maximized ? windowManager.unmaximize() : windowManager.maximize(),
      WindowButton.close => windowManager.close(),
    }),
    label: (button, maximized) => button.name,
  );

  /// A toolbar's height. Blank space in it moves the window, as a title bar
  /// would. That area sits behind the controls: around them, its double tap
  /// would hold their taps back by 300 ms.
  Widget _band(Widget child) => SizedBox(
    height: 52,
    child: Stack(
      fit: StackFit.expand,
      children: [
        const DragToMoveArea(child: SizedBox.expand()),
        child,
      ],
    ),
  );

  Widget _vLine(BuildContext context) => SizedBox(
    width: 1 / MediaQuery.devicePixelRatioOf(context),
    child: ColoredBox(color: context.wc.sep),
  );

  Widget _iconButton(BuildContext context, IconData icon, {Color? color}) =>
      Pressable(
        onTap: () {},
        radius: WhisperRadius.xs,
        label: icon.codePoint.toString(),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 16, color: color ?? context.wc.ink2),
        ),
      );

  /// Room for the traffic lights, or window buttons on the left.
  double get _sidebarLeft {
    if (Platform.isMacOS) return 86;
    final left = WhisperWindow.buttonLayout.value.left.length;
    return left == 0
        ? 20
        : WindowButtons.widthOf(WhisperWindow.buttonStyle, left) + 8;
  }

  Widget _sidebar(BuildContext context, bool material) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    final second = material ? c.ink2Glass : c.ink2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _band(
          Padding(
            padding: EdgeInsets.fromLTRB(
              Platform.isMacOS ? 86 : 20,
              10,
              10,
              10,
            ),
            child: Row(
              children: [
                if (!Platform.isMacOS &&
                    WhisperWindow.buttonLayout.value.left.isEmpty)
                  Text(
                    'Whisper',
                    style: TextStyle(
                      fontSize: type.note,
                      fontWeight: FontWeight.w500,
                      color: c.ink2,
                    ),
                  ),
                const Spacer(),
                _iconButton(context, Icons.search_rounded, color: second),
                _iconButton(context, Icons.add_rounded, color: second),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: _DeviceRows(
              selected: _selected,
              rowKeys: _rowKeys,
              onSelect: (i) => setState(() {
                _selected = i;
                _rowTaps++;
              }),
              second: second,
            ),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 8, 10),
            child: Row(
              children: [
                DeviceGlyph(kind: DeviceKind.laptop, color: second, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'xiaoxin 的 MacBook Air 13 英寸',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: type.note,
                      fontWeight: FontWeight.w500,
                      color: c.ink,
                    ),
                  ),
                ),
                _iconButton(context, Icons.volume_up_outlined, color: second),
                _iconButton(
                  context,
                  Icons.keyboard_alt_outlined,
                  color: second,
                ),
                _iconButton(context, Icons.link_rounded, color: c.accent),
                _iconButton(context, Icons.settings_outlined, color: second),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _content(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    final right =
        12.0 +
        (Platform.isMacOS
            ? 0
            : WindowButtons.widthOf(
                WhisperWindow.buttonStyle,
                WhisperWindow.buttonLayout.value.right.length,
              ));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _band(
          Padding(
            padding: EdgeInsets.fromLTRB(20, 0, right, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _devices[_selected].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: type.head,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                ),
                _Tabs(
                  selected: _tab,
                  keys: _tabKeys,
                  onChanged: (i) => setState(() => _tab = i),
                ),
                const SizedBox(width: 8),
                _iconButton(context, Icons.info_outline_rounded),
              ],
            ),
          ),
        ),
        Expanded(
          child: WhisperTabView(
            index: _tab,
            itemCount: 3,
            blur: _tabBlur,
            itemBuilder: (context, i) => switch (i) {
              0 => _Chat(controller: _chat, touch: false),
              1 => const _Files(touch: false),
              _ => const _Apps(),
            },
          ),
        ),
      ],
    );
  }

  /// Android has no window material: this is here for the blur.
  Widget _phone(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    return Scaffold(
      backgroundColor: c.content,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 50,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'iMac',
                        style: TextStyle(
                          fontSize: type.head,
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                    ),
                    _Tabs(
                      selected: _tab,
                      keys: _tabKeys,
                      onChanged: (i) => setState(() => _tab = i),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: WhisperTabView(
                index: _tab,
                itemCount: 3,
                blur: _tabBlur,
                itemBuilder: (context, i) => switch (i) {
                  0 => _Chat(controller: _chat, touch: true),
                  1 => const _Files(touch: true),
                  _ => const _Apps(),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowEvents with WindowListener {
  VoidCallback? onChange;

  @override
  void onWindowMaximize() => onChange?.call();

  @override
  void onWindowUnmaximize() => onChange?.call();

  @override
  void onWindowResized() => onChange?.call();
}

class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.selected,
    required this.keys,
    required this.onChanged,
  });

  final int selected;
  final Map<int, GlobalKey> keys;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => LiquidSegmented<int>(
    segments: const {0: '对话', 1: '文件', 2: '应用'},
    selected: selected,
    onChanged: onChanged,
    labelKeys: keys,
  );
}

class _DeviceRows extends StatefulWidget {
  const _DeviceRows({
    required this.selected,
    required this.rowKeys,
    required this.onSelect,
    required this.second,
  });

  final int selected;
  final Map<int, GlobalKey> rowKeys;
  final ValueChanged<int> onSelect;
  final Color second;

  @override
  State<_DeviceRows> createState() => _DeviceRowsState();
}

class _DeviceRowsState extends State<_DeviceRows> {
  static const _rowHeight = 46.0, _gap = 2.0;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Stack(
        children: [
          // One element that slides, not a background on each row.
          SpringBuilder(
            value: widget.selected * (_rowHeight + _gap),
            spring: WhisperSprings.snappy,
            builder: (context, top, _) => Positioned(
              left: 0,
              right: 0,
              top: top,
              height: _rowHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.sidebarSelected,
                  borderRadius: BorderRadius.circular(WhisperRadius.s),
                  boxShadow: [
                    BoxShadow(
                      color: dark
                          ? const Color(0x4D000000)
                          : const Color(0x14000000),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                  border: Border(
                    top: BorderSide(
                      width: .5,
                      color: dark
                          ? const Color(0x24FFFFFF)
                          : const Color(0xCCFFFFFF),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Column(
            children: [
              for (final (i, d) in _devices.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: _gap),
                  child: Pressable(
                    key: widget.rowKeys.putIfAbsent(i, GlobalKey.new),
                    onTap: () => widget.onSelect(i),
                    radius: WhisperRadius.s,
                    selected: i == widget.selected,
                    child: SizedBox(
                      height: _rowHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 34,
                              height: 30,
                              child: Center(
                                child: DeviceArt(
                                  kind: d.kind,
                                  wallpaper: d.wall,
                                  size: d.kind == DeviceKind.phone ? 30 : 32,
                                  state: d.state ?? DeviceArtState.normal,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    d.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: type.body,
                                      fontWeight: FontWeight.w500,
                                      color: c.ink,
                                      height: 1.2,
                                    ),
                                  ),
                                  Text(
                                    d.status,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: type.note,
                                      height: 1.25,
                                      fontWeight: d.live
                                          ? FontWeight.w500
                                          : FontWeight.w400,
                                      color: d.live ? c.accent : widget.second,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chat extends StatelessWidget {
  const _Chat({required this.controller, required this.touch});

  final ScrollController controller;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: touch);
    return Stack(
      children: [
        ListView.builder(
          controller: controller,
          padding: EdgeInsets.fromLTRB(
            touch ? 12 : 16,
            8,
            touch ? 12 : 16,
            touch ? 92 : 84,
          ),
          itemCount: 120,
          itemBuilder: (context, i) {
            final (text, mine) = _messages[i % _messages.length];
            return Padding(
              padding: EdgeInsets.only(bottom: i % 3 == 1 ? 8 : 2),
              child: WhisperBubble(text: text, mine: mine, touch: touch),
            );
          },
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: touch ? 24 : 16,
          child: Center(
            child: LayoutBuilder(
              builder: (context, box) => SizedBox(
                width: touch
                    ? box.maxWidth - 36
                    : math.min(620, box.maxWidth - 96),
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: const StadiumBorder(),
                    shadows: WhisperShadow.e2(Theme.of(context).brightness),
                  ),
                  child: WhisperGlass(
                    kind: GlassKind.control,
                    shape: const StadiumBorder(),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: SizedBox(
                        height: touch ? 38 : 28,
                        child: Row(
                          children: [
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                '发给 iMac',
                                style: TextStyle(
                                  fontSize: type.body,
                                  color: c.ink2Glass,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.content_paste_rounded,
                              size: 16,
                              color: c.ink2Glass,
                            ),
                            const SizedBox(width: 16),
                            if (!touch) ...[
                              Icon(
                                Icons.photo_camera_outlined,
                                size: 16,
                                color: c.ink2Glass,
                              ),
                              const SizedBox(width: 12),
                            ],
                            Container(
                              width: touch ? 38 : 28,
                              height: touch ? 38 : 28,
                              decoration: ShapeDecoration(
                                color: c.fill2,
                                shape: const CircleBorder(),
                              ),
                              child: Icon(
                                Icons.add_rounded,
                                size: 18,
                                color: c.ink,
                              ),
                            ),
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
      ],
    );
  }
}

class _Files extends StatelessWidget {
  const _Files({required this.touch});

  final bool touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: touch);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: 40,
      itemBuilder: (context, i) => RiseIn(
        index: i,
        child: SizedBox(
          height: touch ? 48 : 30,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(
                  i % 3 == 0
                      ? Icons.folder_rounded
                      : Icons.description_outlined,
                  size: 18,
                  color: i % 3 == 0 ? c.accent : c.ink2,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '项目资料 $i',
                    maxLines: 1,
                    style: TextStyle(fontSize: type.body, color: c.ink),
                  ),
                ),
                Text(
                  '${(i + 1) * 13} KB',
                  style: TextStyle(fontSize: type.note, color: c.ink2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Apps extends StatelessWidget {
  const _Apps();

  @override
  Widget build(BuildContext context) => GridView.builder(
    padding: const EdgeInsets.all(20),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 76,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
    ),
    itemCount: 48,
    itemBuilder: (context, i) => RiseIn(
      index: i,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(WhisperRadius.m),
          gradient: DeviceWallpaper.forPairingOrder(i).gradient,
        ),
      ),
    ),
  );
}
