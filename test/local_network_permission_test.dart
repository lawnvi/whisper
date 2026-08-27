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

  test(
    'maps every Android native permission status',
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
        expect(await permission.ensureGranted(), entry.value);
      }

      expect(calls, hasLength(4));
      expect(calls.every((call) => call.method == 'ensureGranted'), isTrue);
      expect(calls.every((call) => call.arguments == null), isTrue);
    },
  );

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

  test(
    'reads the current Android LAN address from the native network',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return '192.168.31.53';
          });
      final permission = LocalNetworkPermission(
        channel: channel,
        targetPlatform: TargetPlatform.android,
      );

      expect(await permission.currentLanAddress(), '192.168.31.53');
      expect(calls.single.method, 'currentLanAddress');
    },
  );

  test(
    'LAN address is unavailable off Android or after native failure',
    () async {
      final desktopPermission = LocalNetworkPermission(
        channel: channel,
        targetPlatform: TargetPlatform.macOS,
      );
      expect(await desktopPermission.currentLanAddress(), isNull);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'unavailable');
          });
      final androidPermission = LocalNetworkPermission(
        channel: channel,
        targetPlatform: TargetPlatform.android,
      );
      expect(await androidPermission.currentLanAddress(), isNull);
    },
  );

  test(
    'iOS current status stays unknown without a permission preflight',
    () async {
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
      expect(calls, isEmpty);
    },
  );

  test(
    'iOS ensure starts the foreground Bonjour probe and preserves outcomes',
    () async {
      var response = 'granted';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return response;
          });
      final permission = LocalNetworkPermission(
        channel: channel,
        targetPlatform: TargetPlatform.iOS,
      );

      for (final entry in <String, LocalNetworkPermissionStatus>{
        'granted': LocalNetworkPermissionStatus.granted,
        'denied': LocalNetworkPermissionStatus.denied,
        'unavailable': LocalNetworkPermissionStatus.unavailable,
        'retryable': LocalNetworkPermissionStatus.retryable,
        'unknown': LocalNetworkPermissionStatus.unknown,
      }.entries) {
        response = entry.key;
        expect(await permission.ensureGranted(), entry.value);
      }

      expect(calls, hasLength(5));
      expect(calls.every((call) => call.method == 'ensureGranted'), isTrue);
    },
  );

  test(
    'macOS starts unknown and does not fake a permission preflight',
    () async {
      final permission = LocalNetworkPermission(
        channel: channel,
        targetPlatform: TargetPlatform.macOS,
      );

      expect(
        await permission.ensureGranted(),
        LocalNetworkPermissionStatus.unknown,
      );
    },
  );

  test(
    'Linux and Windows require no runtime local-network permission',
    () async {
      for (final platform in <TargetPlatform>[
        TargetPlatform.linux,
        TargetPlatform.windows,
      ]) {
        final permission = LocalNetworkPermission(
          channel: channel,
          targetPlatform: platform,
        );
        expect(
          await permission.ensureGranted(),
          LocalNetworkPermissionStatus.granted,
        );
      }
    },
  );
}
