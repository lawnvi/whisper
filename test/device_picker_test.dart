// surfaces.md「设备选取器」: every "pick a device", its panel on a desktop and its
// sheet on a phone, quick send, and the six digits after a scan.
//
// To look at them:
//   WHISPER_RENDER_DIR=/some/dir flutter test --no-pub \
//     --dart-define=WHISPER_NEW_UI=true test/device_picker_test.dart

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations_zh.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/phone/phone_pair_page.dart';
import 'package:whisper/new_ui/picker/device_picker.dart';
import 'package:whisper/new_ui/picker/quick_send_sheet.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/theme/whisper_device_art.dart' as art;
import 'package:whisper/widget/pairing_dialog.dart';
import 'package:whisper/widget/quick_send_chooser.dart';

import 'support/phone_shots.dart';

const _imac = DevicePickerEntry(
  id: 'imac',
  name: 'iMac',
  kind: art.DeviceKind.desktop,
);
const _mi = DevicePickerEntry(
  id: 'mi',
  name: 'Xiaomi 16',
  kind: art.DeviceKind.phone,
);
const _laptop = DevicePickerEntry(
  id: 'x1',
  name: 'ThinkPad X1 Carbon Gen 12 with a very long name indeed',
  kind: art.DeviceKind.laptop,
);

/// A page with a button that opens [open] and keeps what it resolves to.
Widget _launcher(
  Future<String?> Function(BuildContext) open,
  void Function(String?) got,
) => Scaffold(
  body: Align(
    alignment: const Alignment(.5, .7),
    child: Builder(
      builder: (context) => TextButton(
        onPressed: () async => got(await open(context)),
        child: const Text('open'),
      ),
    ),
  ),
);

const _device = DeviceData(
  id: 7,
  uid: 'imac',
  name: '2698b',
  host: '192.168.31.20',
  port: 10002,
  platform: 'android',
  isServer: true,
  online: true,
  clipboard: true,
  auth: false,
  lastTime: 0,
);

PairingRequest _request({
  PairingReason reason = PairingReason.newDevice,
  PairingPromptMode mode = PairingPromptMode.initiator,
}) => PairingRequest(
  device: _device,
  pairingCode: '481726',
  reason: reason,
  mode: mode,
);

