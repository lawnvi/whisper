import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('outgoing resumable chunks are self-contained websocket frames', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final sendNextTransferChunk = RegExp(
      r'Future<void> _sendNextTransferChunk[\s\S]*?Future<void> _handleTransferChunk',
    ).firstMatch(source)!.group(0)!;

    expect(sendNextTransferChunk, isNot(contains('payloadInNextFrame: true')));
    expect(sendNextTransferChunk, contains('TransferChunkFrame('));
    expect(sendNextTransferChunk,
        contains('offset: range.offset + rawRange.offset'));
    expect(sendNextTransferChunk, contains('payload: Uint8List.sublistView'));
    expect(sendNextTransferChunk, contains(').encode()'));
  });
}
