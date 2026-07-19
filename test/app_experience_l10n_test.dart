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

  test('retained functional experience keys are present', () {
    final keys = _messageKeys(_readArb(localeFiles['zh']!));

    expect(
      keys,
      containsAll(<String>{
        'emptyAppsTitle',
        'emptyAppsSearchTitle',
        'fileDropRejected',
        'validationRequired',
        'validationNicknameRequired',
        'validationNicknameTooLong',
        'validationHostRequired',
        'validationHostInvalid',
        'validationPortInvalid',
        'settingsSectionDeviceAppearance',
        'settingsSectionDeviceAppearanceDesc',
        'settingsSectionConnectionTransfer',
        'settingsSectionConnectionTransferDesc',
        'settingsSectionSystemBehavior',
        'settingsSectionSystemBehaviorDesc',
        'settingsSectionPermissionsSharing',
        'settingsSectionPermissionsSharingDesc',
        'settingsSectionMobileIntegration',
        'settingsSectionMobileIntegrationDesc',
        'settingsSectionNotificationForwarding',
        'settingsSectionNotificationForwardingDesc',
        'notificationForwardingUpdateFailed',
        'settingsSectionLanguageFiles',
        'settingsSectionLanguageFilesDesc',
        'dangerousActions',
      }),
    );
  });

  test('critical Spanish experience copy does not fall back to English', () {
    final english = _readArb(localeFiles['en']!);
    final spanish = _readArb(localeFiles['es']!);
    const criticalKeys = <String>{
      'emptyAppsTitle',
      'emptyAppsSearchTitle',
      'fileDropRejected',
      'validationHostInvalid',
      'settingsSectionDeviceAppearance',
      'settingsSectionConnectionTransfer',
      'settingsSectionSystemBehavior',
      'settingsSectionPermissionsSharing',
      'settingsSectionMobileIntegration',
      'settingsSectionNotificationForwarding',
      'settingsSectionLanguageFiles',
      'dangerousActions',
    };

    for (final key in criticalKeys) {
      expect(spanish[key], isNot(equals(english[key])), reason: key);
    }
    expect(spanish['emptyAppsTitle'], 'No hay aplicaciones disponibles');
    expect(spanish['emptyAppsSearchTitle'], 'No se encontraron aplicaciones');
    expect(spanish['fileDropRejected'], 'No se pueden enviar estos archivos');
    expect(spanish['dangerousActions'], 'Acciones peligrosas');
  });
}

Map<String, dynamic> _readArb(File file) {
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Set<String> _messageKeys(Map<String, dynamic> arb) {
  return arb.keys.where((key) => !key.startsWith('@')).toSet();
}
