import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/macos_permissions.dart';

/// Settings shows what macOS allows Whisper; the switches live in System
/// Settings, so it reads them again while it is on screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/macos_permissions');
  final calls = <MethodCall>[];
  var status = <String, Object?>{
    'accessibility': true,
    'screenRecording': false,
    'audioCapture': 'notAsked',
  };

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'request' &&
              (call.arguments as Map)['kind'] == 'screenRecording') {
            status = {...status, 'screenRecording': true};
          }
          return status;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('reads each permission and asks for one by name', () async {
    final permissions = MacPermissions(channel: channel);
    expect(
      permissions.stateOf(MacPermission.accessibility),
      MacPermissionState.unknown,
    );
    var changes = 0;
    void listener() => changes++;
    permissions.addListener(listener);
    await pumpEventQueue();
    expect(
      permissions.stateOf(MacPermission.accessibility),
      MacPermissionState.granted,
    );
    expect(
      permissions.stateOf(MacPermission.screenRecording),
      MacPermissionState.denied,
    );
    expect(
      permissions.stateOf(MacPermission.audioCapture),
      MacPermissionState.notAsked,
    );
    expect(changes, 1);

    await permissions.request(MacPermission.screenRecording);
    expect(calls.last.method, 'request');
    expect(calls.last.arguments, {'kind': 'screenRecording'});
    expect(
      permissions.stateOf(MacPermission.screenRecording),
      MacPermissionState.granted,
    );
    expect(changes, 2);

    // Read again with nothing new: no rebuild.
    await permissions.refresh();
    expect(changes, 2);
    permissions.removeListener(listener);
  });

  test(
    'a macOS that cannot tell the audio permission has it unknown',
    () async {
      status = {'accessibility': false, 'screenRecording': false};
      final permissions = MacPermissions(channel: channel);
      await permissions.refresh();
      expect(
        permissions.stateOf(MacPermission.audioCapture),
        MacPermissionState.unknown,
      );
      expect(
        permissions.stateOf(MacPermission.accessibility),
        MacPermissionState.denied,
      );
    },
  );
}
