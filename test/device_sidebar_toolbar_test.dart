import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/device_connection_widgets.dart';
import 'package:whisper/widget/device_sidebar_toolbar.dart';

Widget _toolbar({int count = 2, bool expanded = false, double width = 320}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: DeviceSidebarToolbar(
            searchExpanded: expanded,
            search: const SizedBox(key: ValueKey('search'), height: 38),
            tools: [
              for (var index = 0; index < count; index++)
                DeviceToolbarButton(
                  key: ValueKey('tool-$index'),
                  icon: Icons.settings_outlined,
                  label: 'tool $index',
                  onPressed: () {},
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('two mobile buttons reclaim unused desktop button space', (
    tester,
  ) async {
    await tester.pumpWidget(_toolbar(count: 4));
    final desktopSearchWidth = tester
        .getSize(find.byKey(const ValueKey('search')))
        .width;
    expect(
      tester.getSize(find.byKey(const ValueKey('sidebar-tools'))).width,
      140,
    );

    await tester.pumpWidget(_toolbar());
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('sidebar-tools'))).width,
      72,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('search'))).width,
      desktopSearchWidth + 68,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('tool-1'))).right,
      320 - 14 - 3,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('search fills resized toolbars and expands without overflow', (
    tester,
  ) async {
    for (final width in [280.0, 320.0, 430.0]) {
      await tester.pumpWidget(_toolbar(width: width));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('search'))).width,
        width - 28 - 10 - 72,
      );
      await tester.pumpWidget(_toolbar(width: width, expanded: true));
      await tester.pump(const Duration(milliseconds: 110));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('search'))).width,
        width - 28,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
