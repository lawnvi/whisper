import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'completed incoming transfer refreshes the visible message final path',
    () {
      final source = File('lib/page/conversation.dart').readAsStringSync();
      final start = source.indexOf(
        'void onTransferUpdated(TransferSnapshot snapshot)',
      );
      expect(start, isNonNegative);
      final body = source.substring(start);

      // completeIncomingFileTransfer updates message.path in Drift, but the
      // conversation keeps its own MessageData list. The completion event must
      // apply the published path to that in-memory message as well.
      expect(body, contains('snapshot.state == FileTransferState.completed'));
      expect(body, contains('snapshot.finalPath.isNotEmpty'));
      expect(body, contains('snapshot.messageUuid'));
      expect(body, contains('copyWith('));
      expect(body, contains('path: snapshot.finalPath'));
    },
  );

  test(
    'snapshot reload cannot replace newer state and also publishes path',
    () {
      final source = File('lib/page/conversation.dart').readAsStringSync();
      final start = source.indexOf(
        'Future<void> _loadTransferSnapshotsForMessages',
      );
      final end = source.indexOf('void _loadMessages()', start);
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(body, contains('current.updatedAt > snapshot.updatedAt'));
      expect(body, contains('snapshot.state == FileTransferState.completed'));
      expect(body, contains('path: snapshot.finalPath'));
    },
  );
}
