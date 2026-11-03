// surfaces.md「手机 · 连接设备」: every tab and exception of the phone's connect
// page, in both themes, three languages and at 200% text.
//
// To look at them next to docs/design/reference/:
//   WHISPER_RENDER_DIR=/some/dir flutter test --no-pub \
//     --dart-define=WHISPER_NEW_UI=true test/phone_connect_test.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations_en.dart';
import 'package:whisper/l10n/app_localizations_zh.dart';
import 'package:whisper/new_ui/phone/phone_connect_page.dart';
import 'package:whisper/page/pairing_qr.dart';
import 'package:whisper/state/pairing_invite.dart';

import 'support/phone_shots.dart';

const _selfId = '123e4567-e89b-42d3-a456-426614174000';
const _otherId = '223e4567-e89b-42d3-a456-426614174000';

final _self = PairingInvite(
  host: '192.168.31.8',
  port: 10002,
  peerId: _selfId,
  publicKeyHash: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);
final _other = PairingInvite(
  host: '192.168.31.20',
  port: 10002,
  peerId: _otherId,
  publicKeyHash: 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA',
);

class _Camera {
  int built = 0;
  ValueChanged<String>? onCode;
  ValueChanged<bool>? onPermission;
  int torch = 0, flips = 0, paused = 0;
  bool grant = true;

  Widget call(
    BuildContext context, {
    required ValueChanged<PhoneScannerHandle> onReady,
    required ValueChanged<String> onCode,
    required ValueChanged<bool> onPermission,
  }) => _CameraView(
    camera: this,
    onReady: onReady,
    onCode: onCode,
    onPermission: onPermission,
  );
}

class _CameraView extends StatefulWidget {
  const _CameraView({
    required this.camera,
    required this.onReady,
    required this.onCode,
    required this.onPermission,
  });

  final _Camera camera;
  final ValueChanged<PhoneScannerHandle> onReady;
  final ValueChanged<String> onCode;
  final ValueChanged<bool> onPermission;

  @override
  State<_CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<_CameraView> {
  @override
  void initState() {
    super.initState();
    final camera = widget.camera;
    camera.built++;
    camera.onCode = widget.onCode;
    camera.onPermission = widget.onPermission;
    widget.onReady(
      PhoneScannerHandle(
        toggleTorch: () async => camera.torch++,
        flip: () async => camera.flips++,
        pause: () async => camera.paused++,
      ),
    );
    if (!camera.grant) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onPermission(false),
      );
    }
  }

  @override
  void dispose() {
    widget.camera.onCode = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('fake-camera'));
}

Widget _page(
  _Camera camera, {
  PairingInvite? invite,
  bool noInvite = false,
  bool startWithAddress = false,
  PairingQrDialogController? controller,
  Future<PairingInvite?> Function()? reloadInvite,
  Future<void> Function()? openSettings,
}) => PhoneConnectPage(
  localInvite: noInvite ? null : (invite ?? _self),
  localName: '这台手机',
  localPeerId: _selfId,
  fingerprint: 'AAAAAAAAAAAAAAAA',
  startWithAddress: startWithAddress,
  controller: controller,
  reloadInvite: reloadInvite,
  scanner: camera.call,
  openSettings: openSettings ?? () async {},
);

