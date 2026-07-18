import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote input checks both sides of trust before starting', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    final socketManager = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(socketManager, contains('bool remoteTrustsPeer(String peerId)'));
    expect(socketManager, contains('bool remotePeerTrustsPeer'));
    expect(
      conversation,
      matches(
        RegExp(
          r'socketManager\.remotePeerTrustsPeer\(\s*device\.uid,\s*self\.uid,?\s*\)',
        ),
      ),
    );
    expect(conversation, contains('remoteInputPeerMustTrustThisDevice'));
    expect(conversation, contains('isMutuallyTrusted: isMutuallyTrusted'));
    expect(
      conversation,
      contains('remoteCanInject: socketManager.supportsRemoteInputFor'),
    );

    final toggleMethod = RegExp(
      r'Future<void> _toggleRemoteInput[\s\S]*?Future<void> _maybeAutoStartRemoteInput',
    ).firstMatch(conversation)!.group(0)!;
    expect(toggleMethod, isNot(contains('isMutuallyTrusted: true')));
    expect(toggleMethod, isNot(contains('remoteCanInject: true')));
    expect(
      toggleMethod.indexOf('final localTrustsRemote'),
      lessThan(
        toggleMethod.indexOf(
          'if (!socketManager.supportsRemoteInputFor(device.uid))',
        ),
      ),
    );
  });

  test('conversation keeps remote input action visible for capable peers', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    final getter = RegExp(
      r'bool get _shouldShowRemoteInputAction \{[\s\S]*?\n  \}',
    ).firstMatch(conversation)!.group(0)!;

    expect(getter, contains('_isConnectedSession'));
    expect(getter, contains('supportsNativeRemoteInput()'));
    expect(
      getter,
      contains('socketManager.supportsRemoteInputFor(device.uid)'),
    );
  });

  test('settings remote input entry explains missing mutual trust', () {
    final settings = File('lib/page/settings.dart').readAsStringSync();

    expect(
      settings,
      isNot(contains('device.auth ? _openRemoteInputAutoModePicker : null')),
    );
    expect(settings, contains('_openRemoteInputAutoModePickerWithTrustPrompt'));
    expect(
      settings,
      contains('showAppToast(l10n.remoteInputRequiresMutualTrust)'),
    );
    expect(
      settings,
      contains('showAppToast(l10n.remoteInputPeerMustTrustThisDevice)'),
    );
    expect(
      settings,
      contains('WsSvrManager().remotePeerTrustsPeer(device.uid, self.uid)'),
    );
  });
}
