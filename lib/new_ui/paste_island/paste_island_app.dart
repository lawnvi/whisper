import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/shell/shell_island.dart';
import 'package:whisper/new_ui/shell/shell_island_sources.dart';
import 'package:whisper/remote_input/remote_clipboard_paste_watch.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/radix_colors.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';

const pasteIslandArgument = 'paste_island';

/// Where a paste waiting for its files shows over every app: macOS and
/// Windows, whose windows can float without taking the keyboard.
bool get pasteIslandSupported => Platform.isMacOS || Platform.isWindows;

const _theme = MethodChannel('com.vireen.whisper/window_theme');

/// docs/design/surfaces.md「灵动岛」, floating: the same black capsule at the
/// top middle of the screen with the pointer, for a paste whose files are
/// still coming. Its own window and engine, fed over the window channel.
class PasteIslandApp extends StatefulWidget {
  const PasteIslandApp({super.key});

  @override
  State<PasteIslandApp> createState() => _PasteIslandAppState();
}

class _PasteIslandAppState extends State<PasteIslandApp> {
  /// The island lays itself out in this much; the window shows the part of
  /// it the island is in, so the rest of the screen keeps its clicks.
  static const _area = Size(_openWidth + 2 * _openMargin, 360);
  static const _openWidth = 372.0, _compactMax = 260.0, _pill = 34.0;

  /// Room for the island's shadows: `WhisperShadow.islandClosed` and
  /// `islandOpen`, blur plus offset.
  static const _compactMargin = 20.0, _openMargin = 44.0, _openBelow = 60.0;
  static const _top = 9.0;

  /// The open card: its padding, and a row per paste (`_Moment`), at most
  /// this many counted.
  static const _cardPadding = 20.0, _rowHeight = 46.0, _rowsAtMost = 5;

  final _source = IslandListSource();
  late final IslandCenter _center = IslandCenter(sources: [_source]);

  String? _host;
  String _locale = 'zh';
  final Map<int, String> _devices = {};
  final Set<int> _seen = {};
  final Map<int, DateTime> _since = {};
  final Map<int, Timer> _settles = {};
  Timer? _fallback;
  Size? _placed;
  Size _drawn = Size.zero;
  bool _visible = false;
  IslandStage _stage = IslandStage.hidden;

