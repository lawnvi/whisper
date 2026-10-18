import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/page/window_stream/viewer/viewer_loading.dart';
import 'package:whisper/page/window_stream/viewer/viewer_settle.dart';

void main() {
  group('when the streamed picture is stable', () {
    late Duration now;
    late PictureSettle settle;

    setUp(() {
      now = Duration.zero;
      settle = PictureSettle(now: () => now);
    });

    void at(int ms) {
      now = Duration(milliseconds: ms);
      settle.check();
    }

    test('first frame, wrong size, then settles 300 ms after the resize', () {
      expect(settle.stable, isFalse);
      expect(settle.loading, isTrue);
      expect(settle.watching, isTrue);
      // The window still has its old size over there.
      settle.sizeMessage(1280, 800);
      at(40);
      settle.frame(1280, 800);
      // The other device resizes it for this screen.
      at(60);
      settle.sizeMessage(780, 1560);
      at(80);
      settle.frame(1280, 800); // a stretched frame still in flight
      at(120);
      settle.frame(780, 1560);
      expect(settle.stable, isFalse, reason: 'resized 60 ms ago');
      at(150);
      settle.frame(780, 1560);
      expect(settle.stable, isFalse, reason: 'not 300 ms quiet yet');
      expect(settle.nextCheck(), const Duration(milliseconds: 211));
      at(359);
      expect(settle.stable, isFalse);
      at(361);
      expect(settle.stable, isTrue);
      expect(settle.settledByCap, isFalse);
      expect(settle.loading, isFalse);
      expect(settle.watching, isFalse);
    });

    test('a frame that never matches the size settles at the 2.5 s cap', () {
      settle.sizeMessage(780, 1560);
      at(100);
      settle.frame(1280, 800);
      for (var ms = 133; ms < 2600; ms += 33) {
        at(ms);
        settle.frame(1280, 800);
        expect(settle.stable, isFalse, reason: 'at $ms ms');
      }
      at(2601);
      expect(settle.stable, isTrue);
      expect(settle.settledByCap, isTrue);
    });

    test('a window that sends a single frame settles on it', () {
      settle.sizeMessage(800, 600);
      at(200);
      settle.frame(800, 600);
      expect(settle.nextCheck(), const Duration(milliseconds: 301));
      at(499);
      expect(settle.stable, isFalse, reason: 'streaming under 300 ms');
      at(501);
      expect(settle.stable, isTrue);
      expect(settle.settledByCap, isFalse);
    });

    test('the size known at open waits for the source to fit the window', () {
      // As measured from a Windows source: the window's own size is known
      // before the first frame; the source resizes it 280 ms later.
      settle.sizeMessage(902, 732);
      at(500);
      settle.frame(902, 732);
      at(700);
      settle.frame(902, 732);
      expect(settle.stable, isFalse, reason: '200 ms of streaming');
      at(778);
      settle.sizeMessage(1000, 508);
      at(800);
      settle.frame(902, 732);
      at(830);
      settle.frame(1000, 508);
      at(1000);
      expect(settle.stable, isFalse);
      at(1079);
      expect(settle.stable, isTrue);
    });

    test('a change of size inside the 300 ms starts the wait again', () {
      settle.sizeMessage(800, 600);
      at(10);
      settle.frame(800, 600);
      at(50);
      settle.frame(800, 600);
      at(250);
      settle.sizeMessage(820, 600);
      settle.frame(820, 600);
      settle.frame(820, 600);
      at(400);
      expect(settle.stable, isFalse);
      at(551);
      expect(settle.stable, isTrue);
    });

    test('without SIZE messages the decoded size stands in', () {
      at(30);
      settle.frame(640, 480);
      at(60);
      settle.frame(640, 480);
      at(200);
      expect(settle.stable, isFalse);
      at(331);
      expect(settle.stable, isTrue);
    });

    test('sizes a pixel or two apart count as the same', () {
      settle.sizeMessage(781, 1561);
      at(10);
      settle.frame(780, 1560);
      settle.frame(780, 1560);
      at(311);
      expect(settle.stable, isTrue);
    });

    test('later resizes do not bring the spinner back', () {
      settle.sizeMessage(800, 600);
      settle.frame(800, 600);
      settle.frame(800, 600);
      at(301);
      expect(settle.stable, isTrue);
      at(5000);
      settle.sizeMessage(1200, 600);
      settle.frame(800, 600);
      expect(settle.stable, isTrue);
      expect(settle.loading, isFalse);
    });

    test(
      'after a resume the spinner returns only without a frame in 300 ms',
      () {
        settle.alreadySettled();
        expect(settle.stable, isTrue);
        at(1000);
        settle.resumed();
        expect(settle.loading, isFalse);
        expect(settle.watching, isTrue);
        expect(settle.nextCheck(), const Duration(milliseconds: 301));
        at(1299);
        expect(settle.loading, isFalse);
        at(1301);
        expect(settle.loading, isTrue, reason: 'no new frame within 300 ms');
        expect(settle.slow, isFalse);
        settle.frame(800, 600);
        expect(settle.loading, isFalse);
        expect(settle.watching, isFalse);

        // A frame in time: no spinner at all.
        at(5000);
        settle.resumed();
        at(5100);
        settle.frame(800, 600);
        at(5400);
        expect(settle.loading, isFalse);
      },
    );

    test('nothing decoded for 8 s adds the hint', () {
      at(7999);
      expect(settle.slow, isFalse);
      at(8000);
      expect(settle.slow, isTrue);
      expect(settle.loading, isTrue);
      settle.frame(800, 600);
      expect(settle.slow, isFalse);
    });

    test('a stalled resume gets the hint after 8 s too', () {
      settle.alreadySettled();
      at(100);
      settle.resumed();
      at(8099);
      expect(settle.slow, isFalse);
      at(8100);
      expect(settle.slow, isTrue);
    });
  });

  group('the loading stage', () {
    Widget host({
      required bool visible,
      Uint8List? image,
      Uint8List? icon,
      String? slow,
      bool dimOnly = false,
      bool reduceMotion = false,
    }) {
      return MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: ViewerLoadingStage(
              visible: visible,
              image: image,
              icon: icon,
              slowText: slow,
              dimOnly: dimOnly,
            ),
          ),
        ),
      );
    }

    AnimatedOpacity fade(WidgetTester tester) => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('viewer-loading')),
    );

    testWidgets('a spinner without words, words only when slow', (
      tester,
    ) async {
      await tester.pumpWidget(host(visible: true));
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.byType(Text), findsNothing);
      expect(fade(tester).opacity, 1);

      await tester.pumpWidget(host(visible: true, slow: '正在连接…'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('正在连接…'), findsOneWidget);
    });

    testWidgets('the last picture shows aspect-fit under the spinner', (
      tester,
    ) async {
      final png = base64Decode(_onePixelPng);
      await tester.pumpWidget(host(visible: true, image: png));
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.fit, BoxFit.contain);
      expect(find.byType(ColoredBox), findsWidgets);
      // After a resume only a dim goes over the live picture.
      await tester.pumpWidget(host(visible: true, image: png, dimOnly: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('without a picture the app icon shows, 64 pt', (tester) async {
      final png = base64Decode(_onePixelPng);
      await tester.pumpWidget(host(visible: true, icon: png));
      final icon = tester.widget<Image>(find.byType(Image));
      expect([icon.width, icon.height], [64, 64]);
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      // A picture wins over the icon.
      await tester.pumpWidget(host(visible: true, icon: png, image: png));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('crossfades in 180 ms, at once with reduce motion', (
      tester,
    ) async {
      await tester.pumpWidget(host(visible: false));
      expect(fade(tester).opacity, 0);
      expect(fade(tester).duration, const Duration(milliseconds: 180));

      await tester.pumpWidget(host(visible: false, reduceMotion: true));
      expect(fade(tester).duration, Duration.zero);
    });
  });
}

/// A 1×1 PNG.
const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
