import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/page/transfer_assistant.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestDatabase database;
  late MessageData favoriteMessage;
  late MessageData searchableMessage;
  late List<String> copiedTexts;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{'_uuid': 'local'});
    database = _TestDatabase();
    favoriteMessage = await database.insertMessageReturning(
      _message('saved note', timestamp: 1),
    );
    searchableMessage = await database.insertMessageReturning(
      _message('old needle text', timestamp: 2),
    );
    await database.insertMessageReturning(
      _message('latest note', timestamp: 3),
    );
    await database.favoriteTextMessage(favoriteMessage, peerUid: 'peer-a');
    copiedTexts = <String>[];
  });

  tearDown(() => database.close());

  testWidgets('shows a single recent list and filters saved snapshots', (
    tester,
  ) async {
    await _pumpPage(tester, database, copiedTexts);

    expect(find.text('Search chat history'), findsOneWidget);
    expect(find.text('Recent messages'), findsOneWidget);
    expect(find.text('saved note'), findsOneWidget);
    expect(find.text('latest note'), findsOneWidget);

    await tester.tap(find.byKey(transferAssistantFavoritesFilterKey));
    await tester.pumpAndSettle();
    expect(find.text('latest note'), findsNothing);
    expect(find.text('saved note'), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(find.byKey(transferAssistantFavoritesFilterKey))
          .selected,
      isTrue,
    );
    await tester.tap(
      find.byKey(transferAssistantFavoriteCopyKey(favoriteMessage.id)),
    );
    await tester.pumpAndSettle();
    expect(copiedTexts, <String>['saved note']);
  });

  testWidgets(
    'searches history and saves or removes favorites directly in the list',
    (tester) async {
      await _pumpPage(tester, database, copiedTexts);
      await _search(tester, 'needle');

      expect(find.text('Search results'), findsOneWidget);
      expect(find.text('old needle text'), findsOneWidget);
      expect(find.text('latest note'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(
        find.byKey(transferAssistantMessageFavoriteKey(searchableMessage.id)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        (await database.fetchFavoriteTextsForPeer(
          'peer-a',
        )).map((item) => item.sourceMessageId),
        contains(searchableMessage.id),
      );

      await tester.tap(find.byKey(transferAssistantFavoritesFilterKey));
      await tester.pumpAndSettle();
      expect(find.text('saved note'), findsNothing);
      await tester.tap(
        find.byKey(transferAssistantFavoriteRemoveKey(searchableMessage.id)),
      );
      await tester.pumpAndSettle();
      expect(
        (await database.fetchFavoriteTextsForPeer(
          'peer-a',
        )).map((item) => item.sourceMessageId),
        isNot(contains(searchableMessage.id)),
      );
      expect(find.text('No matching text found'), findsOneWidget);
      await tester.tap(find.text('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('saved note'), findsOneWidget);
      expect(find.text('latest note'), findsNothing);
    },
  );

  testWidgets(
    'short messages show selectable content and actions without details',
    (tester) async {
      await _pumpPage(tester, database, copiedTexts);
      expect(find.byType(SelectableText), findsNWidgets(3));
      expect(find.byTooltip('Expand message'), findsNothing);
      await tester.tap(find.text('latest note'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.byKey(transferAssistantMessageCopyKey(searchableMessage.id)),
        findsOneWidget,
      );
      expect(
        find.byKey(transferAssistantMessageFavoriteKey(searchableMessage.id)),
        findsOneWidget,
      );
    },
  );

  testWidgets('copy action briefly morphs into a success check', (
    tester,
  ) async {
    await _pumpPage(tester, database, copiedTexts);
    await tester.tap(
      find.byKey(transferAssistantMessageCopyKey(favoriteMessage.id)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(copiedTexts, <String>['saved note']);
    // Row actions stay in the list.
    expect(find.byType(BottomSheet), findsNothing);
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.content_copy_rounded), findsWidgets);
  });

  testWidgets('reveals a distant match and copies the exact full message', (
    tester,
  ) async {
    final content =
        '${'开头 👨‍👩‍👧‍👦 ' * 80}\nNeedle 🧑🏽‍💻\n  preserve spacing';
    final message = await database.insertMessageReturning(
      _message(content, timestamp: 4),
    );
    await _pumpPage(tester, database, copiedTexts);
    await _search(tester, 'NEEDLE');
    final previewFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.textSpan?.toPlainText().startsWith('…Needle') == true,
    );
    expect(previewFinder, findsOneWidget);
    final preview = tester.widget<Text>(previewFinder);
    final spans = (preview.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(
      spans.any(
        (span) => span.text == 'Needle' && span.style?.backgroundColor != null,
      ),
      isTrue,
    );
    await tester.tap(find.byKey(transferAssistantMessageCopyKey(message.id)));
    await tester.pumpAndSettle();
    expect(copiedTexts.single, content);
    await tester.tap(previewFinder);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(find.byType(SelectableText))
          .textSpan!
          .toPlainText(),
      content,
    );
    final copy = find.byKey(transferAssistantMessageCopyKey(message.id));
    await tester.ensureVisible(copy);
    await tester.pumpAndSettle();
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copiedTexts, <String>[content, content]);
    final collapse = find.byTooltip('Collapse message');
    await tester.ensureVisible(collapse);
    await tester.pumpAndSettle();
    await tester.tap(collapse);
    await tester.pumpAndSettle();
    expect(previewFinder, findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a failed row copy shows an error and can be retried', (
    tester,
  ) async {
    var attempts = 0;
    await _pumpPage(
      tester,
      database,
      copiedTexts,
      copyText: (text) async {
        attempts++;
        if (attempts == 1) throw StateError('clipboard unavailable');
        copiedTexts.add(text);
      },
    );
    final copy = find.byKey(
      transferAssistantMessageCopyKey(searchableMessage.id),
    );
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(find.text("Couldn't copy text"), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copiedTexts, <String>['old needle text']);
    expect(find.text("Couldn't copy text"), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('empty history has one empty state and a reversible filter', (
    tester,
  ) async {
    await _pumpPage(tester, database, copiedTexts, peerId: 'empty-peer');
    expect(find.text('No text messages yet'), findsOneWidget);
    expect(find.text('No favorite texts yet'), findsNothing);
    await tester.tap(find.byKey(transferAssistantFavoritesFilterKey));
    await tester.pumpAndSettle();
    expect(find.text('No text messages yet'), findsNothing);
    expect(find.text('No favorite texts yet'), findsOneWidget);
    await tester.tap(find.text('All messages'));
    await tester.pumpAndSettle();
    expect(find.text('No text messages yet'), findsOneWidget);
  });

  testWidgets('a failed favorite restores the row state and allows retry', (
    tester,
  ) async {
    await _pumpPage(tester, database, copiedTexts);
    database.failFavorite = true;
    final favorite = find.byKey(
      transferAssistantMessageFavoriteKey(searchableMessage.id),
    );
    await tester.tap(favorite);
    await tester.pumpAndSettle();
    expect(find.text("Couldn't update favorites. Try again"), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    database.failFavorite = false;
    await tester.tap(favorite);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      (await database.fetchFavoriteTextsForPeer(
        'peer-a',
      )).map((item) => item.sourceMessageId),
      contains(searchableMessage.id),
    );
  });

  for (final locale in <String>['zh', 'en', 'es']) {
    for (final dark in <bool>[false, true]) {
      testWidgets(
        '$locale ${dark ? 'dark' : 'light'} compact and landscape with large text',
        (tester) async {
          await database.insertMessageReturning(
            _message(
              'A long message with several lines of content. ' * 15,
              timestamp: 4,
            ),
          );
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          for (final size in <Size>[
            const Size(320, 640),
            const Size(740, 360),
          ]) {
            tester.view.physicalSize = size;
            await _pumpPage(
              tester,
              database,
              copiedTexts,
              locale: Locale(locale),
              dark: dark,
              textScale: 1.8,
              disableAnimations: true,
            );
            expect(tester.takeException(), isNull);
            final expand = find.byIcon(Icons.expand_more_rounded).first;
            await tester.tap(expand);
            await tester.pumpAndSettle();
            expect(find.byType(BottomSheet), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.tap(find.byIcon(Icons.expand_more_rounded).first);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }

  testWidgets(
    'keeps pending results visible but blocks stale actions through the fade',
    (tester) async {
      await _pumpPage(tester, database, copiedTexts);
      final gate = Completer<void>();
      database.searchGates['needle'] = gate;
      await tester.enterText(
        find.byKey(transferAssistantSearchFieldKey),
        'needle',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('latest note'), findsOneWidget);
      final staleCopy = find.byKey(
        transferAssistantMessageCopyKey(favoriteMessage.id),
      );
      await tester.tap(staleCopy, warnIfMissed: false);
      await tester.pump();
      expect(copiedTexts, isEmpty);
      gate.complete();
      final newList = find.byKey(
        const ValueKey<(bool, String)>((false, 'needle')),
      );
      for (var i = 0; i < 8 && newList.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(newList, findsOneWidget);
      expect(find.text('latest note'), findsOneWidget);
      await tester.tap(staleCopy, warnIfMissed: false);
      await tester.pump();
      expect(copiedTexts, isEmpty);
      await tester.pumpAndSettle();
      expect(find.text('latest note'), findsNothing);
      expect(find.text('old needle text'), findsOneWidget);
    },
  );

  testWidgets(
    'rapid queries ignore an older response after the new result appears',
    (tester) async {
      await _pumpPage(tester, database, copiedTexts);
      final gate = Completer<void>();
      database.searchGates['needle'] = gate;
      await tester.enterText(
        find.byKey(transferAssistantSearchFieldKey),
        'needle',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await _search(tester, 'latest');
      expect(find.text('latest note'), findsOneWidget);
      expect(find.text('old needle text'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('latest note'), findsOneWidget);
      expect(find.text('old needle text'), findsNothing);
    },
  );

  testWidgets('reduced motion preserves filter, favorite and copy feedback', (
    tester,
  ) async {
    await _pumpPage(tester, database, copiedTexts, disableAnimations: true);
    await tester.tap(
      find.byKey(transferAssistantMessageFavoriteKey(searchableMessage.id)),
    );
    await tester.pumpAndSettle();
    expect(
      (await database.fetchFavoriteTextsForPeer(
        'peer-a',
      )).map((item) => item.sourceMessageId),
      contains(searchableMessage.id),
    );
    await tester.tap(find.byKey(transferAssistantFavoritesFilterKey));
    await tester.pumpAndSettle();
    expect(find.text('latest note'), findsNothing);
    await tester.tap(
      find.byKey(transferAssistantFavoriteCopyKey(searchableMessage.id)),
    );
    await tester.pump();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(copiedTexts, <String>['old needle text']);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('search with an open keyboard keeps empty results scrollable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    await _pumpPage(tester, database, copiedTexts, textScale: 1.6);
    await _search(tester, 'nothing-matches');
    expect(find.text('No matching text found'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -100),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(transferAssistantSearchFieldKey), text);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

Future<void> _pumpPage(
  WidgetTester tester,
  LocalDatabase database,
  List<String> copiedTexts, {
  String peerId = 'peer-a',
  Locale locale = const Locale('en'),
  bool dark = false,
  double textScale = 1,
  bool disableAnimations = false,
  Future<void> Function(String)? copyText,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: TransferAssistantScreen(
        peerId: peerId,
        peerName: 'Peer A',
        database: database,
        copyText: copyText ?? (text) async => copiedTexts.add(text),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

MessageData _message(String content, {required int timestamp}) {
  return MessageData(
    id: 0,
    sender: 'peer-a',
    receiver: 'local',
    name: '',
    clipboard: false,
    size: 0,
    type: MessageEnum.Text,
    content: content,
    message: '',
    timestamp: timestamp,
    uuid: 'message-$timestamp',
    acked: true,
    path: '',
    md5: '',
  );
}

class _TestDatabase extends LocalDatabase {
  _TestDatabase() : super.forTesting(NativeDatabase.memory());

  bool failFavorite = false;
  final Map<String, Completer<void>> searchGates = <String, Completer<void>>{};

  @override
  Future<List<TextMessageSearchResult>> searchTextMessagesForPeer(
    String peerUid, {
    String query = '',
    int beforeId = 0,
    int limit = 100,
  }) async {
    final results = await super.searchTextMessagesForPeer(
      peerUid,
      query: query,
      beforeId: beforeId,
      limit: limit,
    );
    await searchGates[query]?.future;
    return results;
  }

  @override
  Future<void> favoriteTextMessage(
    MessageData source, {
    required String peerUid,
  }) {
    if (failFavorite) {
      return Future<void>.error(StateError('favorite unavailable'));
    }
    return super.favoriteTextMessage(source, peerUid: peerUid);
  }
}
