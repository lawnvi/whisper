import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';
import 'package:whisper/widget/island/island_home.dart';

class _Plain extends IslandPresenter {
  const _Plain();

  @override
  Widget compact(BuildContext context) => const SizedBox.shrink();
  @override
  Widget glyph(BuildContext context, double size) => const SizedBox.shrink();
  @override
  Widget featured(BuildContext context, IslandControls controls) =>
      const SizedBox.shrink();
  @override
  Widget row(BuildContext context, IslandControls controls) =>
      const SizedBox.shrink();
  @override
  String describe(BuildContext context) => '';
}

IslandActivity _activity({
  String id = 'transfer',
  IslandKind kind = IslandKind.copy,
  IslandStatus status = IslandStatus.live,
  String? home = 'message:1',
  bool urgent = false,
  IslandArrival arrival = IslandArrival.quiet,
}) => IslandActivity(
  id: id,
  kind: kind,
  status: status,
  since: DateTime(2026),
  presenter: const _Plain(),
  home: home,
  urgent: urgent,
  arrival: arrival,
);

void main() {
  late IslandListSource source;
  late IslandCenter center;

  setUp(() {
    source = IslandListSource();
    center = IslandCenter(sources: [source]);
  });
  tearDown(() => center.dispose());

  group('the island says what cannot be seen', () {
    test('elsewhere it shows', () {
      source.activities = [_activity()];
      expect(center.visible.map((a) => a.id), ['transfer']);
    });

    test('while its home is on screen it does not, and back again', () {
      source.activities = [_activity()];
      center.enterHome('message:1');
      expect(center.visible, isEmpty);
      expect(center.stage, IslandStage.hidden);
      center.leaveHome('message:1');
      expect(center.visible.map((a) => a.id), ['transfer']);
    });

    test('another home does not count', () {
      source.activities = [_activity()];
      center.enterHome('message:2');
      expect(center.visible, hasLength(1));
    });

    test('it does not open for what is at home', () {
      center.enterHome('message:1');
      source.activities = [_activity(arrival: IslandArrival.open)];
      expect(center.stage, IslandStage.hidden);
    });

    test('what finishes at home was seen: nothing left when leaving', () {
      center.enterHome('message:1');
      source.activities = [_activity()];
      for (final status in [IslandStatus.done, IslandStatus.failed]) {
        source.activities = [_activity(status: status)];
        expect(center.visible, isEmpty);
      }
      center.leaveHome('message:1');
      expect(center.visible, isEmpty);
    });

    test('a failure elsewhere stays until it is put away', () {
      source.activities = [_activity()];
      source.activities = [_activity(status: IslandStatus.failed)];
      expect(center.visible, hasLength(1));
    });

    test('a request is never left to a page', () {
      center.enterHome('message:1');
      source.activities = [_activity(kind: IslandKind.request)];
      expect(center.visible, hasLength(1));
    });

    test('nor what is marked urgent', () {
      center.enterHome('message:1');
      source.activities = [_activity(urgent: true)];
      expect(center.visible, hasLength(1));
    });

    test('in the background nothing is on screen', () {
      center.enterHome('message:1');
      source.activities = [_activity()];
      center.setForeground(false);
      expect(center.visible, hasLength(1));
      center.setForeground(true);
      expect(center.visible, isEmpty);
    });

    test('two cards of one home: gone only when both are', () {
      source.activities = [_activity()];
      center.enterHome('message:1');
      center.enterHome('message:1');
      center.leaveHome('message:1');
      expect(center.visible, isEmpty);
      center.leaveHome('message:1');
      expect(center.visible, hasLength(1));
    });
  });

  group('what counts as on screen', () {
    Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));
    IslandHome home({Key? key}) => IslandHome(
      key: key,
      center: center,
      home: 'message:1',
      child: const Text('card'),
    );

    setUp(() => source.activities = [_activity()]);

    testWidgets('built and in front', (tester) async {
      await tester.pumpWidget(app(home()));
      await tester.pump();
      expect(center.visible, isEmpty);
    });

    testWidgets('scrolled out of its list, or gone', (tester) async {
      await tester.pumpWidget(app(home()));
      await tester.pump();
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pump();
      expect(center.visible, hasLength(1));
    });

    testWidgets('a tab kept behind another does not count', (tester) async {
      await tester.pumpWidget(app(TickerMode(enabled: false, child: home())));
      await tester.pump();
      expect(center.visible, hasLength(1));
      await tester.pumpWidget(app(TickerMode(enabled: true, child: home())));
      await tester.pump();
      expect(center.visible, isEmpty);
    });

    testWidgets('a page pushed over it does not count', (tester) async {
      await tester.pumpWidget(app(home()));
      await tester.pump();
      expect(center.visible, isEmpty);
      final context = tester.element(find.text('card'));
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const Text('over')));
      await tester.pumpAndSettle();
      expect(center.visible, hasLength(1));
      Navigator.of(tester.element(find.text('over'))).pop();
      await tester.pumpAndSettle();
      expect(center.visible, isEmpty);
    });
  });
}
