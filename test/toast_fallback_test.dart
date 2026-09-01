import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toastification/toastification.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('showAppToast displays a toastification notification',
      (tester) async {
    await tester.pumpWidget(
      ToastificationWrapper(
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    showAppToast('键鼠共享需要互信设备');
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('键鼠共享需要互信设备'), findsOneWidget);

    toastification.dismissAll(delayForAnimation: false);
    await tester.pumpAndSettle();
  });

  testWidgets('showAppToast adapts to the dark theme', (tester) async {
    await tester.pumpWidget(
      ToastificationWrapper(
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: ThemeMode.dark,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    showAppToast('键鼠共享需要互信设备');
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('键鼠共享需要互信设备'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);

    final toastText = tester.widget<Text>(find.text('键鼠共享需要互信设备'));
    expect(toastText.style?.color, AppTheme.darkTheme.colorScheme.onSurface);

    toastification.dismissAll(delayForAnimation: false);
    await tester.pumpAndSettle();
  });

}
