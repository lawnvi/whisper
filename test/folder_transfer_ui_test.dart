import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/folder_transfer_store.dart';
import 'package:whisper/helper/transfer_failure_message.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/l10n/app_localizations_en.dart';
import 'package:whisper/l10n/app_localizations_es.dart';
import 'package:whisper/l10n/app_localizations_zh.dart';
import 'package:whisper/socket/folder_transfer_manifest.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/chat_composer.dart';
import 'package:whisper/widget/file_message_card.dart';
import 'package:whisper/widget/folder_skipped_dialog.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  theme: AppTheme.lightTheme,
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Widget _card({
  required bool isFolder,
  bool failed = false,
  bool active = false,
  String status = 'status',
  String? skippedLabel,
  VoidCallback? onShowSkipped,
  VoidCallback? onRetry,
  VoidCallback? onCancel,
}) => FileMessageCard(
  name: 'Project Files',
  isFolder: isFolder,
  failed: failed,
  active: active,
  verifying: false,
  progress: 0.4,
  statusKey: status,
  statusText: (progress) =>
      progress == null ? status : '$status ${(progress * 100).round()}%',
  cardColor: Colors.white,
  borderColor: Colors.black12,
  animationDuration: Duration.zero,
  retryTooltip: 'Retry',
  cancelTooltip: 'Cancel',
  skippedLabel: skippedLabel,
  onShowSkipped: onShowSkipped,
  onRetry: onRetry,
  onCancel: onCancel,
);

