import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';
import 'package:whisper/widget/island/island_host.dart';

import 'island_test_support.dart';

void main() {
  late IslandListSource source;
  late IslandCenter center;

  setUp(() {
    source = IslandListSource();
    center = IslandCenter(sources: [source]);
  });

  tearDown(() {
    center.dispose();
    source.dispose();
  });

  Future<void> pumpHost(WidgetTester tester, {Widget? home}) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(1236, 2676);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 84);
    addTearDown(tester.view.reset);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        navigatorKey: navigatorKey,
        builder: (context, child) => IslandHost(
          navigatorKey: navigatorKey,
          center: center,
          child: child!,
        ),
        home: home ?? const Scaffold(body: SizedBox.expand()),
      ),
    );
  }

  /// Springs settle within a second; time moves in frame-sized steps.
  Future<void> settle(WidgetTester tester, [int steps = 24]) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('one activity: the small island, then its card', (tester) async {
    await pumpHost(tester);
    source.put(islandActivity('copy', arrival: IslandArrival.quiet));
    await settle(tester);
    expect(find.text('compact:copy'), findsOneWidget);
    expect(find.text('glyph:copy'), findsNothing);
    final island = tester.getRect(find.text('compact:copy'));
    // Just under the status bar, centred.
    expect(island.top, greaterThan(28));
    expect(island.top, lessThan(28 + 6 + 36));
    expect(island.center.dx, closeTo(206, 2));

    await tester.tap(find.text('compact:copy'));
    await settle(tester);
    expect(center.stage, IslandStage.expanded);
    expect(find.text('featured:copy '), findsOneWidget);
    expect(find.textContaining('row:'), findsNothing);

    // Tapped again, it closes.
    await tester.tap(find.text('featured:copy '));
    await settle(tester);
    expect(center.stage, IslandStage.compact);
    expect(tester.takeException(), isNull);
  });

  testWidgets('three activities: a circle beside it, all in the card', (
    tester,
  ) async {
    await pumpHost(tester);
    source.activities = [
      islandActivity('copy', arrival: IslandArrival.quiet),
      islandActivity(
        'audio',
        kind: IslandKind.audio,
        arrival: IslandArrival.quiet,
      ),
      islandActivity(
        'streamed',
        kind: IslandKind.streamed,
        arrival: IslandArrival.quiet,
      ),
    ];
    await settle(tester);
    expect(find.text('compact:streamed'), findsOneWidget);
    expect(find.text('glyph:copy'), findsOneWidget);
    final pill = tester.getRect(find.text('compact:streamed'));
    final circle = tester.getRect(find.text('glyph:copy'));
    expect(circle.left, greaterThan(pill.right - 40));

    await tester.tap(find.text('glyph:copy'));
    await settle(tester);
    expect(center.stage, IslandStage.expanded);
    expect(find.text('featured:copy '), findsOneWidget);
    expect(find.text('row:streamed'), findsOneWidget);
    expect(find.text('row:audio'), findsOneWidget);
    expect(find.text('glyph:copy'), findsNothing);

    // Swiped up: the card closes, then the island goes.
    await tester.drag(find.text('featured:copy '), const Offset(0, -80));
    await settle(tester);
    expect(center.stage, IslandStage.compact);
    await tester.drag(find.text('compact:streamed'), const Offset(0, -80));
    await settle(tester);
    expect(center.stage, IslandStage.hidden);
    expect(find.textContaining('compact:'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden in the background, back on return', (tester) async {
    await pumpHost(tester);
    source.put(islandActivity('copy', arrival: IslandArrival.quiet));
    await settle(tester);
    expect(find.text('compact:copy'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // No frames are drawn now; nothing opens or arrives on screen.
    expect(center.stage, IslandStage.hidden);
    source.put(islandActivity('audio', kind: IslandKind.audio));
    await settle(tester);
    expect(center.stage, IslandStage.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    // What came meanwhile opens the card now.
    expect(center.stage, IslandStage.expanded);
    expect(find.text('featured:audio '), findsOneWidget);
    expect(find.text('row:copy'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a page that hides the status bar keeps only what needs you', (
    tester,
  ) async {
    await pumpHost(tester);
    source.activities = [
      islandActivity('copy', arrival: IslandArrival.quiet),
      islandActivity(
        'streamed',
        kind: IslandKind.streamed,
        arrival: IslandArrival.quiet,
        urgent: true,
      ),
    ];
    await settle(tester);
    expect(find.text('glyph:copy'), findsOneWidget);
    tester.view.padding = FakeViewPadding.zero;
    await settle(tester);
    expect(center.immersive, isTrue);
    expect(find.text('compact:streamed'), findsOneWidget);
    expect(find.text('glyph:copy'), findsNothing);
  });

  testWidgets('the island floats: nothing under it moves', (tester) async {
    await pumpHost(
      tester,
      home: Scaffold(
        appBar: AppBar(title: const Text('OnePlus 8'), centerTitle: true),
        body: const SafeArea(child: Text('first row')),
      ),
    );
    final title = find.text('OnePlus 8');
    final row = find.text('first row');
    final titleTop = tester.getTopLeft(title).dy;
    final rowTop = tester.getTopLeft(row).dy;

    source.put(islandActivity('copy', arrival: IslandArrival.quiet));
    await settle(tester);
    expect(find.text('compact:copy'), findsOneWidget);
    expect(tester.getTopLeft(title).dy, closeTo(titleTop, 0.5));
    expect(tester.getTopLeft(row).dy, closeTo(rowTop, 0.5));

    center.tap();
    await settle(tester);
    expect(center.stage, IslandStage.expanded);
    expect(tester.getTopLeft(title).dy, closeTo(titleTop, 0.5));
    expect(tester.getTopLeft(row).dy, closeTo(rowTop, 0.5));
    await tester.pump(const Duration(seconds: 10));
  });

  group('a camera in the middle of the screen', () {
    const camera = ui.DisplayFeature(
      bounds: Rect.fromLTWH(190, 8, 32, 32),
      type: ui.DisplayFeatureType.cutout,
      state: ui.DisplayFeatureState.unknown,
    );

    test('only one in the middle at the top counts', () {
      expect(islandCamera(const [camera], 412), camera.bounds);
      expect(islandCamera(const [], 412), isNull);
      // A corner hole, or a fold.
      const corner = ui.DisplayFeature(
        bounds: Rect.fromLTWH(20, 8, 32, 32),
        type: ui.DisplayFeatureType.cutout,
        state: ui.DisplayFeatureState.unknown,
      );
      const fold = ui.DisplayFeature(
        bounds: Rect.fromLTWH(190, 0, 32, 800),
        type: ui.DisplayFeatureType.fold,
        state: ui.DisplayFeatureState.postureFlat,
      );
      expect(islandCamera(const [corner, fold], 412), isNull);
    });

    testWidgets(
      'the small island goes around it, narrow enough for the clock',
      (tester) async {
        await pumpHost(tester);
        tester.view.displayFeatures = const [
          ui.DisplayFeature(
            bounds: Rect.fromLTWH(190, 8, 32, 32),
            type: ui.DisplayFeatureType.cutout,
            state: ui.DisplayFeatureState.unknown,
          ),
        ];
        source.put(islandActivity('copy', arrival: IslandArrival.quiet));
        await settle(tester);
        final pill = tester.getRect(
          find
              .ancestor(
                of: find.text('compact:copy'),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(pill.center.dy, closeTo(24, 1));
        expect(pill.center.dx, closeTo(206, 1));
        expect(pill.width, lessThan(177));
        await tester.pump(const Duration(seconds: 10));
      },
    );
  });

  testWidgets('a page may hush the island while it is first built', (
    tester,
  ) async {
    // The window viewer hushes it from initState (seen on a real iPad as
    // "setState() called during build").
    source.activities = [islandActivity('copy', arrival: IslandArrival.quiet)];
    await pumpHost(tester, home: _HushesOnOpen(center));
    expect(tester.takeException(), isNull);
    await settle(tester);
    expect(center.quiet, isTrue);
    expect(find.text('glyph:copy'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
  });
}

class _HushesOnOpen extends StatefulWidget {
  const _HushesOnOpen(this.center);

  final IslandCenter center;

  @override
  State<_HushesOnOpen> createState() => _HushesOnOpenState();
}

class _HushesOnOpenState extends State<_HushesOnOpen> {
  late final VoidCallback _unhush;

  @override
  void initState() {
    super.initState();
    _unhush = widget.center.hush();
  }

  @override
  void dispose() {
    _unhush();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}
