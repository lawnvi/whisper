import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String methodBody(String source, String start, String next) {
    final startIndex = source.indexOf(start);
    expect(startIndex, isNonNegative, reason: 'Missing method $start');
    final endIndex = source.indexOf(next, startIndex);
    expect(endIndex, isNonNegative, reason: 'Missing next method $next');
    return source.substring(startIndex, endIndex);
  }

  test('outgoing file messages are dispatched locally before network ack', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final sendFileTo = methodBody(
      source,
      'Future<bool> sendFileTo(',
      'Future<bool> sendAndroidContentUriTo(',
    );
    final sendAndroidUri = methodBody(
      source,
      'Future<bool> sendAndroidContentUriTo(',
      'Future<bool> _persistAndOfferOutgoingTransfer(',
    );

    for (final body in [sendFileTo, sendAndroidUri]) {
      expect(body, contains('_persistAndOfferOutgoingTransfer('));
    }

    final persistAndOffer = methodBody(
      source,
      'Future<bool> _persistAndOfferOutgoingTransfer(',
      'bool _matchesStableOutgoingTransfer(',
    );
    final admissionIndex = persistAndOffer.indexOf(
      'await _database().admitFileTransfer(',
    );
    final dispatchIndex = persistAndOffer.indexOf(
      '_dispatchOutgoingMessage(message)',
    );
    final sendIndex = persistAndOffer.indexOf('_offerOnCurrentConnection(');

    expect(admissionIndex, isNonNegative);
    expect(dispatchIndex, greaterThan(admissionIndex));
    expect(sendIndex, greaterThan(dispatchIndex));
    expect(persistAndOffer.substring(sendIndex), contains('return true;'));
  });

  test('conversation updates an existing message with the same uuid', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final insertItem = methodBody(
      source,
      '_insertItem(index, item)',
      '_insertItems(index, items)',
    );

    expect(insertItem, contains('indexWhere'));
    expect(insertItem, contains('message.uuid == item.uuid'));
    expect(insertItem, contains('messageList[existingIndex] = item'));
    expect(insertItem, contains('key.currentState'));
    expect(insertItem, contains('insertItem(index'));
  });

  test('conversation animates transfer progress instead of jumping', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();

    expect(source, contains('_transferProgressAnimationDuration'));
    expect(source, contains('Widget _buildAnimatedTransferProgress'));
    expect(source, contains('TweenAnimationBuilder<double>'));

    final build = methodBody(
      source,
      'Widget build(BuildContext context)',
      'bool get _canSendCurrentDevice',
    );
    final fileMessage = methodBody(
      source,
      'Widget _buildFileMessage(',
      'void onPairing(',
    );

    expect(build, contains('_buildAnimatedTransferProgress('));
    expect(fileMessage, contains('_buildAnimatedTransferProgress('));
  });

  test('conversation animates visible transfer percentage text', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final fileStatus = methodBody(
      source,
      'String _fileStatusText(',
      'Future<void> _retryTransfer',
    );
    final headerActions = methodBody(
      source,
      'List<Widget> _buildHeaderActions',
      'String _audioShareTooltip',
    );
    final fileMessage = methodBody(
      source,
      'Widget _buildFileMessage(',
      'void onPairing(',
    );

    expect(fileStatus, contains('progressOverride'));
    expect(headerActions, contains('_buildAnimatedTransferProgress('));
    expect(fileMessage, contains('progressOverride: value'));
  });
}
