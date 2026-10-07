import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/subtle_motion.dart';

void main() {
  testWidgets('fading actions lose pointer, focus and semantics immediately', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final oldFocus = FocusNode();
    addTearDown(oldFocus.dispose);
    var oldCalls = 0;
    var newCalls = 0;
    var changed = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return WhisperAnimatedSwitcher(
                value: changed,
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: changed ? 60 : 240,
                  height: 48,
                  child: TextButton(
                    focusNode: changed ? null : oldFocus,
                    onPressed: changed ? () => newCalls++ : () => oldCalls++,
                    child: Text(changed ? 'New' : 'Old'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    oldFocus.requestFocus();
    await tester.pump();
    update(() => changed = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('Old'), findsOneWidget);
    expect(find.semantics.byLabel('Old'), findsNothing);
    oldFocus.requestFocus();
    await tester.pump();
    expect(oldFocus.hasFocus, isFalse);
    await tester.tapAt(const Offset(200, 24));
    expect(oldCalls, 0);
    await tester.tap(find.text('New'));
    expect(newCalls, 1);
    await tester.pumpAndSettle();
    expect(find.text('Old'), findsNothing);
    semantics.dispose();
  });

  testWidgets(
    'reduced motion replaces content immediately with unchanged icon bounds',
    (tester) async {
      var value = false;
      var reduced = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MediaQuery(
                  data: MediaQueryData(disableAnimations: reduced),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox.square(
                      dimension: 40,
                      child: WhisperAnimatedSwitcher(
                        value: value,
                        child: SizedBox.square(
                          key: ValueKey('icon-$value'),
                          dimension: 24,
                          child: Icon(
                            value ? Icons.check_rounded : Icons.add_rounded,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('icon-false'))),
        const Size.square(24),
      );
      update(() {
        value = true;
        reduced = true;
      });
      await tester.pump();
      expect(find.byIcon(Icons.add_rounded), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('icon-true'))),
        const Size.square(24),
      );
    },
  );

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'reveal reverses safely with a focused input, reduced=$reduceMotion',
      (tester) async {
        final fieldKey = GlobalKey();
        final focus = FocusNode();
        final controller = TextEditingController(text: 'Unsent draft');
        addTearDown(focus.dispose);
        addTearDown(controller.dispose);
        var visible = true;
        var calls = 0;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(disableAnimations: reduceMotion),
                child: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return Column(
                      children: [
                        WhisperAnimatedReveal(
                          key: const ValueKey('reveal'),
                          visible: visible,
                          child: visible
                              ? SizedBox(
                                  height: 120,
                                  child: Column(
                                    children: [
                                      TextField(
                                        key: fieldKey,
                                        focusNode: focus,
                                        controller: controller,
                                      ),
                                      TextButton(
                                        onPressed: () => calls++,
                                        child: const Text('Send'),
                                      ),
                                    ],
                                  ),
                                )
                              : null,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
        focus.requestFocus();
        await tester.pump();
        final sendPosition = tester.getCenter(find.text('Send'));
        update(() => visible = false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(focus.hasFocus, isFalse);
        await tester.tapAt(sendPosition);
        expect(calls, 0);
        final height = tester
            .getSize(find.byKey(const ValueKey('reveal')))
            .height;
        expect(height, reduceMotion ? 0 : inExclusiveRange(0, 120));
        // Reopening before the exit finishes must not duplicate the field/focus.
        update(() => visible = true);
        await tester.pump();
        expect(find.byKey(fieldKey), findsOneWidget);
        expect(controller.text, 'Unsent draft');
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const ValueKey('reveal'))).height,
          120,
        );
        update(() => visible = false);
        await tester.pumpAndSettle();
        expect(find.byKey(fieldKey), findsNothing);
        expect(tester.getSize(find.byKey(const ValueKey('reveal'))).height, 0);
      },
    );
  }
}
