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

  test('only the sender controls paused transfers', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final fileMessage = methodBody(
      source,
      'Widget _buildFileMessage(',
      'void onPairing(',
    );
    final retryStart = fileMessage.indexOf('final showRetry =');
    final retryEnd = fileMessage.indexOf('final showCancel', retryStart);
    final retryPolicy = fileMessage.substring(retryStart, retryEnd);
    final cancelEnd = fileMessage.indexOf('final colorScheme', retryEnd);
    final cancelPolicy = fileMessage.substring(retryEnd, cancelEnd);

    expect(
      retryPolicy,
      contains('transfer.direction == FileTransferDirection.outgoing'),
    );
    expect(cancelPolicy, contains('FileTransferState.paused'));
    expect(cancelPolicy, contains('FileTransferState.waitingReconnect'));
  });

}
