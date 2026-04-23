import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/file_transfer.dart';

void main() {
  group('FileTransfer state machine', () {
    test('terminal states cannot be changed by late progress frames', () {
      for (final state in <FileTransferState>[
        FileTransferState.canceled,
        FileTransferState.failed,
        FileTransferState.completed,
      ]) {
        expect(
          stateAfterTransferProgress(
            currentState: state,
            committedBytes: 512,
            size: 1024,
          ),
          isNull,
        );
      }
    });

    test('active states advance to transferring or verifying', () {
      expect(
        stateAfterTransferProgress(
          currentState: FileTransferState.negotiating,
          committedBytes: 512,
          size: 1024,
        ),
        FileTransferState.transferring,
      );
      expect(
        stateAfterTransferProgress(
          currentState: FileTransferState.transferring,
          committedBytes: 1024,
          size: 1024,
        ),
        FileTransferState.verifying,
      );
    });
  });
}
