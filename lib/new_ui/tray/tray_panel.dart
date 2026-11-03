import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/tray/tray_model.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';
import 'package:window_manager/window_manager.dart';

const trayPanelArgument = 'tray_panel';
const _width = 340.0;
const _theme = MethodChannel('com.vireen.whisper/window_theme');

/// docs/design/surfaces.md「托盘」, the prototype's `renderTray`: Whisper's everyday
/// entry. Its own window and engine, fed over the window channel.
class TrayPanelApp extends StatefulWidget {
  const TrayPanelApp({super.key});

  @override
  State<TrayPanelApp> createState() => _TrayPanelAppState();
}

class _TrayPanelAppState extends State<TrayPanelApp> with WindowListener {
  TrayState _state = const TrayState();
  String? _host;
  bool _brightnessSet = false;
  bool _shown = false;
  int _shownCount = 0;
  ({double x, double y, bool up, double maxHeight})? _at;
  final _content = GlobalKey();
  double _height = 200;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await windowManager.ensureInitialized();
    // On Windows this is what creates the plugin's taskbar object, and
    // setSkipTaskbar below crashes the whole process without it.
    if (Platform.isWindows) await windowManager.waitUntilReadyToShow();
    windowManager.addListener(this);
    await windowManager.setAsFrameless();
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setHasShadow(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setResizable(false);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setSize(Size(_width, _height));
    try {
      await _theme.invokeMethod<bool>('enablePanelMaterial', {
        'radius': WhisperRadius.tray,
      });
    } on Object {
      // Falls back to its own opaque colours.
    }
    final me = await WindowController.fromCurrentEngine();
    await me.setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'ping':
          return call.arguments;
        case 'state':
          final map = call.arguments as Map;
          _host = map['host'] as String?;
          final next = TrayState.fromMap(map);
          // The material follows the window's brightness, not the app's theme:
          // left alone it goes dark under a light panel on a dark system.
          if (next.dark != _state.dark || !_brightnessSet) {
            _brightnessSet = true;
            unawaited(
              WhisperWindow.applyBrightness(
                next.dark ? Brightness.dark : Brightness.light,
              ),
            );
          }
          if (mounted) setState(() => _state = next);
          _scheduleFit();
          return null;
        case 'showAt':
          final a = Map<String, dynamic>.from(call.arguments as Map);
          _at = (
            x: (a['x'] as num).toDouble(),
            y: (a['y'] as num).toDouble(),
            up: a['up'] as bool? ?? false,
            maxHeight: (a['maxHeight'] as num).toDouble(),
          );
          await _place();
          await windowManager.show();
          await windowManager.focus();
          if (mounted) {
            setState(() {
              _shown = true;
              _shownCount++;
            });
          }
          // On Windows a window resized while hidden goes on showing what it drew
          // at its old size, until it is resized again while it can be seen.
          if (Platform.isWindows) {
            await windowManager.setSize(Size(_width, _height + 1));
            await _place();
            _scheduleFit();
          }
          return null;
        case 'hide':
          await _hide();
          return null;
      }
      return null;
    });
  }

  void _scheduleFit() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final box = _content.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || !mounted) return;
      final wanted = box.size.height;
      if ((wanted - _height).abs() < 1) return;
      _height = wanted;
      await _place();
    });
  }

  Future<void> _place() async {
    final at = _at;
    if (at == null) return;
    final height = _height.clamp(60.0, at.maxHeight);
    await windowManager.setSize(Size(_width, height));
    await windowManager.setPosition(Offset(at.x, at.up ? at.y - height : at.y));
  }

  Future<void> _hide() async {
    if (mounted) setState(() => _shown = false);
    await windowManager.hide();
    unawaited(_send('closed'));
  }

  /// Back to the main engine, which does the work.
  Future<void> _send(String action, [Object? value]) async {
    final host = _host;
    if (host == null) return;
    final main = WindowController.fromWindowId(host);
    await main.invokeMethod<void>('trayAction', {
      'action': action,
      'value': value,
    });
  }

  @override
  void onWindowBlur() {
    // A request waiting for an answer keeps it open.
    if (_state.moments.any((m) => m.answers.isNotEmpty)) return;
    unawaited(_hide());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final up = _at?.up ?? false;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _state.dark ? AppTheme.darkTheme : AppTheme.lightTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale(_state.locale),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                unawaited(_hide()),
          },
          child: Focus(
            autofocus: true,
            child: SpringBuilder(
              key: ValueKey(_shownCount),
              value: _shown ? 1 : 0,
              from: 0,
              spring: WhisperSprings.smooth,
              animateWhenReduced: true,
              builder: (context, t, child) => Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(0, (up ? 10 : -10) * (1 - t)),
                  child: Transform.scale(
                    scale: .9 + .1 * t.clamp(0.0, 1.0),
                    alignment: up
                        ? Alignment.bottomCenter
                        : Alignment.topCenter,
                    child: child,
                  ),
                ),
              ),
              child: SingleChildScrollView(
                child: KeyedSubtree(
                  key: _content,
                  // surfaces.md: the system's material alone goes grey over a
                  // dark window, so the panel's own tint goes on top of it.
                  child: Builder(
                    builder: (context) => DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.wc.panelTint,
                        borderRadius: BorderRadius.circular(WhisperRadius.tray),
                      ),
                      child: TrayPanelBody(
                        state: _state,
                        onAction: (action, [value]) =>
                            unawaited(_send(action, value)),
                        onHeightChanged: _scheduleFit,
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

typedef TrayAction = void Function(String action, [Object? value]);

/// The panel's contents, apart from its window, so they can be tested.
class TrayPanelBody extends StatefulWidget {
  const TrayPanelBody({
    super.key,
    required this.state,
    required this.onAction,
    this.onHeightChanged,
  });

  final TrayState state;
  final TrayAction onAction;
  final VoidCallback? onHeightChanged;

  @override
  State<TrayPanelBody> createState() => _TrayPanelBodyState();
}

class _TrayPanelBodyState extends State<TrayPanelBody> {
  String? _copied;
  String? _flash;

  Timer? _copiedReset;

  void _copy(TrayClip clip) {
    setState(() => _copied = clip.text);
    widget.onAction('clipCopy', clip.text);
    _copiedReset?.cancel();
    _copiedReset = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _copied = null);
    });
  }

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  void _sendTo(TrayDevice device) {
    setState(() => _flash = device.id);
    widget.onAction('send', device.id);
    Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = context.wc;
    const type = WhisperType(touch: false);
    final state = widget.state;
    final on = widget.onAction;
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Module(
            child: state.targets.isEmpty
                ? _noTargets(context, l10n)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
                        child: Row(
                          children: [
                            SizedBox.square(
                              dimension: _lead,
                              child: Center(
                                child: state.currentImage
                                    ? Container(
                                        width: 22,
                                        height: 22,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            5,
                                          ),
                                          gradient: const LinearGradient(
                                            colors: [
                                              Radix.indigo9,
                                              Radix.violet9,
                                            ],
                                          ),
                                        ),
                                      )
                                    : WhisperIcon(
                                        WhisperGlyph.clip,
                                        size: 17,
                                        color: c.ink2Glass,
                                      ),
                              ),
                            ),
                            const SizedBox(width: _leadGap),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    state.current.isEmpty
                                        ? l10n.shellTrayClipboardEmpty
                                        : state.current,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: type.note,
                                      height: 1.3,
                                      fontWeight: FontWeight.w500,
                                      color: c.ink,
                                    ),
                                  ),
                                  Text(
                                    l10n.shellTrayClipboard,
                                    style: TextStyle(
                                      fontSize: type.note,
                                      color: c.ink2Glass,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            _TrayIcon(
                              glyph: WhisperGlyph.camera,
                              size: 15,
                              label: l10n.shellTrayScreenshot,
                              onTap: () => on('screenshot'),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          for (final device in state.targets)
                            Expanded(
                              child: _Target(
                                device: device,
                                flash: _flash == device.id,
                                onTap: () => _sendTo(device),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
          ),
          for (final moment in state.moments) ...[
            const SizedBox(height: 8),
            _Module(
              padding: moment.progress == null
                  ? const EdgeInsets.all(10)
                  : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: _MomentView(moment: moment, onAction: on),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _Tile(
                  glyph: WhisperGlyph.speaker,
                  title: l10n.shellSound,
                  status: state.soundStatus,
                  on: state.soundOn,
                  onTap: () => on('openSound'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Tile(
                  glyph: WhisperGlyph.keyboard,
                  title: l10n.shellInput,
                  status: state.inputStatus,
                  on: state.inputOn,
                  onTap: () => on('openInput'),
                ),
              ),
            ],
          ),
          if (state.flows.isNotEmpty) ...[
            const SizedBox(height: 8),
            _Module(
              child: Column(
                children: [
                  for (final flow in state.flows)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 34),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: _lead,
                            child: Center(
                              child: WhisperIcon(
                                WhisperGlyph.window,
                                size: 15,
                                color: c.ink2Glass,
                              ),
                            ),
                          ),
                          const SizedBox(width: _leadGap),
                          Expanded(
                            child: _TwoLines(
                              first: flow.title,
                              second: flow.detail,
                            ),
                          ),
                          _TextButton(
                            label: flow.action,
                            onTap: () => on('endFlow', flow.id),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          // One row would only repeat what the send module already says.
          if (state.clips.length > 1) ...[
            const SizedBox(height: 8),
            _Module(
              padding: const EdgeInsets.all(4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                    child: Text(
                      l10n.shellTrayRecent,
                      style: TextStyle(
                        fontSize: type.tiny,
                        fontWeight: FontWeight.w500,
                        color: c.ink2Glass,
                      ),
                    ),
                  ),
                  for (final clip in state.clips.take(5))
                    Pressable(
                      onTap: () => _copy(clip),
                      radius: WhisperRadius.s,
                      scale: 1,
                      label: clip.text,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 40),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 5,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: _TwoLines(
                                  first: clip.text,
                                  second: clip.line,
                                  regular: true,
                                ),
                              ),
                              const SizedBox(width: 9),
                              SizedBox.square(
                                dimension: 24,
                                child: Center(
                                  // Just the icon, for a moment, then back.
                                  child: _copied == clip.text
                                      ? WhisperIcon(
                                          WhisperGlyph.check,
                                          size: 14,
                                          weight: 2.2,
                                          color: c.accentText,
                                        )
                                      : WhisperIcon(
                                          WhisperGlyph.copy,
                                          size: 14,
                                          color: c.ink2Glass,
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _TrayIcon(
                  glyph: WhisperGlyph.window,
                  size: 15,
                  label: l10n.shellTrayOpen,
                  onTap: () => on('openMain'),
                ),
                const SizedBox(width: 2),
                _TrayIcon(
                  glyph: WhisperGlyph.gear,
                  size: 15,
                  label: l10n.shellSettings,
                  onTap: () => on('openSettings'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _noTargets(BuildContext context, AppLocalizations l10n) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    final nearby = widget.state.nearby;
    if (nearby.isEmpty) {
      return Column(
        children: [
          Text(
            l10n.shellTrayNoDevice,
            style: TextStyle(fontSize: type.note, color: c.ink2Glass),
          ),
          const SizedBox(height: 8),
          _FilledButton(
            label: l10n.shellAddDevice,
            onTap: () => widget.onAction('connectNew'),
          ),
        ],
      );
    }
    return Column(
      children: [
        for (final device in nearby.take(3))
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 34),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: type.note, color: c.ink),
                  ),
                ),
                _TextButton(
                  label: l10n.shellConnect,
                  onTap: () => widget.onAction('connect', device.id),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// `.mod`: a block of control glass, with a highlight along the top.
/// Every row's picture sits in a box this size, and its text starts at the same
/// place, whatever the picture.
const double _lead = 24, _leadGap = 8;

class _Module extends StatelessWidget {
  const _Module({required this.child, this.padding = const EdgeInsets.all(10)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.wc.controlTint,
      borderRadius: BorderRadius.circular(WhisperRadius.m),
      border: Border(
        top: BorderSide(
          width: .5,
          color: WhisperShadow.highlight(Theme.of(context).brightness),
        ),
      ),
    ),
    child: Padding(padding: padding, child: child),
  );
}

class _Target extends StatelessWidget {
  const _Target({
    required this.device,
    required this.flash,
    required this.onTap,
  });

  final TrayDevice device;
  final bool flash;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    final kind = deviceKindFor(device.platform, name: device.name);
    return Pressable(
      onTap: onTap,
      radius: WhisperRadius.m,
      label: device.name,
      child: SpringBuilder(
        value: flash ? .3 : 0,
        animateWhenReduced: true,
        builder: (context, t, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: t.clamp(0, 1)),
            borderRadius: BorderRadius.circular(WhisperRadius.m),
          ),
          child: child,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 2, 5),
          child: Column(
            children: [
              SizedBox(
                height: 38,
                child: Center(
                  child: DeviceArt(
                    kind: kind,
                    os: deviceOsFor(device.platform),
                    wallpaper: DeviceWallpaper.forPairingOrder(device.order),
                    size: kind.handheld ? 38 : 48,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                device.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: type.tiny, color: c.ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MomentView extends StatelessWidget {
  const _MomentView({required this.moment, required this.onAction});

  final TrayMoment moment;
  final TrayAction onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final progress = moment.progress;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (progress == null)
              SizedBox.square(
                dimension: _lead,
                child: Center(
                  child: WhisperIcon(WhisperGlyph.ask, size: 18, color: c.warn),
                ),
              )
            else
              SizedBox.square(
                dimension: _lead,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2.5,
                  color: c.accent,
                  backgroundColor: c.fill2,
                ),
              ),
            const SizedBox(width: _leadGap),
            Expanded(
              child: _TwoLines(first: moment.title, second: moment.detail),
            ),
            if (moment.cancelable)
              _TrayIcon(
                glyph: WhisperGlyph.x,
                size: 12,
                weight: 2,
                label: l10n.cancel,
                onTap: () => onAction('cancel', moment.id),
              ),
          ],
        ),
        if (moment.answers.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final (i, answer) in moment.answers.indexed)
                i == 0
                    ? _FilledButton(
                        label: answer,
                        onTap: () =>
                            onAction('answer', {'id': moment.id, 'index': i}),
                      )
                    : _TextButton(
                        label: answer,
                        onTap: () =>
                            onAction('answer', {'id': moment.id, 'index': i}),
                      ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.glyph,
    required this.title,
    required this.status,
    required this.on,
    required this.onTap,
  });

  final WhisperGlyph glyph;
  final String title, status;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    return Pressable(
      onTap: onTap,
      radius: WhisperRadius.m,
      label: title,
      child: _Module(
        padding: const EdgeInsets.all(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 38),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: on ? c.accent : c.fill,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: WhisperIcon(
                    glyph,
                    size: 16,
                    color: on ? c.onAccent : c.ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: type.note,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.tiny,
                        height: 1.3,
                        color: c.ink2Glass,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TwoLines extends StatelessWidget {
  const _TwoLines({
    required this.first,
    required this.second,
    this.regular = false,
  });

  final String first, second;
  final bool regular;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          first,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: type.note,
            height: 1.3,
            fontWeight: regular ? FontWeight.w400 : FontWeight.w500,
            color: c.ink,
          ),
        ),
        Text(
          second,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: type.tiny,
            height: 1.3,
            color: c.ink2Glass,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _TrayIcon extends StatelessWidget {
  const _TrayIcon({
    required this.glyph,
    required this.size,
    required this.label,
    required this.onTap,
    this.weight = 1.6,
  });

  final WhisperGlyph glyph;
  final double size, weight;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Pressable(
      onTap: onTap,
      radius: WhisperRadius.xs,
      label: label,
      child: SizedBox.square(
        dimension: 28,
        child: Center(
          child: WhisperIcon(
            glyph,
            size: size,
            weight: weight,
            color: context.wc.ink2Glass,
          ),
        ),
      ),
    ),
  );
}

class _FilledButton extends StatelessWidget {
  const _FilledButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    radius: WhisperRadius.capsule,
    child: Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color: context.wc.accent,
        borderRadius: BorderRadius.circular(WhisperRadius.capsule),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: const WhisperType(touch: false).note,
              fontWeight: FontWeight.w500,
              color: context.wc.onAccent,
            ),
          ),
        ],
      ),
    ),
  );
}

class _TextButton extends StatelessWidget {
  const _TextButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    radius: WhisperRadius.capsule,
    child: Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: const WhisperType(touch: false).note,
              fontWeight: FontWeight.w500,
              color: context.wc.accentText,
            ),
          ),
        ],
      ),
    ),
  );
}

/// What the app's main engine answers to, in its own window controller.
bool get trayPanelSupported => Platform.isMacOS || Platform.isWindows;
