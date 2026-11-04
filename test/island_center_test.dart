import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';

import 'island_test_support.dart';

void main() {
  late FakeIslandClock clock;
  late IslandListSource source;
  late IslandCenter center;
  late List<IslandHaptic> haptics;

  setUp(() {
    clock = FakeIslandClock();
    source = IslandListSource();
    center = IslandCenter(sources: [source], clock: clock);
    haptics = [];
    center.haptics = haptics.add;
  });

  tearDown(() {
    center.dispose();
    source.dispose();
  });

  List<String> ids(List<IslandActivity> activities) => [
    for (final a in activities) a.id,
  ];

  group('lingering', () {
    test(
      'trouble opens the card for a while; failure stays until put away',
      () {
        source.put(islandActivity('copy'));
        clock.advance(const Duration(seconds: 10));
        haptics.clear();
        source.put(islandActivity('copy', status: IslandStatus.failed));
        expect(haptics, [IslandHaptic.medium]);
        clock.advance(IslandCenter.arrivalDelay);
        expect(center.stage, IslandStage.expanded);
        clock.advance(IslandCenter.troubleOpen);
        expect(center.stage, IslandStage.compact);
        clock.advance(const Duration(minutes: 5));
        expect(ids(center.visible), ['copy']);

        center.swipeUp();
        expect(center.stage, IslandStage.hidden);
        expect(center.visible, isEmpty);
        expect(source.retiredIds, ['copy']);
      },
    );
  });

  test('while something fills the screen only what needs the user shows', () {
    source.activities = [
      islandActivity('copy', arrival: IslandArrival.quiet),
      islandActivity(
        'audio',
        kind: IslandKind.audio,
        arrival: IslandArrival.quiet,
      ),
    ];
    final unhush = center.hush();
    expect(center.stage, IslandStage.hidden);
    source.put(islandActivity('copy', status: IslandStatus.waiting));
    expect(ids(center.visible), ['copy']);
    unhush();
    expect(ids(center.visible), ['copy', 'audio']);
  });
}
