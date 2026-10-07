import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform keeps the sidebar stationary on push and pop', (
      tester,
    ) async {
      var pageBuilds = 0;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.lightTheme.copyWith(platform: platform),
          home: Scaffold(
            body: Row(
              children: [
                Container(
                  key: const ValueKey('sidebar'),
                  width: 260,
                  color: Colors.blue,
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      final sidebar = find.byKey(
        const ValueKey('sidebar'),
        skipOffstage: false,
      );
      final original = tester.getRect(sidebar);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) {
            pageBuilds++;
            return const Scaffold(body: Center(child: Text('Settings')));
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getRect(sidebar), original);
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.getRect(sidebar), original);
      await tester.pumpAndSettle();
      expect(pageBuilds, 1);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(tester.getRect(sidebar), original);
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('interrupted transitions can reverse without leaving a page', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.darkTheme.copyWith(platform: TargetPlatform.macOS),
        home: const Scaffold(body: Text('Home')),
      ),
    );
    for (var i = 0; i < 3; i++) {
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Workspace')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Workspace'), findsNothing);
      expect(find.text('Home'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion presents desktop pages at their final position', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.macOS),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const Scaffold(),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const Scaffold(key: ValueKey('new-page'), body: Text('Settings')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    final initial = tester.getRect(find.byKey(const ValueKey('new-page')));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('new-page'))), initial);
    expect(tester.takeException(), isNull);
  });
}
