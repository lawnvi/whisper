import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/notification_l10n.dart';

void main() {
  test('notification l10n falls back to English for unsupported locales', () {
    final l10n = resolveNotificationL10n(
      localesOverride: const <Locale>[Locale('fr', 'FR')],
    );

    expect(l10n.connectRequest, 'Connection Request');
  });

  test('notification l10n resolves supported Chinese locale', () {
    final l10n = resolveNotificationL10n(
      localesOverride: const <Locale>[Locale('zh', 'CN')],
    );

    expect(l10n.connectRequest, '连接请求');
  });
}
