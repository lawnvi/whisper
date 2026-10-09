import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/remote_input/mobile_control_screen.dart';
import 'package:whisper/remote_input/mobile_motion.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/segmented_tabs.dart';

class _Sensor extends MobileMotionSensor {
  _Sensor(this.supported);
  final bool supported;
  final events = StreamController<MotionSample>.broadcast();
  @override
  Future<bool> available() async => supported;
  @override
  Stream<MotionSample> samples() => events.stream;
}

class _Transport implements RemoteInputPacketTransport {
  final sent = <RemoteInputPacketFrame>[];
  @override
  void send(RemoteInputPacketFrame packet) => sent.add(packet);
  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RemoteInputCoordinator coordinator;
  late _Transport transport;
  late _Sensor sensor;
  late List<RemoteInputControlMessage> controls;
  late List<MethodCall> platformCalls;
  const channel = MethodChannel('test.mobile_screen');
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controls = [];
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
    transport = _Transport();
    sensor = _Sensor(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    coordinator = RemoteInputCoordinator(
      manager: RemoteInputManager(),
      platform: RemoteInputPlatform(channel: channel),
      transportFactory: (_) async => transport,
    );
  });
  tearDown(() async {
    await coordinator.stopLocal();
    await sensor.events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Future<void> start() async {
    await coordinator.startSharingToConnectedPeer(
      sourcePeerId: 'phone',
      sinkPeerId: 'mac',
      sinkHost: 'mac',
      sinkPort: 1,
      mode: RemoteInputMode.manual,
      releaseHotkey: '',
      isMutuallyTrusted: true,
      remoteCanInject: true,
      sendControl: controls.add,
    );
    final offer = controls.last;
    await coordinator.handleControlMessage(
      RemoteInputControlMessage(
        action: RemoteInputControlAction.accept,
        mode: RemoteInputMode.manual,
        sessionId: offer.sessionId,
        sourcePeerId: 'phone',
        sinkPeerId: 'mac',
      ),
      localPeerId: 'phone',
      remoteHost: 'mac',
      remotePort: 1,
      isMutuallyTrusted: true,
      localCanInject: false,
      sendControl: controls.add,
    );
  }

  Widget app({
    Future<void> Function(String)? onStart,
    ThemeData? theme,
    double scale = 1,
    bool reduceMotion = true,
    EdgeInsets padding = EdgeInsets.zero,
    EdgeInsets systemGestureInsets = EdgeInsets.zero,
    EdgeInsets? viewInsets,
    Locale locale = const Locale('en'),
    List<MobileControlTarget> Function()? targets,
  }) => MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: theme ?? AppTheme.lightTheme,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduceMotion,
          padding: padding,
          viewPadding: padding,
          systemGestureInsets: systemGestureInsets,
          viewInsets: viewInsets,
        ),
        child: MobileControlScreen(
          peerId: 'mac',
          peerName: 'My Mac',
          targets: targets,
          coordinator: coordinator,
          sensor: sensor,
          onStart: onStart ?? (_) => start(),
          onStop: () => coordinator.stopSharing(sendControl: controls.add),
        ),
      ),
    ),
  );
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(child);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets(
    'sensor fallback and failed trust start leave controls disabled',
    (tester) async {
      await mount(
        tester,
        app(
          onStart: (_) async =>
              throw const MobileControlStartException('Trust required'),
        ),
      );
      expect(find.byKey(const ValueKey('mobile-touchpad')), findsOneWidget);
      await tester.tap(find.widgetWithText(Tab, 'Air mouse'));
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
      expect(find.byKey(const ValueKey('mobile-touchpad')), findsOneWidget);
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      expect(find.text('Trust required'), findsOneWidget);
      expect(transport.sent, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'keyboard sends selected combo, dragging across keys sends no keys',
    (tester) async {
      await mount(tester, app());
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump();
      final before = transport.sent.length;
      await tester.drag(
        find.byKey(const ValueKey('mobile-key-keyQ')),
        const Offset(-160, 0),
      );
      await tester.pump();
      expect(
        transport.sent.where((p) => p.eventType == RemoteInputEventType.key),
        isEmpty,
      );
      expect(transport.sent.length, greaterThanOrEqualTo(before));
      await tester.tap(find.byTooltip('Function and navigation keys'));
      await tester.pump();
      await tester.tap(find.byTooltip('Command'));
      await tester.pump();
      await tester.tap(find.text('F1'));
      await tester.pump();
      expect(
        transport.sent.where((p) => p.eventType == RemoteInputEventType.key),
        hasLength(4),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(coordinator.state.status, RemoteInputRuntimeStatus.idle);
    },
  );
  testWidgets('disconnect disables keyboard and keeps text draft', (
    tester,
  ) async {
    await mount(tester, app());
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '中文🙂');
    await coordinator.stopLocal();
    await tester.pump();
    expect(find.text('中文🙂'), findsOneWidget);
    final send = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send text'),
    );
    expect(send.onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'small dark screen and large text remain scrollable without overflow',
    (tester) async {
      await mount(tester, app(theme: AppTheme.darkTheme, scale: 1.6));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(844, 390);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'pointer cancellation and background release held buttons and sensors',
    (tester) async {
      sensor = _Sensor(true);
      await mount(tester, app());
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      expect(sensor.events.hasListener, isTrue);
      await tester.ensureVisible(
        find.byKey(const ValueKey('mobile-mouse-left')),
      );
      await tester.pump();
      final held = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('mobile-mouse-left'))),
      );
      await held.cancel();
      await tester.pump();
      List<bool> buttonStates() => transport.sent
          .where((p) => p.eventType == RemoteInputEventType.mouseButton)
          .map(
            (p) => (jsonDecode(utf8.decode(p.payload)) as Map)['down'] as bool,
          )
          .toList();
      expect(buttonStates(), [true, false]);
      final drag = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('mobile-mouse-left'))),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump();
      expect(buttonStates(), [true, false, true, false]);
      expect(sensor.events.hasListener, isFalse);
      expect(coordinator.state.status, RemoteInputRuntimeStatus.idle);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(coordinator.state.status, RemoteInputRuntimeStatus.idle);
      await drag.up();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('mouse feedback never delays down, up or cancellation', (
    tester,
  ) async {
    await mount(tester, app(reduceMotion: false));
    await tester.tap(find.byTooltip('Start control'));
    await tester.pumpAndSettle();
    final left = find.byKey(const ValueKey('mobile-mouse-left'));
    await tester.ensureVisible(left);
    List<bool> states() => transport.sent
        .where((packet) => packet.eventType == RemoteInputEventType.mouseButton)
        .map(
          (packet) =>
              (jsonDecode(utf8.decode(packet.payload)) as Map)['down'] as bool,
        )
        .toList();
    Color surface() =>
        (tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: left,
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration)
            .color!;
    final initial = surface();
    final held = await tester.startGesture(tester.getCenter(left));
    expect(states(), [true]);
    await tester.pump();
    final pressed = surface();
    expect(pressed, isNot(initial));
    await held.up();
    expect(states(), [true, false]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(surface(), isNot(initial));
    expect(surface(), isNot(pressed));
    final next = await tester.startGesture(tester.getCenter(left));
    expect(states(), [true, false, true]);
    await next.cancel();
    expect(states(), [true, false, true, false]);
    await tester.pumpAndSettle();
    expect(surface(), initial);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('touchpad moves while a separate finger holds left click', (
    tester,
  ) async {
    await mount(tester, app());
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('mobile-mouse-left')));
    await tester.pumpAndSettle();
    final held = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('mobile-mouse-left'))),
      pointer: 1,
    );
    await tester.pump();
    final pad = find.byKey(const ValueKey('mobile-touchpad'));
    final finger = await tester.startGesture(tester.getCenter(pad), pointer: 2);
    await tester.pump();
    await finger.moveBy(const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 30));
    await finger.up();
    await held.up();
    await tester.pump();
    final events = transport.sent
        .where((p) => p.eventType != RemoteInputEventType.heartbeat)
        .toList();
    expect(events.map((p) => p.eventType), [
      RemoteInputEventType.mouseButton,
      RemoteInputEventType.mouseMove,
      RemoteInputEventType.mouseButton,
    ]);
    expect(jsonDecode(utf8.decode(events.first.payload))['down'], isTrue);
    expect(jsonDecode(utf8.decode(events.last.payload))['down'], isFalse);
    expect(jsonDecode(utf8.decode(events[1].payload))['deltaX'], 30);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a tap on the pad preserves another finger holding left', (
    tester,
  ) async {
    await mount(tester, app());
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    final held = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('mobile-mouse-left'))),
      pointer: 1,
    );
    final finger = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('mobile-touchpad'))),
      pointer: 2,
    );
    await finger.up();
    await tester.pump();
    List<bool> states() => transport.sent
        .where((p) => p.eventType == RemoteInputEventType.mouseButton)
        .map((p) => jsonDecode(utf8.decode(p.payload))['down'] as bool)
        .toList();
    expect(states(), [true]);
    await held.up();
    expect(states(), [true, false]);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('two-finger scroll stays scroll when one finger lifts', (
    tester,
  ) async {
    await mount(tester, app());
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    final center = tester.getCenter(
      find.byKey(const ValueKey('mobile-touchpad')),
    );
    final first = await tester.startGesture(center, pointer: 1);
    final second = await tester.startGesture(
      center + const Offset(40, 0),
      pointer: 2,
    );
    await first.moveBy(const Offset(0, 20));
    await second.up();
    await first.moveBy(const Offset(0, 20));
    await first.up();
    await tester.pump();
    final inputs = transport.sent.where(
      (p) => p.eventType != RemoteInputEventType.heartbeat,
    );
    expect(inputs, isNotEmpty);
    expect(
      inputs.every((p) => p.eventType == RemoteInputEventType.mouseWheel),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'mode and orientation changes release held input and stop sensors',
    (tester) async {
      sensor = _Sensor(true);
      await mount(tester, app());
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      final held = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('mobile-mouse-left'))),
        pointer: 1,
      );
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump();
      expect(sensor.events.hasListener, isFalse);
      expect(
        transport.sent
            .where((p) => p.eventType == RemoteInputEventType.mouseButton)
            .map((p) => jsonDecode(utf8.decode(p.payload))['down']),
        [true, false],
      );
      await held.up();
      await tester.tap(find.byTooltip('Mouse'));
      await tester.pump();
      final next = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('mobile-mouse-left'))),
        pointer: 2,
      );
      tester.view.physicalSize = const Size(844, 390);
      await tester.pump();
      expect(
        transport.sent
            .where((p) => p.eventType == RemoteInputEventType.mouseButton)
            .map((p) => jsonDecode(utf8.decode(p.payload))['down']),
        [true, false, true, false],
      );
      await next.up();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('pointer buttons share a symmetric integrated surface', (
    tester,
  ) async {
    sensor = _Sensor(true);
    await mount(tester, app());
    tester.view.physicalSize = const Size(360, 640);
    await tester.pump();
    final left = tester.getRect(
      find.byKey(const ValueKey('mobile-mouse-left')),
    );
    final right = tester.getRect(
      find.byKey(const ValueKey('mobile-mouse-right')),
    );
    final scroll = tester.getRect(
      find.byKey(const ValueKey('mobile-mouse-scroll')),
    );
    expect(left.width, right.width);
    expect(scroll.width, 64);
    expect(scroll.left, greaterThan(left.right));
    expect(scroll.right, lessThan(right.left));
    expect(scroll.bottom, lessThanOrEqualTo(640));
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final reduceMotion in [false, true]) {
    testWidgets(
      'pointer tabs reuse connection transitions and keep input current, reduced=$reduceMotion',
      (tester) async {
        sensor = _Sensor(true);
        await mount(tester, app(reduceMotion: reduceMotion));
        await tester.tap(find.byTooltip('Start control'));
        await tester.pumpAndSettle();
        final air = find.widgetWithText(Tab, 'Air mouse');
        final touchpad = find.widgetWithText(Tab, 'Touchpad');
        final surface = find.byKey(const ValueKey('mobile-pointer-surface'));
        final bounds = tester.getRect(surface);
        expect(find.byType(WhisperTabBar), findsOneWidget);
        expect(find.byType(WhisperTabPanels), findsOneWidget);
        final tabs = tester.widget<TabBar>(find.byType(TabBar));
        final controller = tabs.controller!;
        expect(tabs.indicatorAnimation, TabIndicatorAnimation.elastic);
        expect(
          (tabs.indicator! as ShapeDecoration).shape,
          isA<StadiumBorder>(),
        );
        final held = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('mobile-mouse-left'))),
          pointer: 7,
        );
        await tester.tap(touchpad);
        await tester.pump();
        expect(sensor.events.hasListener, isFalse);
        expect(
          transport.sent
              .where((p) => p.eventType == RemoteInputEventType.mouseButton)
              .map((p) => jsonDecode(utf8.decode(p.payload))['down']),
          [true, false],
        );
        await held.up();
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.getRect(surface), bounds);
        final pad = find.byKey(const ValueKey('mobile-touchpad'));
        if (reduceMotion) {
          expect(controller.animation!.value, 1);
          expect(tester.getTopLeft(pad).dx, closeTo(bounds.left, .1));
        } else {
          expect(controller.animation!.value, inExclusiveRange(0, 1));
          final airBounds = tester.getRect(
            find.byKey(const ValueKey('mobile-air-surface')),
          );
          expect(bounds.left - airBounds.left, inExclusiveRange(0, 12));
          expect(pad, findsNothing);
          await tester.pump(const Duration(milliseconds: 80));
          expect(
            tester.getTopLeft(pad).dx - bounds.left,
            inExclusiveRange(0, 12),
          );
          expect(
            find.byKey(const ValueKey('mobile-air-surface')),
            findsNothing,
          );
        }
        await tester.pumpAndSettle();
        final oldTouch = await tester.startGesture(
          tester.getCenter(pad),
          pointer: 11,
        );
        await tester.tap(air);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        await tester.tap(touchpad);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        final newTouch = await tester.startGesture(
          tester.getCenter(pad),
          pointer: 12,
        );
        transport.sent.clear();
        await oldTouch.cancel();
        await newTouch.moveBy(const Offset(20, 0));
        await tester.pump(const Duration(milliseconds: 20));
        final moves = transport.sent.where(
          (p) => p.eventType == RemoteInputEventType.mouseMove,
        );
        expect(moves, hasLength(1));
        expect(jsonDecode(utf8.decode(moves.single.payload))['deltaX'], 20);
        await newTouch.up();
        await tester.pumpAndSettle();
        expect(controller.animation!.value, 1);
        expect(find.text('Enable motion'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('motion toggles without holding and pauses on mode change', (
    tester,
  ) async {
    sensor = _Sensor(true);
    await mount(tester, app());
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    await tester.tap(find.text('Enable motion'));
    await tester.pump();
    expect(find.text('Pause motion'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Pause motion'), findsOneWidget);
    await tester.tap(find.text('Pause motion'));
    await tester.pump();
    expect(find.text('Enable motion'), findsOneWidget);
    await tester.tap(find.text('Enable motion'));
    await tester.pump();
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pump();
    expect(sensor.events.hasListener, isFalse);
    await tester.tap(find.byTooltip('Mouse'));
    await tester.pump();
    expect(find.text('Enable motion'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('expanded touchpad supports a two-finger right click', (
    tester,
  ) async {
    await mount(tester, app());
    tester.view.physicalSize = const Size(360, 640);
    await tester.pump();
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    final pad = find.byKey(const ValueKey('mobile-touchpad'));
    expect(tester.getSize(pad).width, closeTo(328, 2));
    expect(tester.getSize(pad).height, greaterThan(320));
    final first = await tester.startGesture(tester.getCenter(pad), pointer: 1);
    final second = await tester.startGesture(
      tester.getCenter(pad) + const Offset(40, 0),
      pointer: 2,
    );
    await second.up();
    await first.up();
    await tester.pump();
    final events = transport.sent
        .where((p) => p.eventType != RemoteInputEventType.heartbeat)
        .toList();
    expect(events.map((p) => p.eventType), [
      RemoteInputEventType.mouseButton,
      RemoteInputEventType.mouseButton,
    ]);
    expect(jsonDecode(utf8.decode(events.first.payload)), {
      'button': 1,
      'down': true,
    });
    expect(jsonDecode(utf8.decode(events.last.payload)), {
      'button': 1,
      'down': false,
    });
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('portrait QWERTY fits without rotation and has staggered rows', (
    tester,
  ) async {
    await mount(tester, app());
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pump();
    for (final (size, bottomInset, gestureInset, bottomGap) in [
      (const Size(390, 844), 0.0, 0.0, 24.0),
      (const Size(390, 844), 24.0, 24.0, 40.0),
      (const Size(390, 844), 0.0, 24.0, 40.0),
      (const Size(390, 844), 34.0, 0.0, 50.0),
      (const Size(390, 844), 48.0, 0.0, 64.0),
      (const Size(320, 640), 0.0, 0.0, 24.0),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        app(
          padding: EdgeInsets.only(bottom: bottomInset),
          systemGestureInsets: EdgeInsets.only(bottom: gestureInset),
        ),
      );
      await tester.pump();
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('mobile-keyboard-panel')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      for (final letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) {
        final bounds = tester.getRect(
          find.byKey(ValueKey('mobile-key-key$letter')),
        );
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(size.width));
        expect(bounds.height, greaterThanOrEqualTo(48));
        expect(bounds.bottom, lessThanOrEqualTo(size.height - bottomInset));
      }
      final q = tester.getRect(find.byKey(const ValueKey('mobile-key-keyQ')));
      final a = tester.getRect(find.byKey(const ValueKey('mobile-key-keyA')));
      expect(a.left, greaterThan(q.left));
      expect(a.width, closeTo(q.width, 2));
      expect(
        tester.getRect(find.byKey(const ValueKey('mobile-key-enter'))).bottom,
        closeTo(size.height - bottomGap, .1),
      );
      expect(tester.takeException(), isNull);
    }
    expect(
      platformCalls.where(
        (c) => c.method == 'SystemChrome.setPreferredOrientations',
      ),
      isEmpty,
    );
    final toggle = tester.getRect(
      find.byKey(const ValueKey('mobile-control-toggle')),
    );
    final start = tester.getRect(find.byTooltip('Start control'));
    final settings = tester.getRect(find.byTooltip('Pointer settings'));
    expect(toggle.right, lessThanOrEqualTo(start.left));
    expect(start.right, lessThanOrEqualTo(settings.left));
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byTooltip('Mouse'));
    await tester.pump();
    expect(find.byKey(const ValueKey('mobile-touchpad')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'target switching releases the previous session and requires start',
    (tester) async {
      final selected = <String>[];
      await mount(
        tester,
        app(
          reduceMotion: false,
          targets: () => [
            const MobileControlTarget('mac', 'My Mac'),
            const MobileControlTarget('pc', 'Windows PC', platform: 'windows'),
          ],
          onStart: (id) async {
            selected.add(id);
            if (id == 'mac') await start();
          },
        ),
      );
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      await tester.tap(find.text('My Mac'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      final sheet = find.byKey(const ValueKey('mobile-control-target-sheet'));
      final enteringTop = tester.getTopLeft(sheet).dy;
      await tester.pumpAndSettle();
      final openedTop = tester.getTopLeft(sheet).dy;
      expect(enteringTop, greaterThan(openedTop));
      await tester.tap(find.text('Windows PC'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(sheet, findsOneWidget);
      expect(tester.getTopLeft(sheet).dy, greaterThan(openedTop));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(coordinator.state.status, RemoteInputRuntimeStatus.idle);
      expect(selected, ['mac']);
      expect(find.text('Windows PC'), findsOneWidget);
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      expect(selected, ['mac', 'pc']);
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Function and navigation keys'));
      await tester.pump();
      expect(find.text('Win'), findsOneWidget);
      expect(find.text('Alt'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('settings remain available in touchpad mode and persist speeds', (
    tester,
  ) async {
    await mount(tester, app());
    await tester.tap(find.byTooltip('Pointer settings'));
    await tester.pumpAndSettle();
    expect(find.text('Touchpad pointer speed'), findsOneWidget);
    expect(find.text('Scroll speed'), findsOneWidget);
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders, hasLength(2));
    sliders[0].onChanged!(2);
    sliders[0].onChangeEnd!(2);
    sliders[1].onChanged!(0.5);
    sliders[1].onChangeEnd!(0.5);
    await tester.pump();
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getDouble('mobile_pointer_speed'), 2);
    expect(preferences.getDouble('mobile_scroll_speed'), 0.5);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('open pointer settings follows calibration and disconnect', (
    tester,
  ) async {
    sensor = _Sensor(true);
    await mount(tester, app());
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    await tester.tap(find.byTooltip('Pointer settings'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNWidgets(3));
    final calibrate = find.widgetWithText(OutlinedButton, 'Calibrate');
    expect(tester.widget<OutlinedButton>(calibrate).onPressed, isNotNull);
    await tester.tap(calibrate);
    await tester.pump();
    expect(find.text('Hold the phone still briefly…'), findsOneWidget);
    for (var i = 0; i < 50; i++) {
      sensor.events.add(MotionSample(i * 10000, [0, 0, 0], [0, 0, 9.8]));
    }
    await tester.pump();
    expect(tester.widget<OutlinedButton>(calibrate).onPressed, isNotNull);
    await coordinator.stopLocal();
    await tester.pump();
    expect(tester.widget<OutlinedButton>(calibrate).onPressed, isNull);
    expect(sensor.events.hasListener, isFalse);
    await tester.pump(const Duration(seconds: 6));
    expect(
      find.text('Keep the phone still and try calibrating again.'),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('held keyboard repeat stops on page change and disconnect', (
    tester,
  ) async {
    await mount(tester, app());
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pump();
    int keyCount() => transport.sent
        .where((packet) => packet.eventType == RemoteInputEventType.key)
        .length;
    final backspace = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('mobile-key-backspace'))),
      pointer: 1,
    );
    await tester.pump(const Duration(milliseconds: 399));
    expect(keyCount(), 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(keyCount(), 2);
    await tester.pump(const Duration(milliseconds: 60));
    expect(keyCount(), 4);
    await tester.tap(find.byTooltip('Function and navigation keys'));
    await tester.pump(const Duration(milliseconds: 600));
    await backspace.up();
    await tester.pump();
    expect(keyCount(), 4);

    final arrow = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('mobile-key-arrowLeft'))),
      pointer: 2,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(keyCount(), 6);
    await coordinator.stopLocal();
    await tester.pump(const Duration(milliseconds: 600));
    await arrow.up();
    await tester.pump();
    expect(keyCount(), 6);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keyboard transition releases input and fades without rotating', (
    tester,
  ) async {
    await mount(tester, app(reduceMotion: false));
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final fade = tester.widget<FadeTransition>(
      find.byType(FadeTransition).first,
    );
    expect(fade.opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-key-keyQ')));
    await tester.pump();
    expect(
      transport.sent.where((p) => p.eventType == RemoteInputEventType.key),
      hasLength(2),
    );
    expect(
      platformCalls.where(
        (c) => c.method == 'SystemChrome.setPreferredOrientations',
      ),
      isEmpty,
    );
    await tester.tap(find.byTooltip('Mouse'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-touchpad')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'same-page text editing stops repeats, preserves draft across toggle',
    (tester) async {
      await mount(tester, app());
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump();
      final held = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('mobile-key-backspace'))),
      );
      await tester.pump(const Duration(milliseconds: 400));
      int keys() => transport.sent
          .where((p) => p.eventType == RemoteInputEventType.key)
          .length;
      expect(keys(), 2);
      await tester.enterText(find.byType(TextField), '中文🙂');
      await tester.pump(const Duration(milliseconds: 600));
      await held.up();
      expect(keys(), 2);
      expect(find.byKey(const ValueKey('mobile-key-keyQ')), findsNothing);
      await tester.tap(find.text('Return to direct keys'));
      await tester.pump();
      expect(find.byKey(const ValueKey('mobile-key-keyQ')), findsOneWidget);
      await tester.tap(find.byTooltip('Mouse'));
      await tester.pump();
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump();
      expect(find.text('中文🙂'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'central scroll gesture sends wheel events and cancels on switch',
    (tester) async {
      await mount(tester, app());
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      final held = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('mobile-mouse-scroll'))),
      );
      await held.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump();
      await held.cancel();
      final events = transport.sent.where(
        (p) => p.eventType != RemoteInputEventType.heartbeat,
      );
      expect(events.map((e) => e.eventType), [RemoteInputEventType.mouseWheel]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'symbol pages send explicit balanced Shift then clear modifiers',
    (tester) async {
      await mount(tester, app());
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mobile-key-symbolPage')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mobile-key-@')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mobile-key-morePage')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mobile-key-[')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mobile-key-symbolPage')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mobile-key-keyQ')));
      await tester.pump();
      final keys = transport.sent
          .where((p) => p.eventType == RemoteInputEventType.key)
          .map((p) => jsonDecode(utf8.decode(p.payload)) as Map)
          .toList();
      expect(keys.map((e) => (e['keySemantic'], e['down'])), [
        ('shift', true),
        ('digit2', true),
        ('digit2', false),
        ('shift', false),
        ('bracketLeft', true),
        ('bracketLeft', false),
        ('keyQ', true),
        ('keyQ', false),
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'text waits for matching confirmation and timeout keeps the draft',
    (tester) async {
      await mount(tester, app());
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '中文🙂\nhello');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send text'));
      await tester.pump();
      final frame = transport.sent.singleWhere(
        (p) => p.eventType == RemoteInputEventType.textCommit,
      );
      expect(jsonDecode(utf8.decode(frame.payload))['text'], '中文🙂\nhello');
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('mobile-control-toggle')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      Future<void> reply(int sequence) => coordinator.handleControlMessage(
        RemoteInputControlMessage(
          action: RemoteInputControlAction.textResult,
          mode: RemoteInputMode.manual,
          sessionId: frame.sessionId,
          sourcePeerId: 'phone',
          sinkPeerId: 'mac',
          textSequence: sequence,
          textSucceeded: true,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac',
        remotePort: 1,
        isMutuallyTrusted: true,
        localCanInject: false,
        sendControl: controls.add,
      );
      await reply(frame.sequence + 1);
      await tester.pump();
      expect(find.text('中文🙂\nhello'), findsOneWidget);
      expect(coordinator.isSendingText, isTrue);
      await reply(frame.sequence);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(find.byKey(const ValueKey('mobile-key-keyQ')), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'keep this');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send text'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('keep this'), findsOneWidget);
      expect(
        find.text(
          'Input was not confirmed. Draft kept; check the computer before resending.',
        ),
        findsOneWidget,
      );
      expect(
        transport.sent.where(
          (p) => p.eventType == RemoteInputEventType.textCommit,
        ),
        hasLength(2),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('air scroll stops on touch cancellation and keyboard switch', (
    tester,
  ) async {
    sensor = _Sensor(true);
    await mount(tester, app());
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    var micros = 0;
    Future<void> tilt() async {
      for (var i = 0; i < 8; i++) {
        sensor.events.add(
          MotionSample(micros += 10000, [1, 0, 0], [0, 0, 9.8]),
        );
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }

    final scroll = find.byKey(const ValueKey('mobile-mouse-scroll'));
    final held = await tester.startGesture(tester.getCenter(scroll));
    await tester.pump();
    await tilt();
    final count = transport.sent
        .where((p) => p.eventType == RemoteInputEventType.mouseWheel)
        .length;
    expect(count, greaterThan(0));
    expect(
      transport.sent.where(
        (p) => p.eventType == RemoteInputEventType.mouseMove,
      ),
      isEmpty,
    );
    await held.cancel();
    await tester.pump();
    await tilt();
    expect(
      transport.sent.where(
        (p) => p.eventType == RemoteInputEventType.mouseWheel,
      ),
      hasLength(count),
    );
    final next = await tester.startGesture(tester.getCenter(scroll));
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pump();
    expect(sensor.events.hasListener, isFalse);
    await next.up();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'keyboard settings can calibrate without leaving sensors running',
    (tester) async {
      sensor = _Sensor(true);
      await mount(tester, app());
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump();
      expect(sensor.events.hasListener, isFalse);
      await tester.tap(find.byTooltip('Pointer settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Calibrate'));
      await tester.pump();
      expect(sensor.events.hasListener, isTrue);
      for (var i = 0; i < 50; i++) {
        sensor.events.add(MotionSample(i * 10000, [0, 0, 0], [0, 0, 9.8]));
      }
      await tester.pump();
      expect(find.text('Calibration complete'), findsOneWidget);
      expect(sensor.events.hasListener, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final locale in ['en', 'zh', 'es']) {
    testWidgets('$locale keyboard pages fit small screens with large text', (
      tester,
    ) async {
      await mount(
        tester,
        app(locale: Locale(locale), scale: 1.6, theme: AppTheme.darkTheme),
      );
      tester.view.physicalSize = const Size(320, 640);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mobile-control-toggle')));
      await tester.pump();
      for (final page in ['symbolPage', 'morePage', 'fnPage']) {
        expect(tester.takeException(), isNull);
        final key = find.byKey(ValueKey('mobile-key-$page'));
        await tester.ensureVisible(key);
        await tester.pumpAndSettle();
        await tester.tap(key);
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('iPad landscape shows pointer and keyboard together', (
    tester,
  ) async {
    await mount(tester, app(), size: const Size(1024, 768));
    expect(find.byKey(const ValueKey('mobile-control-split')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-touchpad')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-keyboard-panel')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'iPad 中文🙂');
    await tester.pump();
    expect(find.byKey(const ValueKey('mobile-control-split')), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('iPad 中文🙂'), findsOneWidget);
    await tester.pumpWidget(
      app(viewInsets: const EdgeInsets.only(bottom: 300)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'iPad split resizing releases held mouse input without rotation',
    (tester) async {
      await mount(tester, app(), size: const Size(1024, 768));
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      final held = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('mobile-mouse-left'))),
      );
      tester.view.physicalSize = const Size(880, 768);
      await tester.pump();
      expect(
        transport.sent
            .where((p) => p.eventType == RemoteInputEventType.mouseButton)
            .map((p) => jsonDecode(utf8.decode(p.payload))['down']),
        [true, false],
      );
      await held.up();
      for (final size in [const Size(768, 1024), const Size(320, 700)]) {
        tester.view.physicalSize = size;
        await tester.pump();
        expect(
          find.byKey(const ValueKey('mobile-control-split')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('iPad motion pauses for typing and resumes beside the keyboard', (
    tester,
  ) async {
    sensor = _Sensor(true);
    await mount(tester, app(), size: const Size(1024, 768));
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    expect(sensor.events.hasListener, isTrue);
    await tester.enterText(find.byType(TextField), 'keep draft');
    await tester.pump();
    expect(sensor.events.hasListener, isFalse);
    await tester.tap(find.text('Return to direct keys'));
    await tester.pump();
    expect(find.byKey(const ValueKey('mobile-control-split')), findsOneWidget);
    expect(sensor.events.hasListener, isTrue);
    tester.view.physicalSize = const Size(507, 768);
    await tester.pump();
    expect(sensor.events.hasListener, isFalse);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'keep draft',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('permission failure explains the Mac setting', (tester) async {
    await mount(
      tester,
      app(
        onStart: (_) async {
          await start();
          await coordinator.handleControlMessage(
            RemoteInputControlMessage(
              action: RemoteInputControlAction.error,
              mode: RemoteInputMode.manual,
              sessionId: coordinator.state.sessionId,
              sourcePeerId: 'phone',
              sinkPeerId: 'mac',
              errorMessage: 'permission',
            ),
            localPeerId: 'phone',
            remoteHost: 'mac',
            remotePort: 1,
            isMutuallyTrusted: true,
            localCanInject: false,
            sendControl: controls.add,
          );
        },
      ),
    );
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    expect(find.textContaining('Accessibility on the Mac'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
