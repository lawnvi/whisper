import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:whisper/cast_receiver/playback_engine.dart';
import 'package:whisper/cast_receiver/player.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/cast_playback_host.dart';

void main() {
  late _Engine engine;
  late CastPlayer player;

  Future<void> showPlayer(
    WidgetTester tester, {
    bool localVideo = false,
  }) async {
    engine = _Engine();
    player = CastPlayer(engineFactory: () async => engine)..activate();
    await player.command('load', {
      'url': 'https://example.com/video.mp4',
      'metadata': 'Holiday.mp4',
    });
    await player.command('play');
    await player.command('volume', {'value': .5});
    engine.volumes.clear();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      final closing = player.close();
      await tester.pump();
      await closing;
      player.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AnimatedBuilder(
          animation: player,
          builder: (_, _) =>
              CastPlaybackView(player: player, localVideo: localVideo),
        ),
      ),
    );
  }

  Finder volumeSlider() => find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == 'Volume',
    ),
    matching: find.byType(Slider),
  );

  testWidgets(
    'local playback shows the filename and offers replay at the end',
    (tester) async {
      await showPlayer(tester, localVideo: true);
      expect(find.text('Holiday.mp4'), findsOneWidget);
      expect(find.byIcon(Icons.tv_rounded), findsNothing);
      engine.completed = true;
      await player.command('seek', {'seconds': 60.0});
      await tester.pump();
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    },
  );

  testWidgets('dragging changes output volume before releasing the pointer', (
    tester,
  ) async {
    await showPlayer(tester);
    final slider = volumeSlider();
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(-25, 0));
    await tester.pump();
    expect(engine.volume, lessThan(.5));
    final intermediate = engine.volume;
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(engine.volume, greaterThan(intermediate));
    await gesture.up();
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, engine.volume);
  });

  testWidgets(
    'slow volume writes keep the latest value without a release jump',
    (tester) async {
      await showPlayer(tester);
      final gate = Completer<void>();
      engine.volumeGate = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final slider = volumeSlider();
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
      expect(engine.volumes, hasLength(1));
      for (var i = 0; i < 5; i++) {
        await gesture.moveBy(const Offset(8, 0));
        await tester.pump();
      }
      final target = tester.widget<Slider>(slider).value;
      expect(engine.volumes, hasLength(1));
      await gesture.up();
      await tester.pump();
      expect(tester.widget<Slider>(slider).value, target);
      expect(engine.volume, .5);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(engine.volumes, hasLength(2));
      expect(engine.volume, target);
      expect(player.status['volume'], target);

      // Once the drag is acknowledged, remote updates control the thumb again.
      await player.command('volume', {'value': .3});
      await tester.pump();
      expect(tester.widget<Slider>(slider).value, .3);
    },
  );

  testWidgets('failed live volume writes can be retried by dragging again', (
    tester,
  ) async {
    await showPlayer(tester);
    engine.failVolume = true;
    final slider = volumeSlider();
    var gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(-25, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(engine.volume, .5);
    expect(tester.widget<Slider>(slider).value, .5);
    expect(find.byType(SnackBar), findsOneWidget);

    engine.failVolume = false;
    gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump();
    expect(engine.volume, greaterThan(.5));
    await gesture.up();
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, engine.volume);
  });

  testWidgets('disposing playback drops unsent volume changes', (tester) async {
    await showPlayer(tester);
    final gate = Completer<void>();
    engine.volumeGate = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final slider = volumeSlider();
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(-25, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(engine.volumes, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await gesture.cancel();
    gate.complete();
    await tester.pump();
    expect(engine.volumes, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}

class _Engine implements CastPlaybackEngine {
  double volume = .5;
  final volumes = <double>[];
  Completer<void>? volumeGate;
  bool failVolume = false;
  bool completed = false;

  @override
  VideoController? get videoController => null;
  @override
  CastPlaybackState get state => CastPlaybackState(
    playing: !completed,
    completed: completed,
    duration: const Duration(seconds: 60),
  );
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<void> open(String uri) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double value) async {
    volumes.add(value);
    await volumeGate?.future;
    if (failVolume) {
      throw StateError('Volume unavailable');
    }
    volume = value;
  }

  @override
  Future<void> dispose() async {}
}
