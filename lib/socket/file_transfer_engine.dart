import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:whisper/helper/android_system_share.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/folder_transfer_stager.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/helper/parallel_streaming_checksum.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/authenticated_frame.dart';
import 'package:whisper/socket/file_path_policy.dart';
import 'package:whisper/socket/file_transfer_source.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_transfer_runtime.dart';
import 'package:whisper/socket/transfer_ack_watchdog.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/socket/wire_message_replay.dart';
import 'package:whisper/state/peer_profile.dart';

/// 与 svrmanager `_buildMessage` 现签名逐字对应(msg/fileName/path/uid/fileTimestamp 原本未标类型)。
typedef TransferMessageBuilder =
    MessageData Function(
      MessageEnum type,
      String content,
      dynamic msg,
      dynamic fileName,
      int size,
      bool clipboard, {
      String md5,
      dynamic path,
      dynamic uid,
      dynamic fileTimestamp,
      String? receiverOverride,
    });

final class _TransferOperationLaneEntry {
  final Lock lock = Lock();
  int users = 0;
}

final class _OutgoingChecksumState {
  _OutgoingChecksumState({required this.checksum, required this.offset});

  final ParallelStreamingChecksum checksum;
  int offset;
  bool closed = false;

  Future<String> finish({required int expectedOffset}) async {
    if (offset != expectedOffset) {
      throw StateError('Outgoing checksum has not covered the whole file');
    }
    closed = true;
    return checksum.close();
  }

  Future<void> dispose() async {
    if (closed) return;
    closed = true;
    await checksum.dispose();
  }
}

final class _IncomingWritePipeline {
  _IncomingWritePipeline({required this.writtenOffset});

  Future<void> _tail = Future<void>.value();
  Object? _error;
  StackTrace? _stackTrace;
  int writtenOffset;

  void add(
    RandomAccessFile writer,
    Uint8List payload, {
    required int endOffset,
  }) {
    _tail = _tail.then((_) async {
      if (_error != null) {
        return;
      }
      try {
        await writer.writeFrom(payload);
        writtenOffset = endOffset;
      } catch (error, stackTrace) {
        _error = error;
        _stackTrace = stackTrace;
      }
    });
  }

  Future<void> drain() async {
    await _tail;
    final error = _error;
    if (error != null) {
      Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
    }
  }
}

final class _TransferAdmissionRejected implements Exception {
  const _TransferAdmissionRejected(this.decision);

  final FileTransferAdmission decision;
}

enum _IncomingReadyResult { retained, sendFailed, unavailable }

enum FileTransferDiagnosticKind {
  outgoingFailed,
  incomingFailed,
  resumeResetDeferred,
  reservationCleanupFailed,
  completionDispatchFailed,
  temporaryFileCleanupFailed,
  visibilityNotificationFailed,
}

Future<void> _setFileLastModified(File file, int timestamp) {
  return file.setLastModified(DateTime.fromMillisecondsSinceEpoch(timestamp));
}

Future<ParallelStreamingChecksum> _parallelChecksumForFilePrefix(
  File file, {
  required String algorithm,
  required int end,
}) async {
  final checksum = await ParallelStreamingChecksum.start(algorithm: algorithm);
  try {
    if (end > 0) {
      await for (final chunk in file.openRead(0, end)) {
        checksum.add(chunk);
      }
    }
    return checksum;
  } catch (_) {
    await checksum.dispose();
    rethrow;
  }
}

Future<ParallelStreamingChecksum> _parallelChecksumForSourcePrefix(
  FileTransferSource source, {
  required String algorithm,
  required int end,
}) async {
  final checksum = await ParallelStreamingChecksum.start(algorithm: algorithm);
  try {
    var offset = 0;
    while (offset < end) {
      final length = math.min(1024 * 1024, end - offset);
      final bytes = await source.readRange(offset, length);
      if (bytes.length != length) {
        throw const FileSystemException(
          'Unexpected EOF while hashing transfer source prefix',
        );
      }
      checksum.add(bytes);
      offset += bytes.length;
    }
    return checksum;
  } catch (_) {
    await checksum.dispose();
    rethrow;
  }
}

/// V3 文件传输引擎:从 WsSvrManager 机械抽离的发送/接收/断点恢复栈。
/// 与 socket 层的全部交互经构造注入的回调完成,不直接持有连接对象。
class FileTransferEngine {
  FileTransferEngine({
    required TransferConnectionBinding? Function(String peerId)
    currentConnectionBinding,
    required String? Function(TransferConnectionBinding connection)
    authenticatedIdentityHashForConnection,
    required FutureOr<bool> Function(
      TransferConnectionBinding connection,
      Object bytes,
    )
    sendBytesToConnection,
    bool Function(TransferConnectionBinding connection, Object bytes)?
    enqueueBytesToConnection,
    required FutureOr<bool> Function(TransferConnectionBinding connection)
    markPeerUnresponsive,
    TransferAckWatchdog? ackWatchdog,
    required void Function(TransferSnapshot snapshot) emitTransferUpdated,
    required void Function(String message) notify,
    required PeerProfile? Function(String peerId) remoteProfileFor,
    required bool Function(String peerId) isConnectedTo,
    required Set<String> Function() connectedPeerIds,
    required String Function() defaultPeerId,
    required bool Function(String peerId) hasLegacySinkFor,
    required String Function(String authenticatedPeerId) localPeerIdFor,
    required TransferMessageBuilder buildMessage,
    required void Function(MessageData message) dispatchOutgoingMessage,
    required FutureOr<void> Function(MessageData message) ackMessage,
    required WireMessageReplayGuard wireMessageReplayGuard,
    FileTransferSource Function(String sourcePath, int expectedSize)?
    transferSourceFactory,
    Future<Directory> Function()? downloadDirectory,
    Future<int?> Function(String path)? availableBytesForDownloadPath,
    Future<void> Function(String path)? notifyFileVisible,
    Future<void> Function(File file, int timestamp)? setPublishedFileTimestamp,
    PrivacyLog? privacyLogger,
    FileTransferV3FlowParameters? flowLimits,
    LocalDatabase Function() database = LocalDatabase.new,
  }) : _currentConnectionBinding = currentConnectionBinding,
       _authenticatedIdentityHashForConnection =
           authenticatedIdentityHashForConnection,
       _sendBytesToConnection = sendBytesToConnection,
       _enqueueBytesToConnection = enqueueBytesToConnection,
       _markPeerUnresponsive = markPeerUnresponsive,
       _ownsAckWatchdog = ackWatchdog == null,
       _ackWatchdog = ackWatchdog ?? TransferAckWatchdog(),
       _emitTransferUpdated = emitTransferUpdated,
       _notify = notify,
       _remoteProfileFor = remoteProfileFor,
       _isConnectedTo = isConnectedTo,
       _connectedPeerIds = connectedPeerIds,
       _defaultPeerId = defaultPeerId,
       _hasLegacySinkFor = hasLegacySinkFor,
       _localPeerIdFor = localPeerIdFor,
       _buildMessage = buildMessage,
       _dispatchOutgoingMessage = dispatchOutgoingMessage,
       _ackMessage = ackMessage,
       _wireMessageReplayGuard = wireMessageReplayGuard,
       _transferSourceFactory = transferSourceFactory,
       _downloadDirectory = downloadDirectory ?? downloadDir,
       _availableBytesForDownloadPath =
           availableBytesForDownloadPath ?? availableBytesForPath,
       _notifyFileVisible =
           notifyFileVisible ?? notifyFileVisibleToAndroidPickers,
       _setPublishedFileTimestamp =
           setPublishedFileTimestamp ?? _setFileLastModified,
       _privacyLogger = privacyLogger ?? privacyLog,
       _flowLimits =
           flowLimits ??
           ((Platform.isAndroid || Platform.isIOS)
               ? FileTransferV3FlowParameters.mobile
               : FileTransferV3FlowParameters.desktop),
       _database = database;

  static const int defaultTransferChunkSize = fileTransferV3FramePayloadSize;
  static const String defaultTransferChecksumAlgorithm =
      fileTransferV3ChecksumAlgorithm;
  static const int _progressDispatchIntervalMs = 100;

  final TransferConnectionBinding? Function(String peerId)
  _currentConnectionBinding;
  final String? Function(TransferConnectionBinding connection)
  _authenticatedIdentityHashForConnection;
  final FutureOr<bool> Function(
    TransferConnectionBinding connection,
    Object bytes,
  )
  _sendBytesToConnection;
  final bool Function(TransferConnectionBinding connection, Object bytes)?
  _enqueueBytesToConnection;
  final FutureOr<bool> Function(TransferConnectionBinding connection)
  _markPeerUnresponsive;
  final bool _ownsAckWatchdog;
  TransferAckWatchdog _ackWatchdog;
  final void Function(TransferSnapshot snapshot) _emitTransferUpdated;
  final void Function(String message) _notify;
  final PeerProfile? Function(String peerId) _remoteProfileFor;
  final bool Function(String peerId) _isConnectedTo;
  final Set<String> Function() _connectedPeerIds;
  final String Function() _defaultPeerId;
  final bool Function(String peerId) _hasLegacySinkFor;
  final String Function(String authenticatedPeerId) _localPeerIdFor;
  final TransferMessageBuilder _buildMessage;
  final void Function(MessageData message) _dispatchOutgoingMessage;
  final FutureOr<void> Function(MessageData message) _ackMessage;
  final WireMessageReplayGuard _wireMessageReplayGuard;
  final FileTransferSource Function(String sourcePath, int expectedSize)?
  _transferSourceFactory;
  final Future<Directory> Function() _downloadDirectory;
  final Future<int?> Function(String path) _availableBytesForDownloadPath;
  final Future<void> Function(String path) _notifyFileVisible;
  final Future<void> Function(File file, int timestamp)
  _setPublishedFileTimestamp;
  final PrivacyLog _privacyLogger;
  final FileTransferV3FlowParameters _flowLimits;
  final LocalDatabase Function() _database;

  final _sendFileLock = Lock();
  final MultiPeerTransferRuntime _transferRuntime = MultiPeerTransferRuntime();
  final Map<String, IOSink> _receivingTransferSinks = <String, IOSink>{};
  final Map<String, RandomAccessFile> _receivingTransferWritersV3 =
      <String, RandomAccessFile>{};
  final Map<String, _IncomingWritePipeline> _receivingWritePipelines =
      <String, _IncomingWritePipeline>{};
  final Map<String, FileTransferData> _receivingTransfers =
      <String, FileTransferData>{};
  final Map<String, ParallelStreamingChecksum> _receivingChecksums =
      <String, ParallelStreamingChecksum>{};
  final Map<String, VerifiedTransferSnapshot> _sealedIncomingSnapshots =
      <String, VerifiedTransferSnapshot>{};
  final Map<String, int> _receivingTransferOffsets = <String, int>{};
  final Map<String, int> _receivingTransferSequences = <String, int>{};
  final Map<String, int> _incomingProgressDispatchTimes = <String, int>{};
  final Map<String, int> _outgoingTransferSequences = <String, int>{};
  final Map<String, int> _outgoingWindowEndOffsets = <String, int>{};
  final Map<String, FileTransferV3FlowParameters> _outgoingFlows =
      <String, FileTransferV3FlowParameters>{};
  final Map<String, FileTransferV3FlowParameters> _incomingFlows =
      <String, FileTransferV3FlowParameters>{};
  final Map<String, _OutgoingChecksumState> _outgoingChecksums =
      <String, _OutgoingChecksumState>{};
  final Map<String, FileTransferSource> _outgoingTransferSources =
      <String, FileTransferSource>{};
  final Map<String, TransferConnectionBinding> _operationConnectionBindings =
      <String, TransferConnectionBinding>{};
  final Map<String, TransferConnectionBinding> _outgoingConnectionBindings =
      <String, TransferConnectionBinding>{};
  final Map<String, TransferConnectionBinding> _incomingConnectionBindings =
      <String, TransferConnectionBinding>{};
  final Map<String, _TransferOperationLaneEntry> _transferOperationLanes =
      <String, _TransferOperationLaneEntry>{};
  final Map<String, _TransferOperationLaneEntry> _transferSendLanes =
      <String, _TransferOperationLaneEntry>{};
  final Map<String, int> _outgoingIntentEpochs = <String, int>{};
  final Set<String> _blockedOutgoingPeers = <String>{};

  bool _supportsFileTransferV3For(String peerId) =>
      _remoteProfileFor(peerId)?.capabilities.fileTransferV3 == true;

  void _logFailure(
    FileTransferDiagnosticKind kind,
    Object error, {
    FileTransferDirection? direction,
  }) {
    _privacyLogger.event(PrivacyEvent.transferProgress, <PrivacyField, Object>{
      PrivacyField.kind: kind,
      if (direction != null) PrivacyField.direction: direction,
      PrivacyField.success: false,
      PrivacyField.errorType: _privacyLogger.errorType(error),
    });
  }

  Future<void> retryTransfer(String transferId) async {
    final database = _database();
    var transfer = await database.fetchFileTransfer(transferId);
    if (transfer == null) {
      return;
    }
    if (transfer.direction != FileTransferDirection.outgoing) {
      return;
    }
    final connection = _currentConnectionBinding(transfer.peerUid);
    var associatedMessage = await database.fetchAssociatedFileTransferMessage(
      transfer,
    );
    if (associatedMessage == null) {
      return;
    }
    if (transfer.state == FileTransferState.canceled ||
        transfer.state == FileTransferState.completed) {
      return;
    }
    if (transfer.state == FileTransferState.failed) {
      final connected =
          _supportsFileTransferV3For(transfer.peerUid) &&
          _isConnectedTo(transfer.peerUid);
      final admission = await database.reacquireFileTransferCapacity(
        transferId,
        nextState: connected
            ? FileTransferState.negotiating
            : FileTransferState.waitingReconnect,
      );
      if (admission != FileTransferAdmission.admitted) {
        _notify('文件传输队列已满');
        return;
      }
      transfer = await database.fetchFileTransfer(transferId);
      if (transfer == null) {
        return;
      }
      associatedMessage = await database.fetchAssociatedFileTransferMessage(
        transfer,
      );
      if (associatedMessage == null) {
        return;
      }
    }
    if (!_supportsFileTransferV3For(transfer.peerUid) ||
        !_isConnectedTo(transfer.peerUid)) {
      await _updateTransfer(
        transferId,
        state: FileTransferState.waitingReconnect,
        lastError: '',
      );
      return;
    }
    if (connection == null) {
      await _updateTransfer(
        transferId,
        state: FileTransferState.waitingReconnect,
        lastError: '',
      );
      return;
    }
    final sent = await _sendFileTransferV3OfferTo(
      transfer.peerUid,
      associatedMessage,
      connection: connection,
    );
    await _updateTransfer(
      transferId,
      state: sent
          ? FileTransferState.negotiating
          : FileTransferState.waitingReconnect,
      lastError: '',
    );
  }

