import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/local_network_permission.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/local_network_permission');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('maps every Android native status and forwards compat test mode',
      () async {
    var response = 'granted';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });
    final permission = LocalNetworkPermission(
      channel: channel,
      targetPlatform: TargetPlatform.android,
    );

    for (final entry in <String, LocalNetworkPermissionStatus>{
      'granted': LocalNetworkPermissionStatus.granted,
      'denied': LocalNetworkPermissionStatus.denied,
      'restricted': LocalNetworkPermissionStatus.restricted,
      'unknown': LocalNetworkPermissionStatus.unknown,
    }.entries) {
      response = entry.key;
      expect(
        await permission.ensureGranted(android16CompatTest: true),
        entry.value,
      );
    }

    expect(calls, hasLength(4));
    expect(calls.every((call) => call.method == 'ensureGranted'), isTrue);
    expect(
      calls.every(
        (call) =>
            (call.arguments as Map<Object?, Object?>)['android16CompatTest'] ==
            true,
      ),
      isTrue,
    );
  });

  test('maps native permission failures without throwing', () async {
    var code = 'denied';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: code);
    });
    final permission = LocalNetworkPermission(
      channel: channel,
      targetPlatform: TargetPlatform.android,
    );

    expect(
      await permission.ensureGranted(),
      LocalNetworkPermissionStatus.denied,
    );
    code = 'restricted';
    expect(
      await permission.ensureGranted(),
      LocalNetworkPermissionStatus.restricted,
    );
    code = 'unexpected';
    expect(
      await permission.ensureGranted(),
      LocalNetworkPermissionStatus.unknown,
    );
  });

  test('iOS starts unknown and does not fake a permission preflight', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'granted';
    });
    final permission = LocalNetworkPermission(
      channel: channel,
      targetPlatform: TargetPlatform.iOS,
    );

    expect(
      await permission.currentStatus(),
      LocalNetworkPermissionStatus.unknown,
    );
    expect(
      await permission.ensureGranted(),
      LocalNetworkPermissionStatus.unknown,
    );
    expect(calls, isEmpty);
  });

  test('desktop platforms require no runtime local-network permission',
      () async {
    final permission = LocalNetworkPermission(
      channel: channel,
      targetPlatform: TargetPlatform.macOS,
    );

    expect(
      await permission.ensureGranted(),
      LocalNetworkPermissionStatus.granted,
    );
  });
}
