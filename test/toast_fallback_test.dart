import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toastification/toastification.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpApp(
    WidgetTester tester, {
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    await tester.pumpWidget(
      ToastificationWrapper(
        config: appToastConfig,
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeMode,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => toastification.dismissAll(delayForAnimation: false));
  }

  Future<void> pumpToast(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  Future<void> clearToasts(WidgetTester tester) async {
    toastification.dismissAll(delayForAnimation: false);
    await tester.pumpAndSettle();
  }

  testWidgets('a toast appears near the top of the window', (tester) async {
    await pumpApp(tester);

    showAppToast('键鼠共享需要互信设备');
    await pumpToast(tester);

    final message = find.text('键鼠共享需要互信设备');
    expect(message, findsOneWidget);
    expect(find.byIcon(Icons.info_rounded), findsOneWidget);
    final window = tester.getSize(find.byType(MaterialApp));
    expect(tester.getCenter(message).dy, lessThan(window.height / 4));
    expect(
      (tester.getCenter(message).dx - window.width / 2).abs(),
      lessThan(40),
    );

    await clearToasts(tester);
  });

  testWidgets('the tone picks the icon and its colour', (tester) async {
    await pumpApp(tester);
    final palette = AppTheme.fallbackPalette(Brightness.light);

    for (final (tone, icon, color) in [
      (AppToastTone.success, Icons.check_circle_rounded, palette.trusted),
      (AppToastTone.warning, Icons.warning_rounded, palette.warning),
      (AppToastTone.error, Icons.error_rounded, palette.danger),
    ]) {
      showAppToast('提示', tone: tone);
      await pumpToast(tester);

      expect(tester.widget<Icon>(find.byIcon(icon)).color, color);
      // A newer toast takes the place of the one before it.
      expect(find.text('提示'), findsOneWidget);
    }

    await clearToasts(tester);
  });

  testWidgets('toasts raised in the same frame leave only the last', (
    tester,
  ) async {
    await pumpApp(tester);

    showAppToast('文件传输失败', tone: AppToastTone.error);
    showAppToast('无法发送这些文件', tone: AppToastTone.error);
    await pumpToast(tester);

    expect(find.text('文件传输失败'), findsNothing);
    expect(find.text('无法发送这些文件'), findsOneWidget);

    await clearToasts(tester);
  });

  testWidgets('the text follows the dark theme', (tester) async {
    await pumpApp(tester, themeMode: ThemeMode.dark);

    showAppToast('消息发送失败，请重试', tone: AppToastTone.error);
    await pumpToast(tester);

    final text = tester.widget<Text>(find.text('消息发送失败，请重试'));
    expect(text.style?.color, AppTheme.darkTheme.colorScheme.onSurface);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.error_rounded)).color,
      AppTheme.fallbackPalette(Brightness.dark).danger,
    );

    await clearToasts(tester);
  });

  testWidgets('the action runs once and takes the toast away', (tester) async {
    await pumpApp(tester);
    var retried = 0;

    showAppToast(
      '发送失败，分享内容已保留',
      tone: AppToastTone.error,
      action: AppToastAction(label: '重试', onPressed: () => retried++),
    );
    await pumpToast(tester);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(retried, 1);
    expect(find.text('发送失败，分享内容已保留'), findsNothing);
  });

  testWidgets('tapping a toast dismisses it', (tester) async {
    await pumpApp(tester);

    showAppToast('文件已复制', tone: AppToastTone.success);
    await pumpToast(tester);
    await tester.tap(find.text('文件已复制'));
    await tester.pumpAndSettle();

    expect(find.text('文件已复制'), findsNothing);
  });

  testWidgets('a toast leaves on its own', (tester) async {
    await pumpApp(tester);

    showAppToast('文件已复制', tone: AppToastTone.success);
    await pumpToast(tester);
    expect(find.text('文件已复制'), findsOneWidget);
    await tester.pump(appToastDurationFor('文件已复制'));
    await tester.pumpAndSettle();

    expect(find.text('文件已复制'), findsNothing);
  });

  test('longer messages stay longer, within bounds', () {
    final brief = appToastDurationFor('文件已复制');
    final instruction = appToastDurationFor(
      '请在系统设置 → 隐私与安全性中允许 Whisper 录制屏幕，然后重启 Whisper',
    );

    expect(brief, const Duration(milliseconds: 2650));
    expect(instruction, greaterThan(brief));
    expect(appToastDurationFor('长' * 200), const Duration(seconds: 6));
    expect(
      appToastDurationFor('发送失败', hasAction: true),
      const Duration(seconds: 5),
    );
  });

  testWidgets('without an overlay the call is dropped quietly', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());

    showAppToast('没有界面可以显示');
    await tester.pump();

    expect(find.text('没有界面可以显示'), findsNothing);
  });
}