  Future<void> cancelTransfer(String transferId) async {
    final initial = await _database().fetchFileTransfer(transferId);
    if (initial == null) {
      return;
    }
    final connection =
        _outgoingConnectionBindings[transferId] ??
        _incomingConnectionBindings[transferId] ??
        _currentConnectionBinding(initial.peerUid) ??
        TransferConnectionBinding(peerId: initial.peerUid, generation: 0);
    await _runTransferOperation<void>(
      transferId,
      connection: connection,
      operation: () async {
        final transfer = await _database().fetchFileTransfer(transferId);
        if (transfer == null) {
          return;
        }
        if (!isTerminalFileTransferState(transfer.state)) {
          await _updateTransfer(
            transferId,
            state: transfer.direction == FileTransferDirection.incoming
                ? FileTransferState.paused
                : FileTransferState.canceled,
            lastError: '',
          );
        }
        try {
          if (_supportsFileTransferV3For(transfer.peerUid) &&
              _isConnectedTo(transfer.peerUid)) {
            await _sendFileTransferV3ControlTo(
              transfer.peerUid,
              FileTransferV3Control(
                action: FileTransferV3Action.cancel,
                transferId: transfer.transferId,
                durableOffset: transfer.committedBytes,
                size: transfer.size,
                failureReason: FileTransferFailureReason.none,
              ),
            );
          }
        } finally {
          if (transfer.direction == FileTransferDirection.incoming) {
            await _releaseIncomingAndStartNext(
              transfer,
              flush: true,
              connection: connection,
            );
          } else {
            await _releaseOutgoingAndStartNext(
              transfer,
              connection: connection,
            );
          }
        }
      },
    );
  }

  Future<bool> sendPickedFileTo(
    String peerId,
    PickedTransferFile item, {
    String? messageId,
    String? expectedPublicKeyHash,
  }) async {
    if (item.isAndroidContentUri) {
      return sendAndroidContentUriTo(
        peerId,
        uri: item.androidContentUri!,
        name: item.name,
        size: item.size,
        fileTimestamp: item.lastModified,
        messageId: messageId,
        expectedPublicKeyHash: expectedPublicKeyHash,
      );
    }
    final path = item.path;
    if (path == null || path.isEmpty) {
      return false;
    }
    return sendFileTo(
      peerId,
      path,
      messageId: messageId,
      expectedPublicKeyHash: expectedPublicKeyHash,
    );
  }

  Future<bool> sendFileTo(
    String peerId,
    String path, {
    String? messageId,
    String? expectedPublicKeyHash,
  }) async {
    if (peerId.isEmpty ||
        path.isEmpty ||
        (expectedPublicKeyHash != null && expectedPublicKeyHash.isEmpty) ||
        (messageId != null && !isCanonicalTransferId(messageId))) {
      return false;
    }
    final intentEpoch = _outgoingIntentEpochs[peerId] ?? 0;
    final fileName = p.basename(path);
    final existing = messageId == null
        ? null
        : await _database().fetchFileTransfer(messageId);
    if (existing != null) {
      final associated = await _database().fetchAssociatedFileTransferMessage(
        existing,
      );
      final matches = associated == null
          ? existing.state == FileTransferState.canceled &&
                isRetryableOutgoingInvalidationReason(existing.lastError) &&
                _matchesStableOutgoingTransferRecord(
                  transfer: existing,
                  peerId: peerId,
                  sourcePath: path,
                )
          : _matchesStableOutgoingTransfer(
              transfer: existing,
              message: associated,
              peerId: peerId,
              sourcePath: path,
              fileName: fileName,
            );
      if (!matches) {
        return false;
      }
      if (existing.state == FileTransferState.completed ||
          (existing.state == FileTransferState.canceled &&
              !isRetryableOutgoingInvalidationReason(existing.lastError))) {
        return true;
      }
    }
    if (_blockedOutgoingPeers.contains(peerId)) {
      return false;
    }
    final connection = _currentConnectionBinding(peerId);
    final expectedConnection = expectedPublicKeyHash == null
        ? null
        : connection;
    if (!_matchesExpectedIdentity(
      connection,
      expectedPublicKeyHash: expectedPublicKeyHash,
      requiredConnection: expectedConnection,
    )) {
      return false;
    }
    final canUseLegacySink = _hasLegacySinkFor(peerId);
    if (existing == null &&
        (connection == null ||
            (!_isConnectedTo(peerId) && !canUseLegacySink))) {
      return false;
    }
    if (existing == null && !_supportsFileTransferV3For(peerId)) {
      _notify('当前设备版本不支持新版文件传输');
      return false;
    }
    final file = File(path);
    if (!file.existsSync() ||
        FileSystemEntity.typeSync(path) == FileSystemEntityType.directory) {
      return false;
    }
    final source = _sourceFor(path, await file.length());
    final size = await source.length();
    if (size < 0 ||
        size > fileTransferV3MaxFileSize ||
        !validateIncomingFileName(fileName)) {
      _notify('文件名或文件大小不符合传输要求');
      return false;
    }
    final checksumValue = existing?.checksumValue ?? '';
    if (existing != null) {
      final associated = await _database().fetchAssociatedFileTransferMessage(
        existing,
      );
      final matches = associated == null
          ? existing.state == FileTransferState.canceled &&
                isRetryableOutgoingInvalidationReason(existing.lastError) &&
                _matchesStableOutgoingTransferRecord(
                  transfer: existing,
                  peerId: peerId,
                  sourcePath: path,
                  size: size,
                  checksumValue: checksumValue,
                )
          : _matchesStableOutgoingTransfer(
              transfer: existing,
              message: associated,
              peerId: peerId,
              sourcePath: path,
              fileName: fileName,
              size: size,
              checksumValue: checksumValue,
            );
      if (!matches) {
        return false;
      }
    }
    final timestamp = (await file.lastModified()).millisecondsSinceEpoch;
    return _persistAndOfferOutgoingTransfer(
      peerId: peerId,
      sourcePath: path,
      fileName: fileName,
      size: size,
      fileTimestamp: timestamp,
      checksumValue: checksumValue,
      checksumDeferred: checksumValue.isEmpty,
      messageId: messageId,
      intentEpoch: intentEpoch,
      expectedPublicKeyHash: expectedPublicKeyHash,
      expectedConnection: expectedConnection,
    );
  }

