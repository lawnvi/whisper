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
    List<MobileControlTarget> Function()? targets,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: theme ?? AppTheme.lightTheme,
    home: MediaQuery(
      data: MediaQueryData(
        textScaler: TextScaler.linear(scale),
        disableAnimations: reduceMotion,
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
  );
  Future<void> mount(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(390, 844);
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
      expect(
        find.text('Motion unavailable. Switched to touchpad.'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      expect(find.text('Trust required'), findsOneWidget);
      expect(transport.sent, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'keyboard sends selected combo, horizontal scrolling sends no keys',
    (tester) async {
      await mount(tester, app());
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      await tester.tap(find.text('Keyboard'));
      await tester.pump();
      final before = transport.sent.length;
      await tester.drag(find.text('Q'), const Offset(-160, 0));
      await tester.pump();
      expect(
        transport.sent.where((p) => p.eventType == RemoteInputEventType.key),
        isEmpty,
      );
      expect(transport.sent.length, greaterThanOrEqualTo(before));
      await tester.tap(find.text('Fn / symbols'));
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
    await tester.tap(find.text('Text'));
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
      await tester.tap(find.text('Keyboard'));
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
      await tester.ensureVisible(find.text('Left click'));
      await tester.pump();
      final held = await tester.startGesture(
        tester.getCenter(find.text('Left click')),
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
        tester.getCenter(find.text('Left click')),
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
  testWidgets('touchpad moves while a separate finger holds left click', (
    tester,
  ) async {
    await mount(tester, app());
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    await tester.ensureVisible(find.text('Left click'));
    await tester.pumpAndSettle();
    final held = await tester.startGesture(
      tester.getCenter(find.text('Left click')),
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
      tester.getCenter(find.text('Left click')),
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
        tester.getCenter(find.text('Left click')),
        pointer: 1,
      );
      await tester.tap(find.text('Keyboard'));
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
        tester.getCenter(find.text('Left click')),
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
  testWidgets('short portrait keeps every pointer action above navigation', (
    tester,
  ) async {
    sensor = _Sensor(true);
    await mount(tester, app());
    tester.view.physicalSize = const Size(360, 640);
    await tester.pump();
    final navigationTop = tester.getTopLeft(find.byType(NavigationBar)).dy;
    for (final label in [
      'Left click',
      'Right click',
      'Hold and tilt to scroll',
    ]) {
      expect(
        tester.getBottomRight(find.text(label)).dy,
        lessThan(navigationTop),
      );
    }
    expect(
      find.ancestor(
        of: find.text('Left click'),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
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
    await tester.tap(find.text('Keyboard'));
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
    expect(tester.getSize(pad).width, 328);
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
  testWidgets(
    'keyboard requests landscape, fits main keys, and restores portrait',
    (tester) async {
      await mount(tester, app());
      await tester.tap(find.text('Keyboard'));
      await tester.pump();
      List<dynamic> orientations() =>
          platformCalls
                  .where(
                    (c) => c.method == 'SystemChrome.setPreferredOrientations',
                  )
                  .last
                  .arguments
              as List;
      expect(orientations(), [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
      tester.view.physicalSize = const Size(640, 360);
      await tester.pump();
      for (final key in [
        'escape',
        'backspace',
        'keyP',
        'backslash',
        'capsLock',
        'enter',
        'shift',
        'slash',
        'space',
        'meta',
        'arrowRight',
      ]) {
        final bounds = tester.getRect(find.byKey(ValueKey('mobile-key-$key')));
        expect(bounds.left, greaterThanOrEqualTo(0), reason: key);
        expect(bounds.right, lessThanOrEqualTo(640), reason: key);
        expect(bounds.bottom, lessThanOrEqualTo(360), reason: key);
        expect(bounds.width, greaterThanOrEqualTo(48), reason: key);
        expect(bounds.height, greaterThanOrEqualTo(48), reason: key);
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Mouse'));
      await tester.pump();
      expect(orientations(), ['DeviceOrientation.portraitUp']);
      await tester.tap(find.text('Keyboard'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(orientations(), ['DeviceOrientation.portraitUp']);
    },
  );
  testWidgets(
    'target switching releases the previous session and requires start',
    (tester) async {
      final selected = <String>[];
      await mount(
        tester,
        app(
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('Windows PC'));
      await tester.pumpAndSettle();
      expect(coordinator.state.status, RemoteInputRuntimeStatus.idle);
      expect(selected, ['mac']);
      expect(find.text('Windows PC'), findsOneWidget);
      await tester.tap(find.byTooltip('Start control'));
      await tester.pump();
      expect(selected, ['mac', 'pc']);
      await tester.tap(find.text('Keyboard'));
      await tester.pump();
      await tester.tap(find.text('Fn / symbols'));
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
    await tester.tap(find.text('Keyboard'));
    tester.view.physicalSize = const Size(844, 390);
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
    await tester.tap(find.text('Fn / symbols'));
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

  testWidgets('keyboard transition hides orientation reflow and blocks input', (
    tester,
  ) async {
    await mount(tester, app(reduceMotion: false));
    await tester.tap(find.byTooltip('Start control'));
    await tester.pump();
    await tester.tap(find.text('Keyboard'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final fade = tester.widget<FadeTransition>(
      find.byType(FadeTransition).first,
    );
    expect(fade.opacity.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('Q'), findsOneWidget);
    final before = transport.sent
        .where((p) => p.eventType == RemoteInputEventType.key)
        .length;
    await tester.tap(find.text('Q'), warnIfMissed: false);
    await tester.pump();
    expect(
      transport.sent
          .where((p) => p.eventType == RemoteInputEventType.key)
          .length,
      before,
    );
    tester.view.physicalSize = const Size(640, 360);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Q'));
    await tester.pump();
    expect(
      transport.sent
          .where((p) => p.eventType == RemoteInputEventType.key)
          .length,
      before + 2,
    );
    await tester.tap(find.byTooltip('Mouse'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-touchpad')), findsOneWidget);
    expect(tester.takeException(), isNull);
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
