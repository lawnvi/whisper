import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote input checks both sides of trust before starting', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    final socketManager = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(socketManager, contains('bool remoteTrustsPeer(String peerId)'));
    expect(conversation, contains('socketManager.remoteTrustsPeer(self.uid)'));
    expect(conversation, contains('remoteInputPeerMustTrustThisDevice'));
    expect(conversation, contains('isMutuallyTrusted: isMutuallyTrusted'));
    expect(conversation,
        contains('remoteCanInject: socketManager.supportsRemoteInput'));

    final toggleMethod = RegExp(
      r'Future<void> _toggleRemoteInput[\s\S]*?Future<void> _maybeAutoStartRemoteInput',
    ).firstMatch(conversation)!.group(0)!;
    expect(toggleMethod, isNot(contains('isMutuallyTrusted: true')));
    expect(toggleMethod, isNot(contains('remoteCanInject: true')));
    expect(
      toggleMethod.indexOf('final localTrustsRemote'),
      lessThan(toggleMethod.indexOf('if (!socketManager.supportsRemoteInput)')),
    );
  });

  test('conversation keeps remote input action visible for trust prompts', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    final getter = RegExp(
      r'bool get _shouldShowRemoteInputAction \{[\s\S]*?\n  \}',
    ).firstMatch(conversation)!.group(0)!;

    expect(getter, contains('_isConnectedSession'));
    expect(getter, contains('supportsNativeRemoteInput()'));
    expect(getter, isNot(contains('socketManager.supportsRemoteInput')));
  });

  test('settings remote input entry explains missing mutual trust', () {
    final settings = File('lib/page/settings.dart').readAsStringSync();

    expect(
      settings,
      isNot(contains('device.auth ? _openRemoteInputAutoModePicker : null')),
    );
    expect(settings, contains('_openRemoteInputAutoModePickerWithTrustPrompt'));
    expect(settings,
        contains('showAppToast(l10n.remoteInputRequiresMutualTrust)'));
    expect(settings,
        contains('showAppToast(l10n.remoteInputPeerMustTrustThisDevice)'));
    expect(settings, contains('WsSvrManager().remoteTrustsPeer(self.uid)'));
  });
}