  Future<bool> sendAndroidContentUriTo(
    String peerId, {
    required String uri,
    required String name,
    required int size,
    required int fileTimestamp,
    String? messageId,
    String? expectedPublicKeyHash,
  }) async {
    if (peerId.isEmpty ||
        uri.isEmpty ||
        (expectedPublicKeyHash != null && expectedPublicKeyHash.isEmpty) ||
        (messageId != null && !isCanonicalTransferId(messageId))) {
      return false;
    }
    final intentEpoch = _outgoingIntentEpochs[peerId] ?? 0;
    final fileName = name.isNotEmpty ? name : 'document';
    final existing = messageId == null
        ? null
        : await _database().fetchFileTransfer(messageId);
    if (existing != null) {
      final associated = await _database().fetchAssociatedFileTransferMessage(
        existing,
      );
      final matches = associated == null
          ? existing.state == FileTransferState.canceled &&
                isRetryableOutgoingInvalidationReason(existing.lastError) &&
                _matchesStableOutgoingTransferRecord(
                  transfer: existing,
                  peerId: peerId,
                  sourcePath: uri,
                  size: size,
                )
          : _matchesStableOutgoingTransfer(
              transfer: existing,
              message: associated,
              peerId: peerId,
              sourcePath: uri,
              fileName: fileName,
              size: size,
            );
      if (!matches) {
        return false;
      }
      if (existing.state == FileTransferState.completed ||
          (existing.state == FileTransferState.canceled &&
              !isRetryableOutgoingInvalidationReason(existing.lastError))) {
        return true;
      }
    }
    if (_blockedOutgoingPeers.contains(peerId)) {
      return false;
    }
    final connection = _currentConnectionBinding(peerId);
    final expectedConnection = expectedPublicKeyHash == null
        ? null
        : connection;
    if (!_matchesExpectedIdentity(
      connection,
      expectedPublicKeyHash: expectedPublicKeyHash,
      requiredConnection: expectedConnection,
    )) {
      return false;
    }
    final canUseLegacySink = _hasLegacySinkFor(peerId);
    if (existing == null &&
        (connection == null ||
            (!_isConnectedTo(peerId) && !canUseLegacySink))) {
      return false;
    }
    if (!isAndroidContentUri(uri)) {
      return false;
    }
    if (existing == null && !_supportsFileTransferV3For(peerId)) {
      _notify('当前设备版本不支持无复制文件发送');
      return false;
    }
    if (size < 0 ||
        size > fileTransferV3MaxFileSize ||
        !validateIncomingFileName(fileName)) {
      _notify('文件名或文件大小不符合传输要求');
      return false;
    }
    final source = _sourceFor(uri, size);
    final checksumValue = existing?.checksumValue ?? '';
    try {
      if (!await source.exists()) {
        return false;
      }
      if (await source.length() != size) {
        throw const FileSystemException('文件实际大小与选择时记录的大小不一致');
      }
    } catch (error) {
      _logFailure(
        FileTransferDiagnosticKind.outgoingFailed,
        error,
        direction: FileTransferDirection.outgoing,
      );
      _notify(FileTransferFailureReason.source.wireCode);
      return false;
    }
    if (existing != null) {
      final associated = await _database().fetchAssociatedFileTransferMessage(
        existing,
      );
      final matches = associated == null
          ? existing.state == FileTransferState.canceled &&
                isRetryableOutgoingInvalidationReason(existing.lastError) &&
                _matchesStableOutgoingTransferRecord(
                  transfer: existing,
                  peerId: peerId,
                  sourcePath: uri,
                  size: size,
                  checksumValue: checksumValue,
                )
          : _matchesStableOutgoingTransfer(
              transfer: existing,
              message: associated,
              peerId: peerId,
              sourcePath: uri,
              fileName: fileName,
              size: size,
              checksumValue: checksumValue,
            );
      if (!matches) {
        return false;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return _persistAndOfferOutgoingTransfer(
      peerId: peerId,
      sourcePath: uri,
      fileName: fileName,
      size: size,
      fileTimestamp: fileTimestamp > 0 ? fileTimestamp : now,
      checksumValue: checksumValue,
      checksumDeferred: checksumValue.isEmpty,
      messageId: messageId,
      intentEpoch: intentEpoch,
      expectedPublicKeyHash: expectedPublicKeyHash,
      expectedConnection: expectedConnection,
    );
  }

  Future<bool> _persistAndOfferOutgoingTransfer({
    required String peerId,
    required String sourcePath,
    required String fileName,
    required int size,
    required int fileTimestamp,
    required String checksumValue,
    required bool checksumDeferred,
    String? messageId,
    required int intentEpoch,
    String? expectedPublicKeyHash,
    TransferConnectionBinding? expectedConnection,
  }) {
    return _sendFileLock.synchronized(() async {
      if (_blockedOutgoingPeers.contains(peerId) ||
          (_outgoingIntentEpochs[peerId] ?? 0) != intentEpoch ||
          !_matchesExpectedIdentity(
            _currentConnectionBinding(peerId),
            expectedPublicKeyHash: expectedPublicKeyHash,
            requiredConnection: expectedConnection,
          )) {
        return false;
      }
      final metadata = FileTransferV3Metadata(
        checksumValue: checksumValue,
        checksumDeferred: checksumDeferred,
        maxChunkSize: _flowLimits.chunkSize,
        maxWindowSize: _flowLimits.windowSize,
      );
      final content = jsonEncode(metadata.toJson());
      final draft = _buildMessage(
        MessageEnum.File,
        content,
        '',
        fileName,
        size,
        false,
        path: sourcePath,
        uid: messageId,
        md5: '',
        fileTimestamp: fileTimestamp,
        receiverOverride: peerId,
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      final transfer = FileTransferData(
        transferId: draft.uuid,
        messageUuid: draft.uuid,
        messageRowId: 0,
        peerUid: peerId,
        direction: FileTransferDirection.outgoing,
        state: FileTransferState.queued,
        finalPath: sourcePath,
        tempPath: '',
        size: size,
        checksumAlgorithm: metadata.checksumAlgorithm,
        checksumValue: metadata.checksumValue,
        chunkSize: metadata.chunkSize,
        committedBytes: 0,
        resumeProofResetCount: 0,
        lastError: '',
        createdAt: now,
        updatedAt: now,
      );
      var admission = await _database().admitFileTransfer(
        message: draft,
        transfer: transfer,
        expectedPublicKeyHash: expectedPublicKeyHash,
      );
      if (admission.decision == FileTransferAdmission.existing) {
        final existingTransfer = admission.transfer;
        final existingMessage = admission.message;
        if (existingTransfer == null ||
            existingMessage == null ||
            !_matchesStableOutgoingTransfer(
              transfer: existingTransfer,
              message: existingMessage,
              peerId: peerId,
              sourcePath: sourcePath,
              fileName: fileName,
              size: size,
              checksumValue: checksumValue,
            )) {
          return false;
        }
        return _resumeStableOutgoingTransfer(
          existingTransfer,
          existingMessage,
          intentEpoch: intentEpoch,
          expectedPublicKeyHash: expectedPublicKeyHash,
          expectedConnection: expectedConnection,
        );
      }
      if (admission.decision == FileTransferAdmission.missing &&
          messageId != null) {
        final invalidated = await _database().fetchFileTransfer(messageId);
        if (invalidated == null ||
            invalidated.state != FileTransferState.canceled ||
            !isRetryableOutgoingInvalidationReason(invalidated.lastError) ||
            !_matchesStableOutgoingTransferRecord(
              transfer: invalidated,
              peerId: peerId,
              sourcePath: sourcePath,
              size: size,
              checksumValue: checksumValue,
            )) {
          return false;
        }
        admission = await _database().reacquireInvalidatedOutgoingFileTransfer(
          messageId,
          expectedPublicKeyHash: expectedPublicKeyHash ?? '',
          nextState: _currentConnectionBinding(peerId) == null
              ? FileTransferState.waitingReconnect
              : FileTransferState.negotiating,
          replacementMessage: draft,
        );
      }
      if (admission.decision != FileTransferAdmission.admitted) {
        if (admission.decision == FileTransferAdmission.peerLimit ||
            admission.decision == FileTransferAdmission.globalLimit) {
          _notify('文件传输队列已满');
        }
        return false;
      }
      final message = admission.message!;
      _dispatchTransferData(admission.transfer!);
      _dispatchOutgoingMessage(message);
      if (_blockedOutgoingPeers.contains(peerId) ||
          (_outgoingIntentEpochs[peerId] ?? 0) != intentEpoch ||
          !_matchesExpectedIdentity(
            _currentConnectionBinding(peerId),
            expectedPublicKeyHash: expectedPublicKeyHash,
            requiredConnection: expectedConnection,
          )) {
        return false;
      }
      final offerFailed = !await _offerOnCurrentConnection(
        peerId,
        message,
        expectedPublicKeyHash: expectedPublicKeyHash,
        requiredConnection: expectedConnection,
      );
      if (offerFailed) {
        try {
          await _updateTransfer(
            message.uuid,
            state: FileTransferState.waitingReconnect,
            lastError: '',
          );
        } catch (error) {
          _logFailure(
            FileTransferDiagnosticKind.outgoingFailed,
            error,
            direction: FileTransferDirection.outgoing,
          );
        }
      }
      // Admission transfers ownership of the source to the durable queue.
      // Initial wire delivery may fail, but reconnect recovery will retry it.
      return true;
    });
  }

  bool _matchesStableOutgoingTransfer({
    required FileTransferData transfer,
    required MessageData message,
    required String peerId,
    required String sourcePath,
    required String fileName,
    int? size,
    String? checksumValue,
  }) {
    if (!_matchesStableOutgoingTransferRecord(
          transfer: transfer,
          peerId: peerId,
          sourcePath: sourcePath,
          size: size,
          checksumValue: checksumValue,
        ) ||
        message.receiver != peerId ||
        message.type != MessageEnum.File ||
        message.path != sourcePath ||
        message.name != fileName ||
        message.size != transfer.size ||
        message.uuid != transfer.transferId) {
      return false;
    }
    try {
      final metadata = FileTransferV3Metadata.parseOffer(
        message.content,
        size: message.size,
      );
      return metadata.checksumAlgorithm == transfer.checksumAlgorithm &&
          metadata.checksumValue == transfer.checksumValue;
    } on FileTransferV3MetadataException {
      return false;
    }
  }

  bool _matchesStableOutgoingTransferRecord({
    required FileTransferData transfer,
    required String peerId,
    required String sourcePath,
    int? size,
    String? checksumValue,
  }) {
    return transfer.direction == FileTransferDirection.outgoing &&
        transfer.peerUid == peerId &&
        transfer.transferId == transfer.messageUuid &&
        transfer.finalPath == sourcePath &&
        (size == null || transfer.size == size) &&
        transfer.checksumAlgorithm == fileTransferV3ChecksumAlgorithm &&
        (checksumValue == null || transfer.checksumValue == checksumValue);
  }

  Future<bool> _resumeStableOutgoingTransfer(
    FileTransferData transfer,
    MessageData message, {
    required int intentEpoch,
    String? expectedPublicKeyHash,
    TransferConnectionBinding? expectedConnection,
  }) async {
    if (transfer.state == FileTransferState.completed ||
        transfer.state == FileTransferState.transferring ||
        transfer.state == FileTransferState.verifying) {
      return true;
    }
    var current = transfer;
    if (current.state == FileTransferState.canceled) {
      if (!isRetryableOutgoingInvalidationReason(current.lastError)) {
        return true;
      }
      if (expectedPublicKeyHash == null) {
        return false;
      }
      final admission = await _database()
          .reacquireInvalidatedOutgoingFileTransfer(
            current.transferId,
            expectedPublicKeyHash: expectedPublicKeyHash,
            nextState: _currentConnectionBinding(current.peerUid) == null
                ? FileTransferState.waitingReconnect
                : FileTransferState.negotiating,
          );
      if (admission.decision != FileTransferAdmission.admitted) {
        if (admission.decision == FileTransferAdmission.peerLimit ||
            admission.decision == FileTransferAdmission.globalLimit) {
          _notify('文件传输队列已满');
        }
        return false;
      }
      current = admission.transfer ?? current;
      message = admission.message ?? message;
      _dispatchTransferData(current);
    }
    if (current.state == FileTransferState.failed) {
      final admission = await _database().reacquireFileTransferCapacity(
        current.transferId,
        nextState: _currentConnectionBinding(current.peerUid) == null
            ? FileTransferState.waitingReconnect
            : FileTransferState.negotiating,
      );
      if (admission != FileTransferAdmission.admitted &&
          admission != FileTransferAdmission.existing) {
        return true;
      }
      current =
          await _database().fetchFileTransfer(current.transferId) ?? current;
    }
    if (_blockedOutgoingPeers.contains(current.peerUid) ||
        (_outgoingIntentEpochs[current.peerUid] ?? 0) != intentEpoch ||
        !_matchesExpectedIdentity(
          _currentConnectionBinding(current.peerUid),
          expectedPublicKeyHash: expectedPublicKeyHash,
          requiredConnection: expectedConnection,
        )) {
      return false;
    }
    final offerFailed = !await _offerOnCurrentConnection(
      current.peerUid,
      message,
      expectedPublicKeyHash: expectedPublicKeyHash,
      requiredConnection: expectedConnection,
    );
    if (offerFailed) {
      await _updateTransfer(
        current.transferId,
        state: FileTransferState.waitingReconnect,
        lastError: '',
      );
    }
    return true;
  }

  Future<bool> _offerOnCurrentConnection(
    String peerId,
    MessageData message, {
    String? expectedPublicKeyHash,
    TransferConnectionBinding? requiredConnection,
  }) async {
    final attemptedConnections = <TransferConnectionBinding>{};
    for (var attempt = 0; attempt < 2; attempt++) {
      final connection = _currentConnectionBinding(peerId);
      if (connection == null ||
          !attemptedConnections.add(connection) ||
          !_matchesExpectedIdentity(
            connection,
            expectedPublicKeyHash: expectedPublicKeyHash,
            requiredConnection: requiredConnection,
          )) {
        return false;
      }
      try {
        if (await _sendFileTransferV3OfferTo(
          peerId,
          message,
          connection: connection,
        )) {
          return true;
        }
      } catch (error) {
        _logFailure(
          FileTransferDiagnosticKind.outgoingFailed,
          error,
          direction: FileTransferDirection.outgoing,
        );
      }
    }
    return false;
  }

  bool _matchesExpectedIdentity(
    TransferConnectionBinding? connection, {
    required String? expectedPublicKeyHash,
    required TransferConnectionBinding? requiredConnection,
  }) {
    if (expectedPublicKeyHash == null) {
      return true;
    }
    return connection != null &&
        requiredConnection != null &&
        connection == requiredConnection &&
        _authenticatedIdentityHashForConnection(connection) ==
            expectedPublicKeyHash;
  }

  /// fileOffer/fileData/fileReady/fileAck/fileComplete/fileCancel/fileError
  /// 帧入口(原 svrmanager `_handleWhisperFrameV3` 的非 message 分支);
  /// message 帧由 svrmanager 自行处理,不会转发到这里。
  Future<void> handleFrame(
    TransferConnectionBinding connection,
    WhisperFrameV3 frame, {
    required void Function() requireCurrent,
  }) async {
    final authenticatedPeerId = connection.peerId;
    void requireBoundSession() {
      try {
        requireCurrent();
      } on WireInputRejected {
        rethrow;
      } catch (_) {
        throw const WireInputRejected(WireInputReason.sessionNotCurrent);
      }
    }

    requireBoundSession();
    if (frame.type == WhisperFrameType.message) {
      throw const WireInputRejected(WireInputReason.transferFrameMismatch);
    }
    if (!isCanonicalTransferId(frame.transferId)) {
      throw const WireInputRejected(WireInputReason.transferIdInvalid);
    }
    final lockEntry = _transferOperationLanes.putIfAbsent(
      frame.transferId,
      _TransferOperationLaneEntry.new,
    );
    lockEntry.users++;
    try {
      await lockEntry.lock.synchronized(() async {
        requireBoundSession();
        _operationConnectionBindings[frame.transferId] = connection;
        try {
          await _handleFrameLocked(
            authenticatedPeerId,
            frame,
            requireCurrent: requireBoundSession,
          );
        } finally {
          if (_operationConnectionBindings[frame.transferId] == connection) {
            _operationConnectionBindings.remove(frame.transferId);
          }
        }
      });
    } finally {
      lockEntry.users--;
      if (lockEntry.users == 0 &&
          identical(_transferOperationLanes[frame.transferId], lockEntry)) {
        _transferOperationLanes.remove(frame.transferId);
      }
    }
  }

  Future<T> _runTransferOperation<T>(
    String transferId, {
    required TransferConnectionBinding connection,
    required FutureOr<T> Function() operation,
  }) async {
    final lane = _transferOperationLanes.putIfAbsent(
      transferId,
      _TransferOperationLaneEntry.new,
    );
    lane.users++;
    try {
      return await lane.lock.synchronized(() async {
        _operationConnectionBindings[transferId] = connection;
        try {
          return await operation();
        } finally {
          if (_operationConnectionBindings[transferId] == connection) {
            _operationConnectionBindings.remove(transferId);
          }
        }
      });
    } finally {
      lane.users--;
      if (lane.users == 0 &&
          identical(_transferOperationLanes[transferId], lane)) {
        _transferOperationLanes.remove(transferId);
      }
    }
  }

  Future<T> _runTransferSend<T>(
    String transferId,
    FutureOr<T> Function() operation,
  ) async {
    final lane = _transferSendLanes.putIfAbsent(
      transferId,
      _TransferOperationLaneEntry.new,
    );
    lane.users++;
    try {
      return await lane.lock.synchronized(operation);
    } finally {
      lane.users--;
      if (lane.users == 0 && identical(_transferSendLanes[transferId], lane)) {
        _transferSendLanes.remove(transferId);
      }
    }
  }

  Future<void> _handleFrameLocked(
    String authenticatedPeerId,
    WhisperFrameV3 frame, {
    required void Function() requireCurrent,
  }) async {
    switch (frame.type) {
      case WhisperFrameType.message:
      case WhisperFrameType.clipboardOffer:
      case WhisperFrameType.clipboardRequest:
      case WhisperFrameType.clipboardData:
      case WhisperFrameType.clipboardComplete:
      case WhisperFrameType.clipboardClear:
      case WhisperFrameType.clipboardError:
        throw const WireInputRejected(WireInputReason.transferFrameMismatch);
      case WhisperFrameType.fileOffer:
        final message = decodeWireMessage(
          jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>,
        );
        final wireValidation = WireInputPolicy.validateFileOffer(
          frame: frame,
          message: message,
          authenticatedPeerId: authenticatedPeerId,
          localPeerId: _localPeerIdFor(authenticatedPeerId),
        );
        if (!wireValidation.isAccepted &&
            wireValidation.reason == WireInputReason.transferSizeInvalid) {
          await _sendFileOfferError(
            message,
            FileTransferFailureReason.invalidSize,
          );
          return;
        }
        wireValidation.requireAccepted();
        if (message.path.isNotEmpty) {
          await _sendFileOfferError(
            message,
            FileTransferFailureReason.invalidPath,
          );
          return;
        }
        if (!validateIncomingFileName(message.name)) {
          await _sendFileOfferError(
            message,
            FileTransferFailureReason.invalidName,
          );
          return;
        }
        late final FileTransferV3Metadata metadata;
        try {
          metadata = FileTransferV3Metadata.parseOffer(
            message.content,
            size: message.size,
          );
        } on FileTransferV3MetadataException catch (error) {
          await _sendFileOfferError(
            message,
            fileTransferFailureReasonFromWire(error.reason) ??
                FileTransferFailureReason.invalidMetadata,
          );
          return;
        }
        final existing = await _database().fetchFileTransfer(frame.transferId);
        requireCurrent();
        if (existing != null && existing.peerUid != authenticatedPeerId) {
          throw const WireInputRejected(WireInputReason.transferPeerMismatch);
        }
        if (existing != null &&
            existing.direction != FileTransferDirection.incoming) {
          throw const WireInputRejected(
            WireInputReason.transferDirectionMismatch,
          );
        }
        if (existing != null &&
            (existing.messageUuid != message.uuid ||
                existing.size != message.size)) {
          throw const WireInputRejected(WireInputReason.transferFrameMismatch);
        }
        final database = _database();
        final draft = _incomingTransferDraft(message, metadata);
        FileTransferAdmissionResult? claimAdmission;
        late final WireMessageReplayClaim replay;
        try {
          replay = await _wireMessageReplayGuard.claim(
            message,
            fetchExisting: database.fetchMessagesByUuid,
            isDuplicate: _matchesIncomingFileOffer,
            persist: (incoming) async {
              requireCurrent();
              final result = await database.admitFileTransfer(
                message: incoming,
                transfer: draft,
              );
              claimAdmission = result;
              if (result.decision != FileTransferAdmission.admitted &&
                  result.decision != FileTransferAdmission.existing) {
                throw _TransferAdmissionRejected(result.decision);
              }
              return result.message!;
            },
          );
        } on _TransferAdmissionRejected catch (error) {
          if (_isSessionCurrent(requireCurrent)) {
            await _sendFileOfferError(
              message,
              error.decision == FileTransferAdmission.missing
                  ? FileTransferFailureReason.messageMissing
                  : FileTransferFailureReason.queueFull,
            );
          }
          return;
        }
        if (replay.decision == WireMessageReplayDecision.conflict) {
          throw const WireInputRejected(WireInputReason.messageIdConflict);
        }
        var transfer = existing ?? claimAdmission?.transfer;
        var invariantStarted =
            claimAdmission?.decision == FileTransferAdmission.admitted;
        if (transfer == null) {
          requireCurrent();
          final repaired = await database.admitTransferForExistingMessage(
            message: replay.message!,
            transfer: draft,
          );
          invariantStarted =
              repaired.decision != FileTransferAdmission.existing &&
              repaired.transfer != null;
          transfer = repaired.transfer;
        }
        if (transfer == null) {
          throw const WireInputRejected(WireInputReason.messageIdConflict);
        }
        if (invariantStarted && !_isSessionCurrent(requireCurrent)) {
          return;
        }
        if (!invariantStarted) {
          requireCurrent();
        }
        final shouldDispatchPersistedMessage =
            claimAdmission?.decision == FileTransferAdmission.admitted ||
            (replay.decision == WireMessageReplayDecision.duplicate &&
                transfer.tempPath.isEmpty &&
                !isTerminalFileTransferState(transfer.state));
        await _handleFileTransferV3Offer(
          message,
          persistedMessage: replay.message!,
          transfer: transfer,
          isNewMessage: shouldDispatchPersistedMessage,
          requireCurrent: requireCurrent,
        );
        break;
      case WhisperFrameType.fileData:
        final transfer = await _database().fetchFileTransfer(frame.transferId);
        requireCurrent();
        if (transfer == null) {
          throw const WireInputRejected(WireInputReason.transferNotFound);
        }
        if (transfer.peerUid != authenticatedPeerId) {
          throw const WireInputRejected(WireInputReason.transferPeerMismatch);
        }
        final expectedOffset =
            _receivingTransferOffsets[transfer.transferId] ??
            transfer.committedBytes;
        final expectedSequence =
            _receivingTransferSequences[transfer.transferId] ?? 0;
        final validation = WireInputPolicy.validateFileData(
          frame: frame,
          transfer: transfer,
          authenticatedPeerId: authenticatedPeerId,
          expectedOffset: expectedOffset,
          expectedSequence: expectedSequence,
          maxPayloadSize:
              _incomingFlows[transfer.transferId]?.chunkSize ??
              fileTransferV3LegacyFramePayloadSize,
          isActive:
              _transferRuntime.activeIncomingFor(transfer.peerUid) ==
              transfer.transferId,
        );
        if (validation.isIgnored) {
          return;
        }
        if (validation.isDuplicate) {
          _receivingTransferSequences[transfer.transferId] =
              expectedSequence + 1;
          await _sendFileTransferV3Ack(transfer, transfer.committedBytes);
          return;
        }
        validation.requireAccepted();
        try {
          await _handleFileTransferV3Data(
            frame,
            requireCurrent: requireCurrent,
          );
          if (_receivingTransferOffsets.containsKey(transfer.transferId)) {
            _receivingTransferSequences[transfer.transferId] =
                expectedSequence + 1;
          }
        } catch (error) {
          if (error is WireInputRejected) {
            rethrow;
          }
          await _handleIncomingFileTransferV3Error(frame.transferId, error);
        }
        break;
      case WhisperFrameType.fileReady:
      case WhisperFrameType.fileAck:
      case WhisperFrameType.fileComplete:
      case WhisperFrameType.fileCancel:
      case WhisperFrameType.fileError:
        final control = FileTransferV3Control.fromJson(
          jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>,
        );
        WireInputPolicy.validateFileControlHeader(
          frame: frame,
          control: control,
        ).requireAccepted();
        final transfer = await _database().fetchFileTransfer(
          control.transferId,
        );
        requireCurrent();
        if (transfer == null) {
          throw const WireInputRejected(WireInputReason.transferNotFound);
        }
        if (transfer.peerUid != authenticatedPeerId) {
          throw const WireInputRejected(WireInputReason.transferPeerMismatch);
        }
        final validation = WireInputPolicy.validateFileControl(
          frame: frame,
          control: control,
          transfer: transfer,
          authenticatedPeerId: authenticatedPeerId,
        );
        if (validation.isIgnored) {
          return;
        }
        validation.requireAccepted();
        try {
          await _handleFileTransferV3Control(
            control,
            requireCurrent: requireCurrent,
          );
        } catch (error) {
          if (error is WireInputRejected) {
            rethrow;
          }
          if (transfer.direction == FileTransferDirection.incoming) {
            await _handleIncomingFileTransferV3Error(control.transferId, error);
          } else {
            await _handleOutgoingFileTransferV3Error(control.transferId, error);
          }
        }
        break;
    }
  }

  /// 原 svrmanager `_handlePeerDisconnected` 的 transfer 清理段:
  /// 标记该 peer 的传输等待重连,并清空其运行时队列。
  Future<void> handlePeerDisconnected(String peerId) async {
    await _markPeerTransfersWaitingReconnect(peerId);
    _transferRuntime.clearPeer(peerId);
  }

  Future<void> reconcileInterruptedTransfersOnStartup() {
    return _markRecoverableTransfersWaitingReconnect();
  }

  Future<void> markRecoverableTransfersPausedForPeer(String peerId) async {
    final items = await _database().fetchRecoverableFileTransfersForPeer(
      peerId,
    );
    for (final item in items) {
      if (item.state != FileTransferState.waitingReconnect) {
        continue;
      }
      final connection =
          _currentConnectionBinding(peerId) ??
          TransferConnectionBinding(peerId: peerId, generation: -1);
      await _runTransferOperation<void>(
        item.transferId,
        connection: connection,
        operation: () async {
          final current = await _database().fetchFileTransfer(item.transferId);
          if (current?.state != FileTransferState.waitingReconnect) {
            return;
          }
          await _updateTransfer(
            item.transferId,
            state: FileTransferState.paused,
            lastError: '',
          );
        },
      );
    }
  }

  Future<void> invalidateOutgoingTransfersForPeer(
    String peerId, {
    required String reason,
    bool revokeDeviceTrust = false,
  }) async {
    if (peerId.isEmpty) {
      return;
    }
    _blockedOutgoingPeers.add(peerId);
    _outgoingIntentEpochs[peerId] = (_outgoingIntentEpochs[peerId] ?? 0) + 1;
    final canceled = await _sendFileLock.synchronized(
      () => _database().cancelOutgoingTransfersForPeer(
        peerId,
        reason: reason,
        revokeDeviceTrust: revokeDeviceTrust,
      ),
    );
    for (final transfer in canceled) {
      _ackWatchdog.cancel(transfer.transferId);
      _outgoingWindowEndOffsets.remove(transfer.transferId);
      _outgoingTransferSequences.remove(transfer.transferId);
      await _outgoingChecksums.remove(transfer.transferId)?.dispose();
      await _closeOutgoingTransferSource(transfer.transferId);
      _outgoingConnectionBindings.remove(transfer.transferId);
      _transferRuntime.release(
        peerId: peerId,
        transferId: transfer.transferId,
        direction: FileTransferDirection.outgoing,
      );
      _dispatchTransferData(transfer);
    }
  }

  void allowOutgoingTransfersForPeer(String peerId) {
    _blockedOutgoingPeers.remove(peerId);
  }

  bool _matchesIncomingFileOffer(MessageData persisted, MessageData incoming) {
    return persisted.sender == incoming.sender &&
        persisted.receiver == incoming.receiver &&
        persisted.name == incoming.name &&
        persisted.clipboard == incoming.clipboard &&
        persisted.size == incoming.size &&
        persisted.type == MessageEnum.File &&
        persisted.content == incoming.content &&
        persisted.message == incoming.message &&
        persisted.timestamp == incoming.timestamp &&
        persisted.uuid == incoming.uuid &&
        persisted.md5 == incoming.md5 &&
        persisted.fileTimestamp == incoming.fileTimestamp;
  }

  /// 原 svrmanager `closeGracefully` 中的 transfer 清理段:
  /// 标记可恢复传输等待重连,并冲刷/关闭全部续传句柄。
  Future<void> closeAll({bool persistRecoverable = true}) async {
    _ackWatchdog.close();
    if (persistRecoverable) {
      await _markRecoverableTransfersWaitingReconnect();
    }
    await _closeResumableHandles();
    if (_ownsAckWatchdog) {
      _ackWatchdog = TransferAckWatchdog();
    }
  }

  void _dispatchTransferData(FileTransferData data) {
    final snapshot = _database().snapshotForTransfer(data);
    _emitTransferUpdated(snapshot);
  }

  Future<FileTransferData?> _emitTransferById(String transferId) async {
    final data = await _database().fetchFileTransfer(transferId);
    if (data != null) {
      _dispatchTransferData(data);
    }
    return data;
  }

  Future<FileTransferData> _persistTransfer(
    FileTransferData data, {
    void Function()? requireCurrent,
  }) async {
    requireCurrent?.call();
    await _database().upsertFileTransfer(data);
    _dispatchTransferData(data);
    return data;
  }

  Future<FileTransferData?> _updateTransfer(
    String transferId, {
    FileTransferState? state,
    int? committedBytes,
    String? lastError,
    String? finalPath,
    String? tempPath,
    String? checksumValue,
    void Function()? requireCurrent,
  }) async {
    requireCurrent?.call();
    final affected = await _database().updateFileTransfer(
      transferId,
      state: state == null ? const Value.absent() : Value(state),
      committedBytes: committedBytes == null
          ? const Value.absent()
          : Value(committedBytes),
      lastError: lastError == null ? const Value.absent() : Value(lastError),
      finalPath: finalPath == null ? const Value.absent() : Value(finalPath),
      tempPath: tempPath == null ? const Value.absent() : Value(tempPath),
      checksumValue: checksumValue == null
          ? const Value.absent()
          : Value(checksumValue),
      updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
    );
    if (affected != 1) return null;
    final updated = await _database().fetchFileTransfer(transferId);
    if (updated == null ||
        (state != null && updated.state != state) ||
        (committedBytes != null && updated.committedBytes != committedBytes)) {
      return null;
    }
    if ((state == null || !isTerminalFileTransferState(state)) &&
        await _database().fetchAssociatedFileTransferMessage(updated) == null) {
      return null;
    }
    _dispatchTransferData(updated);
    if (updated.direction == FileTransferDirection.outgoing &&
        (updated.state == FileTransferState.completed ||
            updated.state == FileTransferState.canceled)) {
      if (isAndroidSystemShareStagedUri(updated.finalPath)) {
        await releaseAndroidSystemShareStagedItem(updated.finalPath);
      } else {
        await releaseStagedFolderTransferArchive(updated.finalPath);
      }
    }
    return updated;
  }

  Future<void> _markPeerTransfersWaitingReconnect(String peerId) async {
    final items = await _database().fetchRecoverableFileTransfersForPeer(
      peerId,
    );
    for (final item in items) {
      if (isTerminalFileTransferState(item.state)) {
        continue;
      }
      final connection =
          _outgoingConnectionBindings[item.transferId] ??
          TransferConnectionBinding(peerId: peerId, generation: -1);
      await _runTransferOperation<void>(
        item.transferId,
        connection: connection,
        operation: () async {
          final current = await _database().fetchFileTransfer(item.transferId);
          if (current == null || isTerminalFileTransferState(current.state)) {
            return;
          }
          _ackWatchdog.cancel(current.transferId);
          if (current.direction == FileTransferDirection.incoming) {
            await _clearActiveIncomingTransfer(current.transferId, flush: true);
          }
          _outgoingWindowEndOffsets.remove(current.transferId);
          _outgoingTransferSequences.remove(current.transferId);
          _outgoingFlows.remove(current.transferId);
          _incomingFlows.remove(current.transferId);
          await _outgoingChecksums.remove(current.transferId)?.dispose();
          await _closeOutgoingTransferSource(current.transferId);
          _outgoingConnectionBindings.remove(current.transferId);
          _incomingConnectionBindings.remove(current.transferId);
          await _updateTransfer(
            current.transferId,
            state: FileTransferState.waitingReconnect,
            lastError: '',
          );
        },
      );
    }
  }

  Future<bool> _sendFileTransferV3OfferTo(
    String peerId,
    MessageData message, {
    required TransferConnectionBinding connection,
  }) {
    _ackWatchdog.cancel(message.uuid);
    _outgoingTransferSequences[message.uuid] = 0;
    _outgoingWindowEndOffsets.remove(message.uuid);
    _outgoingFlows.remove(message.uuid);
    return _sendFileTransferV3FrameTo(
      peerId,
      WhisperFrameV3(
        type: WhisperFrameType.fileOffer,
        transferId: message.uuid,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(
          utf8.encode(encodeWireMessage(message.copyWith(path: ''))),
        ),
      ),
      connection: connection,
    );
  }

  Future<bool> _sendFileTransferV3ControlTo(
    String peerId,
    FileTransferV3Control control, {
    TransferConnectionBinding? connection,
  }) {
    final type = switch (control.action) {
      FileTransferV3Action.ready => WhisperFrameType.fileReady,
      FileTransferV3Action.ack => WhisperFrameType.fileAck,
      FileTransferV3Action.verify => WhisperFrameType.fileAck,
      FileTransferV3Action.complete => WhisperFrameType.fileComplete,
      FileTransferV3Action.cancel => WhisperFrameType.fileCancel,
      FileTransferV3Action.error => WhisperFrameType.fileError,
    };
    return _sendFileTransferV3FrameTo(
      peerId,
      WhisperFrameV3(
        type: type,
        transferId: control.transferId,
        offset: control.durableOffset,
        sequence: 0,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(control.toJson()))),
      ),
      connection: connection,
    );
  }

  Future<bool> _sendFileTransferV3FrameTo(
    String peerId,
    WhisperFrameV3 frame, {
    TransferConnectionBinding? connection,
  }) async {
    connection ??=
        _operationConnectionBindings[frame.transferId] ??
        _outgoingConnectionBindings[frame.transferId] ??
        _incomingConnectionBindings[frame.transferId] ??
        _currentConnectionBinding(peerId);
    if (connection == null) {
      return false;
    }
    if (connection.peerId != peerId) {
      return false;
    }
    final bytes = frame.encode();
    return _sendBytesToConnection(connection, bytes);
  }

  Future<bool> _sendPreparedFileTransferV3FrameTo(
    String peerId,
    AuthenticatedPayloadBuffer buffer, {
    required TransferConnectionBinding connection,
  }) async {
    if (connection.peerId != peerId) {
      return false;
    }
    final enqueue = _enqueueBytesToConnection;
    if (enqueue != null) {
      return enqueue(connection, buffer);
    }
    return _sendBytesToConnection(connection, buffer.payload);
  }

  bool _isSessionCurrent(void Function() requireCurrent) {
    try {
      requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  FileTransferData _incomingTransferDraft(
    MessageData message,
    FileTransferV3Metadata metadata,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return FileTransferData(
      transferId: message.uuid,
      messageUuid: message.uuid,
      messageRowId: 0,
      peerUid: message.sender,
      direction: FileTransferDirection.incoming,
      state: FileTransferState.queued,
      finalPath: '',
      tempPath: '',
      size: message.size,
      checksumAlgorithm: metadata.checksumAlgorithm,
      checksumValue: metadata.checksumValue,
      chunkSize: metadata.chunkSize,
      committedBytes: 0,
      resumeProofResetCount: 0,
      lastError: '',
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> _sendFileOfferError(
    MessageData message,
    FileTransferFailureReason failureReason,
  ) async {
    await _sendFileTransferV3ControlTo(
      message.sender,
      FileTransferV3Control(
        action: FileTransferV3Action.error,
        transferId: message.uuid,
        durableOffset: 0,
        size: math.max(0, message.size),
        failureReason: failureReason,
      ),
    );
  }

  Future<void> _handleFileTransferV3Offer(
    MessageData message, {
    required MessageData persistedMessage,
    required FileTransferData transfer,
    required bool isNewMessage,
    required void Function() requireCurrent,
  }) async {
    final metadata = FileTransferV3Metadata.parseOffer(
      message.content,
      size: message.size,
    );
    _incomingFlows[transfer.transferId] = selectFileTransferV3FlowParameters(
      offer: metadata,
      localLimits: _flowLimits,
    );
    if (isTerminalFileTransferState(transfer.state)) {
      requireCurrent();
      await _ackMessage(message);
      requireCurrent();
      await _replayIncomingTransferTerminal(transfer);
      return;
    }
    final connection = _operationConnectionBindings[transfer.transferId];
    if (connection != null) {
      _incomingConnectionBindings[transfer.transferId] = connection;
    }
    requireCurrent();
    if (isNewMessage) {
      _dispatchOutgoingMessage(persistedMessage);
    }
    if (transfer.tempPath.isEmpty) {
      final root = await _downloadDirectory();
      requireCurrent();
      final tempPath = await safeTransferTempPath(root, message.uuid);
      requireCurrent();
      final availableBytes = await _availableBytesForDownloadPath(root.path);
      requireCurrent();
      if (!hasEnoughStorageForFile(
        fileSize: message.size,
        availableBytes: availableBytes,
      )) {
        await _updateTransfer(
          transfer.transferId,
          state: FileTransferState.failed,
          tempPath: tempPath,
          lastError: 'storage',
          requireCurrent: requireCurrent,
        );
        try {
          await _sendFileOfferError(message, FileTransferFailureReason.storage);
        } finally {
          await _releaseIncomingAndStartNext(
            transfer,
            flush: false,
            connection: connection,
          );
          _notify('接收 ${message.name} 失败：存储空间不足');
        }
        return;
      }
      final updated = await _updateTransfer(
        transfer.transferId,
        tempPath: tempPath,
        requireCurrent: requireCurrent,
      );
      if (updated == null) {
        return;
      }
      transfer = updated;
    }

    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.incoming,
    );
    final desiredState = decision == TransferRuntimeDecision.started
        ? FileTransferState.negotiating
        : FileTransferState.queued;
    if (transfer.state != desiredState) {
      final updated = await _updateTransfer(
        transfer.transferId,
        state: desiredState,
        lastError: '',
        requireCurrent: requireCurrent,
      );
      if (updated == null) {
        return;
      }
      transfer = updated;
    }

    requireCurrent();
    await _ackMessage(message);
    requireCurrent();
    if (_transferRuntime.activeIncomingFor(transfer.peerUid) ==
        transfer.transferId) {
      await _sendFileTransferV3Ready(
        transfer.transferId,
        requireCurrent: requireCurrent,
      );
    }
  }

  Future<void> _replayIncomingTransferTerminal(
    FileTransferData transfer,
  ) async {
    final action = switch (transfer.state) {
      FileTransferState.completed => FileTransferV3Action.complete,
      FileTransferState.canceled => FileTransferV3Action.cancel,
      _ => FileTransferV3Action.error,
    };
    final failureReason = transfer.state == FileTransferState.failed
        ? switch (transfer.lastError) {
            'queue_full' => FileTransferFailureReason.queueFull,
            'storage' => FileTransferFailureReason.storage,
            'integrity' => FileTransferFailureReason.integrity,
            _ => FileTransferFailureReason.receiver,
          }
        : FileTransferFailureReason.none;
    await _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: action,
        transferId: transfer.transferId,
        durableOffset: transfer.state == FileTransferState.completed
            ? transfer.size
            : transfer.committedBytes,
        size: transfer.size,
        failureReason: failureReason,
      ),
    );
  }

  Future<void> _releaseFailedIncomingReadyAttempt(
    FileTransferData transfer, {
    required TransferConnectionBinding? connection,
    required bool startNext,
  }) async {
    await _releaseIncomingAndStartNext(
      transfer,
      flush: false,
      connection: connection,
      startNext: false,
    );
    if (startNext) {
      await _startNextQueuedIncomingTransfer(
        peerId: transfer.peerUid,
        connection: connection,
        excludedTransferIds: <String>{transfer.transferId},
      );
    }
  }

  Future<_IncomingReadyResult> _sendFileTransferV3Ready(
    String transferId, {
    void Function()? requireCurrent,
    TransferConnectionBinding? connection,
    bool startNextOnFailure = true,
  }) async {
    var transfer = await _database().fetchFileTransfer(transferId);
    requireCurrent?.call();
    if (transfer == null || isTerminalFileTransferState(transfer.state)) {
      return _IncomingReadyResult.unavailable;
    }
    var flow = _incomingFlows[transfer.transferId];
    if (flow == null) {
      final message = await _database().fetchAssociatedFileTransferMessage(
        transfer,
      );
      if (message == null) {
        return _IncomingReadyResult.unavailable;
      }
      try {
        flow = selectFileTransferV3FlowParameters(
          offer: FileTransferV3Metadata.parseOffer(
            message.content,
            size: message.size,
          ),
          localLimits: _flowLimits,
        );
      } on FileTransferV3MetadataException {
        return _IncomingReadyResult.unavailable;
      }
      _incomingFlows[transfer.transferId] = flow;
    }
    connection ??= _incomingConnectionBindings[transfer.transferId];
    if (connection != null) {
      _incomingConnectionBindings[transfer.transferId] = connection;
    }
    if (transfer.resumeProofResetCount == pendingResumeProofResetMarker &&
        transfer.committedBytes > 0) {
      transfer = await _completePendingIncomingResumeProofReset(
        transfer,
        requireCurrent: requireCurrent ?? () {},
      );
      if (transfer == null) return _IncomingReadyResult.unavailable;
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.incoming,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return _IncomingReadyResult.retained;
    }
    var tempFile = await _validatedIncomingTempFile(transfer);
    if (!await tempFile.exists()) {
      tempFile = await _validatedIncomingTempFile(transfer);
      await tempFile.parent.create(recursive: true);
      tempFile = await _validatedIncomingTempFile(transfer);
      await tempFile.create(exclusive: true);
    }
    tempFile = await _validatedIncomingTempFile(transfer);
    var durableOffset = await tempFile.length();
    if (durableOffset > transfer.size) {
      durableOffset = 0;
      tempFile = await _validatedIncomingTempFile(transfer);
      await tempFile.writeAsBytes(const <int>[], flush: true);
    }
    tempFile = await _validatedIncomingTempFile(transfer);
    final checksum = await _parallelChecksumForFilePrefix(
      tempFile,
      algorithm: transfer.checksumAlgorithm,
      end: durableOffset,
    );
    final resumeProofSha256 = durableOffset == 0
        ? ''
        : await resumeProofHash(
            await _validatedIncomingTempFile(transfer),
            resumeOffset: durableOffset,
            chunkSize: math.min(
              fileTransferV3ResumeProofWindowSize,
              durableOffset,
            ),
          );
    requireCurrent?.call();
    final updated = await _updateTransfer(
      transfer.transferId,
      state: durableOffset == transfer.size
          ? FileTransferState.verifying
          : FileTransferState.negotiating,
      committedBytes: durableOffset,
      lastError: '',
      requireCurrent: requireCurrent,
    );
    requireCurrent?.call();
    if (updated == null) {
      await checksum.dispose();
      await _releaseFailedIncomingReadyAttempt(
        transfer,
        connection: connection,
        startNext: startNextOnFailure,
      );
      return _IncomingReadyResult.unavailable;
    }
    _receivingTransfers[updated.transferId] = updated;
    _receivingTransferOffsets[updated.transferId] = durableOffset;
    _receivingTransferSequences[updated.transferId] = 0;
    if (durableOffset == updated.size) {
      await _sealIncomingFileTransferV3(updated, tempFile, checksum: checksum);
      if (updated.checksumValue.isNotEmpty) {
        await _finalizeIncomingFileTransferV3(updated);
        return _IncomingReadyResult.retained;
      }
    } else {
      _receivingChecksums[updated.transferId] = checksum;
    }
    final sent = await _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.ready,
        transferId: transfer.transferId,
        durableOffset: durableOffset,
        size: transfer.size,
        failureReason: FileTransferFailureReason.none,
        resumeProofSha256: resumeProofSha256,
        resumeProofLength: math.min(
          fileTransferV3ResumeProofWindowSize,
          durableOffset,
        ),
        chunkSize: flow.negotiated ? flow.chunkSize : 0,
        ackIntervalSize: flow.negotiated ? flow.ackIntervalSize : 0,
        windowSize: flow.negotiated ? flow.windowSize : 0,
      ),
      connection: connection,
    );
    if (sent) {
      return _IncomingReadyResult.retained;
    }
    await _updateTransfer(
      updated.transferId,
      state: FileTransferState.waitingReconnect,
      lastError: '',
    );
    await _releaseFailedIncomingReadyAttempt(
      updated,
      connection: connection,
      startNext: startNextOnFailure,
    );
    return _IncomingReadyResult.sendFailed;
  }

