import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final localeFiles = <String, File>{
    'zh': File('lib/l10n/app_zh.arb'),
    'en': File('lib/l10n/app_en.arb'),
    'es': File('lib/l10n/app_es.arb'),
  };

  test('experience localization keys stay identical across all locales', () {
    final keySets = localeFiles.map(
      (locale, file) => MapEntry(locale, _messageKeys(_readArb(file))),
    );

    expect(keySets['en'], keySets['zh']);
    expect(keySets['es'], keySets['zh']);
  });

}

Map<String, dynamic> _readArb(File file) {
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Set<String> _messageKeys(Map<String, dynamic> arb) {
  return arb.keys.where((key) => !key.startsWith('@')).toSet();
}
