// Measures the touch recents switcher on a real phone or tablet: the deck
// and switcher Flow shows, nine window cards, then swipes made up in code
// while every frame's build and raster time is kept. Build it in profile
// mode and start it from the command line (`flutter run --profile` drives
// Xcode on iOS 17 and later):
//
//   flutter build ios --profile -t tool/perf/switcher_perf.dart
//   xcrun devicectl device install app --device <id> build/ios/iphoneos/Runner.app
//   xcrun devicectl device process launch --device <id> --console <bundle id>
//
// It prints `perf:` lines. It replaces the app on the device while it runs
// (the app's data is not touched); install the app again afterwards.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:whisper/page/window_stream/flow_recents_deck.dart';
import 'package:whisper/page/window_stream/flow_space_theme.dart';
import 'package:whisper/page/window_stream/flow_space_widgets.dart';
import 'package:whisper/page/window_stream/flow_switcher.dart';
import 'package:whisper/theme/app_theme.dart';

import 'perf_support.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final pictures = [for (var i = 0; i < 9; i++) await perfWindowPicture(i)];
  runApp(
    MaterialApp(
      theme: AppTheme.lightTheme,
      debugShowCheckedModeBanner: false,
      home: _Harness(pictures: pictures),
    ),
  );
}

class _Harness extends StatefulWidget {
  const _Harness({required this.pictures});

  final List<Uint8List> pictures;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final _page = GlobalKey();
  final _input = PerfInput();

  late final cards = [
    for (var i = 0; i < widget.pictures.length; i++)
      FlowTaskCard(
        key: '$i',
        title: 'App $i — Window',
        hue: perfHues[i],
        snapshot: widget.pictures[i],
      ),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<ui.Image?>? _backdrop() {
    final boundary = _page.currentContext?.findRenderObject();
    return boundary is RenderRepaintBoundary ? blurredSnapshot(boundary) : null;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _page,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Flow', style: TextStyle(fontSize: 30)),
                const SizedBox(height: 24),
                const SizedBox(
                  height: 36,
                  child: FlowGlass(child: SizedBox.expand()),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 220,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FlowRecentsDeck(
                      cards: cards,
                      cardWidth: 272,
                      cardAspect: 1.6,
                      curvedStack: true,
                      onOpen: (_, _) {},
                      onClose: (_) {},
                      onShowAll: (origins) => showFlowSwitcher(
                        context,
                        backdrop: _backdrop(),
                        cards: cards,
                        cardAspect: 1.6,
                        origins: origins,
                        onOpen: (_, _) {},
                        onClose: (_) {},
                      ),
                    ),
                  ),
                ),
                // The apps under the stack, as Flow lists them.
                Expanded(
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 110,
                          mainAxisExtent: 120,
                        ),
                    itemCount: 99,
                    itemBuilder: (context, i) => FlowAppTile(
                      label: 'App $i',
                      hue: perfHues[i % perfHues.length],
                      onTap: (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _run() async {
    for (var i = 0; i < 30; i++) {
      await SchedulerBinding.instance.endOfFrame;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    perfStart();
    final front = perfFindText(context, 'App 0 — Window')!;
    await measure('open', () async {
      await _input.tap(front);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    });
    if (!mounted) {
      return;
    }
    final size = MediaQuery.sizeOf(context);
    final y = size.height * 0.55;
    final a = Offset(size.width * 0.75, y);
    final b = Offset(size.width * 0.3, y);
    await measure('swipes', () async {
      for (var round = 0; round < 3; round++) {
        for (final left in [true, true, false, false]) {
          await _input.swipe(
            left ? b : a,
            left ? a : b,
            const Duration(milliseconds: 220),
          );
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
      }
    });
    await measure('drags', () async {
      final c = Offset(size.width * 0.8, y);
      final d = Offset(size.width * 0.2, y);
      for (final left in [true, false]) {
        await _input.swipe(
          left ? d : c,
          left ? c : d,
          const Duration(seconds: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    });
    await measure('idle', () async {
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    perfDone();
  }
}
