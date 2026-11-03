import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_ui.dart';

import 'support/golden_support.dart';

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: child),
);

void main() {
  test('device kinds follow the platform names platformIcon knows', () {
    for (final (platform, kind) in [
      ('android', DeviceKind.phone),
      ('iOS', DeviceKind.phone),
      ('iphone', DeviceKind.phone),
      ('ipad', DeviceKind.tablet),
      ('macos', DeviceKind.laptop),
      ('darwin', DeviceKind.laptop),
      (' Mac ', DeviceKind.laptop),
      ('windows', DeviceKind.desktop),
      ('linux', DeviceKind.desktop),
      ('', DeviceKind.desktop),
    ]) {
      expect(deviceKindFor(platform), kind, reason: platform);
    }
    // The icon of every spelling above exists in the old list too.
    expect(platformIcon('darwin'), platformIcon('macos'));
  });

  testWidgets('measures like the prototype', (t) async {
    Future<Size> sizeOf(DeviceKind kind, double size) async {
      await t.pumpWidget(
        _host(
          DeviceArt(kind: kind, wallpaper: DeviceWallpaper.self, size: size),
        ),
      );
      return t.getSize(find.byType(CustomPaint).first);
    }

    void near(Size got, Size want) {
      expect(got.width, closeTo(want.width, .001));
      expect(got.height, closeTo(want.height, .001));
    }

    near(await sizeOf(DeviceKind.desktop, 100), const Size(100, 86));
    near(await sizeOf(DeviceKind.laptop, 100), const Size(100, 66));
    near(await sizeOf(DeviceKind.phone, 100), const Size(56, 100));
    // Sidebar rows: 32 wide for a computer, 30 high for a phone.
    expect((await sizeOf(DeviceKind.desktop, 32)).width, 32);
    expect((await sizeOf(DeviceKind.phone, 30)).height, 30);
  });

  testWidgets('presence fades the picture without moving it', (t) async {
    Future<Rect> paint(DeviceArtState state) async {
      await t.pumpWidget(
        _host(
          DeviceArt(
            key: const ValueKey('art'),
            kind: DeviceKind.laptop,
            wallpaper: DeviceWallpaper.paired.first,
            size: 64,
            state: state,
          ),
        ),
      );
      return t.getRect(find.byKey(const ValueKey('art')));
    }

    final normal = await paint(DeviceArtState.normal);
    expect(find.byType(Opacity), findsNothing);

    expect(await paint(DeviceArtState.nearby), normal);
    expect(t.widget<Opacity>(find.byType(Opacity)).opacity, .9);

    expect(await paint(DeviceArtState.offline), normal);
    expect(t.widget<Opacity>(find.byType(Opacity)).opacity, .45);
    expect(find.byType(ColorFiltered), findsOneWidget);
  });

  testWidgets('line icons paint for every kind', (t) async {
    for (final kind in DeviceKind.values) {
      await t.pumpWidget(
        _host(DeviceGlyph(kind: kind, color: const Color(0xFF007AFF))),
      );
      expect(t.takeException(), isNull);
    }
  });

  group('next to the prototype', () {
    Widget sheet(WhisperColors c) => ColoredBox(
      color: c.canvas,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Large, as on the device card.
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                DeviceArt(
                  kind: DeviceKind.desktop,
                  wallpaper: DeviceWallpaper.forPairingOrder(0),
                  size: 104,
                ),
                const SizedBox(width: 24),
                DeviceArt(
                  kind: DeviceKind.laptop,
                  wallpaper: DeviceWallpaper.forPairingOrder(1),
                  size: 104,
                ),
                const SizedBox(width: 24),
                DeviceArt(
                  kind: DeviceKind.phone,
                  wallpaper: DeviceWallpaper.forPairingOrder(2),
                  size: 104,
                ),
                const SizedBox(width: 24),
                const DeviceArt(
                  kind: DeviceKind.laptop,
                  wallpaper: DeviceWallpaper.self,
                  size: 96,
                ),
              ],
            ),
            const SizedBox(height: 24),
            // As in the sidebar, in each state of presence.
            for (final state in DeviceArtState.values) ...[
              Row(
                children: [
                  for (final (kind, size) in const [
                    (DeviceKind.desktop, 32.0),
                    (DeviceKind.laptop, 32.0),
                    (DeviceKind.phone, 30.0),
                  ]) ...[
                    SizedBox(
                      width: 34,
                      height: 30,
                      child: Center(
                        child: DeviceArt(
                          kind: kind,
                          wallpaper: DeviceWallpaper.forPairingOrder(3),
                          size: size,
                          state: state,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  const SizedBox(width: 12),
                  DeviceArt(
                    kind: DeviceKind.phone,
                    wallpaper: DeviceWallpaper.unpaired,
                    size: 30,
                    state: state,
                  ),
                  const SizedBox(width: 24),
                  for (final kind in DeviceKind.values) ...[
                    DeviceGlyph(kind: kind, color: c.accent),
                    const SizedBox(width: 12),
                  ],
                ],
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );

    testWidgets('light', skip: goldenSkip != null, (t) async {
      t.view.physicalSize = const Size(1000, 620);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_host(sheet(WhisperColors.light)));
      await expectLater(
        find.byType(ColoredBox).first,
        matchesGoldenFile('goldens/new_ui/device_art_light.png'),
      );
    });

    testWidgets('dark', skip: goldenSkip != null, (t) async {
      t.view.physicalSize = const Size(1000, 620);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_host(sheet(WhisperColors.dark)));
      await expectLater(
        find.byType(ColoredBox).first,
        matchesGoldenFile('goldens/new_ui/device_art_dark.png'),
      );
    });
  });
}
