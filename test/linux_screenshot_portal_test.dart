import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/linux_screenshot_portal.dart';
import 'package:whisper/helper/screenshot_shortcut.dart';

class _Portal extends DBusObject {
  _Portal() : super(DBusObjectPath('/org/freedesktop/portal/desktop'));

  int screenshotResponse = 1;
  bool rejectBinding = false;
  String? latestSession;
  Map<String, DBusValue>? screenshotOptions;
  String? preferredTrigger;

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async =>
      DBusGetPropertyResponse(const DBusUint32(3));

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse({
        'version': const DBusUint32(3),
        'AvailableTargets': const DBusUint32(4),
      });

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    final options = call.values.last.asStringVariantDict();
    final sender = call.sender!.substring(1).replaceAll('.', '_');
    final handle = DBusObjectPath(
      '/org/freedesktop/portal/desktop/request/'
      '$sender/${options['handle_token']!.asString()}',
    );
    final data = <String, DBusValue>{};
    var response = 0;
    switch (call.name) {
      case 'Screenshot':
        screenshotOptions = options;
        response = screenshotResponse;
      case 'CreateSession':
        latestSession =
            '/org/freedesktop/portal/desktop/session/'
            '$sender/${options['session_handle_token']!.asString()}';
        data['session_handle'] = DBusString(latestSession!);
      case 'BindShortcuts':
        preferredTrigger = call.values[1]
            .asArray()
            .first
            .asStruct()[1]
            .asStringVariantDict()['preferred_trigger']!
            .asString();
        data['shortcuts'] = DBusArray(
          DBusSignature('(sa{sv})'),
          rejectBinding
              ? []
              : [
                  DBusStruct([
                    const DBusString('region-screenshot'),
                    DBusDict.stringVariant({
                      'trigger_description': const DBusString('Ctrl+Alt+S'),
                    }),
                  ]),
                ],
        );
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    // Exercise the race where Response arrives before the method's handle reply.
    await client!.emitSignal(
      path: handle,
      interface: 'org.freedesktop.portal.Request',
      name: 'Response',
      values: [DBusUint32(response), DBusDict.stringVariant(data)],
    );
    return DBusMethodSuccessResponse([handle]);
  }

  Future<void> activate(String session) =>
      emitSignal('org.freedesktop.portal.GlobalShortcuts', 'Activated', [
        DBusObjectPath(session),
        const DBusString('region-screenshot'),
        const DBusUint64(1),
        DBusDict.stringVariant({}),
      ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBusServer server;
  late DBusClient host;
  late _Portal service;
  late LinuxScreenshotPortal portal;
  late Directory directory;
  late StreamController<void> activations;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('whisper-portal-test-');
    server = DBusServer();
    final address = await server.listenAddress(
      DBusAddress.unix(dir: directory),
    );
    // The in-process fixture accepts a synthetic UID on macOS as well as Linux.
    host = DBusClient(
      address,
      authClient: DBusAuthClient(uid: '1000', requestUnixFd: false),
    );
    await host.requestName('org.freedesktop.portal.Desktop');
    service = _Portal();
    await host.registerObject(service);
    activations = StreamController<void>.broadcast();
    portal = LinuxScreenshotPortal(
      client: DBusClient(
        address,
        authClient: DBusAuthClient(uid: '1000', requestUnixFd: false),
      ),
      onShortcut: () => activations.add(null),
    );
  });

  tearDown(() async {
    await portal.close();
    await host.close();
    await server.close();
    await activations.close();
    await directory.delete(recursive: true);
  });

  test(
    'region selection requests interactive area capture and treats cancel as silent',
    () async {
      expect(await portal.captureRegion(), false);
      expect(
        service.screenshotOptions!['interactive'],
        const DBusBoolean(true),
      );
      expect(service.screenshotOptions!['target'], const DBusUint32(4));
    },
  );

  test(
    'portal denial is an error rather than a successful screenshot',
    () async {
      service.screenshotResponse = 2;
      await expectLater(
        portal.captureRegion(),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'binding uses system label and ignores activation from unrelated sessions',
    () async {
      final label = await portal.setShortcut(
        ScreenshotShortcut.defaultFor(macOS: false),
        'Capture',
      );
      expect(label, 'Ctrl+Alt+S');
      expect(service.preferredTrigger, 'CTRL+ALT+s');
      var count = 0;
      final subscription = activations.stream.listen((_) => count++);
      await host.getId();
      await service.activate('/unrelated');
      await host.getId();
      expect(count, 0);
      final fired = activations.stream.first.timeout(
        const Duration(seconds: 2),
      );
      await service.activate(service.latestSession!);
      await fired;
      expect(count, 1);
      await subscription.cancel();
    },
  );

  test('cancelled replacement keeps the old shortcut session active', () async {
    await portal.setShortcut(
      ScreenshotShortcut.defaultFor(macOS: false),
      'Capture',
    );
    final previous = service.latestSession!;
    service.rejectBinding = true;
    await expectLater(
      portal.setShortcut(
        const ScreenshotShortcut(key: 'A', control: true),
        'Capture',
      ),
      throwsA(isA<PlatformException>()),
    );
    final fired = activations.stream.first.timeout(const Duration(seconds: 2));
    await service.activate(previous);
    await fired;
  });
}
