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

  group('arrivals', () {
    test('a new copy shows small, opens for a moment, then settles', () {
      source.put(islandActivity('copy'));
      expect(center.stage, IslandStage.compact);
      expect(haptics, [IslandHaptic.selection]);

      clock.advance(const Duration(milliseconds: 139));
      expect(center.stage, IslandStage.compact);
      clock.advance(const Duration(milliseconds: 1));
      expect(center.stage, IslandStage.expanded);
      expect(center.featured?.id, 'copy');

      clock.advance(IslandCenter.arrivalOpen - const Duration(milliseconds: 1));
      expect(center.stage, IslandStage.expanded);
      clock.advance(const Duration(milliseconds: 1));
      expect(center.stage, IslandStage.compact);
    });

    test('a quiet arrival only takes the small island', () {
      source.put(islandActivity('t', arrival: IslandArrival.quiet));
      clock.advance(const Duration(seconds: 1));
      expect(center.stage, IslandStage.compact);
      expect(haptics, isEmpty);
    });

    test('a transfer over before it would show never flashes up', () {
      source.put(
        islandActivity(
          't',
          kind: IslandKind.transfer,
          arrival: IslandArrival.quiet,
          showAfter: const Duration(milliseconds: 600),
        ),
      );
      expect(center.stage, IslandStage.hidden);
      clock.advance(const Duration(milliseconds: 300));
      source.put(
        islandActivity(
          't',
          kind: IslandKind.transfer,
          status: IslandStatus.done,
        ),
      );
      clock.advance(const Duration(seconds: 3));
      expect(center.stage, IslandStage.hidden);
      expect(center.visible, isEmpty);
      expect(source.retiredIds, ['t']);
    });

    test('a slower transfer shows once it has run a moment', () {
      source.put(
        islandActivity(
          't',
          kind: IslandKind.transfer,
          arrival: IslandArrival.quiet,
          showAfter: const Duration(milliseconds: 600),
        ),
      );
      clock.advance(const Duration(milliseconds: 600));
      expect(center.stage, IslandStage.compact);
      expect(ids(center.visible), ['t']);
    });

    test(
      'what was already going on comes in quietly; finished is left out',
      () {
        final early = IslandListSource([
          islandActivity('running'),
          islandActivity('old', status: IslandStatus.done),
        ]);
        final other = IslandCenter(sources: [early], clock: clock);
        addTearDown(other.dispose);
        expect(other.stage, IslandStage.compact);
        expect(ids(other.visible), ['running']);
        clock.advance(const Duration(seconds: 1));
        expect(other.stage, IslandStage.compact);
        expect(early.retiredIds, ['old']);
      },
    );
  });

  group('priority', () {
    test('windows sent here, trouble, streaming, copies, then the speaker', () {
      source.activities = [
        islandActivity('audio', kind: IslandKind.audio),
        islandActivity('copy'),
        islandActivity('streamed', kind: IslandKind.streamed),
        islandActivity('failed', status: IslandStatus.failed),
        islandActivity('offer', kind: IslandKind.offer),
        islandActivity(
          'paused',
          kind: IslandKind.audio,
          status: IslandStatus.paused,
        ),
      ];
      clock.advance(const Duration(seconds: 30));
      expect(ids(center.visible), [
        'offer',
        'failed',
        'streamed',
        'copy',
        'audio',
        'paused',
      ]);
      expect(center.featured?.id, 'offer');
      expect(center.secondary?.id, 'failed');
    });

    test('among equals the newest comes first', () {
      source.activities = [
        islandActivity('older', since: DateTime(2026, 10, 17, 11)),
        islandActivity('newer', since: DateTime(2026, 10, 17, 12)),
      ];
      expect(ids(center.visible), ['newer', 'older']);
    });

    test('the one that just arrived leads the card while it is open', () {
      source.put(islandActivity('copy'));
      clock.advance(const Duration(seconds: 10));
      source.put(islandActivity('audio', kind: IslandKind.audio));
      clock.advance(const Duration(milliseconds: 140));
      expect(center.stage, IslandStage.expanded);
      expect(center.featured?.id, 'audio');
      expect(ids(center.others), ['copy']);
      clock.advance(IslandCenter.arrivalOpen);
      expect(center.stage, IslandStage.compact);
      // Settled: back to what matters most.
      expect(center.featured?.id, 'copy');
      expect(center.secondary?.id, 'audio');
    });
  });

  group('lingering', () {
    test('done shows its tick for a moment, then leaves', () {
      source.put(islandActivity('copy'));
      clock.advance(const Duration(seconds: 10));
      haptics.clear();
      source.put(islandActivity('copy', status: IslandStatus.done));
      expect(haptics, [IslandHaptic.light]);
      expect(ids(center.visible), ['copy']);
      clock.advance(IslandCenter.doneLingers - const Duration(milliseconds: 1));
      expect(ids(center.visible), ['copy']);
      clock.advance(const Duration(milliseconds: 1));
      expect(center.visible, isEmpty);
      expect(center.stage, IslandStage.hidden);
      expect(source.retiredIds, ['copy']);
    });

    test('stopped goes sooner', () {
      source.put(islandActivity('copy'));
      clock.advance(const Duration(seconds: 10));
      source.put(islandActivity('copy', status: IslandStatus.ended));
      clock.advance(IslandCenter.endedLingers);
      expect(center.visible, isEmpty);
    });

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

    test('tried again after failing, it is back', () {
      source.put(islandActivity('copy'));
      source.put(islandActivity('copy', status: IslandStatus.failed));
      center.swipeUp();
      center.swipeUp();
      expect(center.visible, isEmpty);
      source.put(islandActivity('copy'));
      expect(ids(center.visible), ['copy']);
      expect(center.stage, IslandStage.compact);
    });

    test('nothing leaves or closes under the finger', () {
      source.put(islandActivity('copy'));
      clock.advance(const Duration(milliseconds: 140));
      center.hold();
      clock.advance(const Duration(seconds: 10));
      expect(center.stage, IslandStage.expanded);
      source.put(islandActivity('copy', status: IslandStatus.done));
      clock.advance(const Duration(seconds: 10));
      expect(ids(center.visible), ['copy']);
      center.release();
      clock.advance(IslandCenter.afterRelease);
      expect(center.visible, isEmpty);
      expect(center.stage, IslandStage.hidden);
    });
  });

  group('gestures', () {
    test('tap opens the small island and closes the card', () {
      source.put(islandActivity('copy', arrival: IslandArrival.quiet));
      center.tap();
      expect(center.stage, IslandStage.expanded);
      clock.advance(IslandCenter.tapOpen);
      expect(center.stage, IslandStage.compact);
      center.tap();
      center.tap();
      expect(center.stage, IslandStage.compact);
    });

    test('swiped away, what is under way comes back with trouble', () {
      source.put(islandActivity('copy', arrival: IslandArrival.quiet));
      center.swipeUp();
      expect(center.stage, IslandStage.hidden);
      source.put(islandActivity('copy'));
      clock.advance(const Duration(seconds: 2));
      expect(center.stage, IslandStage.hidden);
      source.put(islandActivity('copy', status: IslandStatus.waiting));
      expect(ids(center.visible), ['copy']);
      clock.advance(IslandCenter.arrivalDelay);
      expect(center.stage, IslandStage.expanded);
    });

    test('the card still lists what was swiped out of sight', () {
      source.put(islandActivity('copy', arrival: IslandArrival.quiet));
      center.swipeUp();
      source.put(islandActivity('audio', kind: IslandKind.audio));
      clock.advance(IslandCenter.arrivalDelay);
      expect(center.stage, IslandStage.expanded);
      expect(ids(center.visible), ['audio']);
      expect(ids(center.listed), ['copy', 'audio']);
      expect(center.secondary, isNull);
    });

    test('tapping the circle opens the card on it', () {
      source.activities = [
        islandActivity('copy', arrival: IslandArrival.quiet),
        islandActivity(
          'audio',
          kind: IslandKind.audio,
          arrival: IslandArrival.quiet,
        ),
      ];
      expect(center.secondary?.id, 'audio');
      center.tapSecondary();
      expect(center.stage, IslandStage.expanded);
      expect(center.featured?.id, 'audio');
      expect(ids(center.others), ['copy']);
    });

    test('a row tapped in the card moves to the top', () {
      source.activities = [
        islandActivity('copy', arrival: IslandArrival.quiet),
        islandActivity(
          'audio',
          kind: IslandKind.audio,
          arrival: IslandArrival.quiet,
        ),
      ];
      center.tap();
      center.feature('audio');
      expect(center.featured?.id, 'audio');
      center.collapse();
      expect(center.featured?.id, 'copy');
    });
  });

  group('windows sent here', () {
    IslandActivity offer(String id) => islandActivity(
      id,
      kind: IslandKind.offer,
      openFor: const Duration(seconds: 8),
      waitsFor: const Duration(seconds: 12),
    );

    test('open eight seconds, wait twelve small, then let go', () {
      source.put(offer('o'));
      expect(haptics, [IslandHaptic.medium]);
      clock.advance(IslandCenter.arrivalDelay);
      expect(center.stage, IslandStage.expanded);
      clock.advance(const Duration(seconds: 8));
      expect(center.stage, IslandStage.compact);
      clock.advance(const Duration(seconds: 11));
      expect(source.expiredIds, isEmpty);
      clock.advance(const Duration(seconds: 1));
      expect(source.expiredIds, ['o']);
    });

    test('opened again, it waits afresh', () {
      source.put(offer('o'));
      clock.advance(const Duration(seconds: 8, milliseconds: 140));
      clock.advance(const Duration(seconds: 10));
      center.tap();
      clock.advance(const Duration(seconds: 6));
      expect(source.expiredIds, isEmpty);
      clock.advance(const Duration(seconds: 2));
      expect(center.stage, IslandStage.compact);
      clock.advance(const Duration(seconds: 11));
      expect(source.expiredIds, isEmpty);
      clock.advance(const Duration(seconds: 1));
      expect(source.expiredIds, ['o']);
    });

    test('swiped away, it is dismissed', () {
      source.put(offer('o'));
      clock.advance(const Duration(seconds: 9));
      center.swipeUp();
      expect(source.dismissedIds, ['o']);
      expect(center.stage, IslandStage.hidden);
    });
  });

  group('background', () {
    test('nothing shows; what came opens the card on return', () {
      center.setForeground(false);
      source.put(
        islandActivity(
          'o',
          kind: IslandKind.offer,
          openFor: const Duration(seconds: 8),
        ),
      );
      expect(center.stage, IslandStage.hidden);
      expect(haptics, isEmpty);
      clock.advance(const Duration(seconds: 30));
      center.setForeground(true);
      expect(center.stage, IslandStage.compact);
      clock.advance(IslandCenter.arrivalDelay);
      expect(center.stage, IslandStage.expanded);
      expect(center.featured?.id, 'o');
      clock.advance(const Duration(seconds: 8));
      expect(center.stage, IslandStage.compact);
    });

    test('an open card is small again when the app comes back', () {
      source.put(islandActivity('copy'));
      clock.advance(IslandCenter.arrivalDelay);
      expect(center.stage, IslandStage.expanded);
      center.setForeground(false);
      clock.advance(const Duration(seconds: 1));
      center.setForeground(true);
      expect(center.stage, IslandStage.compact);
    });
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

  test('spotlit, a copy that just finished opens again', () {
    source.put(islandActivity('copy'));
    source.put(islandActivity('copy', status: IslandStatus.done));
    clock.advance(const Duration(seconds: 10));
    expect(center.visible, isEmpty);
    source.spotlight('copy');
    // The stream delivers on the next microtask.
    return Future<void>.delayed(Duration.zero, () {
      expect(ids(center.visible), ['copy']);
      clock.advance(IslandCenter.arrivalDelay);
      expect(center.stage, IslandStage.expanded);
      clock.advance(IslandCenter.arrivalOpen + IslandCenter.doneLingers);
      expect(center.visible, isEmpty);
    });
  });
}
