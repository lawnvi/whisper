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

  late LocalDatabase database;
  late MessageData favoriteMessage;
  late MessageData searchableMessage;
  late List<String> copiedTexts;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      '_uuid': 'local',
    });
    database = LocalDatabase.forTesting(NativeDatabase.memory());
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

  testWidgets('shows favorites and recent text and copies a snapshot',
      (tester) async {
    await _pumpPage(tester, database, copiedTexts);

    expect(find.text('Transfer Assistant'), findsOneWidget);
    expect(find.text('Favorite texts'), findsOneWidget);
    expect(find.text('Recent texts'), findsOneWidget);
    expect(find.text('saved note'), findsNWidgets(2));

    await tester.tap(
      find.byKey(transferAssistantFavoriteCopyKey(favoriteMessage.id)),
    );
    await tester.pumpAndSettle();
    expect(copiedTexts, <String>['saved note']);
  });

  testWidgets('searches history and toggles favorites', (tester) async {
    await _pumpPage(tester, database, copiedTexts);

    await tester.enterText(
      find.byKey(transferAssistantSearchFieldKey),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Search results'), findsOneWidget);
    expect(find.text('old needle text'), findsOneWidget);
    expect(find.text('latest note'), findsNothing);

    await tester.tap(
      find.byKey(
        transferAssistantMessageFavoriteKey(searchableMessage.id),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (await database.fetchFavoriteTextsForPeer('peer-a'))
          .map((item) => item.sourceMessageId),
      contains(searchableMessage.id),
    );

    await tester.enterText(
      find.byKey(transferAssistantSearchFieldKey),
      '',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        transferAssistantFavoriteRemoveKey(searchableMessage.id),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (await database.fetchFavoriteTextsForPeer('peer-a'))
          .map((item) => item.sourceMessageId),
      isNot(contains(searchableMessage.id)),
    );
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  LocalDatabase database,
  List<String> copiedTexts,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.lightTheme,
      home: TransferAssistantScreen(
        peerId: 'peer-a',
        peerName: 'Peer A',
        database: database,
        copyText: (text) async => copiedTexts.add(text),
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
