import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/l10n/app_localizations_zh.dart';
import 'package:whisper/new_ui/shell/shell_requests.dart';
import 'package:whisper/page/remote_files/file_browse_prompt.dart';
import 'package:whisper/remote_files/fs_host.dart';

import 'support/golden_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = AppLocalizationsZh();
  const request = FileBrowseRequest(peerId: 'peer', deviceName: 'iMac');

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    debugIsDesktopOverride = null;
    RequestIslandSource.shared.settle(fileBrowseAskId(request.peerId));
  });

  Future<FileBrowseGate> phone(WidgetTester tester) async {
    debugIsDesktopOverride = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final gate = FileBrowseGate();
    addTearDown(gate.dispose);
    await tester.pumpWidget(
      goldenApp(FileBrowsePromptHost(gate: gate, child: const SizedBox())),
    );
    return gate;
  }

  testWidgets('a phone asks one thing and gives two answers', (tester) async {
    final gate = await phone(tester);
    final answer = gate.ask(request);
    await tester.pumpAndSettle();
    expect(find.text(l10n.remoteFilesPromptTitle('iMac')), findsOneWidget);
    expect(find.text(l10n.remoteFilesAllowOnce), findsOneWidget);
    expect(find.text(l10n.remoteFilesDeny), findsOneWidget);
    expect(find.byType(Switch), findsNothing);

    await tester.tap(find.text(l10n.remoteFilesDeny));
    await tester.runAsync(() => answer);
    expect(await answer, FileBrowseDecision.deny);
  });

  testWidgets('allowing from the question only lets it read', (tester) async {
    final gate = await phone(tester);
    // It could change files once: the question does not bring that back.
    await tester.runAsync(
      () => FileBrowseHost.shared.setReadOnly(request.peerId, false),
    );
    final answer = gate.ask(request);
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.remoteFilesAllowOnce));
    await tester.runAsync(() => answer);
    expect(await answer, FileBrowseDecision.once);
    expect(
      await tester.runAsync(
        () => FileBrowseHost.shared.permissions.isReadOnly(request.peerId),
      ),
      isTrue,
    );
  });

  test('a desktop asks on the island, with two answers and no text', () {
    final decided = <FileBrowseDecision>[];
    askFileBrowse(l10n, request, decided.add);
    final presenter =
        RequestIslandSource.shared.activities.single.presenter
            as RequestPresenter;
    expect(presenter.detail, isEmpty);
    expect(presenter.answers.map((a) => a.label), [
      l10n.remoteFilesAllowOnce,
      l10n.remoteFilesDeny,
    ]);
    presenter.answers.first.onTap();
    expect(decided, [FileBrowseDecision.once]);
    expect(RequestIslandSource.shared.activities, isEmpty);
  });
}
