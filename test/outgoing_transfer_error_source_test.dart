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
    final source =
        File('lib/socket/file_transfer_engine.dart').readAsStringSync();
    final handleReady = methodBody(
      source,
      'Future<void> _handleFileTransferV3Ready(',
      'Future<void> _failOutgoingFileTransferV3(',
    );
    final failHelper = methodBody(
      source,
      'Future<void> _handleOutgoingTransferError(',
      'Future<void> _failStaleIncomingQueueEntry(',
    );

    expect(handleReady, contains('_handleOutgoingTransferError'));
    expect(failHelper, contains('FileTransferState.failed'));
    expect(failHelper, contains('_releaseOutgoingAndStartNext('));
    expect(failHelper, isNot(contains('onError(')));
  });
}
