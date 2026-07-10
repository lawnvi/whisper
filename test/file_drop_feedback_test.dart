import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/file_drop_feedback.dart';

void main() {
  testWidgets('hidden state omits the overlay', (tester) async {
    await tester.pumpWidget(
      _app(state: FileDropFeedbackState.hidden),
    );

    expect(find.byKey(FileDropFeedback.overlayKey), findsNothing);
    expect(tester.getSize(find.byKey(_childKey)), const Size(240, 120));
  });

  testWidgets('accepted state exposes localized live-region semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(state: FileDropFeedbackState.accepted),
    );

    final node = tester.getSemantics(find.byKey(FileDropFeedback.overlayKey));
    expect(node.label, 'Drop to send to Studio Mac');
    expect(node.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
    semantics.dispose();
  });

  testWidgets('rejected state exposes its localized reason', (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(
        state: FileDropFeedbackState.rejected,
        rejectedMessage: 'Connect to the device before dropping files',
      ),
    );

    final node = tester.getSemantics(find.byKey(FileDropFeedback.overlayKey));
    expect(node.label, 'Connect to the device before dropping files');
    expect(node.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
    semantics.dispose();
  });

  testWidgets('switching feedback state does not resize the child',
      (tester) async {
    await tester.pumpWidget(
      _app(state: FileDropFeedbackState.hidden),
    );
    final hiddenSize = tester.getSize(find.byKey(_childKey));

    await tester.pumpWidget(
      _app(state: FileDropFeedbackState.accepted),
    );
    await tester.pump();
    final acceptedSize = tester.getSize(find.byKey(_childKey));

    await tester.pumpWidget(
      _app(state: FileDropFeedbackState.rejected),
    );
    await tester.pump();
    final rejectedSize = tester.getSize(find.byKey(_childKey));

    expect(acceptedSize, hiddenSize);
    expect(rejectedSize, hiddenSize);
  });
}

const _childKey = ValueKey('file-drop-feedback-test-child');

Widget _app({
  required FileDropFeedbackState state,
  String? rejectedMessage,
}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: FileDropFeedback(
          state: state,
          deviceName: 'Studio Mac',
          rejectedMessage: rejectedMessage,
          child: const SizedBox(
            key: _childKey,
            width: 240,
            height: 120,
          ),
        ),
      ),
    ),
  );
}
