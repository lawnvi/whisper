// Step 1 of docs/design/migration.md: can a tray panel be its own window, and
// how does it talk to the main engine? Deleted once step 8 has the real panel.

import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_ui.dart';

const trayPanelProbeArgument = 'tray_panel_probe';

const _panelSize = Size(340, 420);
const _channel = MethodChannel('com.vireen.whisper/window_theme');

/// The main engine's end: owns the window, places it under the tray icon.
class TrayPanelProbeHost {
  WindowController? _window;
  bool _visible = false;

  Future<WindowController> _ensure() async {
    final existing = _window;
    if (existing != null) return existing;
    final window = await WindowController.create(
      const WindowConfiguration(
        hiddenAtLaunch: true,
        arguments: trayPanelProbeArgument,
      ),
    );
    _window = window;
    // The child's engine takes a moment; it answers once its handler is up.
    for (var i = 0; i < 100; i++) {
      try {
        await window
            .invokeMethod<Object?>('ping', 0)
            .timeout(const Duration(milliseconds: 200));
        break;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    return window;
  }

  Future<void> toggle() async {
    final window = await _ensure();
    if (_visible) {
      _visible = false;
      await window.hide();
      return;
    }
    final bounds = await trayManager.getBounds();
    await window.invokeMethod<void>('showAt', {
      'x': bounds?.left ?? 400,
      'y': bounds?.bottom ?? 30,
      'width': bounds?.width ?? 24,
    });
    _visible = true;
  }

  /// Creation cost and round-trip latency between the two engines.
  Future<Map<String, Object?>> measure() async {
    final create = Stopwatch()..start();
    final window = await _ensure();
    create.stop();
    final rounds = <int>[];
    for (var i = 0; i < 200; i++) {
      final watch = Stopwatch()..start();
      final answer = await window.invokeMethod<int>('ping', i);
      watch.stop();
      if (answer != i) throw StateError('answered $answer to $i');
      rounds.add(watch.elapsedMicroseconds);
    }
    rounds.sort();
    // A larger payload, about what the panel's whole state would be.
    final state = {
      'devices': [
        for (var i = 0; i < 12; i++)
          {
            'id': 'device-$i',
            'name': 'Device $i',
            'platform': 'macos',
            'connected': i.isEven,
          },
      ],
      'clips': [for (var i = 0; i < 5; i++) 'clipboard entry $i' * 8],
    };
    final watch = Stopwatch()..start();
    await window.invokeMethod<Object?>('state', state);
    watch.stop();

    final shown = Stopwatch()..start();
    await toggle();
    shown.stop();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final visibleResult = await window.invokeMethod<Map>('status');
    await toggle();
    return {
      'createUntilAnswering': '${create.elapsedMilliseconds} ms',
      'pingP50': '${rounds[rounds.length ~/ 2] / 1000} ms',
      'pingP99': '${rounds[(rounds.length * .99).floor()] / 1000} ms',
      'statePayload': '${watch.elapsedMicroseconds / 1000} ms',
      'showAt': '${shown.elapsedMilliseconds} ms',
      'panel': visibleResult,
    };
  }
}

/// The panel's own engine. Its singletons are separate from the main window's,
/// so everything it shows has to arrive over the window channel.
class TrayPanelProbeApp extends StatefulWidget {
  const TrayPanelProbeApp({super.key});

  @override
  State<TrayPanelProbeApp> createState() => _TrayPanelProbeAppState();
}

class _TrayPanelProbeAppState extends State<TrayPanelProbeApp>
    with WindowListener {
  bool _shown = false;
  int _blurs = 0;
  int _received = 0;
  bool? _material;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    WidgetsFlutterBinding.ensureInitialized();
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setAsFrameless();
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setHasShadow(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setResizable(false);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setSize(_panelSize);
    _material = await _channel
        .invokeMethod<bool>('enablePanelMaterial', {'radius': 24.0})
        .catchError((Object _) => false);
    final me = await WindowController.fromCurrentEngine();
    await me.setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'ping':
          return call.arguments;
        case 'state':
          if (mounted) setState(() => _received++);
          return null;
        case 'status':
          return {
            'visible': await windowManager.isVisible(),
            'focused': await windowManager.isFocused(),
            'size': (await windowManager.getSize()).toString(),
            'material': _material,
            'blursSeen': _blurs,
            'statesReceived': _received,
          };
        case 'showAt':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final x =
              (args['x'] as num).toDouble() +
              (args['width'] as num) / 2 -
              _panelSize.width / 2;
          await windowManager.setPosition(
            Offset(x, (args['y'] as num).toDouble() + 6),
          );
          await windowManager.show();
          await windowManager.focus();
          if (mounted) setState(() => _shown = true);
          return null;
      }
      return null;
    });
  }

  @override
  void onWindowBlur() {
    _blurs++;
    // A real panel closes here (surfaces.md「托盘」). Left open while the checks
    // run, so a capture can see it.
    if (!const bool.fromEnvironment('WHISPER_PROBE_AUTORUN')) {
      unawaited(windowManager.hide());
      if (mounted) setState(() => _shown = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Builder(
          builder: (context) {
            final c = context.wc;
            const type = WhisperType(touch: false);
            return SpringBuilder(
              value: _shown ? 1 : 0,
              from: 0,
              animateWhenReduced: true,
              builder: (context, t, child) => Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(0, -10 * (1 - t)),
                  child: Transform.scale(
                    scale: .9 + .1 * t,
                    alignment: Alignment.topCenter,
                    child: child,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    WhisperGlass(
                      kind: GlassKind.control,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(WhisperRadius.l),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '托盘面板验证',
                              style: TextStyle(
                                fontSize: type.body,
                                fontWeight: FontWeight.w600,
                                color: c.ink,
                              ),
                            ),
                            Text(
                              '独立窗口，独立引擎',
                              style: TextStyle(
                                fontSize: type.note,
                                color: c.ink2Glass,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                DeviceArt(
                                  kind: DeviceKind.desktop,
                                  wallpaper: DeviceWallpaper.forPairingOrder(0),
                                  size: 44,
                                ),
                                DeviceArt(
                                  kind: DeviceKind.laptop,
                                  wallpaper: DeviceWallpaper.forPairingOrder(1),
                                  size: 48,
                                ),
                                DeviceArt(
                                  kind: DeviceKind.phone,
                                  wallpaper: DeviceWallpaper.forPairingOrder(2),
                                  size: 38,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