/// A page that opens [PhoneConnectPage] and keeps what it returns.
Widget _launcher(_Camera camera, void Function(PairingQrResult?) got) =>
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              got(
                await Navigator.of(context).push<PairingQrResult>(
                  MaterialPageRoute(builder: (_) => _page(camera)),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  setUpAll(loadPhoneFonts);

  final zh = AppLocalizationsZh();
  final en = AppLocalizationsEn();

  group('tabs', () {
    testWidgets('it starts on this phone\'s code, with no camera', (
      tester,
    ) async {
      final camera = _Camera();
      await pumpPhone(tester, _page(camera));
      expect(find.byKey(const ValueKey('connect-qr')), findsOneWidget);
      expect(find.text('这台手机'), findsOneWidget);
      expect(find.text(zh.phoneConnectQrHint), findsOneWidget);
      expect(find.text('192.168.31.8:10002'), findsOneWidget);
      expect(find.text('AAAA AAAA AAAA'), findsOneWidget);
      expect(find.text(zh.phoneConnectCopyLink), findsOneWidget);
      expect(camera.built, 0);
      for (final tab in [
        zh.connectionQrTab,
        zh.connectionScanTab,
        zh.connectionAddressTab,
      ]) {
        expect(find.text(tab), findsOneWidget);
      }
      // A tall pill, as wide as the page less its margins.
      final tabs = tester.getRect(find.byKey(const ValueKey('connect-tabs')));
      expect(tabs.height, 36);
      expect(tabs.top, 44 + 50 + 6);
      expect(tabs.top, 44 + 50 + 6);
      expect(tabs.left, 16);
      expect(tabs.right, 380 - 16);
    });

    testWidgets('the camera runs only on the scan tab', (tester) async {
      final camera = _Camera();
      await pumpPhone(tester, _page(camera));
      await tester.tap(find.text(zh.connectionScanTab));
      await phoneSettle(tester);
      expect(camera.built, 1);
      expect(find.byKey(const ValueKey('fake-camera')), findsOneWidget);
      expect(find.text(zh.phoneConnectScanHint), findsOneWidget);

      await tester.tap(find.text(zh.connectionQrTab));
      await phoneSettle(tester);
      expect(find.byKey(const ValueKey('fake-camera')), findsNothing);
    });

    testWidgets('it can start on the address', (tester) async {
      final camera = _Camera();
      await pumpPhone(tester, _page(camera, startWithAddress: true));
      expect(find.byKey(const ValueKey('connection-address')), findsOneWidget);
      expect(find.byKey(const ValueKey('connect-by-address')), findsOneWidget);
    });

    testWidgets('the controller closes the page', (tester) async {
      final camera = _Camera();
      final controller = PairingQrDialogController();
      var returned = false;
      await pumpPhone(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  await Navigator.of(context).push<PairingQrResult>(
                    MaterialPageRoute(
                      builder: (_) => _page(camera, controller: controller),
                    ),
                  );
                  returned = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await phoneSettle(tester);
      expect(find.byType(PhoneConnectPage), findsOneWidget);
      controller.dismiss();
      await phoneSettle(tester);
      expect(find.byType(PhoneConnectPage), findsNothing);
      expect(returned, isTrue);
    });
  });

  group('scan', () {
    Future<_Camera> open(WidgetTester tester, {bool grant = true}) async {
      final camera = _Camera()..grant = grant;
      await pumpPhone(tester, _page(camera));
      await tester.tap(find.text(zh.connectionScanTab));
      await phoneSettle(tester);
      return camera;
    }

    testWidgets('torch and flip are outside the viewfinder, 48 and round', (
      tester,
    ) async {
      final camera = await open(tester);
      final torch = find.byKey(const ValueKey('connect-torch'));
      final flip = find.byKey(const ValueKey('connect-flip'));
      expect(tester.getSize(torch), const Size(48, 48));
      expect(tester.getSize(flip), const Size(48, 48));
      final finder = tester.getRect(find.byType(AspectRatio).first);
      expect(finder.width, finder.height);
      expect(tester.getTopLeft(torch).dy, greaterThan(finder.bottom));
      await tester.tap(torch);
      await tester.tap(flip);
      await tester.pump();
      expect(camera.torch, 1);
      expect(camera.flips, 1);
    });

    testWidgets('an invalid code says so and keeps scanning', (tester) async {
      final camera = await open(tester);
      camera.onCode!('not a whisper code');
      await phoneSettle(tester);
      expect(find.text(zh.qrInvalidCode), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-camera')), findsOneWidget);
      camera.onCode!('still not one');
      await phoneSettle(tester);
      expect(find.text(zh.qrInvalidCode), findsOneWidget);
    });

    testWidgets('its own code says so and keeps scanning', (tester) async {
      final camera = await open(tester);
      camera.onCode!(_self.encode());
      await phoneSettle(tester);
      expect(find.text(zh.qrCannotPairSelf), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-camera')), findsOneWidget);
    });

    testWidgets('a message does not move the tools', (tester) async {
      final camera = await open(tester);
      final torch = find.byKey(const ValueKey('connect-torch'));
      final before = tester.getTopLeft(torch);
      camera.onCode!('nope');
      await phoneSettle(tester);
      expect(tester.getTopLeft(torch), before);
    });

    testWidgets('a good code leaves with the same result as the dialog', (
      tester,
    ) async {
      final camera = _Camera();
      PairingQrResult? result;
      await pumpPhone(tester, _launcher(camera, (r) => result = r));
      await tester.tap(find.text('open'));
      await phoneSettle(tester);
      await tester.tap(find.text(zh.connectionScanTab));
      await phoneSettle(tester);
      camera.onCode!(_other.encode());
      await phoneSettle(tester);
      expect(camera.paused, 1);
      expect(result?.invite?.peerId, _otherId);
      expect(result?.endpoint.host, '192.168.31.20');
    });

    testWidgets(
      'no camera says so inside the viewfinder and goes to settings',
      (tester) async {
        var opened = 0;
        final camera = _Camera()..grant = false;
        await pumpPhone(
          tester,
          _page(camera, openSettings: () async => opened++),
        );
        await tester.tap(find.text(zh.connectionScanTab));
        await phoneSettle(tester);
        expect(find.text(zh.qrCameraUnavailable), findsOneWidget);
        final message = tester.getCenter(find.text(zh.qrCameraUnavailable));
        final finder = tester.getRect(find.byType(AspectRatio).first);
        expect(finder.contains(message), isTrue);
        expect(find.text(zh.phoneConnectScanHint), findsNothing);
        await tester.tap(find.byKey(const ValueKey('connect-open-settings')));
        await tester.pump();
        expect(opened, 1);

        // Back from settings, it tries the camera again.
        camera.grant = true;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await phoneSettle(tester);
        expect(camera.built, 2);
        expect(find.text(zh.qrCameraUnavailable), findsNothing);
        expect(find.byKey(const ValueKey('fake-camera')), findsOneWidget);
      },
    );
  });

  group('no local network', () {
    testWidgets('says so where the code goes and tries again', (tester) async {
      final camera = _Camera();
      await pumpPhone(
        tester,
        _page(camera, noInvite: true, reloadInvite: () async => _self),
      );
      expect(find.text(zh.qrWifiUnavailable), findsOneWidget);
      expect(find.byKey(const ValueKey('connect-qr')), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('connect-no-lan'))).height,
        196,
      );
      await tester.tap(find.byKey(const ValueKey('connect-retry-lan')));
      await phoneSettle(tester);
      expect(find.text(zh.qrWifiUnavailable), findsNothing);
      expect(find.byKey(const ValueKey('connect-qr')), findsOneWidget);
    });

    testWidgets('it can\'t copy what it does not have', (tester) async {
      final camera = _Camera();
      await pumpPhone(tester, _page(camera, noInvite: true));
      await tester.tap(find.byKey(const ValueKey('copy-pairing-invite')));
      await tester.pump();
      expect(find.text(zh.phoneConnectCopied), findsNothing);
    });
  });

  group('address', () {
    Future<void> open(WidgetTester tester, _Camera camera) => pumpPhone(
      tester,
      _page(camera, startWithAddress: true),
      locale: const Locale('en'),
    );

    testWidgets('a wrong address and port are said under their inputs', (
      tester,
    ) async {
      await open(tester, _Camera());
      await tester.enterText(
        find.byKey(const ValueKey('connection-address')),
        'not an address!',
      );
      await tester.enterText(
        find.byKey(const ValueKey('connection-port')),
        '70000',
      );
      await tester.tap(find.byKey(const ValueKey('connect-by-address')));
      await phoneSettle(tester);
      final address = find.text(en.manualConnectAddressInvalid);
      final port = find.text(en.manualConnectPortInvalid);
      expect(address, findsOneWidget);
      expect(port, findsOneWidget);
      expect(
        tester.getTopLeft(address).dy,
        greaterThan(
          tester
              .getBottomLeft(find.byKey(const ValueKey('connection-address')))
              .dy,
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('connection-port')),
        '10002',
      );
      await phoneSettle(tester);
      expect(port, findsNothing);
      expect(address, findsOneWidget);
    });

    testWidgets('a good one leaves with the same result as the dialog', (
      tester,
    ) async {
      PairingQrResult? result;
      final camera = _Camera();
      await pumpPhone(tester, _launcher(camera, (r) => result = r));
      await tester.tap(find.text('open'));
      await phoneSettle(tester);
      await tester.tap(find.text(zh.connectionAddressTab));
      await phoneSettle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('connection-address')),
        '192.168.31.77',
      );
      await tester.tap(find.byKey(const ValueKey('connect-by-address')));
      await phoneSettle(tester);
      expect(result?.invite, isNull);
      expect(result?.endpoint.host, '192.168.31.77');
      expect(result?.endpoint.port, 10002);
    });

    testWidgets('its controls are 48 to hit', (tester) async {
      await open(tester, _Camera());
      expect(
        tester.getSize(find.byKey(const ValueKey('connect-by-address'))).height,
        48,
      );
    });

    testWidgets('its controls are 48 to hit', (tester) async {
      await open(tester, _Camera());
      expect(
        tester.getSize(find.byKey(const ValueKey('connect-by-address'))).height,
        48,
      );
    });

    testWidgets('the prefix of this network is ready to finish', (
      tester,
    ) async {
      await open(tester, _Camera());
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('connection-address')),
      );
      expect(field.controller!.text, '192.168.31.');
    });
  });

  group('copy', () {
    testWidgets('says that it did, and what happened if not', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpPhone(tester, _page(_Camera()));
      await tester.tap(find.byKey(const ValueKey('copy-pairing-invite')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(copied, _self.encode());
      expect(find.text(zh.phoneConnectCopied), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text(zh.phoneConnectCopyLink), findsOneWidget);
    });
  });

  group('every state fits', () {
    for (final (locale, size, scale, brightness) in phoneMatrix) {
      final tag =
          '${locale.languageCode} ${size.width.round()} ${scale}x ${brightness.name}';
      testWidgets(tag, (tester) async {
        final camera = _Camera();
        await pumpPhone(
          tester,
          _page(camera),
          locale: locale,
          size: size,
          textScale: scale,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        for (final tab in const [1, 2, 0]) {
          final state = tester.state<State>(find.byType(PhoneConnectPage));
          // Through the widget, as a person would.
          final labels = find.descendant(
            of: find.byKey(const ValueKey('connect-tabs')),
            matching: find.byType(Text),
          );
          await tester.tap(labels.at(tab));
          await phoneSettle(tester);
          expect(state.mounted, isTrue);
          expect(tester.takeException(), isNull);
        }
      });
    }

    testWidgets('no network, no camera, errors', (tester) async {
      for (final (locale, size, scale, brightness) in phoneMatrix) {
        final camera = _Camera()..grant = false;
        await pumpPhone(
          tester,
          _page(camera, noInvite: true),
          locale: locale,
          size: size,
          textScale: scale,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        final labels = find.descendant(
          of: find.byKey(const ValueKey('connect-tabs')),
          matching: find.byType(Text),
        );
        await tester.tap(labels.at(1));
        await phoneSettle(tester);
        expect(tester.takeException(), isNull);
        await tester.tap(labels.at(2));
        await phoneSettle(tester);
        await tester.enterText(
          find.byKey(const ValueKey('connection-address')),
          'x y',
        );
        await tester.tap(find.byKey(const ValueKey('connect-by-address')));
        await phoneSettle(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });

  group('pictures', () {
    testWidgets('next to the references', (tester) async {
      await withPhoneShadows(() async {
        for (final brightness in Brightness.values) {
          final dark = brightness == Brightness.dark ? '-dark' : '';
          final camera = _Camera();
          await pumpPhone(tester, _page(camera), brightness: brightness);
          await phoneShot(
            tester,
            'connect-qr$dark',
            reference: dark.isEmpty ? 'phone-connect.jpg' : null,
          );
          final labels = find.descendant(
            of: find.byKey(const ValueKey('connect-tabs')),
            matching: find.byType(Text),
          );
          await tester.tap(labels.at(1));
          await phoneSettle(tester);
          await phoneShot(
            tester,
            'connect-scan$dark',
            reference: dark.isEmpty ? 'phone-connect-scan.jpg' : null,
          );
          camera.onCode!('nope');
          await phoneSettle(tester);
          await phoneShot(tester, 'connect-scan-invalid$dark');
          await tester.tap(labels.at(2));
          await phoneSettle(tester);
          await phoneShot(
            tester,
            'connect-address$dark',
            reference: dark.isEmpty ? 'phone-connect-address.jpg' : null,
          );
          await tester.enterText(
            find.byKey(const ValueKey('connection-address')),
            'not an address',
          );
          await tester.enterText(
            find.byKey(const ValueKey('connection-port')),
            '70000',
          );
          await tester.tap(find.byKey(const ValueKey('connect-by-address')));
          await phoneSettle(tester);
          await phoneShot(tester, 'connect-address-errors$dark');
          await tester.pumpWidget(const SizedBox.shrink());

          await pumpPhone(
            tester,
            _page(_Camera(), noInvite: true),
            brightness: brightness,
          );
          await phoneShot(tester, 'connect-no-lan$dark');
          await tester.pumpWidget(const SizedBox.shrink());

          final denied = _Camera()..grant = false;
          await pumpPhone(tester, _page(denied), brightness: brightness);
          await tester.tap(labels.at(1));
          await phoneSettle(tester);
          await phoneShot(tester, 'connect-camera-denied$dark');
          await tester.pumpWidget(const SizedBox.shrink());
        }
        for (final (name, locale, scale) in const [
          ('en', Locale('en'), 1.0),
          ('es-200', Locale('es'), 2.0),
        ]) {
          await pumpPhone(
            tester,
            _page(_Camera()),
            locale: locale,
            size: const Size(360, 720),
            textScale: scale,
          );
          await phoneShot(tester, 'connect-qr-$name');
          await tester.pumpWidget(const SizedBox.shrink());
        }
      });
    });
  });
}
