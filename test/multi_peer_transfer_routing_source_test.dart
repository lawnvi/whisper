import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resumable transfer controls route to the transfer peer', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('void _sendTransferControlTo(String peerId'));
    expect(source, contains('_sendTransferControlTo(\n      transfer.peerUid'));
    expect(source, contains('_sendTransferControlTo(\n      updated.peerUid'));
    expect(source, contains('_sendTransferControlTo(\n          item.peerUid'));
  });

  test('resumable transfer chunks are written to the transfer peer socket', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final sendNextTransferChunk = RegExp(
      r'Future<void> _sendNextTransferChunk[\s\S]*?Future<void> _handleTransferChunk',
    ).firstMatch(source)!.group(0)!;

    expect(sendNextTransferChunk, contains('_sendBytesToPeer('));
    expect(sendNextTransferChunk, contains('transfer.peerUid'));
    expect(sendNextTransferChunk, isNot(contains('_sink?.add(')));
  });

  test('resumable transfer active state is tracked per peer', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('final MultiPeerTransferRuntime _transferRuntime'));
    expect(source, contains('_transferRuntime.activeIncomingFor('));
    expect(source, contains('_transferRuntime.activeOutgoingFor('));
    expect(source, contains('_transferRuntime.enqueue('));
    expect(source, isNot(contains('_activeOutgoingTransferId')));
    expect(source, isNot(contains('_receivingTransferId')));
  });

  test('raw resumable payload state is scoped by peer stream', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final listen = RegExp(
      r'Future<void> _listen[\s\S]*?Future<void> _freeIoSink',
    ).firstMatch(source)!.group(0)!;

    expect(source, contains('_pendingIncomingChunkHeadersByPeer'));
    expect(source, contains('_pendingIncomingRawRemainingByPeer'));
    expect(listen, contains('final streamPeerKey = _streamPeerKey(sink)'));
    expect(listen, contains('_supportsResumableTransferFor(streamPeerId)'));
  });
}
