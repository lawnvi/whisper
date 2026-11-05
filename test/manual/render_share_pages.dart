// Every state of the sound and keyboard and mouse pages, in both themes, at the
// smallest content area and either side of the width where channels fold. A
// layout overflow fails the test on its own.
//
// To look at them next to docs/design/reference/:
//   WHISPER_RENDER_DIR=/some/dir flutter test --no-pub test/manual/render_share_pages.dart

import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/new_ui/input/shell_input_page.dart';
import 'package:whisper/new_ui/sound/shell_sound_page.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

import '../support/golden_support.dart';
import '../support/share_page_fixtures.dart';

const _window = Size(876, 690);
const _regular = Size(524, 690);
const _minimum = Size(468, 480);
const _atFold = Size(520, 480);

typedef _Scene = Future<void> Function(SoundWorld world);
typedef _InputScene = Future<void> Function(InputWorld world);

/// Runs [body] in the test's fake-async zone, where everything it touches was
/// made, pumping so that its microtasks run. Awaiting it inside `runAsync` would
/// deadlock: nothing in the fake zone moves until something pumps.
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
  for (var i = 0; i < 500 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    // Some of it is real I/O, like reading the key map's assets.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  if (failure != null) throw failure!;
  expect(done, isTrue, reason: 'the scene never finished');
}

final _soundScenes = <String, (_Scene, SoundWorld Function(), String?)>{
  'idle': ((world) async {}, SoundWorld.new, 'desktop-audio-idle.jpg'),
  'playing': (
    (world) async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.accept(imacDevice.uid);
      await world.accept(xiaomiDevice.uid);
      await world.report(imacDevice.uid);
      await world.report(
        xiaomiDevice.uid,
        rttMs: 9,
        jitterMs: 9,
        bufferMs: 120,
      );
    },
    SoundWorld.new,
    'desktop-audio.jpg',
  ),
  'establishing': (
    (world) async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.accept(imacDevice.uid);
    },
    SoundWorld.new,
    null,
  ),
  'switch-off': (
    (world) async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.controller.setChannel(
        xiaomiDevice.uid,
        AudioChannelRole.mono,
      );
      await world.controller.setOn(false);
    },
    SoundWorld.new,
    null,
  ),
  'member-failed': (
    (world) async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.accept(imacDevice.uid);
      await world.report(imacDevice.uid);
      await world.reject(xiaomiDevice.uid);
    },
    SoundWorld.new,
    null,
  ),
  'no-permission': (
    (world) async {
      await world.controller.toggle(imacDevice.uid);
    },
    () => SoundWorld(denied: true),
    null,
  ),
  'old-device': (
    (world) async {},
    () => SoundWorld(solo: {thinkPadDevice.uid}),
    null,
  ),
  'old-device-picked': (
    (world) async {
      await world.controller.toggle(thinkPadDevice.uid);
    },
    () => SoundWorld(solo: {thinkPadDevice.uid}),
    null,
  ),
  'sink': (
    (world) async {
      await world.offerFrom(imacDevice.uid);
    },
    SoundWorld.new,
    'desktop-audio-sink.jpg',
  ),
  'sink-paused': (
    (world) async {
      await world.offerFrom(imacDevice.uid);
      await world.group.pausePlaybackAsSink();
    },
    SoundWorld.new,
    null,
  ),
  'sink-paused-no-rejoin': (
    (world) async {
      await world.offerFrom(imacDevice.uid);
      await world.group.pausePlaybackAsSink();
    },
    () => SoundWorld(canRejoin: false),
    null,
  ),
};

