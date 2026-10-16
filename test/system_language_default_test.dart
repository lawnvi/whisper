import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a new install speaks the system language when the app has it', () {
    expect(systemLanguageCode(const [Locale('es', 'MX')]), 'es');
    expect(
      systemLanguageCode([
        const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'CN',
        ),
      ]),
      'zh',
    );
    expect(
      systemLanguageCode(const [Locale('fr', 'FR'), Locale('zh', 'TW')]),
      'zh',
    );
    // Any other language, and a system that names none, such as the
    // AppImage catalog's test machine.
    expect(systemLanguageCode(const [Locale('fr', 'FR')]), 'en');
    expect(systemLanguageCode(const []), 'en');
  });

  test('the language follows the system until one is picked', () async {
    SharedPreferences.setMockInitialValues({});
    final setting = LocalSetting();
    final prefs = await SharedPreferences.getInstance();

    expect(
      await setting.localization(),
      systemLanguageCode(PlatformDispatcher.instance.locales),
    );
    expect(prefs.get('_localization'), isNull);

    await setting.setLocalization('es');
    expect(await setting.localization(), 'es');

    // Earlier versions stored Chinese on first start.
    await prefs.setString('_localization', 'zh');
    expect(await setting.localization(), 'zh');
  });
}
