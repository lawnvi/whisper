import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../island_activity.dart';
import '../island_views.dart';

/// This phone's apps shown, and usable, on another device (a desktop
/// streaming them over adb). The window-stream agent reports to the app's
/// provider; the provider tells this source, and "停止流转" asks the agent to
/// stop the same way the notification's button does.
class StreamedIslandSource extends ChangeNotifier implements IslandSource {
  StreamedIslandSource({
    MethodChannel? channel,
    bool? enabled,
    IslandClock clock = const IslandClock(),
  }) : _channel = channel ?? const MethodChannel(channelName),
       _clock = clock {
    if (enabled ?? Platform.isAndroid) {
      _channel.setMethodCallHandler(_onCall);
      unawaited(_load());
    }
  }

  static const channelName = 'com.vireen.whisper/window_stream_phone';

  final MethodChannel _channel;
  final IslandClock _clock;

  int _round = 0;
  int _windows = 0;
  String _viewer = '';
  bool _stopping = false;
  bool _ended = false;
  DateTime _since = DateTime.fromMillisecondsSinceEpoch(0);

  String get _id => 'streamed:$_round';

  @override
  List<IslandActivity> get activities {
    if (_windows <= 0 && !_ended) {
      return const [];
    }
    return [
      IslandActivity(
        id: _id,
        kind: IslandKind.streamed,
        status: _ended ? IslandStatus.ended : IslandStatus.live,
        since: _since,
        // Someone can see and use this phone: shown even over a page that
        // fills the screen.
        urgent: true,
        presenter: StreamedPresenter(
          id: _id,
          windows: _windows,
          viewer: _viewer,
          stopping: _stopping,
          ended: _ended,
          stop: stop,
        ),
      ),
    ];
  }

  Future<void> _load() async {
    try {
      final state = await _channel.invokeMapMethod<String, Object?>('state');
      if (state != null) {
        _apply(state);
      }
    } on PlatformException {
      // No provider (older build): nothing is streamed as far as we know.
    } on MissingPluginException {
      // Same.
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'state') {
      final arguments = call.arguments;
      if (arguments is Map) {
        _apply(Map<String, Object?>.from(arguments));
      }
    }
    return null;
  }

  /// What the provider last heard from the agent.
  @visibleForTesting
  void apply(Map<String, Object?> state) => _apply(state);

  void _apply(Map<String, Object?> state) {
    final windows = (state['windows'] as num?)?.toInt() ?? 0;
    final viewer = (state['viewer'] as String?)?.trim() ?? '';
    final stopping = state['stopping'] == true;
    final wasStreaming = _windows > 0;
    if (windows > 0 && (!wasStreaming || _ended)) {
      _round++;
      _since = _clock.now();
      _ended = false;
    }
    if (windows <= 0 && wasStreaming) {
      _ended = true;
    }
    final changed =
        windows != _windows || viewer != _viewer || stopping != _stopping;
    _windows = windows;
    if (viewer.isNotEmpty || windows <= 0) {
      _viewer = viewer.isEmpty ? _viewer : viewer;
    }
    _stopping = stopping && windows > 0;
    if (changed) {
      notifyListeners();
    }
  }

  /// Same as the notification's "停止流转".
  Future<void> stop() async {
    if (_windows <= 0 || _stopping) {
      return;
    }
    _stopping = true;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      _stopping = false;
      notifyListeners();
    } on MissingPluginException {
      _stopping = false;
      notifyListeners();
    }
  }

  @override
  Stream<String> get spotlights => const Stream<String>.empty();

  @override
  void retired(String id) {
    if (id == _id && _ended) {
      _ended = false;
      _viewer = '';
    }
  }

  @override
  void dismissed(IslandActivity activity) {}

  @override
  void expired(IslandActivity activity) {}

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

class StreamedPresenter extends IslandPresenter {
  const StreamedPresenter({
    required this.id,
    required this.windows,
    required this.viewer,
    required this.stopping,
    required this.ended,
    required this.stop,
  });

  final String id;
  final int windows;
  final String viewer;
  final bool stopping;
  final bool ended;
  final Future<void> Function() stop;

  Color get _tint => ended
      ? IslandColors.gray
      : stopping
      ? IslandColors.paused
      : IslandColors.live;

  String _device(AppLocalizations l10n) =>
      viewer.isEmpty ? l10n.islandStreamedOtherDevice : viewer;

  String _status(AppLocalizations l10n) => ended
      ? l10n.islandStreamedEnded
      : stopping
      ? l10n.islandStreamedStopping
      : l10n.islandStreamedWindows(windows);

  Widget _picture(double size) => Icon(
    ended
        ? CupertinoIcons.device_phone_portrait
        : CupertinoIcons.dot_radiowaves_left_right,
    size: size * 0.78,
    color: _tint,
  );

  @override
  Widget compact(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IslandCompactLine(
      leading: SizedBox.square(dimension: 20, child: _picture(22)),
      title: _device(l10n),
      trailing: ended || stopping
          ? Text(
              ended ? l10n.islandStreamedEnded : l10n.islandStreamedStopping,
              style: IslandText.compactFigure(_tint),
            )
          : _Count(windows: windows, tint: _tint),
    );
  }

  @override
  Widget glyph(BuildContext context, double size) => _picture(size);

  @override
  Widget featured(BuildContext context, IslandControls controls) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IslandHead(
            leading: IslandTile(tint: _tint, child: _picture(26)),
            title: ended
                ? l10n.islandStreamedEnded
                : l10n.islandStreamedTitle(_device(l10n)),
            subtitle: ended ? '' : _status(l10n),
            subtitleColor: stopping ? _tint : null,
          ),
          if (!ended) ...[
            const SizedBox(height: 14),
            IslandCapsuleButton(
              label: stopping
                  ? l10n.islandStreamedStopping
                  : l10n.islandStreamedStop,
              foreground: stopping ? IslandColors.dim : IslandColors.failed,
              onPressed: () => unawaited(stop()),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget row(BuildContext context, IslandControls controls) {
    final l10n = AppLocalizations.of(context)!;
    return IslandRowLine(
      leading: _picture(18),
      title: _device(l10n),
      status: _status(l10n),
      statusColor: _tint,
      onTap: () => controls.feature(id),
      trailing: ended || stopping
          ? null
          : IslandRoundButton(
              icon: CupertinoIcons.stop_fill,
              size: 28,
              label: l10n.islandStreamedStop,
              tint: IslandColors.failed,
              onPressed: () => unawaited(stop()),
            ),
    );
  }

  @override
  String describe(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ended
        ? l10n.islandStreamedEnded
        : '${l10n.islandStreamedTitle(_device(l10n))}, ${_status(l10n)}';
  }
}

/// How many windows are out there, in a small pill.
class _Count extends StatelessWidget {
  const _Count({required this.windows, required this.tint});

  final int windows;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: ShapeDecoration(
        color: tint.withValues(alpha: 0.22),
        shape: const StadiumBorder(),
      ),
      child: Text(
        '$windows',
        textAlign: TextAlign.center,
        style: IslandText.compactFigure(tint).copyWith(fontSize: 12),
      ),
    );
  }
}
