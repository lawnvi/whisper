import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/island/island_overlay_setting.dart';

void main() {
  testWidgets('the settings row shows only where needed, and catches up '
      'on return', (tester) async {
    var state = (needed: false, allowed: false);
    Widget app() => MaterialApp(
      home: IslandOverlaySetting(
        read: () async => state,
        builder: (context, allowed) => Text(allowed ? 'on' : 'off'),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text('off'), findsNothing);
    expect(find.text('on'), findsNothing);

    state = (needed: true, allowed: false);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text('off'), findsOneWidget);

    // Back from the system page with the permission given.
    state = (needed: true, allowed: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.text('on'), findsOneWidget);
  });
}
