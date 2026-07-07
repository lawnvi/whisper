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
      'void _sendMessageData(',
      'void _dispatchOutgoingMessage',
    );

    expect(sendMessageData, contains('WhisperFrameV3('));
    expect(sendMessageData, contains('WhisperFrameType.message'));
    expect(sendMessageData, contains('.encode()'));
  });

  test('incoming websocket bytes dispatch WhisperFrameV3 before legacy parsing',
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
      listen.indexOf('WhisperFrameV3.looksLikeFrame(data)'),
      lessThan(listen.indexOf('TransferChunkFrame.looksLikeFrame(data)')),
    );
  });

  test('sendFileTo requires v3 and sends a file offer frame', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final sendFileTo = methodBody(
      source,
      'Future<bool> sendFileTo(String peerId, String path)',
      'Future<bool> sendAndroidContentUriTo(',
    );

    expect(sendFileTo, contains('_supportsFileTransferV3For(peerId)'));
    expect(sendFileTo, contains('_sendFileTransferV3OfferTo(peerId, message)'));
    expect(sendFileTo,
        isNot(contains('_sendMessageData(message, peerId: peerId)')));
    expect(sendFileTo, isNot(contains('protocolVersion: 2')));
  });

  test('v3 file data path does not use raw payload continuation frames', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final sendWindow = methodBody(
      source,
      'Future<void> _sendFileTransferV3Window(',
      'Future<void> _handleFileTransferV3Data',
    );

    expect(sendWindow, contains('WhisperFrameType.fileData'));
    expect(sendWindow, contains('fileTransferV3FramePayloadSize'));
    expect(sendWindow, isNot(contains('payloadInNextFrame')));
    expect(sendWindow, isNot(contains('TransferChunkFrame(')));
  });

  test('v3 outgoing send uses sliding window credit from durable acks', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final sendWindow = methodBody(
      source,
      'Future<void> _sendFileTransferV3Window(',
      'Future<void> _handleFileTransferV3Data',
    );
    final handleAck = methodBody(
      source,
      'Future<void> _handleFileTransferV3Ack',
      'Future<void> _startQueuedOutgoingFileTransferV3',
    );

    expect(
      sendWindow,
      contains('durableOffset + fileTransferV3WindowSize'),
    );
    expect(
      sendWindow,
      contains('_outgoingWindowEndOffsets[transfer.transferId] ??'),
    );
    expect(handleAck, contains('_sendFileTransferV3WindowSafely('));
    expect(
      handleAck,
      isNot(contains('durableOffset < windowEnd')),
    );
  });

  test('v3 outgoing file sender yields between data frames', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final sendWindow = methodBody(
      source,
      'Future<void> _sendFileTransferV3Window(',
      'Future<void> _handleFileTransferV3Data',
    );

    expect(source, contains('Future<void> _yieldAfterFileTransferFrame()'));
    expect(sendWindow, contains('await _yieldAfterFileTransferFrame();'));
    expect(
      sendWindow.indexOf('await _yieldAfterFileTransferFrame();'),
      greaterThan(sendWindow.indexOf('_sendFileTransferV3FrameTo(')),
    );
  });

  test('v3 incoming file data acks before the full send window', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final handleData = methodBody(
      source,
      'Future<void> _handleFileTransferV3Data',
      'Future<void> _handleIncomingFileTransferV3Error',
    );

    expect(handleData, contains('fileTransferV3AckIntervalSize'));
    expect(
      handleData.indexOf('fileTransferV3AckIntervalSize'),
      lessThan(handleData.lastIndexOf('_sendFileTransferV3Ack(')),
    );
    expect(
      handleData,
      isNot(contains('>= fileTransferV3WindowSize')),
    );
  });

  test('queued incoming v3 transfers resume from transfer metadata', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final startNext = methodBody(
      source,
      'Future<void> _startNextQueuedIncomingTransfer',
      'Future<void> _markRecoverableTransfersWaitingReconnect',
    );

    expect(startNext, contains('_fileTransferUsesV3(item)'));
    expect(
      startNext,
      isNot(contains('_supportsFileTransferV3For(item.peerUid)')),
    );
  });

  test('v3 complete starts the next queued outgoing transfer', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final handleComplete = methodBody(
      source,
      'Future<void> _handleFileTransferV3Complete',
      'Future<void> _handleFileTransferV3Cancel',
    );

    expect(handleComplete, contains('String? nextTransferId'));
    expect(
      handleComplete,
      contains('await _startQueuedOutgoingFileTransferV3(nextTransferId)'),
    );
  });

  test('v3 incoming file data uses awaited random access writes', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final handleData = methodBody(
      source,
      'Future<void> _handleFileTransferV3Data',
      'void _dispatchTransferProgress',
    );

    expect(source, contains('_receivingTransferWritersV3'));
    expect(handleData, contains('await writer.writeFrom(frame.payload)'));
    expect(handleData, isNot(contains('openWrite(mode: FileMode.append)')));
  });

  test('v3 transfer failures do not bubble into connection errors', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final frameHandler = methodBody(
      source,
      'Future<void> _handleWhisperFrameV3',
      'Future<void> _listen(',
    );
    final incomingError = methodBody(
      source,
      'Future<void> _handleIncomingFileTransferV3Error',
      'String _incomingFileTransferV3ErrorMessage',
    );
    final failOutgoing = methodBody(
      source,
      'Future<void> _failOutgoingFileTransferV3',
      'Future<void> _handleOutgoingFileTransferV3Error',
    );
    final outgoingError = methodBody(
      source,
      'Future<void> _handleOutgoingFileTransferV3Error',
      'String _outgoingFileTransferV3ErrorMessage',
    );

    expect(frameHandler, contains('_handleIncomingFileTransferV3Error'));
    expect(frameHandler, contains('_handleOutgoingFileTransferV3Error'));
    expect(incomingError, contains('FileTransferState.failed'));
    expect(incomingError, contains('FileTransferV3Action.error'));
    expect(failOutgoing, contains('FileTransferState.failed'));
    expect(failOutgoing, contains('FileTransferV3Action.error'));
    expect(incomingError, isNot(contains('onError(')));
    expect(failOutgoing, isNot(contains('onError(')));
    expect(outgoingError, isNot(contains('onError(')));
  });

  test('peer socket close cleanup is serialized behind received frames', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();
    final queuedDone = methodBody(
      source,
      'Future<void> _handlePeerSocketDoneQueued',
      'Future<void> _handlePeerSocketDone(',
    );
    final startServer = methodBody(
      source,
      'void startServer(',
      'Future<void> connectToServer(',
    );
    final connectToServer = methodBody(
      source,
      'Future<void> connectToServer(',
      'Future<void> closeGracefully(',
    );

    expect(queuedDone, contains('_receiveQueue = _receiveQueue.then'));
    expect(queuedDone, contains('await _handlePeerSocketDone(sink)'));
    expect(
        startServer, contains('_handlePeerSocketDoneQueued(webSocket.sink)'));
    expect(
        connectToServer, contains('_handlePeerSocketDoneQueued(channelSink)'));
    expect(
        startServer, isNot(contains('_handlePeerSocketDone(webSocket.sink)')));
    expect(connectToServer,
        isNot(contains('_handlePeerSocketDone(channel.sink)')));
  });
}
