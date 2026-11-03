// What the pages do when used, through the widgets: the logic itself is covered
// by shell_sound_test.dart and shell_input_test.dart.

import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/new_ui/input/input_rules.dart';
import 'package:whisper/new_ui/input/shell_input_page.dart';
import 'package:whisper/new_ui/share/share_parts.dart';
import 'package:whisper/new_ui/sound/shell_sound_page.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/theme/whisper_ui.dart';

import 'support/share_page_fixtures.dart';

const _wide = Size(876, 690);
const _narrow = Size(468, 480);

Future<void> _drive(WidgetTester tester, Future<void> Function() body) async {
  var done = false;
  Object? failure;
  unawaited(
    body().then(
      (_) => done = true,
      onError: (Object error) {
        failure = error;
        done = true;
      },
    ),
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (failure != null) throw failure!;
  expect(done, isTrue);
}

Future<SoundWorld> _sound(
  WidgetTester tester, {
  Size size = _wide,
  SoundWorld Function() make = SoundWorld.new,
}) async {
  final world = make();
  addTearDown(world.dispose);
  await pumpContent(
    tester,
    ShellSoundPage(
      rightInset: 0,
      selfDevice: selfMac,
      sessions: world.sessions,
      controller: world.controller,
    ),
    size: size,
  );
  return world;
}

Future<InputWorld> _input(
  WidgetTester tester, {
  Size size = _wide,
  InputWorld Function() make = InputWorld.new,
}) async {
  final world = make();
  addTearDown(world.dispose);
  await pumpContent(
    tester,
    ShellInputPage(
      rightInset: 0,
      selfDevice: selfMac,
      sessions: world.sessions,
      controller: world.controller,
    ),
    size: size,
  );
  return world;
}

Finder _check(String device) => find.bySemanticsLabel('把声音播放到 $device');

Finder _screen(String device) => find.bySemanticsLabel(RegExp('^$device 的屏幕'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sound', () {
    testWidgets('checking starts it, and every row stays 60 high', (
      tester,
    ) async {
      final world = await _sound(tester);
      double height() =>
          tester.getSize(find.byKey(ValueKey(imacDevice.uid))).height;
      expect(height(), 60);

      await tester.tap(_check('iMac'));
      await settle(tester);
      expect(world.controller.isSelected(imacDevice.uid), isTrue);
      expect(world.group.session, isNotNull);
      expect(height(), 60);

      await _drive(tester, () => world.accept(imacDevice.uid));
      await settle(tester);
      expect(height(), 60);

      await _drive(tester, () => world.report(imacDevice.uid));
      await settle(tester);
      expect(find.text('同步良好'), findsWidgets);
      expect(height(), 60);

      await _drive(tester, () => world.reject(imacDevice.uid));
      await settle(tester);
      expect(height(), 60);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('states do not move what is below them', (tester) async {
      final world = await _sound(tester);
      await tester.tap(_check('iMac'));
      await settle(tester);
      double switchTop() => tester.getTopLeft(find.byType(ShareSwitch)).dy;
      final before = switchTop();

      await _drive(tester, () => world.accept(imacDevice.uid));
      await settle(tester);
      expect(switchTop(), before);
      await _drive(tester, () => world.report(imacDevice.uid));
      await settle(tester);
      expect(switchTop(), before);
      await tester.tap(find.byType(ShareSwitch));
      await settle(tester);
      expect(switchTop(), before);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a nearby device cannot be checked', (tester) async {
      final world = await _sound(tester);
      await tester.tap(_check('Redmi Pad'), warnIfMissed: false);
      await settle(tester);
      expect(world.controller.isSelected(redmiDevice.uid), isFalse);
      expect(find.text('未连接'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the channels are in the row, and tapping one sets it', (
      tester,
    ) async {
      final world = await _sound(tester);
      await tester.tap(_check('iMac'));
      await settle(tester);
      await tester.tap(find.text('单声道'));
      await settle(tester);
      expect(world.controller.channelOf(imacDevice.uid), AudioChannelRole.mono);
      expect(
        world.sentGroup.last.$2.action,
        AudioGroupControlAction.groupUpdate,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('narrow, they fold into a menu', (tester) async {
      final world = await _sound(tester, size: _narrow);
      await tester.tap(_check('iMac'));
      await settle(tester);
      expect(find.byType(LiquidSegmented<AudioChannelRole>), findsNothing);

      await tester.tap(find.text('立体声'));
      await settle(tester);
      expect(find.text('左声道'), findsOneWidget);
      await tester.tap(find.text('单声道'));
      await settle(tester);
      expect(world.controller.channelOf(imacDevice.uid), AudioChannelRole.mono);
      expect(find.text('左声道'), findsNothing);

      await tester.tap(find.text('单声道'));
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text('左声道'), findsNothing);
      expect(world.controller.channelOf(imacDevice.uid), AudioChannelRole.mono);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the master switch appears with members and keeps them', (
      tester,
    ) async {
      final world = await _sound(tester);
      expect(find.byType(ShareSwitch), findsNothing);
      await tester.tap(_check('iMac'));
      await settle(tester);
      expect(find.byType(ShareSwitch), findsOneWidget);

      await tester.tap(find.byType(ShareSwitch));
      await settle(tester);
      expect(world.group.session, isNull);
      expect(find.text('已停止'), findsOneWidget);
      expect(world.controller.isSelected(imacDevice.uid), isTrue);
      expect(find.text('播放到其他设备'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without permission there is a button to go and allow it', (
      tester,
    ) async {
      final world = await _sound(tester, make: () => SoundWorld(denied: true));
      expect(find.text('需要允许屏幕与系统录音'), findsOneWidget);
      await tester.tap(find.text('去开启'));
      await settle(tester);
      expect(world.permissionAsked, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a sink slides the gain live and saves it when let go', (
      tester,
    ) async {
      final world = SoundWorld();
      addTearDown(world.dispose);
      await _drive(tester, () => world.offerFrom(imacDevice.uid));
      await pumpContent(
        tester,
        ShellSoundPage(
          rightInset: 0,
          selfDevice: selfMac,
          sessions: world.sessions,
          controller: world.controller,
        ),
        size: _wide,
      );
      expect(find.text('正在播放 iMac 的声音'), findsOneWidget);
      expect(find.text('1.0x'), findsOneWidget);
      await tester.drag(find.byType(Slider), const Offset(100, 0));
      await settle(tester);
      expect(world.controller.gain, greaterThan(1));
      expect(world.savedGain, world.controller.gain);

      await tester.tap(find.text('暂停'));
      await settle(tester);
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      await tester.tap(find.text('断开'));
      await settle(tester);
      expect(world.controller.sinkView, isNull);
      expect(find.text('播放到其他设备'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no way back to a source that cannot take it', (tester) async {
      final world = SoundWorld(canRejoin: false);
      addTearDown(world.dispose);
      await _drive(tester, () async {
        await world.offerFrom(imacDevice.uid);
        await world.controller.pause();
      });
      await pumpContent(
        tester,
        ShellSoundPage(
          rightInset: 0,
          selfDevice: selfMac,
          sessions: world.sessions,
          controller: world.controller,
        ),
        size: _wide,
      );
      expect(find.text('继续'), findsNothing);
      expect(find.text('断开'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('keyboard and mouse', () {
    testWidgets('the switch is at the right of the toolbar and starts it', (
      tester,
    ) async {
      final world = await _input(tester);
      final toggle = find.byType(ShareSwitch);
      expect(tester.getTopRight(toggle).dx, _wide.width - 20);
      expect(tester.getCenter(toggle).dy, 26);
      await tester.tap(toggle);
      await settle(tester);
      expect(world.workspace.isControllerLive, isTrue);
      expect(find.textContaining('收回键鼠'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the canvas keeps its size whatever the footer says', (
      tester,
    ) async {
      final world = await _input(
        tester,
        make: () => InputWorld(notTrustingUs: {thinkPadDevice.uid}),
      );
      final canvas = find.bySemanticsLabel('屏幕排列');
      final before = tester.getSize(canvas);
      await tester.tap(find.byType(ShareSwitch));
      await settle(tester);
      expect(find.text('重试'), findsOneWidget);
      expect(tester.getSize(canvas), before);
      expect(world.workspace.isControllerLive, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a retry brings it in', (tester) async {
      final world = await _input(
        tester,
        make: () => InputWorld(notTrustingUs: {thinkPadDevice.uid}),
      );
      await tester.tap(find.byType(ShareSwitch));
      await settle(tester);
      expect(find.text('对方未信任本机'), findsOneWidget);
      world.notTrustingUs.clear();
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(find.text('对方未信任本机'), findsNothing);
      expect(
        world.workspace.snapshot.targets.keys,
        contains(thinkPadDevice.uid),
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('clicking selects, and the footer can take it out', (
      tester,
    ) async {
      final world = await _input(tester);
      await tester.tap(_screen('iMac'));
      await settle(tester);
      expect(world.controller.selected, imacDevice.uid);
      expect(find.text('2560×1440 · 右侧'), findsOneWidget);

      await tester.tap(find.text('移出'));
      await settle(tester);
      expect(world.layouts[imacDevice.uid]!.enabled, isFalse);
      expect(world.controller.selected, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a held screen shows where it will land, and lands there', (
      tester,
    ) async {
      final world = await _input(tester);
      final start = tester.getCenter(_screen('iMac'));
      final held = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await held.moveBy(const Offset(0, -4));
      await tester.pump();
      await held.moveBy(const Offset(10, -200));
      await settle(tester);
      expect(world.layouts[imacDevice.uid]!.y, -229, reason: 'not yet');

      await held.up();
      await settle(tester);
      final landed = world.layouts[imacDevice.uid]!;
      expect(landed.y, isNot(-229));
      final screens = world.controller.screens;
      final imac = screens.firstWhere((s) => s.peerId == imacDevice.uid);
      expect(world.controller.selected, imacDevice.uid);
      expect(inputSideOf(screens.first.bounds, imac.bounds), InputSide.above);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('dragged out of the canvas it leaves', (tester) async {
      final world = await _input(tester);
      final held = await tester.startGesture(
        tester.getCenter(_screen('iMac')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await held.moveBy(const Offset(0, -4));
      await tester.pump();
      await held.moveBy(const Offset(0, -600));
      await settle(tester);
      await held.up();
      await settle(tester);
      expect(world.layouts[imacDevice.uid]!.enabled, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a candidate comes in with a tap', (tester) async {
      final world = await _input(tester, make: () => InputWorld(layouts: {}));
      await tester.tap(find.text('iMac'));
      await settle(tester);
      expect(world.layouts[imacDevice.uid]!.enabled, isTrue);
      expect(world.controller.selected, imacDevice.uid);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a candidate dragged onto the canvas lands there', (
      tester,
    ) async {
      final world = await _input(tester, make: () => InputWorld(layouts: {}));
      final held = await tester.startGesture(
        tester.getCenter(find.text('iMac')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await held.moveBy(const Offset(0, -4));
      await tester.pump();
      await held.moveBy(const Offset(40, -250));
      await settle(tester);
      expect(world.layouts[imacDevice.uid]!.enabled, isFalse, reason: 'held');
      await held.up();
      await settle(tester);
      expect(world.layouts[imacDevice.uid]!.enabled, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a candidate dropped off the canvas stays a candidate', (
      tester,
    ) async {
      final world = await _input(tester, make: () => InputWorld(layouts: {}));
      final held = await tester.startGesture(
        tester.getCenter(find.text('iMac')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await held.moveBy(const Offset(0, -2));
      await tester.pump();
      await held.moveBy(const Offset(0, 60));
      await settle(tester);
      await held.up();
      await settle(tester);
      expect(world.layouts[imacDevice.uid]!.enabled, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the keyboard can do what the mouse can', (tester) async {
      final world = await _input(tester);
      await tester.tap(_screen('iMac'));
      await settle(tester);
      expect(world.controller.selected, imacDevice.uid);
      final y = world.layouts[imacDevice.uid]!.y;

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
      expect(world.layouts[imacDevice.uid]!.y, y + 100);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await settle(tester);
      expect(world.layouts[imacDevice.uid]!.y, y + 500);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(world.controller.selected, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('being controlled: no switch, and stop works', (tester) async {
      final world = InputWorld();
      addTearDown(world.dispose);
      await tester.pump();
      await _driveWithIo(tester, () async {
        await world.runtime.handleControlMessage(
          RemoteInputControlMessage(
            action: RemoteInputControlAction.offer,
            sessionId: 'controlled',
            sourcePeerId: imacDevice.uid,
            sinkPeerId: selfMac.uid,
            layoutEdge: RemoteInputEdge.right,
          ),
          localPeerId: selfMac.uid,
          remoteHost: 'imac.local',
          remotePort: 10002,
          isMutuallyTrusted: true,
          localCanInject: true,
          sendControl: (_) {},
        );
      });
      await pumpContent(
        tester,
        ShellInputPage(
          rightInset: 0,
          selfDevice: selfMac,
          sessions: world.sessions,
          controller: world.controller,
        ),
        size: _wide,
      );
      expect(find.text('iMac 正在控制本机'), findsOneWidget);
      expect(find.byType(ShareSwitch), findsNothing);
      await tester.tap(find.text('停止'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await settle(tester);
      expect(world.controller.controlledBy, isNull);
      expect(find.byType(ShareSwitch), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

Future<void> _driveWithIo(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  var done = false;
  Object? failure;
  unawaited(
    body().then(
      (_) => done = true,
      onError: (Object error) {
        failure = error;
        done = true;
      },
    ),
  );
  for (var i = 0; i < 500 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  if (failure != null) throw failure!;
  expect(done, isTrue);
}