  /// macOS: no frame goes to the engine until the window has its size, as
  /// for the tray panel (see `TrayPanelApp`): the first resize after a frame
  /// waits a second.
  bool _firstFrameHeld = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS) {
      WidgetsBinding.instance.deferFirstFrame();
      _firstFrameHeld = true;
    }
    _center.addListener(_onStage);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      // First on macOS: a panel, which can float without activating Whisper.
      if (Platform.isMacOS) await _theme.invokeMethod<bool>('becomeTrayPanel');
      await _theme.invokeMethod<bool>('becomeIsland');
    } on Object {
      // An older runner: nothing shows, the paste still happens.
    }
    final me = await WindowController.fromCurrentEngine();
    await me.setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'ping':
          return call.arguments;
        case 'state':
          await _onState(Map<String, dynamic>.from(call.arguments as Map));
          return null;
      }
      return null;
    });
  }

  Future<void> _onState(Map<String, dynamic> map) async {
    _host = map['host'] as String? ?? _host;
    _locale = map['locale'] as String? ?? _locale;
    final pastes = <RemoteClipboardPasteState>[];
    for (final raw in map['pastes'] as List? ?? const []) {
      final paste = RemoteClipboardPasteState.fromMap(raw);
      if (paste == null) continue;
      pastes.add(paste);
      _devices[paste.id] = (raw as Map)['device'] as String? ?? '';
    }
    final fresh = pastes.any((paste) => !_seen.contains(paste.id));
    if (fresh) {
      if (!_visible) {
        await _place(_compactSize, rescreen: true);
        if (_firstFrameHeld) {
          _firstFrameHeld = false;
          WidgetsBinding.instance.allowFirstFrame();
          await WidgetsBinding.instance.endOfFrame;
        }
        await _theme.invokeMethod<bool>('showIsland');
        _visible = true;
        // On Windows a window resized while hidden goes on showing what it
        // drew at its old size until it is resized where it can be seen.
        if (Platform.isWindows) {
          await _place(_compactSize + const Offset(0, 1));
          await _place(_compactSize);
        }
      }
    }
    final ids = {for (final paste in pastes) 'paste:${paste.id}'};
    for (final activity in _source.activities) {
      if (!ids.contains(activity.id)) _source.remove(activity.id);
    }
    for (final paste in pastes) {
      _seen.add(paste.id);
      _put(paste);
    }
    // More rows in the open card: a taller window.
    _fitWindow();
  }

  void _put(RemoteClipboardPasteState paste) {
    final id = 'paste:${paste.id}';
    final status = switch (paste.stage) {
      RemoteClipboardPasteStage.receiving => IslandStatus.live,
      // The card opens: what to press, or where the files went while the
      // user was in another window.
      RemoteClipboardPasteStage.ready ||
      RemoteClipboardPasteStage.placed => IslandStatus.waiting,
      RemoteClipboardPasteStage.pasted => IslandStatus.done,
      RemoteClipboardPasteStage.failed => IslandStatus.failed,
      RemoteClipboardPasteStage.canceled => IslandStatus.ended,
    };
    _source.put(
      IslandActivity(
        id: id,
        kind: IslandKind.copy,
        status: status,
        since: _since.putIfAbsent(paste.id, DateTime.now),
        urgent: true,
        presenter: PasteIslandPresenter(
          paste: paste,
          device: _devices[paste.id] ?? '',
          onCancel: () => unawaited(_send('cancel', paste.id)),
        ),
      ),
    );
    switch (paste.stage) {
      case RemoteClipboardPasteStage.placed:
        // Done: it says where the files went for as long as a done thing
        // stays, then goes.
        _settles[paste.id] ??= Timer(
          IslandCenter.doneLingers,
          () => _source.remove(id),
        );
      case RemoteClipboardPasteStage.ready || RemoteClipboardPasteStage.failed:
        // Open for as long as trouble is, then away: nothing to try here.
        _settles[paste.id] ??= Timer(
          IslandCenter.troubleOpen + const Duration(seconds: 1),
          () => _source.put(_ended(id, paste)),
        );
      case RemoteClipboardPasteStage.receiving ||
          RemoteClipboardPasteStage.pasted ||
          RemoteClipboardPasteStage.canceled:
        break;
    }
  }

  IslandActivity _ended(String id, RemoteClipboardPasteState paste) =>
      IslandActivity(
        id: id,
        kind: IslandKind.copy,
        status: paste.stage == RemoteClipboardPasteStage.failed
            ? IslandStatus.ended
            : IslandStatus.done,
        since: _since[paste.id] ?? DateTime.now(),
        urgent: true,
        presenter: PasteIslandPresenter(
          paste: paste,
          device: _devices[paste.id] ?? '',
          onCancel: null,
        ),
      );

  Size get _compactSize => const Size(
    _compactMax + 2 * _compactMargin,
    _top + _pill + _compactMargin,
  );
  Size get _openSize {
    final rows = _source.activities.length.clamp(1, _rowsAtMost);
    return Size(
      _openWidth + 2 * _openMargin,
      _top + _cardPadding + _rowHeight * rows + _openBelow,
    );
  }

  /// The window follows the island: bigger the moment it needs to be,
  /// smaller only once what the island draws fits in less, and away once it
  /// has left. Not by the clock: a busy moment slows the island down, and a
  /// window that went small on time would cut it off.
  void _onStage() {
    final stage = _center.stage;
    if (stage == _stage) return;
    _stage = stage;
    _fitWindow();
    // If no frame says so (none drawn at all), the window follows anyway.
    _fallback?.cancel();
    _fallback = Timer(
      const Duration(milliseconds: 1500),
      () => _fitWindow(force: true),
    );
  }

  /// How big the island is drawn now: the capsule or card, scaled as it
  /// comes or goes; nothing once it has gone.
  void _onDrawn(Size size) {
    _drawn = size;
    _fitWindow();
  }

  void _fitWindow({bool force = false}) {
    if (!_visible) return;
    final (wanted, side, below) = switch (_stage) {
      IslandStage.expanded => (_openSize, _openMargin, _openBelow),
      IslandStage.compact => (_compactSize, _compactMargin, _compactMargin),
      IslandStage.hidden => (Size.zero, 0.0, 0.0),
    };
    if (_stage == IslandStage.hidden) {
      if (force || _drawn == Size.zero) _hide();
      return;
    }
    final fits =
        _drawn.width <= wanted.width - 2 * side + 1 &&
        _drawn.height <= wanted.height - _top - below + 1;
    final placed = _placed ?? wanted;
    unawaited(
      _place(
        fits || force
            ? wanted
            : Size(
                math.max(wanted.width, placed.width),
                math.max(wanted.height, placed.height),
              ),
      ),
    );
  }

  void _hide() {
    _visible = false;
    _fallback?.cancel();
    for (final activity in _source.activities) {
      _source.remove(activity.id);
    }
    unawaited(_theme.invokeMethod<bool>('hideIsland'));
  }

  Future<void> _place(Size size, {bool rescreen = false}) async {
    // Progress comes four times a second: the window only moves for a change.
    if (!rescreen && size == _placed) return;
    _placed = size;
    try {
      await _theme.invokeMethod<bool>('placeIsland', {
        'width': size.width,
        'height': size.height,
        // Where the runner can, the island's view keeps this size and only
        // the window around it changes.
        'areaWidth': _area.width,
        'areaHeight': _area.height,
        'rescreen': rescreen,
      });
    } on Object {
      // An older runner.
    }
  }

  /// Back to the main engine, which does the work.
  Future<void> _send(String action, int id) async {
    final host = _host;
    if (host == null) return;
    await WindowController.fromWindowId(
      host,
    ).invokeMethod<void>('pasteIsland', {'action': action, 'id': id});
  }

  @override
  void dispose() {
    for (final timer in _settles.values) {
      timer.cancel();
    }
    _fallback?.cancel();
    _center.removeListener(_onStage);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale(_locale),
      color: Colors.transparent,
      home: Material(
        type: MaterialType.transparency,
        child: Align(
          alignment: Alignment.topCenter,
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minWidth: _area.width,
            maxWidth: _area.width,
            minHeight: _area.height,
            maxHeight: _area.height,
            child: Stack(
              children: [
                ShellIsland(
                  center: _center,
                  onDrawn: _onDrawn,
                  windowWidth: _area.width,
                  controlsLeft: _area.width,
                  titleRight: 0,
                  buttonsLeft: _area.width * 2,
                  buttonsBottom: 0,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One paste on the island: what comes, from where, how far along.
class PasteIslandPresenter extends IslandPresenter with MomentViews {
  const PasteIslandPresenter({
    required this.paste,
    required this.device,
    required this.onCancel,
  });

  final RemoteClipboardPasteState paste;
  final String device;
  final VoidCallback? onCancel;

  String _title(AppLocalizations l10n) => paste.names.length == 1
      ? paste.names.single
      : l10n.pasteIslandFiles(paste.names.length);

  String? get _percent {
    final progress = paste.progress;
    return progress == null ? null : '${(progress * 100).floor()}%';
  }

  Widget get _leading => switch (paste.stage) {
    RemoteClipboardPasteStage.receiving => IslandProgressRing(
      paste.progress ?? 0,
      key: const ValueKey('ring'),
    ),
    RemoteClipboardPasteStage.pasted ||
    RemoteClipboardPasteStage.placed ||
    RemoteClipboardPasteStage.ready => const WhisperIcon(
      WhisperGlyph.check,
      key: ValueKey('tick'),
      size: 16,
      weight: 2.4,
      color: Colors.white,
    ),
    RemoteClipboardPasteStage.failed ||
    RemoteClipboardPasteStage.canceled => const WhisperIcon(
      WhisperGlyph.warn,
      key: ValueKey('warn'),
      size: 16,
      color: Radix.amber9,
    ),
  };

  String _detail(AppLocalizations l10n) {
    switch (paste.stage) {
      case RemoteClipboardPasteStage.receiving:
        final seconds = paste.secondsLeft;
        if (paste.queued) {
          return [
            if (device.isNotEmpty) l10n.pasteIslandFrom(device),
            l10n.pasteIslandQueued,
          ].join(' · ');
        }
        return [
          if (device.isNotEmpty) l10n.pasteIslandFrom(device),
          ?_percent,
          if (seconds != null)
            seconds < 60
                ? l10n.pasteIslandSecondsLeft(seconds)
                : l10n.pasteIslandMinutesLeft((seconds / 60).ceil()),
        ].join(' · ');
      case RemoteClipboardPasteStage.pasted:
        return l10n.pasteIslandPasted;
      case RemoteClipboardPasteStage.placed:
        return l10n.pasteIslandPlaced(paste.folder);
      case RemoteClipboardPasteStage.ready:
        return l10n.pasteIslandReady(Platform.isMacOS ? '⌘V' : 'Ctrl+V');
      case RemoteClipboardPasteStage.failed:
        return l10n.pasteIslandFailed;
      case RemoteClipboardPasteStage.canceled:
        return l10n.pasteIslandCanceled;
    }
  }

  @override
  IslandMoment moment(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final receiving = paste.stage == RemoteClipboardPasteStage.receiving;
    return IslandMoment(
      leading: _leading,
      title: _title(l10n),
      value: receiving && !paste.queued ? _percent : null,
      detail: _detail(l10n),
      stopLabel: l10n.cancel,
      onStop: receiving ? onCancel : null,
    );
  }

  @override
  Widget glyph(BuildContext context, double size) => _leading;

  @override
  String describe(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return '${_title(l10n)} ${_detail(l10n)}';
  }
}
