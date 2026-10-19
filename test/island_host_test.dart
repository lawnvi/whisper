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

  testWidgets('pages make room for the small island, the card lies over', (
    tester,
  ) async {
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
    // The band under the status bar: gap, island, gap; no double padding
    // for the body under the app bar.
    expect(tester.getTopLeft(title).dy, closeTo(titleTop + 48, 0.5));
    expect(tester.getTopLeft(row).dy, closeTo(rowTop + 48, 0.5));
    final island = tester.getRect(find.text('compact:copy'));
    expect(island.bottom, lessThan(tester.getTopLeft(title).dy));

    center.tap();
    await settle(tester);
    expect(center.stage, IslandStage.expanded);
    expect(tester.getTopLeft(title).dy, closeTo(titleTop + 48, 0.5));

    center.collapse();
    center.swipeUp();
    await settle(tester);
    expect(tester.getTopLeft(title).dy, closeTo(titleTop, 0.5));

    // A page that hides the status bar is not pushed.
    source.put(
      islandActivity(
        'streamed',
        kind: IslandKind.streamed,
        arrival: IslandArrival.quiet,
        urgent: true,
      ),
    );
    tester.view.padding = FakeViewPadding.zero;
    await settle(tester);
    expect(find.text('compact:streamed'), findsOneWidget);
    expect(tester.getTopLeft(row).dy, closeTo(rowTop - 28, 0.5));
    await tester.pump(const Duration(seconds: 10));
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
