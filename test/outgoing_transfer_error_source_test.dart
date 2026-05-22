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

  test('outgoing file source errors fail only the transfer', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final handleReady = methodBody(
      source,
      'Future<void> _handleReady(TransferControl control)',
      'Future<void> _handleRestart(TransferControl control)',
    );
    final sendSafely = methodBody(
      source,
      'Future<void> _sendNextTransferChunkSafely(',
      'Future<void> _handleOutgoingTransferError(',
    );
    final failHelper = methodBody(
      source,
      'Future<void> _handleOutgoingTransferError(',
      'String _outgoingTransferErrorMessage(',
    );

    expect(handleReady, contains('_handleOutgoingTransferError'));
    expect(handleReady, contains('_sendNextTransferChunkSafely'));
    expect(sendSafely, contains('_sendNextTransferChunk('));
    expect(sendSafely, contains('_handleOutgoingTransferError'));
    expect(failHelper, contains('FileTransferState.failed'));
    expect(failHelper, contains('_transferRuntime.complete'));
    expect(failHelper, contains('TransferAction.error'));
    expect(failHelper, isNot(contains('onError(')));
  });
}
