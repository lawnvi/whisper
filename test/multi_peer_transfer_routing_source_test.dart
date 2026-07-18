import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v3 transfer controls route to the transfer peer', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();

    expect(source, contains('Future<bool> _sendFileTransferV3ControlTo('));
    expect(
      source,
      contains('_sendFileTransferV3ControlTo(\n      transfer.peerUid'),
    );
    expect(
      source,
      contains('_sendFileTransferV3ControlTo(\n        transfer.peerUid'),
    );
    expect(
      source,
      isNot(contains('_sendFileTransferV3ControlTo(\n        message.sender')),
    );
    expect(
      source,
      contains(
        '_sendFileTransferV3Ready(\n'
        '              item.transferId,\n'
        '              connection: itemConnection,',
      ),
    );
  });

  test('v3 transfer offers route to the transfer peer', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();

    expect(source, contains('Future<bool> _sendFileTransferV3OfferTo('));
    expect(source, matches(RegExp(r'_sendFileTransferV3OfferTo\(\s*peerId,')));
    expect(
      source,
      matches(RegExp(r'_sendFileTransferV3OfferTo\(\s*item\.peerUid,')),
    );
    expect(source, contains('connection: connection'));
  });

  test('resumable transfer active state is tracked per peer', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();

    expect(source, contains('final MultiPeerTransferRuntime _transferRuntime'));
    expect(source, contains('_transferRuntime.activeIncomingFor('));
    expect(source, contains('_transferRuntime.activeOutgoingFor('));
    expect(source, contains('_transferRuntime.enqueue('));
    expect(source, isNot(contains('_activeOutgoingTransferId')));
    expect(source, isNot(contains('_receivingTransferId')));
  });

  test('peer disconnect marks only that peer transfers waiting reconnect', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();

    expect(source, contains('_markPeerTransfersWaitingReconnect(peerId)'));
    expect(source, contains('_transferRuntime.clearPeer(peerId)'));
    expect(
      source,
      contains('fetchRecoverableFileTransfersForPeer(\n      peerId'),
    );
    expect(source, contains('FileTransferState.waitingReconnect'));
  });
}
