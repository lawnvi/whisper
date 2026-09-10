import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/helper/screenshot_shortcut.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/widget/screenshot_controls.dart';

class _Backend extends ScreenshotBackend {
  ScreenshotShortcut? registered;
  ScreenshotShortcut? failRegistration;
  int captures = 0;
  Future<bool> Function() capture = () async => true;

  @override
  Future<bool> captureRegion() {
    captures++;
    return capture();
  }

  @override
  Future<String?> setShortcut(
    ScreenshotShortcut? shortcut,
    String description,
  ) async {
    if (shortcut != null && shortcut == failRegistration) {
      throw PlatformException(code: 'shortcut-unavailable');
    }
    registered = shortcut;
    return null;
  }

  @override
  Future<void> close() async {
    registered = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Backend backend;
  late DesktopScreenshotController controller;
  late List<ScreenshotNotice> notices;
  String? saved;
  bool failSave = false;

  setUp(() {
    backend = _Backend();
    saved = null;
    failSave = false;
    notices = [];
    controller = DesktopScreenshotController(
      backend: backend,
      macOS: true,
      load: () async => saved,
      save: (value) async {
        if (failSave) throw StateError('write failed');
        saved = value;
      },
    )..onNotice = notices.add;
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
  });

  const custom = ScreenshotShortcut(key: 'A', control: true, alt: true);

  test(
    'Option-modified letters retain a recordable key and portal uses base keysyms',
    () {
      final key = ScreenshotShortcut.keyLabelFor(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey(0xe5),
          timeStamp: Duration.zero,
        ),
      );
      expect(key, 'A');
      expect(custom.portalTrigger, 'CTRL+ALT+a');
    },
  );

  testWidgets(
    'records and saves a global shortcut without capturing the screen',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showScreenshotShortcutDialog(
                  context,
                  screenshotController: controller,
                ),
                child: const Text('Configure'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Configure'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Click here, then press a key combination'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      const expected = ScreenshotShortcut(key: 'K', control: true, shift: true);
      expect(
        find.text(expected.label(macOS: controller.macOS)),
        findsOneWidget,
      );
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(controller.shortcut, expected);
      expect(backend.captures, 0);
    },
  );

  test('restores disabled shortcut without registering it', () async {
    saved = jsonEncode({...custom.toJson(), 'enabled': false});
    await controller.initialize('Capture region');
    expect(controller.shortcut, custom);
    expect(controller.enabled, false);
    expect(backend.registered, null);
    await controller.capture();
    expect(notices, [ScreenshotNotice.copied]);
  });

  test(
    'registration failure preserves working shortcut and stored preference',
    () async {
      await controller.initialize('Capture region');
      final old = controller.shortcut;
      backend.failRegistration = custom;
      await expectLater(
        controller.configure(custom, enabled: true),
        throwsA(isA<PlatformException>()),
      );
      expect(controller.shortcut, old);
      expect(backend.registered, old);
      expect(controller.registered, true);
      expect(saved, null);
    },
  );

  test('persistence failure rolls native binding back', () async {
    await controller.initialize('Capture region');
    final old = controller.shortcut;
    failSave = true;
    await expectLater(
      controller.configure(custom, enabled: true),
      throwsStateError,
    );
    expect(controller.shortcut, old);
    expect(backend.registered, old);
    expect(controller.configuring, false);
  });

  test(
    'saves a replacement and disables only the screenshot shortcut',
    () async {
      await controller.configure(custom, enabled: true);
      expect(backend.registered, custom);
      expect(jsonDecode(saved!)['key'], 'A');
      await controller.configure(custom, enabled: false);
      expect(backend.registered, null);
      expect(jsonDecode(saved!)['enabled'], false);
      expect(controller.shortcut, custom);
    },
  );

  test('rejects unmodified, shift-only and quick-send combinations', () async {
    for (final shortcut in [
      const ScreenshotShortcut(key: 'S'),
      const ScreenshotShortcut(key: 'S', shift: true),
      const ScreenshotShortcut(key: 'V', meta: true, alt: true),
    ]) {
      await expectLater(
        controller.configure(shortcut, enabled: true),
        throwsA(isA<PlatformException>()),
      );
    }
    expect(saved, null);
  });

  test('invalid stored data falls back to a usable default', () async {
    saved = '{corrupt';
    await controller.initialize('Capture region');
    expect(backend.registered, ScreenshotShortcut.defaultFor(macOS: true));
  });

  test('concurrent capture requests open only one selector', () async {
    final pending = Completer<bool>();
    backend.capture = () => pending.future;
    final first = controller.capture();
    await controller.capture();
    expect(backend.captures, 1);
    pending.complete(true);
    await first;
    expect(notices, [ScreenshotNotice.copied]);
    expect(controller.capturing, false);
  });

  test(
    'cancel is silent and capture failure does not block the next attempt',
    () async {
      backend.capture = () async => false;
      await controller.capture();
      expect(notices, isEmpty);
      backend.capture = () async =>
          throw PlatformException(code: 'permission-denied');
      await controller.capture();
      expect(notices, [ScreenshotNotice.permissionDenied]);
      backend.capture = () async => true;
      await controller.capture();
      expect(notices.last, ScreenshotNotice.copied);
    },
  );

  test(
    'shortcut recording suppresses capture without unregistering the key',
    () async {
      await controller.initialize('Capture region');
      controller.shortcutsPaused = true;
      backend.onShortcut!();
      expect(backend.captures, 0);
      expect(backend.registered, isNotNull);
      controller.shortcutsPaused = false;
      backend.onShortcut!();
      await Future<void>.delayed(Duration.zero);
      expect(backend.captures, 1);
    },
  );
}
