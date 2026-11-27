part of 'file_transfer_engine.dart';

/// Recovery helpers for stalled or bulk-channel-dropped outgoing transfers.
extension FileTransferBulkRecovery on FileTransferEngine {
  /// Handles an unexpected `/transfer` `bulk` channel drop while `/chat`
  /// remains connected.
  ///
  /// Synchronously invalidates the active outgoing window pump so the in-flight
  /// send loop exits cleanly without throwing a fatal error, then schedules
  /// normal reconnect-retry (`waitingReconnect`) so both single-file and folder
  /// transfers resume safely from the receiver's durable offset.
  Future<void> handleBulkChannelDropped(TransferConnectionBinding connection) {
    final activeId = _transferRuntime.activeOutgoingFor(connection.peerId);
    if (activeId == null ||
        _outgoingConnectionBindings[activeId] != connection) {
      return Future<void>.value();
    }
    _outgoingStopRequests.add(activeId);
    _outgoingWindowPump.cancel(activeId);
    return _runTransferOperation<void>(
      activeId,
      connection: connection,
      operation: () async {
        if (_outgoingConnectionBindings[activeId] != connection ||
            _transferRuntime.activeOutgoingFor(connection.peerId) != activeId) {
          return;
        }
        final transfer = await _database().fetchFileTransfer(activeId);
        if (_outgoingConnectionBindings[activeId] != connection ||
            transfer == null ||
            transfer.direction != FileTransferDirection.outgoing ||
            isTerminalFileTransferState(transfer.state)) {
          return;
        }
        await _handleStalledOutgoingTransfer(transfer, connection);
      },
    );
  }

  Future<void> _handleStalledOutgoingTransfer(
    FileTransferData transfer,
    TransferConnectionBinding connection,
  ) async {
    // Keep the peer connection and other subsystems intact. Put only this
    // transfer into a recoverable state with automatic backoff retries so
    // transient weak-Wi-Fi stalls (including ephemeral pastes) resume from
    // the receiver's preserved partial bytes; fail only after consecutive
    // stalled retries make no durable progress.
    final scheduled = _timeoutRetries.scheduleRetry(
      transferId: transfer.transferId,
      peerId: transfer.peerUid,
      durableOffset: transfer.committedBytes,
      onRetry: () => _retryTimedOutTransfer(transfer.transferId, connection),
    );
    if (scheduled) {
      await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.waitingReconnect,
        lastError: '',
      );
      await _releaseOutgoingAndStartNext(
        transfer,
        connection: connection,
        startNext: false,
        clearTimeoutRetry: false,
      );
      return;
    }
    await _failOutgoingFileTransferV3(
      transfer,
      FileTransferFailureReason.receiver,
    );
  }

  Future<void> _retryTimedOutTransfer(
    String transferId,
    TransferConnectionBinding connection,
  ) async {
    final transfer = await _database().fetchFileTransfer(transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        transfer.state != FileTransferState.waitingReconnect ||
        !_isConnectedTo(transfer.peerUid)) {
      return;
    }
    await retryTransfer(transferId);
    final afterOffer = await _database().fetchFileTransfer(transferId);
    if (afterOffer != null &&
        afterOffer.state == FileTransferState.negotiating) {
      _timeoutRetries.scheduleOfferTimeout(
        transferId: transferId,
        delay: _ackWatchdog.timeout,
        onTimeout: () => _runTransferOperation<void>(
          transferId,
          connection: connection,
          operation: () async {
            final current = await _database().fetchFileTransfer(transferId);
            if (current == null ||
                current.direction != FileTransferDirection.outgoing ||
                current.state != FileTransferState.negotiating) {
              return;
            }
            await _handleStalledOutgoingTransfer(current, connection);
          },
        ),
      );
    }
  }
}
