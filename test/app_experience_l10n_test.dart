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

  test('all planned experience key families are present', () {
    final keys = _messageKeys(_readArb(localeFiles['zh']!));

    expect(
      keys,
      containsAll(<String>{
        'emptyDevicesTitle',
        'emptyDevicesBody',
        'emptySearchTitle',
        'emptySearchBody',
        'emptyConversationConnectedBody',
        'emptyConversationDisconnectedBody',
        'emptyAppsTitle',
        'emptyAppsBody',
        'sessionGroupConnected',
        'sessionGroupNearby',
        'sessionGroupRecent',
        'sessionGroupDeviceCount',
        'localDiscoveryStarting',
        'localDiscoveryActive',
        'localDiscoveryStopped',
        'localDiscoveryUnavailable',
        'localDiscoveryPermissionDenied',
        'localDiscoveryPermissionRestricted',
        'localDiscoveryFailed',
        'workbenchActionManualConnect',
        'workbenchActionAudioShare',
        'workbenchActionRemoteInput',
        'workbenchActionSettings',
        'workbenchActionBack',
        'workbenchActionUnavailable',
        'clipboardPreviewTitle',
        'clipboardPreviewTextCount',
        'clipboardPreviewImage',
        'clipboardPreviewFiles',
        'clipboardPreviewRemove',
        'clipboardPreviewSend',
        'clipboardPreviewEmpty',
        'clipboardPreviewReadFailed',
        'fileDropAccepted',
        'fileDropRejectedDisconnected',
        'fileDropRejectedLocalSession',
        'fileDropRejectedNoFiles',
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
        'remoteInputWorkspaceDevicesPanel',
        'remoteInputWorkspaceDetailsPanel',
        'remoteInputWorkspaceSelectTargetBody',
        'remoteInputWorkspaceClosePanel',
      }),
    );
  });

  test('critical Spanish experience copy does not fall back to English', () {
    final english = _readArb(localeFiles['en']!);
    final spanish = _readArb(localeFiles['es']!);
    const criticalKeys = <String>{
      'emptyDevicesTitle',
      'emptySearchTitle',
      'sessionGroupConnected',
      'sessionGroupNearby',
      'sessionGroupRecent',
      'localDiscoveryActive',
      'workbenchActionManualConnect',
      'clipboardPreviewTitle',
      'fileDropAccepted',
      'validationHostInvalid',
      'settingsSectionDeviceAppearance',
      'settingsSectionConnectionTransfer',
      'settingsSectionSystemBehavior',
      'settingsSectionPermissionsSharing',
      'settingsSectionMobileIntegration',
      'settingsSectionNotificationForwarding',
      'settingsSectionLanguageFiles',
      'dangerousActions',
      'remoteInputWorkspaceDevicesPanel',
      'remoteInputWorkspaceDetailsPanel',
      'remoteInputWorkspaceSelectTargetBody',
    };

    for (final key in criticalKeys) {
      expect(spanish[key], isNot(equals(english[key])), reason: key);
    }
    expect(spanish['sessionGroupConnected'], 'Dispositivos conectados');
    expect(spanish['sessionGroupNearby'], 'Disponibles cerca');
    expect(spanish['emptySearchTitle'], 'Sin resultados');
    expect(spanish['clipboardPreviewTitle'], 'Vista previa del portapapeles');
    expect(spanish['dangerousActions'], 'Acciones peligrosas');
  });
}

Map<String, dynamic> _readArb(File file) {
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Set<String> _messageKeys(Map<String, dynamic> arb) {
  return arb.keys.where((key) => !key.startsWith('@')).toSet();
}
