import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'package:whisper/cast_receiver/playback_window.dart';
import 'package:whisper/cast_receiver/player.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/cast_playback_host.dart';

/// Playback-only UI in a child Flutter engine in the existing app process.
class CastPlaybackWindowApp extends StatefulWidget {
  const CastPlaybackWindowApp({super.key, this.localVideo = false});

  final bool localVideo;

  @override
  State<CastPlaybackWindowApp> createState() => _CastPlaybackWindowAppState();
}

class _CastPlaybackWindowAppState extends State<CastPlaybackWindowApp>
    with WindowListener {
  late final WindowController _controller;
  late final CastPlayer _player = CastPlayer(revealWindow: _showWindow);
  Future<void> _windowOperations = Future.value();
  Locale? _locale;
  bool _wasVisible = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await windowManager.ensureInitialized();
    // The native close button stops this video; it never exits Whisper.
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(960, 600),
        minimumSize: Size(560, 360),
        center: true,
        backgroundColor: Colors.black,
        titleBarStyle: TitleBarStyle.normal,
      ),
    );
    _controller = await WindowController.fromCurrentEngine();
    _player.addListener(_publishState);
    _player.activate();
    await _controller.setWindowMethodHandler((call) async {
      if (call.method != 'cast_command') {
        throw MissingPluginException('Unknown playback window method');
      }
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final language = args['locale'] as String?;
      final locale = AppLocalizations.supportedLocales
          .where((locale) => locale.languageCode == language)
          .firstOrNull;
      if (mounted && _locale != locale) setState(() => _locale = locale);
      final titleLocale =
          locale ?? WidgetsBinding.instance.platformDispatcher.locale;
      final supported =
          AppLocalizations.supportedLocales
              .where(
                (locale) => locale.languageCode == titleLocale.languageCode,
              )
              .firstOrNull ??
          const Locale('en');
      var failed = false;
      try {
        final command = args['command'] as String;
        if (command == 'shutdown') {
          await _player.close();
        } else {
          _player.activate();
          await _player.command(
            command,
            Map<String, Object>.from(args['data'] as Map),
          );
        }
        await windowManager.setTitle(
          'Whisper · ${widget.localVideo ? _player.metadata : lookupAppLocalizations(supported).castReceiverTitle}',
        );
        await _windowOperations;
      } on Object {
        failed = true;
      }
      return {'failed': failed, 'snapshot': _player.snapshot};
    });
    await _sendEvent('ready');
  }

  Future<void> _sendEvent(String name) async {
    try {
      await PlaybackWindowBridge.eventsFor(
        localVideo: widget.localVideo,
      ).invokeMethod('event', {
        'name': name,
        'windowId': _controller.windowId,
        'snapshot': _player.snapshot,
      });
    } on Object {
      // The main engine may already be shutting down.
    }
  }

  Future<void> _showWindow() {
    return _windowOperations = _windowOperations.then((_) async {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    });
  }

  void _publishState() {
    if (_wasVisible && !_player.visible) {
      _windowOperations = _windowOperations.then((_) async {
        if (await windowManager.isFullScreen()) {
          await windowManager.setFullScreen(false);
        }
        await windowManager.hide();
      });
    }
    _wasVisible = _player.visible;
    unawaited(_sendEvent('state'));
  }

  @override
  void onWindowClose() => unawaited(_stopFromWindow());

  Future<void> _stopFromWindow() async {
    await _player.command('stop');
    await _windowOperations;
    // A window can be closed before any media is loaded, too.
    await windowManager.hide();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _player.removeListener(_publishState);
    unawaited(_player.close().whenComplete(_player.dispose));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      locale: _locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: AnimatedBuilder(
        animation: _player,
        builder: (context, _) =>
            CastPlaybackView(player: _player, localVideo: widget.localVideo),
      ),
    );
  }
}
