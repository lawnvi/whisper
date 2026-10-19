// Measures Flow's desktop pieces on a real computer: the device shelf, the
// direction picker with its arrows, the recents stack and the grid it opens,
// a page of app icons. A mouse made up in code hovers, clicks and scrolls
// while every frame's build and raster time is kept; it also counts frames
// drawn while nothing moves (there should be none).
//
//   flutter run --profile -t tool/perf/desktop_flow_perf.dart -d <desktop>
//
// It prints `perf:` lines, one per phase.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:whisper/page/window_stream/flow_desktop_switcher.dart';
import 'package:whisper/page/window_stream/flow_recents_deck.dart';
import 'package:whisper/page/window_stream/flow_space_theme.dart';
import 'package:whisper/page/window_stream/flow_space_widgets.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:window_manager/window_manager.dart';

import 'perf_support.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final pictures = [for (var i = 0; i < 9; i++) await perfWindowPicture(i)];
  await windowManager.ensureInitialized();
  unawaited(
    windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(1280, 820), center: true),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    ),
  );
  final navigator = GlobalKey<NavigatorState>();
  runApp(
    MaterialApp(
      navigatorKey: navigator,
      theme: AppTheme.lightTheme,
      debugShowCheckedModeBanner: false,
      home: _Harness(pictures: pictures, navigator: navigator),
    ),
  );
}

class _Harness extends StatefulWidget {
  const _Harness({required this.pictures, required this.navigator});

  final List<Uint8List> pictures;
  final GlobalKey<NavigatorState> navigator;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final _deck = GlobalKey();
  final _shelf = GlobalKey();
  final _picker = GlobalKey();
  final _apps = GlobalKey();
  final _input = PerfInput(kind: PointerDeviceKind.mouse);
  var _send = false;
  var _selected = 0;

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

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Flow',
                  style: TextStyle(
                    color: colors.label,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                const SizedBox(
                  width: 260,
                  height: 36,
                  child: FlowGlass(child: SizedBox.expand()),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              key: _shelf,
              height: FlowDeviceCard.height + 20,
              child: Row(
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    FlowDeviceCard(
                      name: 'Device $i',
                      subtitle: 'Wi-Fi',
                      platform: WindowStreamPlatform.values[i],
                      hue: perfHues[i],
                      selected: _selected == i,
                      onTap: () => setState(() => _selected = i),
                    ),
                    const SizedBox(width: 12),
                  ],
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                key: _picker,
                width: 640,
                child: FlowDirectionPicker(
                  sendSelected: _send,
                  hue: perfHues[_selected],
                  devicePlatform: WindowStreamPlatform.android,
                  openTitle: 'Open here',
                  openDetail: 'Use apps from Device',
                  sendTitle: 'Send to Device',
                  sendDetail: 'Move a window to Device',
                  onChanged: (send) => setState(() => _send = send),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FlowRecentsDeck(
                  key: _deck,
                  cards: cards,
                  cardWidth: 272,
                  cardAspect: 1.6,
                  onOpen: (_, _) {},
                  onClose: (_) {},
                  onShowAll: (origins) => showFlowDesktopSwitcher(
                    context,
                    cards: cards,
                    cardAspect: 1.6,
                    origins: origins,
                    onOpen: (_, _) {},
                    onClose: (_) {},
                    title: 'Recents',
                  ),
                ),
              ),
            ),
            Expanded(
              child: GridView.builder(
                key: _apps,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
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
    );
  }

  Offset _center(GlobalKey key, [Alignment where = Alignment.center]) {
    final box = key.currentContext!.findRenderObject()! as RenderBox;
    return box.localToGlobal(where.alongSize(box.size));
  }

  Future<void> _wait(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> _run() async {
    for (var i = 0; i < 30; i++) {
      await SchedulerBinding.instance.endOfFrame;
    }
    await _wait(2500);
    perfStart();
    await measure('idle-page', () => _wait(3000));
    final places = {
      'shelf': _shelf,
      'picker': _picker,
      'deck': _deck,
      'apps': _apps,
      'shelf-again': _shelf,
    };
    for (final place in places.entries) {
      await measure('hover-${place.key}', () async {
        await _input.hoverTo(
          _center(place.value, Alignment.centerLeft),
          const Duration(milliseconds: 300),
        );
        await _input.hoverTo(
          _center(place.value, Alignment.centerRight),
          const Duration(milliseconds: 600),
        );
      });
    }
    await measure('direction', () async {
      for (final send in [true, false, true, false]) {
        await _input.tap(
          _center(_picker, send ? Alignment.centerRight : Alignment.centerLeft),
        );
        await _wait(900);
      }
    });
    await measure('idle-sending', () => _wait(3000));
    await measure('grid', () async {
      for (var round = 0; round < 3; round++) {
        await _input.tap(perfFindText(context, 'App 0 — Window')!);
        await _wait(600);
        final size = MediaQuery.sizeOf(context);
        for (final x in [0.2, 0.5, 0.8]) {
          await _input.hoverTo(
            Offset(size.width * x, size.height * 0.45),
            const Duration(milliseconds: 250),
          );
        }
        widget.navigator.currentState?.maybePop();
        await _wait(600);
      }
    });
    await measure('scroll-apps', () async {
      await _input.hoverTo(_center(_apps), const Duration(milliseconds: 200));
      for (var i = 0; i < 12; i++) {
        _input.wheel(i < 6 ? 60 : -60);
        await _wait(50);
      }
      await _wait(600);
    });
    await measure('idle-end', () => _wait(3000));
    perfDone();
  }
}