void main() {
  setUpAll(loadPhoneFonts);
  final zh = AppLocalizationsZh();

  group('picker', () {
    testWidgets('a phone: a sheet from the bottom, rows of 48', (tester) async {
      String? picked;
      await pumpPhone(
        tester,
        _launcher(
          (context) => showDevicePicker(
            context,
            title: zh.pickerSendFile('周报.pdf'),
            touch: true,
            devices: const [_imac, _mi],
          ),
          (value) => picked = value,
        ),
      );
      await tester.tap(find.text('open'));
      await phoneSettle(tester);
      expect(find.text(zh.pickerSendFile('周报.pdf')), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-sheet-grab')), findsOneWidget);
      final row = tester.getRect(
        find.byKey(const ValueKey('device-picker-imac')),
      );
      expect(row.height, 48);
      expect(find.byType(art.DeviceGlyph), findsNWidgets(2));
      // At the bottom of the screen, as wide as it.
      final sheet = tester.getRect(find.byType(PhoneSheetFrame));
      expect(sheet.bottom, 780);
      await tester.tap(find.text('Xiaomi 16'));
      await phoneSettle(tester);
      expect(picked, 'mi');
    });

    testWidgets('a desktop: a `panel` menu on the button', (tester) async {
      String? picked;
      late BuildContext button;
      await pumpPhone(
        tester,
        Scaffold(
          body: Center(
            child: Builder(
              builder: (context) {
                button = context;
                return TextButton(
                  onPressed: () async {
                    picked = await showDevicePicker(
                      context,
                      title: zh.pickerSendFile('周报.pdf'),
                      touch: false,
                      anchor: button,
                      devices: const [_imac, _mi],
                    );
                  },
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
        size: const Size(800, 600),
      );
      await tester.tap(find.text('open'));
      await phoneSettle(tester);
      expect(find.text(zh.pickerSendFile('周报.pdf')), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-sheet-grab')), findsNothing);
      final row = tester.getRect(
        find.byKey(const ValueKey('device-picker-imac')),
      );
      expect(row.height, greaterThanOrEqualTo(30));
      expect(row.height, lessThan(40));
      expect(row.top, greaterThan(tester.getBottomLeft(find.text('open')).dy));
      await tester.tap(find.text('iMac'));
      await phoneSettle(tester);
      expect(picked, 'imac');
    });

    testWidgets('nothing to pick from: says so, resolves to null', (
      tester,
    ) async {
      var done = false;
      await pumpPhone(
        tester,
        _launcher(
          (context) => showDevicePicker(
            context,
            title: 'x',
            touch: true,
            devices: const [],
          ),
          (value) {
            done = true;
            expect(value, isNull);
          },
        ),
      );
      await tester.tap(find.text('open'));
      await phoneSettle(tester);
      expect(done, isTrue);
      expect(find.byKey(const ValueKey('phone-sheet-grab')), findsNothing);
    });
  });

  group('quick send', () {
    const mac = QuickSendTarget(id: 'mac', name: 'iMac', platform: 'macos');
    const phone = QuickSendTarget(
      id: 'mi',
      name: 'Xiaomi 16',
      platform: 'android',
    );
    const text = QuickSendItem.text(
      '周五发版清单：跑一遍多设备传输，更新西语文案，打 macOS 和 Windows 包。',
    );
    const file = QuickSendItem.file(
      name: '周报.pdf',
      source: '/tmp/x.pdf',
      size: 2048,
    );

    Future<void> openSheet(
      WidgetTester tester, {
      required ValueListenable<List<QuickSendTarget>> targets,
      required void Function(String?) got,
      List<QuickSendItem> items = const [file],
      bool touch = true,
      String? initial,
      Size size = phoneScreen,
      double textScale = 1,
      Locale locale = const Locale('zh'),
      Brightness brightness = Brightness.light,
    }) async {
      await pumpPhone(
        tester,
        _launcher(
          (context) => touch
              ? showPhoneSheet<String>(
                  context,
                  builder: (context) => QuickSendPicker(
                    touch: true,
                    items: items,
                    targets: targets,
                    initialTargetId: initial,
                  ),
                )
              : showShellSheet<String>(
                  context,
                  builder: (context) => QuickSendPicker(
                    touch: false,
                    items: items,
                    targets: targets,
                    initialTargetId: initial,
                  ),
                ),
          got,
        ),
        size: size,
        textScale: textScale,
        locale: locale,
        brightness: brightness,
      );
      await tester.tap(find.text('open'));
      await phoneSettle(tester);
    }

    testWidgets('a tap on a device sends it there', (tester) async {
      final targets = ValueNotifier<List<QuickSendTarget>>(const [mac, phone]);
      String? picked;
      await openSheet(tester, targets: targets, got: (v) => picked = v);
      expect(find.text(zh.pickerSendFile('周报.pdf')), findsOneWidget);
      expect(find.text('2.00 KB'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quick-send-target-mi')));
      await phoneSettle(tester);
      expect(picked, 'mi');
    });

    testWidgets('稍后 leaves it for later', (tester) async {
      final targets = ValueNotifier<List<QuickSendTarget>>(const [mac]);
      String? picked = 'unset';
      await openSheet(tester, targets: targets, got: (v) => picked = v);
      expect(find.text(zh.quickSendLater), findsOneWidget);
      await tester.tap(find.text(zh.quickSendLater));
      await phoneSettle(tester);
      expect(picked, isNull);
    });

    testWidgets('follows connections while it is open', (tester) async {
      final targets = ValueNotifier<List<QuickSendTarget>>(const []);
      await openSheet(tester, targets: targets, got: (_) {});
      expect(
        find.byKey(const ValueKey('quick-send-no-targets')),
        findsOneWidget,
      );
      targets.value = const [mac];
      await phoneSettle(tester);
      expect(find.byKey(const ValueKey('quick-send-no-targets')), findsNothing);
      expect(
        find.byKey(const ValueKey('quick-send-target-mac')),
        findsOneWidget,
      );
    });

    testWidgets('the one in mind has a tick, a lone device too', (
      tester,
    ) async {
      final targets = ValueNotifier<List<QuickSendTarget>>(const [mac, phone]);
      await openSheet(tester, targets: targets, got: (_) {}, initial: 'mi');
      bool ticked(String id) => tester
          .widget<DevicePickerRow>(
            find.byKey(ValueKey('quick-send-target-$id')),
          )
          .device
          .checked;
      expect(ticked('mi'), isTrue);
      expect(ticked('mac'), isFalse);
      targets.value = const [mac];
      await phoneSettle(tester);
      expect(ticked('mac'), isTrue);
    });

    testWidgets('a desktop: the standard sheet, with 稍后', (tester) async {
      final targets = ValueNotifier<List<QuickSendTarget>>(const [mac, phone]);
      String? picked;
      await openSheet(
        tester,
        targets: targets,
        got: (v) => picked = v,
        touch: false,
        items: const [text],
        size: const Size(800, 600),
      );
      expect(find.text(zh.quickSendTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-send-text')), findsOneWidget);
      expect(find.text(zh.quickSendLater), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quick-send-target-mac')));
      await phoneSettle(tester);
      expect(picked, 'mac');
    });

    for (final (locale, size, scale, brightness) in phoneMatrix) {
      final tag =
          '${locale.languageCode} ${size.width.round()} ${scale}x ${brightness.name}';
      testWidgets('fits: $tag', (tester) async {
        final targets = ValueNotifier<List<QuickSendTarget>>(const [
          mac,
          phone,
        ]);
        await openSheet(
          tester,
          targets: targets,
          got: (_) {},
          items: const [text, file],
          size: size,
          textScale: scale,
          locale: locale,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the six digits', () {
    testWidgets('shows them, and says yes or no once', (tester) async {
      final answers = <bool>[];
      await pumpPhone(
        tester,
        PhonePairPage(request: _request(), onResolved: answers.add),
      );
      for (final digit in '481726'.split('')) {
        expect(find.text(digit), findsOneWidget);
      }
      expect(find.text(zh.shellNearbyTitle('2698b')), findsOneWidget);
      expect(find.text(zh.pairingCompareCode), findsOneWidget);
      expect(find.text(zh.pairingEncryptionNotice), findsOneWidget);
      expect(tester.getSize(find.byKey(pairingApproveKey)).height, 48);
      await tester.tap(find.byKey(pairingApproveKey));
      await tester.pump();
      await tester.tap(find.byKey(pairingApproveKey), warnIfMissed: false);
      await tester.tap(find.byKey(pairingCancelKey), warnIfMissed: false);
      await tester.pump();
      expect(answers, [true]);
    });

    testWidgets('the arrow says no', (tester) async {
      final answers = <bool>[];
      await pumpPhone(
        tester,
        PhonePairPage(request: _request(), onResolved: answers.add),
      );
      await tester.tap(find.bySemanticsLabel(zh.back));
      await tester.pump();
      expect(answers, [false]);
    });

    testWidgets('asked by another device: 拒绝 in red, why it is asking', (
      tester,
    ) async {
      final answers = <bool>[];
      await pumpPhone(
        tester,
        PhonePairPage(
          request: _request(mode: PairingPromptMode.responder),
          onResolved: answers.add,
        ),
      );
      expect(
        find.text(zh.pairingNewDeviceCompareCode('2698b')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(pairingRejectKey));
      await tester.pump();
      expect(answers, [false]);
    });

    testWidgets('a changed identity reads as a warning', (tester) async {
      await pumpPhone(
        tester,
        PhonePairPage(
          request: _request(reason: PairingReason.identityChanged),
          onResolved: (_) {},
        ),
      );
      expect(find.text(zh.pairingIdentityChangedTitle), findsOneWidget);
      expect(
        find.text(zh.pairingIdentityChangedDescription('2698b')),
        findsOneWidget,
      );
      expect(find.text(zh.pairingCompareCode), findsOneWidget);
      expect(find.text(zh.pairingApprove), findsOneWidget);
    });

    for (final (locale, size, scale, brightness) in phoneMatrix) {
      final tag =
          '${locale.languageCode} ${size.width.round()} ${scale}x ${brightness.name}';
      testWidgets('fits: $tag', (tester) async {
        await pumpPhone(
          tester,
          PhonePairPage(
            request: _request(reason: PairingReason.identityChanged),
            onResolved: (_) {},
          ),
          locale: locale,
          size: size,
          textScale: scale,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('pictures', (tester) async {
    await withPhoneShadows(() async {
      const mac = QuickSendTarget(id: 'mac', name: 'iMac', platform: 'macos');
      const phone = QuickSendTarget(
        id: 'mi',
        name: 'Xiaomi 16',
        platform: 'android',
      );
      final targets = ValueNotifier<List<QuickSendTarget>>(const [mac, phone]);
      for (final brightness in Brightness.values) {
        final dark = brightness == Brightness.dark ? '-dark' : '';
        await pumpPhone(
          tester,
          _launcher(
            (context) => showDevicePicker(
              context,
              title: zh.pickerSendFile('周报.pdf'),
              touch: true,
              devices: const [_imac, _mi, _laptop],
            ),
            (_) {},
          ),
          brightness: brightness,
        );
        await tester.tap(find.text('open'));
        await phoneSettle(tester);
        await phoneShot(tester, 'picker-phone$dark');
        await tester.pumpWidget(const SizedBox.shrink());

        await pumpPhone(
          tester,
          Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => unawaited(
                    showDevicePicker(
                      context,
                      title: zh.pickerSendFile('周报.pdf'),
                      touch: false,
                      anchor: context,
                      devices: const [_imac, _mi, _laptop],
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          size: const Size(600, 420),
          brightness: brightness,
        );
        await tester.tap(find.text('open'));
        await phoneSettle(tester);
        await phoneShot(tester, 'picker-desktop$dark');
        await tester.pumpWidget(const SizedBox.shrink());

        await pumpPhone(
          tester,
          _launcher(
            (context) => showPhoneSheet<String>(
              context,
              builder: (context) => QuickSendPicker(
                touch: true,
                items: const [
                  QuickSendItem.file(
                    name: '周报.pdf',
                    source: '/tmp/x.pdf',
                    size: 2048,
                  ),
                  QuickSendItem.text('周五发版清单：跑一遍多设备传输，更新西语文案。'),
                ],
                targets: targets,
              ),
            ),
            (_) {},
          ),
          brightness: brightness,
        );
        await tester.tap(find.text('open'));
        await phoneSettle(tester);
        await phoneShot(tester, 'quick-send-phone$dark');
        await tester.pumpWidget(const SizedBox.shrink());

        await pumpPhone(
          tester,
          _launcher(
            (context) => showShellSheet<String>(
              context,
              builder: (context) => QuickSendPicker(
                touch: false,
                items: const [QuickSendItem.text('周五发版清单：跑一遍多设备传输，更新西语文案。')],
                targets: targets,
                initialTargetId: 'mac',
              ),
            ),
            (_) {},
          ),
          size: const Size(600, 560),
          brightness: brightness,
        );
        await tester.tap(find.text('open'));
        await phoneSettle(tester);
        await phoneShot(tester, 'quick-send-desktop$dark');
        await tester.pumpWidget(const SizedBox.shrink());

        await pumpPhone(
          tester,
          PhonePairPage(request: _request(), onResolved: (_) {}),
          brightness: brightness,
        );
        await phoneShot(
          tester,
          'pair$dark',
          reference: dark.isEmpty ? 'phone-scanned.jpg' : null,
        );
        await tester.pumpWidget(const SizedBox.shrink());

        await pumpPhone(
          tester,
          PhonePairPage(
            request: _request(
              reason: PairingReason.identityChanged,
              mode: PairingPromptMode.responder,
            ),
            onResolved: (_) {},
          ),
          brightness: brightness,
        );
        await phoneShot(tester, 'pair-changed$dark');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });
}
