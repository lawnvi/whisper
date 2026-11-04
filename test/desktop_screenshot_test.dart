import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/helper/screenshot_shortcut.dart';

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
}
