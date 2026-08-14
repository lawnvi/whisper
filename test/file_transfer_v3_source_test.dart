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

  test('peer profile advertises file transfer v3 capability', () {
    final profile = File('lib/state/peer_profile.dart').readAsStringSync();
    final socket = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(profile, contains('this.fileTransferV3 = false'));
    expect(profile, contains('final bool fileTransferV3'));
    expect(profile, contains("'fileTransferV3': fileTransferV3"));
    expect(socket, contains('fileTransferV3: true'));
  });

  test('main websocket messages are wrapped in WhisperFrameV3', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final sendMessageData = methodBody(
      source,
      'Future<bool> _sendMessageData(',
      'void _dispatchOutgoingMessage',
    );

    expect(sendMessageData, contains('WhisperFrameV3('));
    expect(sendMessageData, contains('WhisperFrameType.message'));
    expect(sendMessageData, contains('.encode()'));
  });

  test(
    'incoming websocket bytes dispatch WhisperFrameV3 before legacy parsing',
    () {
      final source = File('lib/socket/svrmanager.dart').readAsStringSync();
      final listen = methodBody(
        source,
        'Future<void> _listen(',
        'MessageData _buildMessage',
      );

      expect(listen, contains('WhisperFrameV3.looksLikeFrame(data)'));
      expect(listen, contains('_handleWhisperFrameV3('));
      expect(
        listen,
        isNot(contains('TransferChunkFrame.looksLikeFrame(data)')),
      );
    },
  );

  test('sendFileTo requires v3 and sends a file offer frame', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final sendFileTo = methodBody(
      source,
      'Future<bool> sendFileTo(',
      'Future<bool> sendAndroidContentUriTo(',
    );
    final persistAndOffer = methodBody(
      source,
      'Future<bool> _persistAndOfferOutgoingTransfer(',
      'bool _matchesStableOutgoingTransfer(',
    );

    expect(sendFileTo, contains('_supportsFileTransferV3For(peerId)'));
    expect(sendFileTo, contains('_persistAndOfferOutgoingTransfer('));
    expect(
      persistAndOffer,
      allOf(
        contains('_offerOnCurrentConnection('),
        contains('expectedPublicKeyHash: expectedPublicKeyHash'),
        contains('return true;'),
      ),
    );
    expect(
      sendFileTo,
      isNot(contains('_sendMessageData(message, peerId: peerId)')),
    );
    expect(sendFileTo, isNot(contains('protocolVersion: 2')));
  });

  test('v3 file data path does not use raw payload continuation frames', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final sendWindow = methodBody(
      source,
      'Future<int?> _sendFileTransferV3Window(',
      'Future<void> _handleFileTransferV3Data',
    );

    expect(sendWindow, contains('WhisperFrameType.fileData'));
    expect(sendWindow, contains('flow.chunkSize'));
    expect(sendWindow, isNot(contains('payloadInNextFrame')));
    expect(sendWindow, isNot(contains('TransferChunkFrame(')));
  });

  test('v3 outgoing send uses sliding window credit from durable acks', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final sendWindow = methodBody(
      source,
      'Future<int?> _sendFileTransferV3Window(',
      'Future<void> _handleFileTransferV3Data',
    );
    final handleAck = methodBody(
      source,
      'Future<void> _handleFileTransferV3Ack',
      'Future<void> _releaseOutgoingAndStartNext',
    );

    expect(sendWindow, contains('durableOffset + flow.windowSize'));
    expect(
      sendWindow,
      contains('_outgoingWindowEndOffsets[transfer.transferId] ??'),
    );
    expect(handleAck, contains('_sendFileTransferV3WindowSafely('));
    expect(handleAck, isNot(contains('durableOffset < windowEnd')));
  });

  test('v3 outgoing file sender yields between data frames', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final sendWindow = methodBody(
      source,
      'Future<int?> _sendFileTransferV3Window(',
      'Future<void> _handleFileTransferV3Data',
    );

    expect(source, contains('Future<void> _yieldAfterFileTransferFrame()'));
    expect(sendWindow, contains('await _yieldAfterFileTransferFrame();'));
    expect(
      sendWindow.indexOf('await _yieldAfterFileTransferFrame();'),
      greaterThan(sendWindow.indexOf('_sendFileTransferV3FrameTo(')),
    );
  });

  test('v3 outgoing file data uses an in-place authenticated buffer', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final sendWindow = methodBody(
      source,
      'Future<int?> _sendFileTransferV3Window(',
      'Future<_OutgoingChecksumState> _outgoingChecksumStateFor',
    );

    expect(sendWindow, contains('AuthenticatedPayloadBuffer.allocate('));
    expect(sendWindow, contains('readTransferSourceRangeInto('));
    expect(sendWindow, contains('_sendPreparedFileTransferV3FrameTo('));
    expect(sendWindow, isNot(contains('source.readRange(cursor, length)')));
    expect(
      sendWindow.indexOf('checksumState.checksum.add(payload)'),
      lessThan(sendWindow.indexOf('_sendPreparedFileTransferV3FrameTo(')),
    );
  });

  test('v3 incoming file data acks before the full send window', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final handleData = methodBody(
      source,
      'Future<void> _handleFileTransferV3Data',
      'Future<void> _handleIncomingFileTransferV3Error',
    );

    expect(handleData, contains('ackIntervalSize'));
    expect(
      handleData.indexOf('ackIntervalSize'),
      lessThan(handleData.lastIndexOf('_sendFileTransferV3Ack(')),
    );
    expect(handleData, isNot(contains('>= fileTransferV3WindowSize')));
  });

  test(
    'queued incoming transfers always resume via v3 (WSP2 stack removed)',
    () {
      final source = File(
        'lib/socket/file_transfer_engine.dart',
      ).readAsStringSync();
      final startNext = methodBody(
        source,
        'Future<void> _startNextQueuedIncomingTransfer',
        'Future<void> _markRecoverableTransfersWaitingReconnect',
      );

      expect(
        startNext,
        allOf(
          contains('_sendFileTransferV3Ready('),
          contains('item.transferId'),
          contains('connection: itemConnection'),
        ),
      );
      expect(startNext, isNot(contains('_fileTransferUsesV3')));
      expect(
        startNext,
        isNot(contains('_supportsFileTransferV3For(item.peerUid)')),
      );
    },
  );

  test('v3 complete starts the next queued outgoing transfer', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final handleComplete = methodBody(
      source,
      'Future<void> _handleFileTransferV3Complete',
      'Future<void> _handleFileTransferV3Cancel',
    );

    expect(handleComplete, contains('await _releaseOutgoingAndStartNext('));
  });

  test('v3 incoming file data pipelines writes and drains before ACK', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final handleData = methodBody(
      source,
      'Future<void> _handleFileTransferV3Data',
      'void _dispatchTransferProgress',
    );

    expect(source, contains('_receivingTransferWritersV3'));
    expect(handleData, contains('writePipeline.add('));
    expect(source, contains('await _receivingWritePipelines['));
    expect(handleData, isNot(contains('openWrite(mode: FileMode.append)')));
  });

  test('v3 transfer failures do not bubble into connection errors', () {
    final source = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final frameHandler = methodBody(
      source,
      'Future<void> handleFrame(',
      'Future<void> handlePeerDisconnected(',
    );
    final incomingError = methodBody(
      source,
      'Future<void> _handleIncomingFileTransferV3Error',
      'void _dispatchTransferProgress(',
    );
    final failOutgoing = methodBody(
      source,
      'Future<void> _failOutgoingFileTransferV3',
      'Future<void> _handleOutgoingFileTransferV3Error',
    );
    final outgoingError = methodBody(
      source,
      'Future<void> _handleOutgoingFileTransferV3Error',
      'Future<int?> _sendFileTransferV3WindowSafely(',
    );

    expect(frameHandler, contains('_handleIncomingFileTransferV3Error'));
    expect(frameHandler, contains('_handleOutgoingFileTransferV3Error'));
    expect(incomingError, contains('FileTransferState.failed'));
    expect(incomingError, contains('FileTransferV3Action.error'));
    expect(failOutgoing, contains('FileTransferState.failed'));
    expect(failOutgoing, contains('FileTransferV3Action.error'));
    expect(outgoingError, contains('_failOutgoingFileTransferV3('));
    expect(incomingError, isNot(contains('onError(')));
    expect(failOutgoing, isNot(contains('onError(')));
    expect(outgoingError, isNot(contains('onError(')));
  });

  test('peer socket close cleanup drains its own received frames', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final queuedDone = methodBody(
      source,
      'Future<void> _handlePeerSocketDoneQueued',
      'Future<void> _handlePeerSocketDone(',
    );
    final attachIncomingSocket = methodBody(
      source,
      'Future<void> _attachIncomingSocket(',
      'void _completeSocketAuth(',
    );
    final connectToServer = methodBody(
      source,
      'Future<ConnectionAttemptResult> connectToServer(',
      'Future<void> closeGracefully(',
    );

    expect(queuedDone, contains('stopReceivingAndDrain('));
    expect(queuedDone, contains('await _handlePeerSocketDone(sink)'));
    expect(attachIncomingSocket, contains('_attachSocketTransport('));
    expect(connectToServer, contains('_attachSocketTransport('));
    expect(
      attachIncomingSocket,
      isNot(contains('_handlePeerSocketDone(webSocket.sink)')),
    );
    expect(
      connectToServer,
      isNot(contains('_handlePeerSocketDone(channel.sink)')),
    );
    expect(source, isNot(contains('Future<void> _receiveQueue')));
  });
}
