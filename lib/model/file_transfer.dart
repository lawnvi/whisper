import 'package:drift/drift.dart';

enum FileTransferDirection {
  incoming,
  outgoing,
}

enum FileTransferState {
  queued,
  negotiating,
  transferring,
  waitingReconnect,
  paused,
  verifying,
  completed,
  failed,
  canceled,
}

bool isTerminalFileTransferState(FileTransferState state) {
  return state == FileTransferState.completed ||
      state == FileTransferState.failed ||
      state == FileTransferState.canceled;
}

FileTransferState? stateAfterTransferProgress({
  required FileTransferState currentState,
  required int committedBytes,
  required int size,
}) {
  if (isTerminalFileTransferState(currentState)) {
    return null;
  }
  return committedBytes >= size
      ? FileTransferState.verifying
      : FileTransferState.transferring;
}

class FileTransfer extends Table {
  TextColumn get transferId => text().named('transfer_id')();
  TextColumn get messageUuid => text().named('message_uuid')();
  TextColumn get peerUid => text().named('peer_uid')();
  TextColumn get direction =>
      textEnum<FileTransferDirection>().named('direction')();
  TextColumn get state => textEnum<FileTransferState>().named('state')();
  TextColumn get finalPath => text().named('final_path')();
  TextColumn get tempPath => text().named('temp_path')();
  IntColumn get size => integer().withDefault(const Constant(0))();
  TextColumn get checksumAlgorithm =>
      text().named('checksum_algorithm').withDefault(const Constant(''))();
  TextColumn get checksumValue =>
      text().named('checksum_value').withDefault(const Constant(''))();
  IntColumn get chunkSize => integer().named('chunk_size')();
  IntColumn get committedBytes =>
      integer().named('committed_bytes').withDefault(const Constant(0))();
  TextColumn get lastError =>
      text().named('last_error').withDefault(const Constant(''))();
  IntColumn get createdAt => integer().named('created_at')();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column<Object>> get primaryKey => {transferId};
}

class TransferSnapshot {
  const TransferSnapshot({
    required this.transferId,
    required this.messageUuid,
    required this.peerUid,
    required this.direction,
    required this.state,
    required this.finalPath,
    required this.tempPath,
    required this.size,
    required this.committedBytes,
    required this.lastError,
    required this.updatedAt,
  });

  final String transferId;
  final String messageUuid;
  final String peerUid;
  final FileTransferDirection direction;
  final FileTransferState state;
  final String finalPath;
  final String tempPath;
  final int size;
  final int committedBytes;
  final String lastError;
  final int updatedAt;

  double get progress {
    if (size <= 0) {
      return 0;
    }
    return committedBytes / size;
  }
}
