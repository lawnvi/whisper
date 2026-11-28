part of 'file_transfer_engine.dart';

/// How the sender takes a receiver's ACK of a file transfer.
extension FileTransferOutgoingAck on FileTransferEngine {
  Future<void> _handleFileTransferV3Ack(
    FileTransferV3Control control, {
    required void Function() requireCurrent,
  }) async {
    final connection = _operationConnectionBindings[control.transferId];
    final transfer = await _database().fetchFileTransfer(control.transferId);
    requireCurrent();
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final currentWindow = _ackWatchdog.currentWindow(control.transferId);
    if (currentWindow == null &&
        connection != null &&
        connection.peerId == transfer.peerUid &&
        (transfer.state == FileTransferState.waitingReconnect ||
            transfer.state == FileTransferState.negotiating)) {
      // Late in-flight ACK (e.g. a folder receiver's keep-alive) arriving
      // while this transfer is backing off or re-negotiating; ignore without
      // tearing down the peer connection.
      return;
    }
    if (currentWindow == null &&
        transfer.state == FileTransferState.verifying &&
        control.durableOffset == transfer.committedBytes) {
      return;
    }
    if (currentWindow == null &&
        connection != null &&
        connection.peerId == transfer.peerUid &&
        _outgoingConnectionBindings[transfer.transferId] == connection &&
        _transferRuntime.activeOutgoingFor(transfer.peerUid) ==
            transfer.transferId &&
        transfer.state == FileTransferState.transferring) {
      // A round publishes its window only after its first frame is handed
      // over, and the receiver may answer that frame first: progress on this
      // connection, not a stale one.
      final sentEnd =
          _outgoingWindowEndOffsets[transfer.transferId] ??
          transfer.committedBytes;
      if (control.durableOffset < transfer.committedBytes ||
          control.durableOffset > sentEnd) {
        throw const WireInputRejected(WireInputReason.transferOffsetInvalid);
      }
      if (control.durableOffset == transfer.committedBytes) {
        return;
      }
    } else {
      if (connection == null ||
          currentWindow == null ||
          currentWindow.transferId != transfer.transferId ||
          currentWindow.connection != connection ||
          currentWindow.connection.peerId != transfer.peerUid) {
        throw const WireInputRejected(WireInputReason.sessionNotCurrent);
      }
      // The window ends at what was sent when it was published; a frame
      // handed over since may already be answered.
      final sentEnd = math.max(
        currentWindow.sentEnd,
        _outgoingWindowEndOffsets[transfer.transferId] ?? 0,
      );
      if (control.durableOffset < transfer.committedBytes ||
          control.durableOffset > sentEnd) {
        throw const WireInputRejected(WireInputReason.transferOffsetInvalid);
      }
      if (!_ackWatchdog.acknowledge(currentWindow)) {
        throw const WireInputRejected(WireInputReason.sessionNotCurrent);
      }
    }
    final durableOffset = control.durableOffset;
    _timeoutRetries.noteProgress(transfer.transferId, durableOffset);
    _outgoingProgress.onAck(transfer.transferId, durableOffset);
    final pacer = _outgoingPacerFor?.call(transfer.transferId);
    pacer?.acknowledged(
      transfer.transferId,
      durableOffset,
      interval: _isFolderTransfer(transfer)
          ? null
          : _outgoingFlows[transfer.transferId]?.ackIntervalSize,
      size: transfer.size,
      since: transfer.committedBytes,
    );
    if (durableOffset >= transfer.size) {
      pacer?.forget(transfer.transferId);
      _outgoingProgress.untrack(transfer.transferId);
    }
    final updated = await _updateTransfer(
      transfer.transferId,
      state: durableOffset >= transfer.size
          ? FileTransferState.verifying
          : FileTransferState.transferring,
      committedBytes: durableOffset,
      lastError: '',
    );
    if (updated == null) {
      return;
    }
    if (durableOffset >= updated.size) {
      _outgoingWindowEndOffsets.remove(control.transferId);
      _outgoingProgress.untrack(control.transferId);
      final message = await _database().fetchAssociatedFileTransferMessage(
        updated,
      );
      requireCurrent();
      if (message != null) {
        await _sendOutgoingFileVerification(updated, message);
      }
      return;
    }
    final message = await _database().fetchAssociatedFileTransferMessage(
      updated,
    );
    if (message == null) {
      return;
    }
    final sentEnd =
        _outgoingWindowEndOffsets[updated.transferId] ?? durableOffset;
    if (sentEnd > durableOffset) {
      _armOutgoingAckWatchdog(
        transfer: updated,
        message: message,
        connection: connection,
        durableOffset: durableOffset,
        sentEnd: sentEnd,
      );
    }
    _outgoingWindowPump.schedule((
      transfer: updated,
      message: message,
      offset: durableOffset,
    ));
  }

  TransferAckWindow _publishOutgoingAckWindow({
    required FileTransferData transfer,
    required MessageData message,
    required TransferConnectionBinding connection,
    required int durableOffset,
    required int sentEnd,
  }) {
    return _ackWatchdog.publishWindow(
      transferId: transfer.transferId,
      connection: connection,
      durableOffset: durableOffset,
      sentEnd: sentEnd,
      retransmit: (timeout) => _retransmitTimedOutWindow(timeout, message),
      markUnresponsive: _markTimedOutTransferUnresponsive,
    );
  }

  void _armOutgoingAckWatchdog({
    required FileTransferData transfer,
    required MessageData message,
    required TransferConnectionBinding connection,
    required int durableOffset,
    required int sentEnd,
  }) {
    _ackWatchdog.armWindow(
      transferId: transfer.transferId,
      connection: connection,
      durableOffset: durableOffset,
      sentEnd: sentEnd,
      retransmit: (timeout) => _retransmitTimedOutWindow(timeout, message),
      markUnresponsive: _markTimedOutTransferUnresponsive,
      quietLimit: _isFolderTransfer(transfer) ? _folderQuietLimit : null,
    );
  }
}