void main() {
  group('file message card', () {
    testWidgets('a folder shows a folder, a file shows a file', (tester) async {
      await tester.pumpWidget(_app(_card(isFolder: true)));
      expect(find.byIcon(Icons.folder_rounded), findsOneWidget);
      expect(find.byIcon(Icons.insert_drive_file), findsNothing);
      expect(find.text('Project Files'), findsOneWidget);
      expect(find.text('status'), findsOneWidget);
      expect(find.byKey(FileMessageCard.skippedKey), findsNothing);

      await tester.pumpWidget(_app(_card(isFolder: false)));
      expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
      expect(find.byIcon(Icons.folder_rounded), findsNothing);
    });

    testWidgets('what was left out is one tap away', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _app(
          _card(
            isFolder: true,
            skippedLabel: '3 not transferred',
            onShowSkipped: () => opened++,
          ),
        ),
      );

      await tester.tap(find.text('3 not transferred'));

      expect(opened, 1);
    });

    testWidgets('progress and failure replace the icon', (tester) async {
      await tester.pumpWidget(
        _app(_card(isFolder: true, active: true, onCancel: () {})),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.folder_rounded), findsNothing);
      expect(find.text('status 40%'), findsOneWidget);
      expect(find.byTooltip('Cancel'), findsOneWidget);
      expect(find.byTooltip('Retry'), findsNothing);

      await tester.pumpWidget(
        _app(_card(isFolder: true, failed: true, onRetry: () {})),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.byTooltip('Retry'), findsOneWidget);
    });
  });

  group('skipped dialog', () {
    testWidgets('names what this device knows and counts the rest', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const FolderSkippedDialog(
            skippedCount: 5,
            entries: <FolderSkippedEntry>[
              FolderSkippedEntry(
                path: 'docs/latest',
                reason: FolderSkipReason.symlink,
              ),
              FolderSkippedEntry(
                path: 'a/b.txt',
                reason: FolderSkipReason.sourceUnavailable,
              ),
            ],
          ),
        ),
      );
      final l10n = AppLocalizationsEn();

      expect(find.text(l10n.folderSkippedTitle), findsOneWidget);
      expect(find.text('docs/latest'), findsOneWidget);
      expect(find.text(l10n.folderSkipSymlink), findsOneWidget);
      expect(find.text('a/b.txt'), findsOneWidget);
      expect(find.text(l10n.folderSkipSourceUnavailable), findsOneWidget);
      expect(find.text(l10n.folderSkippedMore(3)), findsOneWidget);
    });

    testWidgets('says nothing about other devices when it knows all', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const FolderSkippedDialog(
            skippedCount: 1,
            entries: <FolderSkippedEntry>[
              FolderSkippedEntry(
                path: 'x',
                reason: FolderSkipReason.nameCollision,
              ),
            ],
          ),
        ),
      );
      final l10n = AppLocalizationsEn();

      expect(find.text(l10n.folderSkipNameCollision), findsOneWidget);
      expect(find.textContaining('other device'), findsNothing);
    });

    testWidgets('opens from the stored list and closes', (tester) async {
      final temp = Directory.systemTemp.createTempSync('whisper-folder-ui-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final store = FolderTransferStore(
        directory: () async => Directory(p.join(temp.path, 'store')),
      );
      const transferId = '01234567-89ab-4cde-8fab-0123456789ab';
      await tester.runAsync(
        () => store.addSkipped(transferId, const <FolderSkippedEntry>[
          FolderSkippedEntry(
            path: 'old/name?.txt',
            reason: FolderSkipReason.invalidName,
          ),
        ]),
      );
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showFolderSkippedDialog(
                context,
                transferId: transferId,
                skippedCount: 1,
                store: store,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      // Reading the list is real file access: each step of it finishes
      // outside the test clock and continues on the next pump.
      for (var step = 0; step < 10; step += 1) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('old/name?.txt'), findsOneWidget);
      expect(
        find.text(AppLocalizationsEn().folderSkipInvalidName),
        findsOneWidget,
      );

      await tester.tap(find.text(AppLocalizationsEn().confirm));
      await tester.pumpAndSettle();
      expect(find.text('old/name?.txt'), findsNothing);
    });

    test('every reason has its own wording in every language', () {
      for (final l10n in <AppLocalizations>[
        AppLocalizationsZh(),
        AppLocalizationsEn(),
        AppLocalizationsEs(),
      ]) {
        final labels = <String>{
          for (final reason in FolderSkipReason.values)
            folderSkipReasonLabel(l10n, reason),
        };
        expect(labels, hasLength(FolderSkipReason.values.length));
        expect(labels.every((label) => label.isNotEmpty), isTrue);
      }
    });
  });

  group('attachment button', () {
    Future<({int Function() files, int Function() folders})> pumpComposer(
      WidgetTester tester, {
      required bool desktop,
      required bool withFolder,
    }) async {
      var files = 0;
      var folders = 0;
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              const Spacer(),
              ChatComposer(
                clipboardEnabled: false,
                canSend: true,
                isInputEmpty: true,
                isLoading: false,
                isLocalhost: false,
                isDesktopStyle: desktop,
                keyPressedMap: const <String, bool>{},
                controller: controller,
                focusNode: focus,
                onPickFiles: () async => files++,
                onPickFolder: withFolder ? () async => folders++ : null,
                onSendClipboard: () async {},
                onSendText: (_) async => true,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (files: () => files, folders: () => folders);
    }

    testWidgets('offers a file or a folder on desktop', (tester) async {
      final counts = await pumpComposer(
        tester,
        desktop: true,
        withFolder: true,
      );
      final l10n = AppLocalizationsEn();

      await tester.tap(find.byKey(ChatComposer.attachmentButtonKey));
      await tester.pumpAndSettle();
      expect(find.text(l10n.attachFile), findsOneWidget);
      expect(find.text(l10n.attachFolder), findsOneWidget);
      expect(counts.files(), 0);
      // The menu sits above the button it came from.
      expect(
        tester.getBottomLeft(find.text(l10n.attachFolder)).dy,
        lessThan(
          tester.getTopLeft(find.byKey(ChatComposer.attachmentButtonKey)).dy,
        ),
      );

      await tester.tap(find.text(l10n.attachFolder));
      await tester.pumpAndSettle();
      expect(counts.folders(), 1);
      expect(counts.files(), 0);

      await tester.tap(find.byKey(ChatComposer.attachmentButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.attachFile));
      await tester.pumpAndSettle();
      expect(counts.files(), 1);
      expect(counts.folders(), 1);
    });

    testWidgets('goes straight to files where folders are not offered', (
      tester,
    ) async {
      final desktop = await pumpComposer(
        tester,
        desktop: true,
        withFolder: false,
      );
      await tester.tap(find.byKey(ChatComposer.attachmentButtonKey));
      await tester.pumpAndSettle();
      expect(desktop.files(), 1);
      expect(find.text(AppLocalizationsEn().attachFolder), findsNothing);

      final mobile = await pumpComposer(
        tester,
        desktop: false,
        withFolder: true,
      );
      await tester.tap(find.byKey(ChatComposer.attachmentButtonKey));
      await tester.pumpAndSettle();
      expect(mobile.files(), 1);
      expect(mobile.folders(), 0);
    });
  });

  test('an old peer turning a folder down is explained as such', () {
    final l10n = AppLocalizationsEn();

    expect(
      transferFailureMessage(l10n, 'folder_unsupported'),
      l10n.folderSendUnsupported,
    );
    expect(
      transferFailureNotice(l10n, 'folder_unsupported'),
      l10n.folderSendUnsupported,
    );
  });

  test('counts read naturally in every language', () {
    expect(AppLocalizationsZh().folderFileCount(0), '空文件夹');
    expect(AppLocalizationsZh().folderFileCount(48213), '48,213 个文件');
    expect(AppLocalizationsEn().folderFileCount(1), '1 file');
    expect(AppLocalizationsEn().folderFileCount(2), '2 files');
    expect(AppLocalizationsEs().folderFileCount(1), '1 archivo');
    expect(AppLocalizationsZh().folderSkippedCount(3), '3 项未传');
    expect(
      AppLocalizationsZh().folderFileProgress(3214, 14797),
      '3,214/14,797 个文件',
    );
    expect(
      AppLocalizationsEn().folderFileProgress(3214, 14797),
      '3,214 of 14,797 files',
    );
    expect(
      AppLocalizationsEn().folderSendTooManyEntries(folderManifestMaxEntries),
      contains('500,000'),
    );
  });
}