final _inputScenes = <String, (_InputScene, InputWorld Function(), String?)>{
  'selected': (
    (world) async {
      world.controller.select(thinkPadDevice.uid);
    },
    InputWorld.new,
    'desktop-input.jpg',
  ),
  'idle': ((world) async {}, InputWorld.new, null),
  'imac-above': (
    (world) async {
      world.controller.select(imacDevice.uid);
    },
    () => InputWorld(
      layouts: {
        imacDevice.uid: layoutOf(imacDevice.uid, 1290, -1440, 2560, 1440),
        thinkPadDevice.uid: layoutOf(
          thinkPadDevice.uid,
          3850,
          -233,
          3840,
          1200,
        ),
        ubuntuDevice.uid: layoutOf(ubuntuDevice.uid, -1920, -49, 1920, 1080),
      },
    ),
    null,
  ),
  'on-failed': (
    (world) async {
      await world.controller.setOn(true);
      await world.accept(imacDevice.uid);
    },
    () => InputWorld(notTrustingUs: {thinkPadDevice.uid}),
    'desktop-input-on.jpg',
  ),
  'on': (
    (world) async {
      await world.controller.setOn(true);
      await world.accept(imacDevice.uid);
      await world.accept(thinkPadDevice.uid);
    },
    InputWorld.new,
    null,
  ),
  'candidates': (
    (world) async {},
    () => InputWorld(
      connected: {imacDevice.uid, thinkPadDevice.uid},
      layouts: {
        imacDevice.uid: layoutOf(imacDevice.uid, 1512, 0, 2560, 1440),
        thinkPadDevice.uid: layoutOf(
          thinkPadDevice.uid,
          4072,
          0,
          3840,
          1200,
          enabled: false,
        ),
        ubuntuDevice.uid: layoutOf(
          ubuntuDevice.uid,
          -1920,
          -49,
          1920,
          1080,
          enabled: false,
        ),
      },
    ),
    null,
  ),
  'no-targets': (
    (world) async {},
    () => InputWorld(connected: {}, layouts: {}),
    null,
  ),
  'no-permission': (
    (world) async {
      await world.controller.setOn(true);
    },
    () => InputWorld(denied: true),
    null,
  ),
  'unsupported-peer': (
    (world) async {},
    () => InputWorld(unsupported: {thinkPadDevice.uid}),
    null,
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadGoldenFonts);

  for (final MapEntry(key: name, value: scene) in _soundScenes.entries) {
    final (act, make, reference) = scene;
    group('sound: $name', () {
      for (final brightness in Brightness.values) {
        for (final size in [_window, _minimum, _atFold]) {
          testWidgets('${brightness.name} ${size.width}', (tester) async {
            final world = make();
            addTearDown(world.dispose);
            await _drive(tester, () => act(world));
            await pumpContent(
              tester,
              ShellSoundPage(
                rightInset: 0,
                selfDevice: selfMac,
                sessions: world.sessions,
                controller: world.controller,
              ),
              size: size,
              brightness: brightness,
            );
            await renderShot(
              tester,
              'sound-$name-${brightness.name}-${size.width.round()}',
              reference: size != _window
                  ? null
                  : brightness == Brightness.light
                  ? reference
                  : (name == 'switch-off' ? 'dark-audio.jpg' : null),
            );
            await tester.pumpWidget(const SizedBox());
          });
        }
      }
    });
  }

  for (final MapEntry(key: name, value: scene) in _inputScenes.entries) {
    final (act, make, reference) = scene;
    group('input: $name', () {
      for (final brightness in Brightness.values) {
        for (final size in [_window, _minimum, _regular]) {
          testWidgets('${brightness.name} ${size.width}', (tester) async {
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
              brightness: brightness,
            );
            await _drive(tester, () => act(world));
            await settle(tester);
            await renderShot(
              tester,
              'input-$name-${brightness.name}-${size.width.round()}',
              reference: name == 'imac-above'
                  ? (size == _window && brightness == Brightness.dark
                        ? 'dark-input.jpg'
                        : size == _regular && brightness == Brightness.light
                        ? 'regular-input.jpg'
                        : null)
                  : (size == _window && brightness == Brightness.light
                        ? reference
                        : null),
              crop: size == _regular
                  ? referenceRegularContent
                  : referenceContent,
            );
            await tester.pumpWidget(const SizedBox());
          });
        }
      }
    });
  }

  testWidgets('dragging a screen', (tester) async {
    final world = InputWorld();
    addTearDown(world.dispose);
    await pumpContent(
      tester,
      ShellInputPage(
        rightInset: 0,
        selfDevice: selfMac,
        sessions: world.sessions,
        controller: world.controller,
      ),
      size: _window,
    );
    await _drive(tester, () async {
      await world.controller.setOn(true);
      await world.accept(imacDevice.uid);
      await world.accept(thinkPadDevice.uid);
      world.controller.select(thinkPadDevice.uid);
    });
    await settle(tester);
    final imac = find.bySemanticsLabel(RegExp('^iMac')).first;
    final held = await tester.startGesture(
      tester.getCenter(imac),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    // The move that starts a drag only says that it has started.
    await held.moveBy(const Offset(0, -4));
    await tester.pump();
    await held.moveBy(const Offset(16, -264));
    await settle(tester);
    await renderShot(
      tester,
      'input-drag-light',
      reference: 'desktop-input-drag.jpg',
    );
    await held.cancel();
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('being controlled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    for (final brightness in Brightness.values) {
      final world = InputWorld();
      addTearDown(world.dispose);
      await _drive(tester, () async {
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
        size: _window,
        brightness: brightness,
      );
      await renderShot(
        tester,
        'input-controlled-${brightness.name}',
        reference: brightness == Brightness.light
            ? 'desktop-input-controlled.jpg'
            : null,
      );
      await tester.pumpWidget(const SizedBox());
    }
  });
}
