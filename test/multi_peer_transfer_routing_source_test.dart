import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v3 transfer controls route to the transfer peer', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('void _sendFileTransferV3ControlTo('));
    expect(source,
        contains('_sendFileTransferV3ControlTo(\n      transfer.peerUid'));
    expect(source,
        contains('_sendFileTransferV3ControlTo(\n        message.sender'));
    expect(source, contains('_sendFileTransferV3Ready(item.transferId)'));
  });

  test('v3 transfer offers route to the transfer peer', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('void _sendFileTransferV3OfferTo('));
    expect(source, contains('_sendFileTransferV3OfferTo(peerId, message)'));
    expect(
        source, contains('_sendFileTransferV3OfferTo(item.peerUid, message)'));
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

  test('peer disconnect marks only that peer transfers waiting reconnect', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('_markPeerTransfersWaitingReconnect(peerId)'));
    expect(source, contains('_transferRuntime.clearPeer(peerId)'));
    expect(
      source,
      contains('fetchRecoverableFileTransfersForPeer(\n      peerId'),
    );
    expect(source, contains('FileTransferState.waitingReconnect'));
  });

  test('legacy raw resumable payload state is scoped by peer stream', () {
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
