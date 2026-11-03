// surfaces.md「应用」on a phone, `phone-apps.jpg`. A layout overflow fails a test on
// its own.
//
// To look at them next to docs/design/reference/:
//   WHISPER_RENDER_DIR=/some/dir flutter test --no-pub test/phone_apps_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations_zh.dart';
import 'package:whisper/new_ui/apps/apps_parts.dart';
import 'package:whisper/new_ui/apps/phone_apps.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

import 'support/phone_shots.dart';

class _Log {
  final taps = <String>[];
}

Widget _page(
  _Log log, {
  bool withFlows = true,
  List<PhoneAppsEntry>? apps,
  PhoneAppsFailure? failure,
  bool loading = false,
  Widget? search,
  String? notice,
  bool closing = false,
  bool sendable = true,
}) {
  final zh = AppLocalizationsZh();
  void tap(String what) => log.taps.add(what);
  PhoneAppsEntry app(String name, Color color, {bool running = false}) =>
      PhoneAppsEntry(
        label: name,
        hue: color,
        running: running,
        onTap: () => tap(name),
      );
  return Builder(
    builder: (context) => PhonePage(
      background: context.wc.content,
      title: zh.shellTabApps,
      end: PhoneBarButton(
        key: const ValueKey('apps-more'),
        glyph: WhisperGlyph.more,
        iconSize: 15,
        weight: 2.4,
        label: zh.windowStreamQuality,
        onTap: () => tap('more'),
      ),
      child: Builder(
        builder: (context) => PhoneAppsView(
          movingTitle: zh.shellAppsMoving,
          closeLabel: zh.windowStreamCloseWindow,
          flows: withFlows
              ? [
                  PhoneAppsFlow(
                    title: '备忘录',
                    detail: '运行于 iMac，显示于 ThinkPad X1 Carbon',
                    action: '结束',
                    onAction: () => tap('end'),
                  ),
                  PhoneAppsFlow(
                    title: '访达 · 下载',
                    detail: '运行于 这台，显示于 iMac',
                    action: '收回',
                    onAction: () => tap('back'),
                  ),
                ]
              : const [],
          appsTitle: zh.shellAppsOn('iMac'),
          notice: notice,
          search: search,
          failure: failure,
          loading: loading,
          noApps: zh.windowStreamNoApps,
          tasks: [
            PhoneAppsTask(
              title: '浏览器 · Whisper 发布页',
              closing: closing,
              onTap: () => tap('task'),
              onClose: () => tap('close'),
            ),
            PhoneAppsTask(title: '设计 · 新版首页', onTap: () => tap('task2')),
          ],
          apps:
              apps ??
              [
                app('备忘录', const Color(0xFFFFB800), running: false),
                app('终端', const Color(0xFF3A3A3C)),
                app('浏览器', const Color(0xFF2F8FFF)),
                app('音乐', const Color(0xFFFF3B5C)),
                app('日历', const Color(0xFFFF5A47)),
                app('照片', const Color(0xFF34C759)),
                app('设计', const Color(0xFF8E6CFF)),
                app('编辑器', const Color(0xFF2192D9)),
              ],
          sendTitle: zh.windowStreamSendTo('iMac'),
          send: sendable
              ? ShellAutoGrid(
                  minWidth: 160,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    ShellWindowThumb(
                      touch: true,
                      title: '备忘录 · 周五发版',
                      onTap: (_) => tap('send1'),
                    ),
                    ShellWindowThumb(
                      touch: true,
                      title: '浏览器 · 提交记录',
                      onTap: (_) => tap('send2'),
                    ),
                  ],
                )
              : null,
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(loadPhoneFonts);
  final zh = AppLocalizationsZh();

  testWidgets('what is moving, the device\'s windows and apps, what can go', (
    tester,
  ) async {
    final log = _Log();
    await pumpPhone(tester, _page(log));
    for (final text in [
      zh.shellAppsMoving,
      zh.shellAppsOn('iMac'),
      zh.windowStreamSendTo('iMac'),
      '备忘录 · 周五发版',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // 4 / 20 / 30, thumbnails in two columns of 164, apps in four.
    final thumb = tester.getSize(find.byType(ShellWindowThumb).first);
    expect(thumb.width, 164);
    final icon = tester.getSize(find.byType(ShellAppIcon).first);
    expect(icon.width, closeTo(80.5, .1));
    expect(icon.height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap opens, a long press on a window offers closing it', (
    tester,
  ) async {
    final log = _Log();
    await pumpPhone(tester, _page(log));
    await tester.tap(find.text('备忘录').last);
    await tester.tap(find.text('结束'));
    await tester.tap(find.text('浏览器 · Whisper 发布页'));
    await tester.pump(const Duration(seconds: 1));
    expect(log.taps, ['备忘录', 'end', 'task']);

    await tester.longPress(find.text('浏览器 · Whisper 发布页'));
    await phoneSettle(tester);
    expect(find.text(zh.windowStreamCloseWindow), findsOneWidget);
    await tester.tap(find.text(zh.windowStreamCloseWindow));
    await phoneSettle(tester);
    expect(log.taps.last, 'close');
    // Only windows that can be closed offer it.
    await tester.longPress(find.text('设计 · 新版首页'));
    await phoneSettle(tester);
    expect(find.text(zh.windowStreamCloseWindow), findsNothing);
  });

  testWidgets('loading, failure, nothing, a notice', (tester) async {
    final log = _Log();
    await pumpPhone(tester, _page(log, loading: true, apps: const []));
    expect(find.text(zh.windowStreamNoApps), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpPhone(tester, _page(log, apps: const []));
    expect(find.text(zh.windowStreamNoApps), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpPhone(
      tester,
      _page(
        log,
        apps: const [],
        notice: '需要先解锁',
        failure: PhoneAppsFailure(
          title: zh.windowStreamLoadFailed,
          body: '没有回应',
          retry: zh.windowStreamRetry,
          onRetry: () => log.taps.add('retry'),
        ),
      ),
    );
    expect(find.text('需要先解锁'), findsOneWidget);
    await tester.tap(find.text(zh.windowStreamRetry));
    await tester.pump();
    expect(log.taps.last, 'retry');
  });

  testWidgets('a phone\'s apps can be searched, the field is 44', (
    tester,
  ) async {
    final field = TextEditingController();
    addTearDown(field.dispose);
    await pumpPhone(
      tester,
      _page(
        _Log(),
        search: PhoneAppsSearch(
          controller: field,
          hint: zh.windowStreamSearchApps,
          onChanged: (_) {},
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(PhoneAppsSearch)).height,
      greaterThanOrEqualTo(44),
    );
  });

  testWidgets('a window that runs here and one open here have a dot', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      _page(
        _Log(),
        apps: [
          PhoneAppsEntry(
            label: 'A',
            hue: const Color(0xFF2F8FFF),
            running: true,
            onTap: () {},
          ),
          PhoneAppsEntry(
            label: 'B',
            hue: const Color(0xFF2F8FFF),
            onTap: () {},
          ),
        ],
      ),
    );
    expect(find.byKey(const ValueKey('app-running-dot')), findsOneWidget);
  });

  group('every state fits', () {
    for (final (locale, size, scale, brightness) in phoneMatrix) {
      final tag =
          '${locale.languageCode} ${size.width.round()} ${scale}x ${brightness.name}';
      testWidgets(tag, (tester) async {
        await pumpPhone(
          tester,
          _page(_Log()),
          locale: locale,
          size: size,
          textScale: scale,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('pictures, next to the reference', (tester) async {
    await withPhoneShadows(() async {
      for (final brightness in Brightness.values) {
        final dark = brightness == Brightness.dark ? '-dark' : '';
        await pumpPhone(tester, _page(_Log()), brightness: brightness);
        await phoneShot(
          tester,
          'apps$dark',
          reference: dark.isEmpty ? 'phone-apps.jpg' : null,
        );
        await tester.longPress(find.text('浏览器 · Whisper 发布页'));
        await phoneSettle(tester);
        await phoneShot(tester, 'apps-close$dark');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await pumpPhone(
        tester,
        _page(_Log()),
        locale: const Locale('es'),
        size: const Size(360, 720),
        textScale: 2,
      );
      await phoneShot(tester, 'apps-es-200');
    });
  });
}
