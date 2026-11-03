import 'dart:ui'
    show
        DisplayFeature,
        DisplayFeatureState,
        DisplayFeatureType,
        PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/whisper_ui.dart';

Widget app(Widget child, {Brightness b = Brightness.light}) => MaterialApp(
  theme: ThemeData(
    brightness: b,
    extensions: [
      b == Brightness.light ? WhisperColors.light : WhisperColors.dark,
    ],
  ),
  home: Scaffold(body: child),
);

class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.onInit});
  final VoidCallback onInit;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final _c = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(controller: _c);
}

void main() {
  test('spring numbers match DESIGN.md', () {
    expect(WhisperSprings.smooth.stiffness, closeTo(224, 1));
    expect(WhisperSprings.smooth.damping, closeTo(25.7, .1));
    expect(WhisperSprings.snappy.stiffness, closeTo(504, 1));
    expect(WhisperSprings.snappy.damping, closeTo(40.4, .1));
    expect(WhisperSprings.expressive.stiffness, closeTo(158, 1));
    expect(WhisperSprings.follow.stiffness, closeTo(1755, 1));
  });

  testWidgets('SpringBuilder keeps its speed when the target changes', (
    t,
  ) async {
    final seen = <double>[];
    Widget at(double v) => app(
      SpringBuilder(
        value: v,
        builder: (context, x, _) {
          seen.add(x);
          return const SizedBox();
        },
      ),
    );
    await t.pumpWidget(at(0));
    await t.pumpWidget(at(100));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    final before = seen.last;
    final speed = seen.last - seen[seen.length - 2];
    expect(speed, greaterThan(0));
    await t.pumpWidget(at(-100));
    await t.pump(const Duration(milliseconds: 16));
    // Retargeting backwards: momentum still carries it forward for a moment.
    expect(seen.last, greaterThan(before));
    await t.pumpAndSettle();
    expect(seen.last, closeTo(-100, .01));
  });

  testWidgets('reduced motion jumps', (t) async {
    double last = 0;
    Widget at(double v) => MaterialApp(
      theme: ThemeData(extensions: const [WhisperColors.light]),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: SpringBuilder(
          value: v,
          builder: (context, x, _) {
            last = x;
            return const SizedBox();
          },
        ),
      ),
    );
    await t.pumpWidget(at(0));
    await t.pumpWidget(at(50));
    await t.pump();
    expect(last, 50);
  });

  testWidgets('liquid thumb stretches on the way and settles on the target', (
    t,
  ) async {
    var sel = 'a';
    late StateSetter set;
    await t.pumpWidget(
      app(
        Center(
          child: StatefulBuilder(
            builder: (context, s) {
              set = s;
              return LiquidSegmented<String>(
                segments: const {'a': '对话', 'b': '文件', 'c': '应用'},
                selected: sel,
                onChanged: (v) => s(() => sel = v),
              );
            },
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    final thumb = find.byKey(const ValueKey('liquid-thumb'));
    final w0 = t.getSize(thumb).width;
    final x0 = t.getRect(thumb).left;
    set(() => sel = 'c');
    await t.pump();
    await t.pump();
    var widest = 0.0;
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 16));
      final w = t.getRect(thumb).width;
      if (w > widest) widest = w;
    }
    expect(widest, greaterThan(w0 + 6));
    await t.pumpAndSettle();
    expect(t.getRect(thumb).left, greaterThan(x0 + 20));
    expect(t.getSize(thumb).width, closeTo(w0, 1));
    expect(find.bySemanticsLabel('应用'), findsOneWidget);
  });

  testWidgets('tab view: state survives, pages build lazily, both move', (
    t,
  ) async {
    var aInits = 0, bInits = 0;
    Widget at(int i) => app(
      SizedBox(
        width: 400,
        height: 300,
        child: WhisperTabView(
          index: i,
          itemCount: 3,
          blur: false,
          itemBuilder: (context, n) => _Probe(
            key: ValueKey('page$n'),
            onInit: () => n == 0 ? aInits++ : bInits++,
          ),
        ),
      ),
    );
    await t.pumpWidget(at(0));
    expect(aInits, 1);
    expect(bInits, 0, reason: 'page 1 is not built before it is shown');
    await t.enterText(find.byType(TextField), '草稿');
    await t.pumpWidget(at(1));
    await t.pump(const Duration(milliseconds: 60));
    expect(bInits, 1);
    expect(
      find.byKey(const ValueKey('page0'), skipOffstage: false),
      findsOneWidget,
    );
    final x = t.getTopLeft(find.byKey(const ValueKey('page1'))).dx;
    expect(x, greaterThan(0), reason: 'new page comes from the right');
    expect(
      t.getTopLeft(find.byKey(const ValueKey('page0'))).dx,
      lessThan(0),
      reason: 'old page leaves left',
    );
    await t.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('page0')),
      findsNothing,
      reason: 'offstage once settled',
    );
    await t.pumpWidget(at(0));
    await t.pumpAndSettle();
    expect(aInits, 1, reason: 'not rebuilt');
    expect(
      t.widget<TextField>(find.byType(TextField)).controller?.text ?? '',
      '草稿',
    );
    expect(find.text('草稿'), findsOneWidget);
  });

  testWidgets('tab view: switching mid-flight does not snap', (t) async {
    Widget at(int i) => app(
      SizedBox(
        width: 400,
        height: 300,
        child: WhisperTabView(
          index: i,
          itemCount: 2,
          blur: false,
          itemBuilder: (context, n) => Text('p$n', key: ValueKey('p$n')),
        ),
      ),
    );
    await t.pumpWidget(at(0));
    await t.pumpWidget(at(1));
    await t.pump(const Duration(milliseconds: 120));
    final mid = t
        .widget<Opacity>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('p1')),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    expect(mid, greaterThan(.1));
    expect(mid, lessThan(1));
    await t.pumpWidget(at(0));
    await t.pump(const Duration(milliseconds: 16));
    final after = t
        .widget<Opacity>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('p1'), skipOffstage: false),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    expect(
      (after - mid).abs(),
      lessThan(.2),
      reason: 'continues from where it was',
    );
    await t.pumpAndSettle();
  });

  testWidgets('tab view: reduced motion only fades', (t) async {
    Widget at(int i) => MaterialApp(
      theme: ThemeData(extensions: const [WhisperColors.light]),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: WhisperTabView(
          index: i,
          itemCount: 2,
          itemBuilder: (context, n) => Text('p$n', key: ValueKey('p$n')),
        ),
      ),
    );
    await t.pumpWidget(at(0));
    final x0 = t.getTopLeft(find.byKey(const ValueKey('p0'))).dx;
    await t.pumpWidget(at(1));
    await t.pump(const Duration(milliseconds: 60));
    expect(
      t.getTopLeft(find.byKey(const ValueKey('p1'))).dx,
      x0,
      reason: 'no movement',
    );
    final o = t
        .widget<Opacity>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('p1')),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    expect(o, lessThan(1), reason: 'still fades');
    await t.pumpAndSettle();
  });

  testWidgets('RiseIn replays each time the tab is entered', (t) async {
    Widget at(int i) => app(
      WhisperTabView(
        index: i,
        itemCount: 2,
        blur: false,
        itemBuilder: (context, n) => n == 1
            ? const RiseIn(index: 0, child: Text('row', key: ValueKey('row')))
            : const SizedBox(),
      ),
    );
    await t.pumpWidget(at(0));
    await t.pumpWidget(at(1));
    await t.pumpAndSettle();
    await t.pumpWidget(at(0));
    await t.pumpAndSettle();
    await t.pumpWidget(at(1));
    await t.pump();
    final o = t
        .widget<Opacity>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('row')),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    expect(o, lessThan(.5), reason: 'starts again from hidden');
    await t.pumpAndSettle();
    expect(
      t
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('row')),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity,
      1,
    );
  });

  testWidgets('keyboard: segments and pressables activate with Enter', (
    t,
  ) async {
    var sel = 'a';
    var tapped = 0;
    await t.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, s) => Column(
            children: [
              LiquidSegmented<String>(
                segments: const {'a': '对话', 'b': '文件'},
                selected: sel,
                onChanged: (v) => s(() => sel = v),
              ),
              Pressable(
                onTap: () => tapped++,
                label: '按钮',
                child: const SizedBox(width: 40, height: 40),
              ),
            ],
          ),
        ),
      ),
    );
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(sel, 'b');
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump();
    expect(tapped, 1);
    await t.pumpAndSettle();
  });

  testWidgets('slider has a real hit area', (t) async {
    for (final (touch, min) in [(true, 48.0), (false, 28.0)]) {
      await t.pumpWidget(
        app(
          Builder(
            builder: (context) => SliderTheme(
              data: whisperSliderTheme(context, touch: touch),
              child: Slider(value: 1.5, min: 1, max: 3, onChanged: (_) {}),
            ),
          ),
        ),
      );
      expect(t.getSize(find.byType(Slider)).height, greaterThanOrEqualTo(min));
    }
  });

  testWidgets('progress highlight stops at 100%', (t) async {
    Widget at(double v) =>
        app(SizedBox(width: 200, child: WhisperProgressBar(value: v)));
    await t.pumpWidget(at(.4));
    expect(t.hasRunningAnimations, isTrue);
    await t.pumpWidget(at(1));
    await t.pumpAndSettle();
    expect(t.hasRunningAnimations, isFalse);
  });

  testWidgets('page route: pushes with a spring and pops', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: ThemeData(extensions: const [WhisperColors.light]),
        onGenerateRoute: (_) => WhisperPageRoute(
          builder: (_) =>
              const Scaffold(body: Text('root', key: ValueKey('root'))),
        ),
      ),
    );
    await t.pumpAndSettle();
    nav.currentState!.push(
      WhisperPageRoute(
        builder: (_) =>
            const Scaffold(body: Text('next', key: ValueKey('next'))),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 80));
    expect(t.getTopLeft(find.byKey(const ValueKey('next'))).dx, greaterThan(0));
    expect(
      t.getTopLeft(find.byKey(const ValueKey('root'))).dx,
      lessThan(0),
      reason: 'old page backs off',
    );
    await t.pumpAndSettle();
    expect(t.getTopLeft(find.byKey(const ValueKey('next'))).dx, 0);
    nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('next')), findsNothing);
  });

  testWidgets('bubble hugs its longest line after wrapping', (t) async {
    await t.pumpWidget(
      app(
        const SizedBox(
          width: 900,
          child: Column(
            children: [
              WhisperBubble(
                key: ValueKey('s'),
                text: '完成',
                mine: true,
                touch: false,
              ),
              WhisperBubble(
                key: ValueKey('l'),
                text: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbb',
                mine: false,
                touch: false,
              ),
            ],
          ),
        ),
      ),
    );
    final short = t.getSize(
      find
          .descendant(
            of: find.byKey(const ValueKey('s')),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect(short.width, lessThan(60));
    final long = t.getSize(
      find
          .descendant(
            of: find.byKey(const ValueKey('l')),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect(long.height, greaterThan(40), reason: 'wraps');
    expect(
      long.width,
      lessThan(14 * 30),
      reason: 'smaller than the cap: hugs the longest line',
    );
  });

  testWidgets('slider, progress, pressable and glass build in both themes', (
    t,
  ) async {
    for (final b in Brightness.values) {
      await t.pumpWidget(
        app(
          Builder(
            builder: (context) => Column(
              children: [
                SliderTheme(
                  data: whisperSliderTheme(context),
                  child: Slider(value: 1.5, min: 1, max: 3, onChanged: (_) {}),
                ),
                const SizedBox(
                  width: 200,
                  child: WhisperProgressBar(value: .4),
                ),
                Pressable(onTap: () {}, child: const Text('按钮')),
                const WhisperGlass(kind: GlassKind.panel, child: Text('玻璃')),
                const RiseIn(index: 2, child: Text('行')),
              ],
            ),
          ),
          b: b,
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(t.takeException(), isNull);
    }
    await t.pumpWidget(const SizedBox());
  });

  test(
    'order: nearby above away, offline keeps its place, new goes above away',
    () {
      final o = StableDeviceOrder();
      final first = o.apply({
        'old1': DevicePresence.away,
        'old2': DevicePresence.away,
        'near': DevicePresence.nearby,
        'on': DevicePresence.connected,
      });
      expect(first, ['on', 'near', 'old1', 'old2']);
      final off = o.apply({
        'old1': DevicePresence.away,
        'old2': DevicePresence.away,
        'near': DevicePresence.nearby,
        'on': DevicePresence.away,
      });
      expect(off, [
        'on',
        'near',
        'old1',
        'old2',
      ], reason: 'going offline moves nothing');
      final added = o.apply({
        'old1': DevicePresence.away,
        'old2': DevicePresence.away,
        'near': DevicePresence.nearby,
        'on': DevicePresence.away,
        'new': DevicePresence.nearby,
      });
      expect(added, [
        'on',
        'near',
        'new',
        'old1',
        'old2',
      ], reason: 'does not push down a row above it');
    },
  );

  test('order: starting offline, a device that connects moves up', () {
    final o = StableDeviceOrder();
    expect(o.apply({'a': DevicePresence.away, 'b': DevicePresence.away}), [
      'a',
      'b',
    ]);
    expect(o.apply({'a': DevicePresence.away, 'b': DevicePresence.connected}), [
      'b',
      'a',
    ]);
    expect(
      o.apply({'a': DevicePresence.connected, 'b': DevicePresence.connected}),
      ['b', 'a'],
    );
    expect(o.apply({'a': DevicePresence.connected, 'b': DevicePresence.away}), [
      'b',
      'a',
    ]);
    expect(o.apply({'a': DevicePresence.connected}), ['a']);
  });

  test('spring types exist', () {
    expect(WhisperSprings.smooth, isA<SpringDescription>());
  });

  group('window buttons', () {
    test('reads the GTK layout', () {
      final stock = WindowButtonLayout.parse('appmenu:close');
      expect(stock.left, isEmpty);
      expect(stock.right, [WindowButton.close]);
      final ubuntu = WindowButtonLayout.parse(':minimize,maximize,close');
      expect(ubuntu.right, WindowButton.values);
      final left = WindowButtonLayout.parse('close,minimize,maximize:');
      expect(left.left, [
        WindowButton.close,
        WindowButton.minimize,
        WindowButton.maximize,
      ]);
      expect(left.right, isEmpty);
    });

    testWidgets('Windows buttons are 138 by 32 and report what was pressed', (
      t,
    ) async {
      final pressed = <WindowButton>[];
      await t.pumpWidget(
        app(
          Align(
            alignment: Alignment.topRight,
            child: WindowButtons(
              buttons: WindowButtonLayout.windows.right,
              style: WindowButtonStyle.windows,
              maximized: false,
              onPressed: pressed.add,
              label: (b, m) => b.name,
            ),
          ),
        ),
      );
      expect(t.getSize(find.byType(WindowButtons)), const Size(138, 32));
      expect(WindowButtons.widthOf(WindowButtonStyle.windows, 3), 138);
      await t.tap(find.bySemanticsLabel('close'));
      expect(pressed, [WindowButton.close]);
    });

    testWidgets(
      'close turns red under the pointer, maximize changes its name',
      (t) async {
        Widget build(bool maximized) => app(
          WindowButtons(
            buttons: WindowButton.values,
            style: WindowButtonStyle.windows,
            maximized: maximized,
            onPressed: (_) {},
            label: (b, m) =>
                b == WindowButton.maximize && m ? 'restore' : b.name,
          ),
        );
        await t.pumpWidget(build(false));
        expect(find.bySemanticsLabel('maximize'), findsOneWidget);
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(
          location: t.getCenter(find.bySemanticsLabel('close')),
        );
        await t.pump();
        final box = t.widget<Container>(
          find
              .descendant(
                of: find.bySemanticsLabel('close'),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(
          (box.decoration! as BoxDecoration).color,
          const Color(0xFFC42B1C),
        );
        await mouse.removePointer();
        await t.pumpWidget(build(true));
        expect(find.bySemanticsLabel('restore'), findsOneWidget);
      },
    );

    testWidgets('GNOME and KDE measure what the toolbar has to leave free', (
      t,
    ) async {
      for (final (style, count, width) in [
        (WindowButtonStyle.gnome, 3, 112.0),
        (WindowButtonStyle.gnome, 1, 48.0),
        (WindowButtonStyle.kde, 3, 104.0),
      ]) {
        await t.pumpWidget(
          app(
            Align(
              alignment: Alignment.topRight,
              child: WindowButtons(
                buttons: WindowButton.values.sublist(3 - count),
                style: style,
                maximized: false,
                onPressed: (_) {},
                label: (b, m) => b.name,
              ),
            ),
          ),
        );
        expect(t.getSize(find.byType(WindowButtons)).width, width);
        expect(WindowButtons.widthOf(style, count), width);
      }
    });
  });

  group('WhisperLayout', () {
    DisplayFeature fold(
      Rect bounds, {
      DisplayFeatureState state = DisplayFeatureState.postureHalfOpened,
      DisplayFeatureType type = DisplayFeatureType.fold,
    }) => DisplayFeature(bounds: bounds, type: type, state: state);

    test('the size class comes from the window width at both lines', () {
      WhisperSizeClass of(double w) =>
          WhisperLayout.resolve(size: Size(w, 800), touch: true).sizeClass;
      expect(of(599.9), WhisperSizeClass.compact);
      expect(of(600), WhisperSizeClass.regular);
      expect(of(999.9), WhisperSizeClass.regular);
      expect(of(1000), WhisperSizeClass.expanded);
    });

    test('every state of a tri-fold lands on one step of the same ladder', () {
      WhisperSizeClass of(double w) =>
          WhisperLayout.resolve(size: Size(w, 937), touch: true).sizeClass;
      expect(of(422), WhisperSizeClass.compact);
      expect(of(860), WhisperSizeClass.regular);
      expect(of(1337), WhisperSizeClass.expanded);
    });

    test('density does not follow width', () {
      final split = WhisperLayout.resolve(
        size: const Size(405, 820),
        touch: true,
      );
      expect(split.compact, isTrue);
      expect(split.touch, isTrue);
      final tablet = WhisperLayout.resolve(
        size: const Size(1180, 820),
        touch: true,
      );
      expect(tablet.compact, isFalse);
      expect(tablet.touch, isTrue);
      final desktop = WhisperLayout.resolve(
        size: const Size(1180, 820),
        touch: false,
      );
      expect(desktop.touch, isFalse);
    });

    test('the sidebar is clamped on touch and fixed with a pointer', () {
      double side(double w, bool touch) =>
          WhisperLayout.resolve(size: Size(w, 800), touch: touch).sidebarWidth;
      expect(side(500, true), 0);
      expect(side(640, true), 240);
      expect(side(820, true), closeTo(262.4, .01));
      expect(side(1337, true), 300);
      expect(side(1337, false), 252);
    });

    test('a flat fold changes nothing', () {
      final l = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [
          fold(
            const Rect.fromLTWH(452, 0, 0, 640),
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      );
      expect(l.posture, WhisperPosture.flat);
      expect(l.foldX, isNull);
      expect(l.sidebarWidth, closeTo(289.28, .01));
    });

    test('a half-opened vertical fold puts the sidebar edge on the fold', () {
      final l = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [fold(const Rect.fromLTWH(452, 0, 0, 640))],
      );
      expect(l.posture, WhisperPosture.book);
      expect(l.foldX, 452);
      expect(l.sidebarWidth, 452);
    });

    test('a half-opened horizontal fold is the tabletop posture', () {
      final l = WhisperLayout.resolve(
        size: const Size(640, 904),
        touch: true,
        features: [fold(const Rect.fromLTWH(0, 452, 640, 0))],
      );
      expect(l.posture, WhisperPosture.tabletop);
      expect(l.foldY, 452);
      expect(l.sidebarWidth, 240);
    });

    test('a hinge counts, a camera cutout does not', () {
      final hinge = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [
          fold(
            const Rect.fromLTWH(440, 0, 24, 640),
            type: DisplayFeatureType.hinge,
          ),
        ],
      );
      expect(hinge.posture, WhisperPosture.book);
      expect(hinge.foldX, 440);
      final cutout = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [
          fold(
            const Rect.fromLTWH(440, 0, 24, 30),
            type: DisplayFeatureType.cutout,
            state: DisplayFeatureState.unknown,
          ),
        ],
      );
      expect(cutout.posture, WhisperPosture.flat);
    });

    test('a fold outside this window is ignored', () {
      final l = WhisperLayout.resolve(
        size: const Size(400, 640),
        touch: true,
        features: [fold(const Rect.fromLTWH(452, 0, 0, 640))],
      );
      expect(l.posture, WhisperPosture.flat);
    });

    test('short height is its own axis', () {
      expect(
        WhisperLayout.resolve(
          size: const Size(857, 533),
          touch: true,
        ).shortHeight,
        isTrue,
      );
      expect(
        WhisperLayout.resolve(
          size: const Size(533, 857),
          touch: true,
        ).shortHeight,
        isFalse,
      );
    });

    testWidgets('of() reads the fold from MediaQuery', (tester) async {
      late WhisperLayout got;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(904, 640),
            displayFeatures: [fold(const Rect.fromLTWH(452, 0, 0, 640))],
          ),
          child: Builder(
            builder: (c) {
              got = WhisperLayout.of(c);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(got.posture, WhisperPosture.book);
      expect(got.sizeClass, WhisperSizeClass.regular);
    });
  });
}