  Future<void> _handleFileTransferV3Control(
    FileTransferV3Control control, {
    required void Function() requireCurrent,
  }) async {
    requireCurrent();
    switch (control.action) {
      case FileTransferV3Action.ready:
        await _handleFileTransferV3Ready(
          control,
          requireCurrent: requireCurrent,
        );
        break;
      case FileTransferV3Action.ack:
        await _handleFileTransferV3Ack(control, requireCurrent: requireCurrent);
        break;
      case FileTransferV3Action.verify:
        await _handleFileTransferV3Verify(
          control,
          requireCurrent: requireCurrent,
        );
        break;
      case FileTransferV3Action.complete:
        await _handleFileTransferV3Complete(
          control,
          requireCurrent: requireCurrent,
        );
        break;
      case FileTransferV3Action.cancel:
        await _handleFileTransferV3Cancel(
          control,
          requireCurrent: requireCurrent,
        );
        break;
      case FileTransferV3Action.error:
        await _handleFileTransferV3Error(
          control,
          requireCurrent: requireCurrent,
        );
        break;
    }
  }

  Future<void> _handleFileTransferV3Ready(
    FileTransferV3Control control, {
    required void Function() requireCurrent,
  }) async {
    final connection = _operationConnectionBindings[control.transferId];
    if (connection == null) {
      throw const WireInputRejected(WireInputReason.sessionNotCurrent);
    }
    final transfer = await _database().fetchFileTransfer(control.transferId);
    requireCurrent();
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final activeOutgoing = _transferRuntime.activeOutgoingFor(transfer.peerUid);
    if ((transfer.state == FileTransferState.transferring ||
            transfer.state == FileTransferState.verifying) &&
        activeOutgoing == transfer.transferId) {
      if (_outgoingConnectionBindings[transfer.transferId] != connection) {
        throw const WireInputRejected(WireInputReason.sessionNotCurrent);
      }
      if (control.durableOffset <= transfer.committedBytes) {
        if (control.durableOffset == transfer.size &&
            transfer.checksumValue.isEmpty) {
          final message = await _database().fetchAssociatedFileTransferMessage(
            transfer,
          );
          requireCurrent();
          if (message != null) {
            await _sendOutgoingFileVerification(transfer, message);
          }
        }
        return;
      }
      throw const WireInputRejected(WireInputReason.transferOffsetInvalid);
    }
    _ackWatchdog.cancel(transfer.transferId);
    final message = await _database().fetchAssociatedFileTransferMessage(
      transfer,
    );
    requireCurrent();
    if (message == null) {
      return;
    }
    final offer = FileTransferV3Metadata.parseOffer(
      message.content,
      size: message.size,
    );
    late final FileTransferV3FlowParameters flow;
    if (control.hasFlowParameters) {
      if (!offer.supportsFlowNegotiation ||
          control.chunkSize > offer.maxChunkSize! ||
          control.windowSize > offer.maxWindowSize!) {
        throw const WireInputRejected(WireInputReason.transferPayloadInvalid);
      }
      flow = FileTransferV3FlowParameters(
        chunkSize: control.chunkSize,
        ackIntervalSize: control.ackIntervalSize,
        windowSize: control.windowSize,
      );
    } else {
      flow = FileTransferV3FlowParameters(
        chunkSize: offer.chunkSize,
        ackIntervalSize: math.min(
          offer.windowSize,
          math.max(fileTransferV3LegacyAckIntervalSize, offer.chunkSize),
        ),
        windowSize: offer.windowSize,
      );
    }
    _outgoingFlows[transfer.transferId] = flow;
    final source = _transferSourceForMessage(message, transfer);
    late final bool sourceIsValid;
    try {
      sourceIsValid =
          await source.exists() && await source.length() == transfer.size;
    } catch (error) {
      requireCurrent();
      await _handleOutgoingTransferError(transfer, error);
      return;
    }
    requireCurrent();
    if (!sourceIsValid) {
      await _failOutgoingFileTransferV3(
        transfer,
        FileTransferFailureReason.source,
      );
      return;
    }
    if (control.durableOffset > 0) {
      late final String sourceProof;
      try {
        sourceProof = await resumeProofHashForTransferSource(
          source,
          resumeOffset: control.durableOffset,
        );
      } catch (error) {
        requireCurrent();
        await _handleOutgoingTransferError(transfer, error);
        return;
      }
      requireCurrent();
      if (sourceProof != control.resumeProofSha256) {
        _ackWatchdog.cancel(transfer.transferId);
        _outgoingWindowEndOffsets.remove(transfer.transferId);
        _outgoingTransferSequences[transfer.transferId] = 0;
        await _sendFileTransferV3ControlTo(
          transfer.peerUid,
          FileTransferV3Control(
            action: FileTransferV3Action.error,
            transferId: transfer.transferId,
            durableOffset: control.durableOffset,
            size: transfer.size,
            failureReason: FileTransferFailureReason.resumeProofMismatch,
          ),
        );
        return;
      }
    }
    _outgoingConnectionBindings[transfer.transferId] = connection;
    if (activeOutgoing != null && activeOutgoing != transfer.transferId) {
      final decision = _transferRuntime.enqueue(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.outgoing,
      );
      if (decision == TransferRuntimeDecision.queued) {
        return;
      }
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.outgoing,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return;
    }
    final offset = control.durableOffset;
    _outgoingWindowEndOffsets[transfer.transferId] = offset;
    _outgoingTransferSequences[transfer.transferId] = 0;
    final updated = await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.transferring,
      committedBytes: offset,
      lastError: '',
    );
    if (updated == null) {
      await _releaseOutgoingAndStartNext(transfer, connection: connection);
      return;
    }
    if (offset >= updated.size) {
      await _sendOutgoingFileVerification(updated, message);
      return;
    }
    await _sendFileTransferV3WindowSafely(updated, message, offset: offset);
  }

  Future<void> _failOutgoingFileTransferV3(
    FileTransferData transfer,
    FileTransferFailureReason failureReason,
  ) async {
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.failed,
      lastError: failureReason.wireCode,
    );
    final connection =
        _outgoingConnectionBindings[transfer.transferId] ??
        _operationConnectionBindings[transfer.transferId];
    try {
      await _sendFileTransferV3ControlTo(
        transfer.peerUid,
        FileTransferV3Control(
          action: FileTransferV3Action.error,
          transferId: transfer.transferId,
          durableOffset: transfer.committedBytes,
          size: transfer.size,
          failureReason: failureReason,
        ),
      );
    } finally {
      await _releaseOutgoingAndStartNext(transfer, connection: connection);
      _notify(failureReason.wireCode);
    }
  }

  Future<void> _handleOutgoingFileTransferV3Error(
    String transferId,
    Object error,
  ) async {
    final transfer = await _database().fetchFileTransfer(transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    _logFailure(
      FileTransferDiagnosticKind.outgoingFailed,
      error,
      direction: FileTransferDirection.outgoing,
    );
    await _failOutgoingFileTransferV3(
      transfer,
      FileTransferFailureReason.source,
    );
  }

  Future<int?> _sendFileTransferV3WindowSafely(
    FileTransferData transfer,
    MessageData message, {
    required int offset,
  }) async {
    try {
      return await _runTransferSend<int?>(
        transfer.transferId,
        () => _sendFileTransferV3Window(transfer, message, offset: offset),
      );
    } catch (error) {
      await _handleOutgoingFileTransferV3Error(transfer.transferId, error);
      return null;
    }
  }

  Future<int?> _sendFileTransferV3Window(
    FileTransferData transfer,
    MessageData message, {
    required int offset,
    bool armWatchdog = true,
  }) async {
    if (!_isConnectedTo(transfer.peerUid) &&
        transfer.peerUid != _defaultPeerId()) {
      return null;
    }
    if (_transferRuntime.activeOutgoingFor(transfer.peerUid) !=
        transfer.transferId) {
      return null;
    }
    final connection = _outgoingConnectionBindings[transfer.transferId];
    if (connection == null || connection.peerId != transfer.peerUid) {
      return null;
    }
    final source = _transferSourceForMessage(message, transfer);
    final flow =
        _outgoingFlows[transfer.transferId] ??
        FileTransferV3FlowParameters.legacy;
    final durableOffset = offset;
    final windowEnd = math.min(transfer.size, durableOffset + flow.windowSize);
    var sequence = _outgoingTransferSequences[transfer.transferId] ?? 0;
    var cursor =
        _outgoingWindowEndOffsets[transfer.transferId] ?? durableOffset;
    if (cursor < durableOffset || cursor > windowEnd) {
      cursor = durableOffset;
    }
    final checksumState = transfer.checksumValue.isEmpty
        ? await _outgoingChecksumStateFor(
            transfer,
            source,
            requiredOffset: cursor,
          )
        : null;
    while (cursor < windowEnd) {
      if (_transferRuntime.activeOutgoingFor(transfer.peerUid) !=
          transfer.transferId) {
        return null;
      }
      final expectedWindow = armWatchdog
          ? _ackWatchdog.currentWindow(transfer.transferId)
          : null;
      final length = math.min(flow.chunkSize, windowEnd - cursor);
      final buffer = AuthenticatedPayloadBuffer.allocate(
        WhisperFrameV3.headerLength + length,
      );
      final payload = Uint8List.sublistView(
        buffer.payload,
        WhisperFrameV3.headerLength,
      );
      final readLength = await readTransferSourceRangeInto(
        source,
        payload,
        destinationOffset: 0,
        sourceOffset: cursor,
        length: length,
      );
      if (_transferRuntime.activeOutgoingFor(transfer.peerUid) !=
              transfer.transferId ||
          _outgoingConnectionBindings[transfer.transferId] != connection) {
        return cursor;
      }
      if (expectedWindow != null &&
          !identical(
            _ackWatchdog.currentWindow(transfer.transferId),
            expectedWindow,
          )) {
        return cursor;
      }
      if (readLength != length) {
        throw const FileSystemException(
          'Unexpected EOF while reading transfer frame',
        );
      }
      final frame = WhisperFrameV3(
        type: WhisperFrameType.fileData,
        transferId: transfer.transferId,
        offset: cursor,
        sequence: sequence,
        payload: payload,
      );
      frame.writeHeaderInto(buffer.payload);
      if (checksumState != null) {
        final payloadEnd = cursor + payload.length;
        if (checksumState.offset == cursor) {
          checksumState.checksum.add(payload);
          checksumState.offset = payloadEnd;
        } else if (checksumState.offset < payloadEnd) {
          throw StateError('Outgoing checksum stream is not contiguous');
        }
      }
      final sent = await _sendPreparedFileTransferV3FrameTo(
        transfer.peerUid,
        buffer,
        connection: connection,
      );
      if (!sent) {
        throw StateError('generation-bound transfer send failed');
      }
      cursor += payload.length;
      sequence++;
      _outgoingWindowEndOffsets[transfer.transferId] = cursor;
      _outgoingTransferSequences[transfer.transferId] = sequence;
      if (expectedWindow != null &&
          !identical(
            _ackWatchdog.currentWindow(transfer.transferId),
            expectedWindow,
          )) {
        return cursor;
      }
      final publishedWindow = armWatchdog
          ? _publishOutgoingAckWindow(
              transfer: transfer,
              message: message,
              connection: connection,
              durableOffset: durableOffset,
              sentEnd: cursor,
            )
          : null;
      await _yieldAfterFileTransferFrame();
      if (publishedWindow != null &&
          !identical(
            _ackWatchdog.currentWindow(transfer.transferId),
            publishedWindow,
          )) {
        return cursor;
      }
    }
    if (armWatchdog && cursor > durableOffset) {
      _armOutgoingAckWatchdog(
        transfer: transfer,
        message: message,
        connection: connection,
        durableOffset: durableOffset,
        sentEnd: cursor,
      );
    }
    return cursor;
  }

  Future<_OutgoingChecksumState> _outgoingChecksumStateFor(
    FileTransferData transfer,
    FileTransferSource source, {
    required int requiredOffset,
  }) async {
    final existing = _outgoingChecksums[transfer.transferId];
    if (existing != null && existing.offset >= requiredOffset) {
      return existing;
    }
    await existing?.dispose();
    final checksum = await _parallelChecksumForSourcePrefix(
      source,
      algorithm: transfer.checksumAlgorithm,
      end: requiredOffset,
    );
    final state = _OutgoingChecksumState(
      checksum: checksum,
      offset: requiredOffset,
    );
    _outgoingChecksums[transfer.transferId] = state;
    return state;
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
    );
  }

  Future<int?> _retransmitTimedOutWindow(
    TransferAckWindow timeout,
    MessageData message,
  ) {
    return _runTransferOperation<int?>(
      timeout.transferId,
      connection: timeout.connection,
      operation: () async {
        if (!identical(
              _ackWatchdog.currentWindow(timeout.transferId),
              timeout,
            ) ||
            _outgoingConnectionBindings[timeout.transferId] !=
                timeout.connection ||
            _transferRuntime.activeOutgoingFor(timeout.connection.peerId) !=
                timeout.transferId) {
          return null;
        }
        final transfer = await _database().fetchFileTransfer(
          timeout.transferId,
        );
        if (transfer == null ||
            transfer.peerUid != timeout.connection.peerId ||
            transfer.direction != FileTransferDirection.outgoing ||
            isTerminalFileTransferState(transfer.state) ||
            transfer.committedBytes != timeout.durableOffset) {
          return null;
        }
        _outgoingWindowEndOffsets[timeout.transferId] = timeout.durableOffset;
        try {
          return await _runTransferSend<int?>(
            timeout.transferId,
            () => _sendFileTransferV3Window(
              transfer,
              message,
              offset: timeout.durableOffset,
              armWatchdog: false,
            ),
          );
        } catch (error) {
          await _handleOutgoingTransferError(transfer, error);
          return null;
        }
      },
    );
  }

  Future<void> _markTimedOutTransferUnresponsive(
    TransferAckWindow timeout,
  ) async {
    if (_outgoingConnectionBindings[timeout.transferId] != timeout.connection ||
        _transferRuntime.activeOutgoingFor(timeout.connection.peerId) !=
            timeout.transferId) {
      return;
    }
    final transfer = await _database().fetchFileTransfer(timeout.transferId);
    if (_outgoingConnectionBindings[timeout.transferId] != timeout.connection ||
        transfer == null ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    await _markPeerUnresponsive(timeout.connection);
  }

  Future<void> _yieldAfterFileTransferFrame() {
    return Future<void>.delayed(Duration.zero);
  }

  Future<void> _handleFileTransferV3Data(
    WhisperFrameV3 frame, {
    required void Function() requireCurrent,
  }) async {
    var transfer = _receivingTransfers[frame.transferId];
    transfer ??= await _database().fetchFileTransfer(frame.transferId);
    requireCurrent();
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    if (_transferRuntime.activeIncomingFor(transfer.peerUid) !=
        transfer.transferId) {
      return;
    }
    final expectedOffset =
        _receivingTransferOffsets[transfer.transferId] ??
        transfer.committedBytes;
    if (frame.offset != expectedOffset) {
      final durableOffset = await _flushIncomingFileTransferV3(
        transfer,
        expectedOffset,
      );
      await _sendFileTransferV3Ack(transfer, durableOffset);
      return;
    }

    var writer = _receivingTransferWritersV3[transfer.transferId];
    var tempFile = File(transfer.tempPath);
    if (writer == null) {
      tempFile = await _validatedIncomingTempFile(transfer);
      var transitionStarted = false;
      if (!await tempFile.exists()) {
        tempFile = await _validatedIncomingTempFile(transfer);
        await tempFile.parent.create(recursive: true);
        tempFile = await _validatedIncomingTempFile(transfer);
        await tempFile.create(exclusive: true);
        transitionStarted = true;
      }
      tempFile = await _validatedIncomingTempFile(transfer);
      final currentLength = await tempFile.length();
      if (!transitionStarted) {
        requireCurrent();
      }
      if (currentLength > frame.offset) {
        tempFile = await _validatedIncomingTempFile(transfer);
        final truncatingWriter = await tempFile.open(mode: FileMode.write);
        try {
          await _validatedIncomingTempFile(transfer);
          await truncatingWriter.truncate(frame.offset);
        } finally {
          await truncatingWriter.close();
        }
      } else if (currentLength < frame.offset) {
        await _sendFileTransferV3Ack(transfer, currentLength);
        return;
      }
      tempFile = await _validatedIncomingTempFile(transfer);
      final openedWriter = await tempFile.open(mode: FileMode.writeOnlyAppend);
      writer = openedWriter;
      _receivingTransferWritersV3[transfer.transferId] = writer;
      _receivingWritePipelines[transfer.transferId] = _IncomingWritePipeline(
        writtenOffset: frame.offset,
      );
      _receivingTransfers[transfer.transferId] = transfer;
      _receivingTransferOffsets[transfer.transferId] = frame.offset;
    }

    var checksum = _receivingChecksums[transfer.transferId];
    if (checksum == null) {
      tempFile = await _validatedIncomingTempFile(transfer);
      checksum = await _parallelChecksumForFilePrefix(
        tempFile,
        algorithm: transfer.checksumAlgorithm,
        end: frame.offset,
      );
      requireCurrent();
      _receivingChecksums[transfer.transferId] = checksum;
    }
    final writePipeline = _receivingWritePipelines.putIfAbsent(
      transfer.transferId,
      () => _IncomingWritePipeline(writtenOffset: frame.offset),
    );
    final committedBytes = frame.offset + frame.payload.length;
    writePipeline.add(writer, frame.payload, endOffset: committedBytes);
    checksum.add(frame.payload);
    _receivingTransferOffsets[transfer.transferId] = committedBytes;
    _dispatchTransferProgress(
      transfer,
      committedBytes: committedBytes,
      state: committedBytes >= transfer.size
          ? FileTransferState.verifying
          : FileTransferState.transferring,
    );

    if (committedBytes >= transfer.size) {
      tempFile = await _validatedIncomingTempFile(transfer);
      final durableOffset = await _flushIncomingFileTransferV3(
        transfer,
        transfer.size,
      );
      await _sealIncomingFileTransferV3(transfer, tempFile);
      final updated = await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.verifying,
        committedBytes: durableOffset,
        lastError: '',
      );
      if (updated != null) {
        await _sendFileTransferV3Ack(updated, durableOffset);
        if (updated.checksumValue.isNotEmpty) {
          await _finalizeIncomingFileTransferV3(updated);
        }
      }
      return;
    }

    final ackInterval =
        _incomingFlows[transfer.transferId]?.ackIntervalSize ??
        fileTransferV3LegacyAckIntervalSize;
    if (committedBytes - transfer.committedBytes >= ackInterval) {
      final durableOffset = await _flushIncomingFileTransferV3(
        transfer,
        committedBytes,
      );
      final updated = await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.transferring,
        committedBytes: durableOffset,
        lastError: '',
      );
      if (updated != null) {
        _receivingTransfers[updated.transferId] = updated;
        await _sendFileTransferV3Ack(updated, durableOffset);
      }
    }
  }

  Future<void> _handleIncomingFileTransferV3Error(
    String transferId,
    Object error,
  ) async {
    final transfer =
        _receivingTransfers[transferId] ??
        await _database().fetchFileTransfer(transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }

    const failureReason = FileTransferFailureReason.receiver;
    final durableOffset =
        _receivingTransferOffsets[transferId] ?? transfer.committedBytes;
    _logFailure(
      FileTransferDiagnosticKind.incomingFailed,
      error,
      direction: FileTransferDirection.incoming,
    );
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.failed,
      committedBytes: math.min(durableOffset, transfer.size),
      lastError: failureReason.wireCode,
    );
    try {
      await _sendFileTransferV3ControlTo(
        transfer.peerUid,
        FileTransferV3Control(
          action: FileTransferV3Action.error,
          transferId: transfer.transferId,
          durableOffset: math.min(durableOffset, transfer.size),
          size: transfer.size,
          failureReason: failureReason,
        ),
      );
    } finally {
      await _releaseIncomingAndStartNext(
        transfer,
        flush: false,
        connection: _operationConnectionBindings[transfer.transferId],
      );
      _notify(failureReason.wireCode);
    }
  }

  void _dispatchTransferProgress(
    FileTransferData transfer, {
    required int committedBytes,
    required FileTransferState state,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = _incomingProgressDispatchTimes[transfer.transferId];
    if (state == FileTransferState.transferring &&
        previous != null &&
        now - previous < _progressDispatchIntervalMs) {
      return;
    }
    _incomingProgressDispatchTimes[transfer.transferId] = now;
    _emitTransferUpdated(
      TransferSnapshot(
        transferId: transfer.transferId,
        messageUuid: transfer.messageUuid,
        peerUid: transfer.peerUid,
        direction: transfer.direction,
        state: state,
        finalPath: transfer.finalPath,
        tempPath: transfer.tempPath,
        size: transfer.size,
        committedBytes: committedBytes,
        lastError: transfer.lastError,
        updatedAt: now,
      ),
    );
  }

  Future<int> _flushIncomingFileTransferV3(
    FileTransferData transfer,
    int offset,
  ) async {
    final writer = _receivingTransferWritersV3[transfer.transferId];
    if (writer != null) {
      await _receivingWritePipelines[transfer.transferId]?.drain();
      await writer.flush();
      return math.min(offset, transfer.size);
    }
    final sink = _receivingTransferSinks[transfer.transferId];
    if (sink != null) {
      await sink.flush();
    }
    return math.min(offset, transfer.size);
  }

  Future<void> _sealIncomingFileTransferV3(
    FileTransferData transfer,
    File tempFile, {
    ParallelStreamingChecksum? checksum,
  }) async {
    await _closeReceivingTransferFile(transfer.transferId, flush: true);
    checksum ??= _receivingChecksums.remove(transfer.transferId);
    checksum ??= await _parallelChecksumForFilePrefix(
      tempFile,
      algorithm: transfer.checksumAlgorithm,
      end: transfer.size,
    );
    final snapshot = await VerifiedTransferSnapshot.openFromStreamingDigest(
      tempFile,
      expectedSize: transfer.size,
      streamingSha256: await checksum.close(),
    );
    await _sealedIncomingSnapshots.remove(transfer.transferId)?.close();
    _sealedIncomingSnapshots[transfer.transferId] = snapshot;
  }

  Future<void> _sendFileTransferV3Ack(
    FileTransferData transfer,
    int durableOffset,
  ) async {
    await _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.ack,
        transferId: transfer.transferId,
        durableOffset: durableOffset,
        size: transfer.size,
        failureReason: FileTransferFailureReason.none,
      ),
    );
  }

  Future<String> _finishOutgoingChecksum(
    FileTransferData transfer,
    MessageData message,
  ) async {
    try {
      final source = _transferSourceForMessage(message, transfer);
      if (await source.length() != transfer.size) {
        return '';
      }
      final state = await _outgoingChecksumStateFor(
        transfer,
        source,
        requiredOffset: transfer.size,
      );
      return await state.finish(expectedOffset: transfer.size);
    } catch (error) {
      _logFailure(
        FileTransferDiagnosticKind.outgoingFailed,
        error,
        direction: FileTransferDirection.outgoing,
      );
      return '';
    }
  }

  Future<void> _sendOutgoingFileVerification(
    FileTransferData transfer,
    MessageData message,
  ) async {
    if (transfer.checksumValue.isNotEmpty) {
      return;
    }
    final checksum = await _finishOutgoingChecksum(transfer, message);
    final current = await _database().fetchFileTransfer(transfer.transferId);
    if (current == null || isTerminalFileTransferState(current.state)) {
      return;
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
      await _failOutgoingFileTransferV3(
        current,
        FileTransferFailureReason.source,
      );
      return;
    }
    final sent = await _sendFileTransferV3ControlTo(
      current.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.verify,
        transferId: current.transferId,
        durableOffset: current.size,
        size: current.size,
        failureReason: FileTransferFailureReason.none,
        checksumValue: checksum,
      ),
    );
    if (!sent) {
      await _updateTransfer(
        current.transferId,
        state: FileTransferState.waitingReconnect,
        lastError: '',
      );
    }
  }

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
        transfer.state == FileTransferState.verifying &&
        control.durableOffset == transfer.committedBytes) {
      return;
    }
    if (connection == null ||
        currentWindow == null ||
        currentWindow.transferId != transfer.transferId ||
        currentWindow.connection != connection ||
        currentWindow.connection.peerId != transfer.peerUid) {
      throw const WireInputRejected(WireInputReason.sessionNotCurrent);
    }
    if (control.durableOffset < transfer.committedBytes ||
        control.durableOffset > currentWindow.sentEnd) {
      throw const WireInputRejected(WireInputReason.transferOffsetInvalid);
    }
    if (!_ackWatchdog.acknowledge(currentWindow)) {
      throw const WireInputRejected(WireInputReason.sessionNotCurrent);
    }
    final durableOffset = control.durableOffset;
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
    await _sendFileTransferV3WindowSafely(
      updated,
      message,
      offset: durableOffset,
    );
  }

  Future<void> _handleFileTransferV3Verify(
    FileTransferV3Control control, {
    required void Function() requireCurrent,
  }) async {
    final transfer = await _database().fetchFileTransfer(control.transferId);
    requireCurrent();
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    if (transfer.checksumValue.isNotEmpty ||
        transfer.state != FileTransferState.verifying ||
        transfer.committedBytes != transfer.size) {
      throw const WireInputRejected(WireInputReason.transferFrameMismatch);
    }
    await _finalizeIncomingFileTransferV3(
      transfer,
      expectedChecksum: control.checksumValue,
    );
  }

  Future<void> _releaseOutgoingAndStartNext(
    FileTransferData transfer, {
    TransferConnectionBinding? connection,
    bool startNext = true,
  }) async {
    connection ??=
        _outgoingConnectionBindings[transfer.transferId] ??
        _operationConnectionBindings[transfer.transferId];
    _ackWatchdog.cancel(transfer.transferId);
    _outgoingWindowEndOffsets.remove(transfer.transferId);
    _outgoingTransferSequences.remove(transfer.transferId);
    _outgoingFlows.remove(transfer.transferId);
    await _outgoingChecksums.remove(transfer.transferId)?.dispose();
    await _closeOutgoingTransferSource(transfer.transferId);
    _outgoingConnectionBindings.remove(transfer.transferId);
    final released = _transferRuntime.release(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.outgoing,
    );
    if (released == TransferRuntimeReleaseKind.activeReleased &&
        startNext &&
        connection != null) {
      await _startQueuedOutgoingFileTransferV3(
        peerId: transfer.peerUid,
        connection: connection,
      );
    }
  }

  Future<void> _startQueuedOutgoingFileTransferV3({
    required String peerId,
    required TransferConnectionBinding connection,
  }) async {
    while (true) {
      final transferId = _transferRuntime.claimNext(
        peerId: peerId,
        direction: FileTransferDirection.outgoing,
      );
      if (transferId == null) {
        return;
      }
      final transfer = await _database().fetchFileTransfer(transferId);
      if (transfer == null ||
          transfer.peerUid != peerId ||
          transfer.direction != FileTransferDirection.outgoing ||
          isTerminalFileTransferState(transfer.state)) {
        _transferRuntime.release(
          peerId: peerId,
          transferId: transferId,
          direction: FileTransferDirection.outgoing,
        );
        continue;
      }
      final message = await _database().fetchAssociatedFileTransferMessage(
        transfer,
      );
      if (message == null) {
        _transferRuntime.release(
          peerId: peerId,
          transferId: transferId,
          direction: FileTransferDirection.outgoing,
        );
        continue;
      }
      final offset = transfer.committedBytes;
      final updated = await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.transferring,
        committedBytes: offset,
        lastError: '',
      );
      if (updated == null) {
        _transferRuntime.release(
          peerId: peerId,
          transferId: transferId,
          direction: FileTransferDirection.outgoing,
        );
        continue;
      }
      _outgoingConnectionBindings[transferId] = connection;
      await _sendFileTransferV3WindowSafely(updated, message, offset: offset);
      return;
    }
  }

  Future<void> _handleFileTransferV3Complete(
    FileTransferV3Control control, {
    required void Function() requireCurrent,
  }) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.completed,
      committedBytes: control.size,
      lastError: '',
      requireCurrent: requireCurrent,
    );
    final transfer = await _database().fetchFileTransfer(control.transferId);
    if (transfer != null) {
      await _releaseOutgoingAndStartNext(
        transfer,
        connection: _operationConnectionBindings[control.transferId],
      );
    }
  }

  Future<void> _handleFileTransferV3Cancel(
    FileTransferV3Control control, {
    required void Function() requireCurrent,
  }) async {
    final existing = await _database().fetchFileTransfer(control.transferId);
    requireCurrent();
    if (existing == null) {
      return;
    }
    await _updateTransfer(
      control.transferId,
      state: existing.direction == FileTransferDirection.outgoing
          ? FileTransferState.paused
          : FileTransferState.canceled,
      lastError: control.failureReason.wireCode,
      requireCurrent: requireCurrent,
    );
    final transfer = await _database().fetchFileTransfer(control.transferId);
    if (transfer == null) {
      return;
    }
    if (transfer.direction == FileTransferDirection.incoming) {
      await _releaseIncomingAndStartNext(
        transfer,
        flush: true,
        connection: _operationConnectionBindings[control.transferId],
      );
    } else {
      await _releaseOutgoingAndStartNext(
        transfer,
        connection: _operationConnectionBindings[control.transferId],
      );
    }
  }

  Future<void> _handleFileTransferV3Error(
    FileTransferV3Control control, {
    required void Function() requireCurrent,
  }) async {
    final existing = await _database().fetchFileTransfer(control.transferId);
    requireCurrent();
    if (existing != null &&
        existing.direction == FileTransferDirection.incoming &&
        control.failureReason ==
            FileTransferFailureReason.resumeProofMismatch &&
        control.durableOffset > 0 &&
        control.durableOffset == existing.committedBytes &&
        existing.tempPath.isNotEmpty) {
      if (existing.resumeProofResetCount == pendingResumeProofResetMarker) {
        final recovered = await _completePendingIncomingResumeProofReset(
          existing,
          requireCurrent: requireCurrent,
        );
        if (recovered != null && _isSessionCurrent(requireCurrent)) {
          await _sendFileTransferV3Ready(
            recovered.transferId,
            requireCurrent: requireCurrent,
          );
        }
        return;
      }
      var prefixMatches = false;
      try {
        final tempFile = await _validatedIncomingTempFile(existing);
        prefixMatches =
            await tempFile.exists() &&
            await tempFile.length() == control.durableOffset;
      } catch (_) {
        prefixMatches = false;
      }
      requireCurrent();
      if (prefixMatches) {
        final claimed = await _database().claimIncomingResumeProofReset(
          existing.transferId,
          expectedOffset: control.durableOffset,
        );
        requireCurrent();
        if (claimed != null) {
          final recovered = await _completePendingIncomingResumeProofReset(
            claimed,
            requireCurrent: requireCurrent,
          );
          if (recovered != null && _isSessionCurrent(requireCurrent)) {
            await _sendFileTransferV3Ready(
              recovered.transferId,
              requireCurrent: requireCurrent,
            );
          }
          return;
        }
      }
    }
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.failed,
      lastError: control.failureReason.wireCode,
      requireCurrent: requireCurrent,
    );
    final transfer = await _database().fetchFileTransfer(control.transferId);
    if (transfer != null) {
      if (transfer.direction == FileTransferDirection.incoming) {
        await _releaseIncomingAndStartNext(
          transfer,
          flush: true,
          connection: _operationConnectionBindings[control.transferId],
        );
      } else {
        await _releaseOutgoingAndStartNext(
          transfer,
          connection: _operationConnectionBindings[control.transferId],
        );
      }
    }
    if (control.failureReason != FileTransferFailureReason.none) {
      _notify(control.failureReason.wireCode);
    }
  }

  Future<FileTransferData?> _completePendingIncomingResumeProofReset(
    FileTransferData transfer, {
    required void Function() requireCurrent,
  }) async {
    if (transfer.direction != FileTransferDirection.incoming ||
        transfer.resumeProofResetCount != pendingResumeProofResetMarker ||
        transfer.committedBytes <= 0 ||
        transfer.tempPath.isEmpty) {
      return null;
    }
    requireCurrent();
    try {
      await _closeReceivingTransferFile(transfer.transferId, flush: false);
      var tempFile = await _validatedIncomingTempFile(transfer);
      await tempFile.parent.create(recursive: true);
      tempFile = await _validatedIncomingTempFile(transfer);
      if (!await tempFile.exists()) {
        tempFile = await _validatedIncomingTempFile(transfer);
        await tempFile.create(exclusive: true);
      }
      tempFile = await _validatedIncomingTempFile(transfer);
      final writer = await tempFile.open(mode: FileMode.append);
      try {
        await _validatedIncomingTempFile(transfer);
        await writer.truncate(0);
        await writer.flush();
      } finally {
        await writer.close();
      }
    } on FileSystemException catch (error) {
      _logFailure(FileTransferDiagnosticKind.resumeResetDeferred, error);
      _receivingTransfers.remove(transfer.transferId);
      await _receivingChecksums.remove(transfer.transferId)?.dispose();
      await _sealedIncomingSnapshots.remove(transfer.transferId)?.close();
      _receivingTransferOffsets.remove(transfer.transferId);
      _receivingTransferSequences.remove(transfer.transferId);
      return null;
    }
    _receivingTransfers.remove(transfer.transferId);
    await _receivingChecksums.remove(transfer.transferId)?.dispose();
    await _sealedIncomingSnapshots.remove(transfer.transferId)?.close();
    _receivingTransferOffsets[transfer.transferId] = 0;
    _receivingTransferSequences[transfer.transferId] = 0;
    try {
      return await _database().completeIncomingResumeProofReset(
        transfer.transferId,
        expectedOffset: transfer.committedBytes,
      );
    } catch (error) {
      _logFailure(FileTransferDiagnosticKind.resumeResetDeferred, error);
      return null;
    }
  }

  Future<void> _finalizeIncomingFileTransferV3(
    FileTransferData transfer, {
    String? expectedChecksum,
  }) async {
    await _closeReceivingTransferFile(transfer.transferId, flush: true);
    var tempFile = File(transfer.tempPath);
    VerifiedTransferSnapshot? snapshot;
    try {
      snapshot = _sealedIncomingSnapshots.remove(transfer.transferId);
      if (snapshot == null) {
        tempFile = await _validatedIncomingTempFile(transfer);
        var checksum = _receivingChecksums.remove(transfer.transferId);
        checksum ??= await _parallelChecksumForFilePrefix(
          tempFile,
          algorithm: transfer.checksumAlgorithm,
          end: transfer.size,
        );
        snapshot = await VerifiedTransferSnapshot.openFromStreamingDigest(
          tempFile,
          expectedSize: transfer.size,
          streamingSha256: await checksum.close(),
        );
      }
      if (snapshot.sha256Value !=
          (expectedChecksum ?? transfer.checksumValue)) {
        throw FileSystemException('transfer checksum mismatch', tempFile.path);
      }
    } on FileSystemException {
      await snapshot?.close();
      snapshot = null;
      tempFile = await _validatedIncomingTempFile(transfer);
      if (await tempFile.exists()) {
        tempFile = await _validatedIncomingTempFile(transfer);
        await tempFile.delete();
      }
      await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.failed,
        committedBytes: transfer.size,
        lastError: 'integrity',
      );
      try {
        await _sendFileTransferV3ControlTo(
          transfer.peerUid,
          FileTransferV3Control(
            action: FileTransferV3Action.error,
            transferId: transfer.transferId,
            durableOffset: transfer.size,
            size: transfer.size,
            failureReason: FileTransferFailureReason.integrity,
          ),
        );
      } finally {
        await _releaseIncomingAndStartNext(
          transfer,
          flush: false,
          connection: _operationConnectionBindings[transfer.transferId],
        );
      }
      return;
    }
    try {
      try {
        final message = await _database().fetchAssociatedFileTransferMessage(
          transfer,
        );
        if (message == null) {
          throw StateError('incoming file message is missing');
        }
        final root = await _downloadDirectory();
        final reservation = await reserveUniqueDownloadFile(root, message.name);
        late final File published;
        late final FileTransferData completed;
        try {
          final fileTimestamp = message.fileTimestamp ?? 0;
          published = await publishVerifiedSnapshot(
            snapshot,
            reservation,
            preparePublishedFile: fileTimestamp > 0
                ? (file) => _setPublishedFileTimestamp(file, fileTimestamp)
                : null,
          );
          completed = await _database().completeIncomingFileTransfer(
            transferId: transfer.transferId,
            finalPath: published.path,
            size: transfer.size,
          );
        } catch (_) {
          try {
            await discardDownloadReservation(reservation);
          } catch (cleanupError) {
            _logFailure(
              FileTransferDiagnosticKind.reservationCleanupFailed,
              cleanupError,
            );
          }
          rethrow;
        }
        await releaseDownloadReservation(reservation);

        try {
          _dispatchTransferData(completed);
        } catch (error) {
          _logFailure(
            FileTransferDiagnosticKind.completionDispatchFailed,
            error,
          );
        }
        try {
          tempFile = await _validatedIncomingTempFile(transfer);
          if (await tempFile.exists()) {
            tempFile = await _validatedIncomingTempFile(transfer);
            await tempFile.delete();
          }
        } catch (error) {
          _logFailure(
            FileTransferDiagnosticKind.temporaryFileCleanupFailed,
            error,
          );
        }
        try {
          await _notifyFileVisible(published.path);
        } catch (error) {
          _logFailure(
            FileTransferDiagnosticKind.visibilityNotificationFailed,
            error,
          );
        }
        await _sendFileTransferV3ControlTo(
          transfer.peerUid,
          FileTransferV3Control(
            action: FileTransferV3Action.complete,
            transferId: transfer.transferId,
            durableOffset: transfer.size,
            size: transfer.size,
            failureReason: FileTransferFailureReason.none,
          ),
        );
      } finally {
        await _releaseIncomingAndStartNext(
          transfer,
          flush: false,
          connection: _operationConnectionBindings[transfer.transferId],
        );
      }
    } finally {
      await snapshot.close();
    }
  }

  FileTransferSource _transferSourceForMessage(
    MessageData message,
    FileTransferData transfer,
  ) {
    return _outgoingTransferSources.putIfAbsent(
      transfer.transferId,
      () => _sourceFor(message.path, transfer.size),
    );
  }

  Future<void> _closeOutgoingTransferSource(String transferId) async {
    final source = _outgoingTransferSources.remove(transferId);
    if (source != null) {
      await closeTransferSource(source);
    }
  }

  Future<File> _validatedIncomingTempFile(FileTransferData transfer) async {
    if (transfer.direction != FileTransferDirection.incoming ||
        transfer.tempPath.isEmpty) {
      throw StateError('incoming transfer temp path is unavailable');
    }
    final root = await _downloadDirectory();
    return revalidateTransferTempFile(
      root: root,
      transferId: transfer.transferId,
      expectedPath: transfer.tempPath,
    );
  }

  FileTransferSource _sourceFor(String sourcePath, int expectedSize) {
    final factory = _transferSourceFactory;
    if (factory != null) {
      return factory(sourcePath, expectedSize);
    }
    if (isAndroidContentUri(sourcePath)) {
      return AndroidContentUriTransferSource(
        uri: sourcePath,
        expectedSize: expectedSize,
      );
    }
    return PathFileTransferSource(sourcePath);
  }

  Future<void> _handleOutgoingTransferError(
    FileTransferData transfer,
    Object error,
  ) async {
    const failureReason = FileTransferFailureReason.source;
    _logFailure(
      FileTransferDiagnosticKind.outgoingFailed,
      error,
      direction: FileTransferDirection.outgoing,
    );
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.failed,
      lastError: failureReason.wireCode,
    );
    await _releaseOutgoingAndStartNext(
      transfer,
      connection:
          _outgoingConnectionBindings[transfer.transferId] ??
          _operationConnectionBindings[transfer.transferId],
    );
    _notify(failureReason.wireCode);
  }

  Future<void> _failStaleIncomingQueueEntry(FileTransferData transfer) async {
    final failed = await _database().failRecoverableFileTransfer(
      transferId: transfer.transferId,
      peerUid: transfer.peerUid,
      direction: FileTransferDirection.incoming,
      reason: 'stale_queue',
    );
    if (failed != null) {
      _dispatchTransferData(failed);
    }
  }

  TransferConnectionBinding? _incomingProgressionConnection(
    String candidatePeerId,
    TransferConnectionBinding? preferred,
  ) {
    if (preferred?.peerId == candidatePeerId) {
      return preferred;
    }
    final current = _currentConnectionBinding(candidatePeerId);
    return current?.peerId == candidatePeerId ? current : null;
  }

  Future<void> _startNextQueuedIncomingTransfer({
    String? peerId,
    TransferConnectionBinding? connection,
    Set<String> excludedTransferIds = const <String>{},
  }) async {
    final peerIds = <String>{
      if (peerId?.isNotEmpty ?? false) peerId!,
      ..._connectedPeerIds(),
      if (_defaultPeerId().isNotEmpty) _defaultPeerId(),
    };
    for (final candidatePeerId in peerIds) {
      if (_transferRuntime.activeIncomingFor(candidatePeerId) != null) {
        continue;
      }
      final attemptedTransferIds = <String>{...excludedTransferIds};
      var preferredConnection = connection?.peerId == candidatePeerId
          ? connection
          : null;
      while (true) {
        final queuedId = _transferRuntime.claimNext(
          peerId: candidatePeerId,
          direction: FileTransferDirection.incoming,
        );
        if (queuedId == null) {
          break;
        }
        final queued = await _database().fetchFileTransfer(queuedId);
        if (queued == null ||
            queued.peerUid != candidatePeerId ||
            queued.direction != FileTransferDirection.incoming ||
            isTerminalFileTransferState(queued.state)) {
          _transferRuntime.release(
            peerId: candidatePeerId,
            transferId: queuedId,
            direction: FileTransferDirection.incoming,
          );
          continue;
        }
        if (await _database().fetchAssociatedFileTransferMessage(queued) ==
            null) {
          await _failStaleIncomingQueueEntry(queued);
          _transferRuntime.release(
            peerId: candidatePeerId,
            transferId: queuedId,
            direction: FileTransferDirection.incoming,
          );
          continue;
        }
        attemptedTransferIds.add(queuedId);
        final queuedConnection = _incomingProgressionConnection(
          candidatePeerId,
          preferredConnection,
        );
        if (queuedConnection != null) {
          _operationConnectionBindings[queuedId] = queuedConnection;
        }
        late final _IncomingReadyResult readyResult;
        try {
          readyResult = await _sendFileTransferV3Ready(
            queuedId,
            connection: queuedConnection,
            startNextOnFailure: false,
          );
        } finally {
          if (_operationConnectionBindings[queuedId] == queuedConnection) {
            _operationConnectionBindings.remove(queuedId);
          }
        }
        if (readyResult == _IncomingReadyResult.sendFailed) {
          if (queuedConnection == preferredConnection) {
            preferredConnection = null;
          }
          continue;
        }
        if (readyResult == _IncomingReadyResult.retained &&
            _transferRuntime.activeIncomingFor(candidatePeerId) == queuedId) {
          return;
        }
        final unclaimed = await _database().fetchFileTransfer(queuedId);
        if (unclaimed != null &&
            !isTerminalFileTransferState(unclaimed.state)) {
          await _failStaleIncomingQueueEntry(unclaimed);
        }
        _transferRuntime.release(
          peerId: candidatePeerId,
          transferId: queuedId,
          direction: FileTransferDirection.incoming,
        );
      }
      final items = await _database().fetchRecoverableFileTransfersForPeer(
        candidatePeerId,
        direction: FileTransferDirection.incoming,
      );
      items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final item in items) {
        if (attemptedTransferIds.contains(item.transferId)) {
          continue;
        }
        if (item.state == FileTransferState.queued ||
            item.state == FileTransferState.waitingReconnect) {
          if (await _database().fetchAssociatedFileTransferMessage(item) ==
              null) {
            await _failStaleIncomingQueueEntry(item);
            continue;
          }
          final decision = _transferRuntime.enqueue(
            peerId: candidatePeerId,
            transferId: item.transferId,
            direction: FileTransferDirection.incoming,
          );
          if (decision == TransferRuntimeDecision.queued) {
            return;
          }
          // WSP2 可续传栈已删除,排队中的接收任务统一走 V3 就绪握手。
          attemptedTransferIds.add(item.transferId);
          final itemConnection = _incomingProgressionConnection(
            candidatePeerId,
            preferredConnection,
          );
          if (itemConnection != null) {
            _operationConnectionBindings[item.transferId] = itemConnection;
          }
          late final _IncomingReadyResult readyResult;
          try {
            readyResult = await _sendFileTransferV3Ready(
              item.transferId,
              connection: itemConnection,
              startNextOnFailure: false,
            );
          } finally {
            if (_operationConnectionBindings[item.transferId] ==
                itemConnection) {
              _operationConnectionBindings.remove(item.transferId);
            }
          }
          if (readyResult == _IncomingReadyResult.sendFailed) {
            if (itemConnection == preferredConnection) {
              preferredConnection = null;
            }
            continue;
          }
          if (readyResult == _IncomingReadyResult.retained &&
              _transferRuntime.activeIncomingFor(candidatePeerId) ==
                  item.transferId) {
            return;
          }
          final unclaimed = await _database().fetchFileTransfer(
            item.transferId,
          );
          if (unclaimed != null &&
              !isTerminalFileTransferState(unclaimed.state)) {
            await _failStaleIncomingQueueEntry(unclaimed);
          }
          _transferRuntime.release(
            peerId: candidatePeerId,
            transferId: item.transferId,
            direction: FileTransferDirection.incoming,
          );
        }
      }
    }
  }

  Future<void> _markRecoverableTransfersWaitingReconnect() async {
    final items = await _database().fetchRecoverableFileTransfers();
    for (final item in items) {
      if (item.state == FileTransferState.completed ||
          item.state == FileTransferState.failed ||
          item.state == FileTransferState.canceled) {
        continue;
      }
      final connection =
          _outgoingConnectionBindings[item.transferId] ??
          TransferConnectionBinding(peerId: item.peerUid, generation: -1);
      await _runTransferOperation<void>(
        item.transferId,
        connection: connection,
        operation: () async {
          final current = await _database().fetchFileTransfer(item.transferId);
          if (current == null || isTerminalFileTransferState(current.state)) {
            return;
          }
          await _updateTransfer(
            current.transferId,
            state: FileTransferState.waitingReconnect,
          );
        },
      );
    }
  }

  Future<void> _closeReceivingTransferFile(
    String transferId, {
    bool flush = false,
  }) async {
    final writer = _receivingTransferWritersV3.remove(transferId);
    final writePipeline = _receivingWritePipelines.remove(transferId);
    if (writer != null) {
      try {
        await writePipeline?.drain();
        if (flush) {
          await writer.flush();
        }
      } finally {
        await writer.close();
      }
    }
    final sink = _receivingTransferSinks.remove(transferId);
    if (sink != null) {
      if (flush) {
        await sink.flush();
      }
      await sink.close();
    }
  }

  Future<void> _closeAllReceivingTransferFiles({bool flush = false}) async {
    final transferIds = <String>{
      ..._receivingTransferWritersV3.keys,
      ..._receivingWritePipelines.keys,
    };
    for (final transferId in transferIds) {
      await _closeReceivingTransferFile(transferId, flush: flush);
    }
    final sinks = _receivingTransferSinks.values.toList(growable: false);
    _receivingTransferSinks.clear();
    for (final sink in sinks) {
      if (flush) {
        await sink.flush();
      }
      await sink.close();
    }
  }

  Future<void> _clearActiveIncomingTransfer(
    String transferId, {
    bool flush = false,
  }) async {
    await _closeReceivingTransferFile(transferId, flush: flush);
    await _sealedIncomingSnapshots.remove(transferId)?.close();
    _receivingTransfers.remove(transferId);
    await _receivingChecksums.remove(transferId)?.dispose();
    _receivingTransferOffsets.remove(transferId);
    _receivingTransferSequences.remove(transferId);
    _incomingProgressDispatchTimes.remove(transferId);
    _incomingFlows.remove(transferId);
  }

  Future<void> _releaseIncomingAndStartNext(
    FileTransferData transfer, {
    required bool flush,
    TransferConnectionBinding? connection,
    bool startNext = true,
  }) async {
    connection ??=
        _incomingConnectionBindings[transfer.transferId] ??
        _operationConnectionBindings[transfer.transferId];
    await _clearActiveIncomingTransfer(transfer.transferId, flush: flush);
    final released = _transferRuntime.release(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.incoming,
    );
    _incomingConnectionBindings.remove(transfer.transferId);
    if (released == TransferRuntimeReleaseKind.activeReleased && startNext) {
      await _startNextQueuedIncomingTransfer(
        peerId: transfer.peerUid,
        connection: connection,
      );
    }
  }

  Future<void> _closeResumableHandles() async {
    await _closeAllReceivingTransferFiles(flush: true);
    for (final snapshot in _sealedIncomingSnapshots.values) {
      await snapshot.close();
    }
    _sealedIncomingSnapshots.clear();
    _receivingTransfers.clear();
    for (final checksum in _receivingChecksums.values) {
      await checksum.dispose();
    }
    _receivingChecksums.clear();
    _receivingTransferOffsets.clear();
    _receivingTransferSequences.clear();
    _incomingProgressDispatchTimes.clear();
    _receivingTransferWritersV3.clear();
    _receivingWritePipelines.clear();
    _transferRuntime.clearAll();
    _outgoingConnectionBindings.clear();
    _incomingConnectionBindings.clear();
    _outgoingTransferSequences.clear();
    _outgoingWindowEndOffsets.clear();
    _outgoingFlows.clear();
    _incomingFlows.clear();
    for (final checksum in _outgoingChecksums.values) {
      await checksum.dispose();
    }
    _outgoingChecksums.clear();
    final sources = _outgoingTransferSources.values.toList(growable: false);
    _outgoingTransferSources.clear();
    for (final source in sources) {
      await closeTransferSource(source);
    }
  }

  /// 原 svrmanager `_resumeRecoverableOutgoingTransfers`:
  /// 显式请求恢复时重新对可恢复的 outgoing 传输发 offer。
  Future<void> resumeRecoverableOutgoing() async {
    final peerIds = <String>{
      ..._connectedPeerIds(),
      if (_defaultPeerId().isNotEmpty) _defaultPeerId(),
    };
    for (final peerId in peerIds) {
      if (!_supportsFileTransferV3For(peerId)) {
        continue;
      }
      final connection = _currentConnectionBinding(peerId);
      if (connection == null) {
        continue;
      }
      final items = await _database().fetchRecoverableFileTransfersForPeer(
        peerId,
        direction: FileTransferDirection.outgoing,
      );
      items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final item in items) {
        if (item.state == FileTransferState.completed ||
            item.state == FileTransferState.failed ||
            item.state == FileTransferState.canceled) {
          continue;
        }
        final message = await _database().fetchAssociatedFileTransferMessage(
          item,
        );
        if (message != null) {
          final sent = await _sendFileTransferV3OfferTo(
            item.peerUid,
            message,
            connection: connection,
          );
          if (!sent) {
            await _updateTransfer(
              item.transferId,
              state: FileTransferState.waitingReconnect,
            );
            continue;
          }
        } else {
          continue;
        }
        await _updateTransfer(
          item.transferId,
          state: FileTransferState.negotiating,
        );
      }
    }
  }
}
