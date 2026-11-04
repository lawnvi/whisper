import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';

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
  });
}
