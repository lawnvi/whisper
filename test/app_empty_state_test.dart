import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_empty_state.dart';

void main() {
  testWidgets('renders one compact accessible action without a card',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var actions = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: AppEmptyState(
            icon: Icons.devices_outlined,
            title: 'No devices',
            body: 'Nearby devices will appear here.',
            actionLabel: 'Connect manually',
            onAction: () => actions += 1,
          ),
        ),
      ),
    );

    expect(
        find.descendant(
          of: find.byType(AppEmptyState),
          matching: find.byType(Card),
        ),
        findsNothing);
    expect(
      find.bySemanticsLabel('No devices\nNearby devices will appear here.'),
      findsOneWidget,
    );

    final action = find.widgetWithText(FilledButton, 'Connect manually');
    expect(action, findsOneWidget);
    expect(tester.getSize(action).height,
        greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
    await tester.tap(action);
    expect(actions, 1);

    semantics.dispose();
  });

  testWidgets('omits the action when no complete action is supplied',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppEmptyState(
            icon: Icons.search_off,
            title: 'No results',
            body: 'Try another search.',
          ),
        ),
      ),
    );

    expect(find.byType(ButtonStyleButton), findsNothing);
  });
}
