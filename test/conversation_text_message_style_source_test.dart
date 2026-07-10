import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text message body font size is slightly toned down', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final textMessageBuilder = RegExp(
      r'Widget _buildTextMessage\([\s\S]*?Widget _buildFileMessage',
    ).firstMatch(source)!.group(0)!;

    expect(textMessageBuilder, isNot(contains('isDesktop() ? 17 : 16.5')));
    expect(textMessageBuilder, contains('fontSize: isDesktop() ? 16.5 : 16'));
    expect(textMessageBuilder, contains('height: 1.55'));
  });

  test('text and notification messages keep the native selection menu', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final textMessageBuilder = RegExp(
      r'Widget _buildTextMessage\([\s\S]*?Widget _buildFileMessage',
    ).firstMatch(source)!.group(0)!;

    expect(textMessageBuilder, contains('chatMessageDisplayText(messageData)'));
    expect(textMessageBuilder, contains('SelectableText('));
    expect(textMessageBuilder, contains('contextMenuBuilder:'));
    expect(textMessageBuilder, contains('buildChatTextSelectionToolbar('));
    expect(textMessageBuilder, isNot(contains('children: const []')));
  });

  test('message surfaces use restrained radius and responsive max widths', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final textMessageBuilder = RegExp(
      r'Widget _buildTextMessage\([\s\S]*?Widget _buildFileMessage',
    ).firstMatch(source)!.group(0)!;
    final fileMessageBuilder = RegExp(
      r'Widget _buildFileMessage\([\s\S]*?void onPairing',
    ).firstMatch(source)!.group(0)!;

    expect(textMessageBuilder, contains('640'));
    expect(textMessageBuilder, contains('0.82'));
    expect(textMessageBuilder, contains('TextPainter('));
    expect(textMessageBuilder, contains('width: bubbleWidth'));
    expect(
        textMessageBuilder, contains('final outerPadding = EdgeInsets.only('));
    expect(
      textMessageBuilder,
      isNot(contains(
        'alignment: isOpponent ? Alignment.centerLeft : Alignment.centerRight',
      )),
    );
    expect(textMessageBuilder, contains('BorderRadius.circular(8)'));
    expect(fileMessageBuilder, contains('BorderRadius.circular(8)'));
    expect(fileMessageBuilder, contains('return LayoutBuilder('));
    expect(fileMessageBuilder, contains('final cardWidth ='));
    expect(fileMessageBuilder, contains('final compact = cardWidth < 260;'));
    expect(fileMessageBuilder, contains('if (compact && actions.isNotEmpty)'));
  });

  test('first live message rebuilds the empty conversation before animating',
      () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final insertItem = RegExp(
      r'_insertItem\(index, item\) \{[\s\S]*?_insertItems\(index, items\)',
    ).firstMatch(source)!.group(0)!;
    final insertItems = RegExp(
      r'_insertItems\(index, items\) \{[\s\S]*?TransferSnapshot\?',
    ).firstMatch(source)!.group(0)!;

    for (final entry in <(String, String, String)>[
      (
        insertItem,
        'messageList.insert(index, item)',
        'listState?.insertItem(',
      ),
      (
        insertItems,
        'messageList.insertAll(insertionIndex, uniqueItems)',
        'listState?.insertAllItems(',
      ),
    ]) {
      final (method, mutation, animation) = entry;
      expect(method, contains('final listState = key.currentState'));
      expect(method, contains('setState'));
      expect(method.indexOf(mutation), isNonNegative);
      expect(method.indexOf(animation), greaterThan(method.indexOf(mutation)));
    }
  });

  test('deletion updates group data before AnimatedList builds its removal',
      () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final deleteItem = RegExp(
      r'_deleteItem\(id\) \{[\s\S]*?LocalDatabase\(\)\.deleteMessage',
    ).firstMatch(source)!.group(0)!;

    final mutationIndex = deleteItem.indexOf('messageList.removeAt(index)');
    final animationIndex = deleteItem.indexOf('listState?.removeItem(');
    expect(mutationIndex, isNonNegative);
    expect(animationIndex, isNonNegative);
    expect(mutationIndex, lessThan(animationIndex));
    expect(deleteItem, contains('setState'));
  });

  test('conversation imports shared dialogs and awaits disconnect confirmation',
      () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    expect(source,
        isNot(contains("import 'package:whisper/page/deviceList.dart'")));
    expect(
      source,
      contains(
        "import 'package:whisper/widget/app_dialogs.dart'",
      ),
    );
    expect(source, contains('show confirmAction, showLoadingDialog;'));
    final toggleConnection = RegExp(
      r'Future<void> _toggleConnection\(\) async \{[\s\S]*?Future<bool> _connectServer',
    ).firstMatch(source)!.group(0)!;
    expect(toggleConnection, isNot(contains('showConfirmationDialog(')));
    expect(toggleConnection, contains('await confirmAction('));
    expect(toggleConnection, contains('if (!confirmed || !mounted)'));
    expect(toggleConnection, contains('await socketManager.disconnectPeer'));

    final connectServer = RegExp(
      r'Future<bool> _connectServer[\s\S]*?Future<bool> _restoreConnectionIfNeeded',
    ).firstMatch(source)!.group(0)!;
    expect(
      connectServer.indexOf('if (!mounted)'),
      lessThan(connectServer.indexOf('final displayMessage')),
    );
  });

  test('initial load and pagination deduplicate UUIDs and serialize fetches',
      () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final insertItems = RegExp(
      r'_insertItems\(index, items\) \{[\s\S]*?TransferSnapshot\?',
    ).firstMatch(source)!.group(0)!;
    final scrollListener = RegExp(
      r'void _scrollListener\(\) async \{[\s\S]*?_insertItem\(index, item\)',
    ).firstMatch(source)!.group(0)!;

    expect(insertItems, contains('uniqueChatMessagesForInsertion('));
    expect(source, contains('bool _loadingOlderMessages = false;'));
    expect(
      scrollListener,
      contains('if (_loadingOlderMessages || messageList.isEmpty)'),
    );
    expect(scrollListener, contains('_loadingOlderMessages = true;'));
    expect(scrollListener, contains('finally'));
    expect(scrollListener, contains('_loadingOlderMessages = false;'));

    final initialLoad = RegExp(
      r'void _loadMessages\(\) async \{[\s\S]*?Future<void> _refreshCurrentDeviceState',
    ).firstMatch(source)!.group(0)!;
    expect(initialLoad, contains('_insertItems(messageList.length, arr);'));
    expect(initialLoad, isNot(contains('_insertItems(0, arr);')));
  });

  test('local messages dispatch the persisted database identity', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final sendText = RegExp(
      r'Future<bool> _sendText\([\s\S]*?// 获取设备横向宽度',
    ).firstMatch(source)!.group(0)!;

    expect(sendText, contains('insertMessageReturning(message)'));
    expect(sendText, contains('onMessage(persisted)'));
    expect(sendText, isNot(contains('onMessage(message)')));
  });
}
