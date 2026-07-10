import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/file_path_policy.dart';
import 'package:whisper/socket/file_transfer_source.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/peer_transfer_runtime.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/socket/wire_message_replay.dart';
import 'package:whisper/state/peer_profile.dart';

/// 与 svrmanager `_buildMessage` 现签名逐字对应(msg/fileName/path/uid/fileTimestamp 原本未标类型)。
typedef TransferMessageBuilder = MessageData Function(
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

final class _IncomingFrameLockEntry {
  final Lock lock = Lock();
  int users = 0;
}

final class _TransferAdmissionRejected implements Exception {
  const _TransferAdmissionRejected(this.decision);

  final FileTransferAdmission decision;
}

Future<void> _setFileLastModified(File file, int timestamp) {
  return file.setLastModified(DateTime.fromMillisecondsSinceEpoch(timestamp));
}

/// V3 文件传输引擎:从 WsSvrManager 机械抽离的发送/接收/断点恢复栈。
/// 与 socket 层的全部交互经构造注入的回调完成,不直接持有连接对象。
class FileTransferEngine {
  FileTransferEngine({
    required FutureOr<bool> Function(String peerId, Object bytes)
        sendBytesToPeer,
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
    LocalDatabase Function() database = LocalDatabase.new,
  })  : _sendBytesToPeer = sendBytesToPeer,
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
        _database = database;

  static const int defaultTransferChunkSize = fileTransferV3FramePayloadSize;
  static const String defaultTransferChecksumAlgorithm =
      fileTransferV3ChecksumAlgorithm;

  final FutureOr<bool> Function(String peerId, Object bytes) _sendBytesToPeer;
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
  final LocalDatabase Function() _database;

  final _sendFileLock = Lock();
  final MultiPeerTransferRuntime _transferRuntime = MultiPeerTransferRuntime();
  final Map<String, IOSink> _receivingTransferSinks = <String, IOSink>{};
  final Map<String, RandomAccessFile> _receivingTransferWritersV3 =
      <String, RandomAccessFile>{};
  final Map<String, FileTransferData> _receivingTransfers =
      <String, FileTransferData>{};
  final Map<String, StreamingChecksum> _receivingChecksums =
      <String, StreamingChecksum>{};
  final Map<String, int> _receivingTransferOffsets = <String, int>{};
  final Map<String, int> _receivingTransferSequences = <String, int>{};
  final Map<String, int> _outgoingWindowSentAt = <String, int>{};
  final Map<String, int> _outgoingTransferSequences = <String, int>{};
  final Map<String, int> _outgoingWindowEndOffsets = <String, int>{};
  final Map<String, _IncomingFrameLockEntry> _incomingFrameLocks =
      <String, _IncomingFrameLockEntry>{};

  bool _supportsFileTransferV3For(String peerId) =>
      _remoteProfileFor(peerId)?.capabilities.fileTransferV3 == true;

  Future<void> retryTransfer(String transferId) async {
    final database = _database();
    var transfer = await database.fetchFileTransfer(transferId);
    if (transfer == null) {
      return;
    }
    var associatedMessage =
        await database.fetchAssociatedFileTransferMessage(transfer);
    if (associatedMessage == null) {
      return;
    }
    if (transfer.state == FileTransferState.canceled ||
        transfer.state == FileTransferState.completed) {
      return;
    }
    if (transfer.state == FileTransferState.failed) {
      final connected = _supportsFileTransferV3For(transfer.peerUid) &&
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
      associatedMessage =
          await database.fetchAssociatedFileTransferMessage(transfer);
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
    if (transfer.direction == FileTransferDirection.outgoing) {
      await _sendFileTransferV3OfferTo(transfer.peerUid, associatedMessage);
      await _updateTransfer(
        transferId,
        state: FileTransferState.negotiating,
        lastError: '',
      );
      return;
    }
    await _updateTransfer(
      transferId,
      state: FileTransferState.negotiating,
      lastError: '',
    );
    await _sendFileTransferV3Ready(transferId);
  }

  Future<void> cancelTransfer(String transferId) async {
    final transfer = await _database().fetchFileTransfer(transferId);
    if (transfer == null) {
      return;
    }
    await _updateTransfer(
      transferId,
      state: FileTransferState.canceled,
      lastError: '',
    );
    if (_supportsFileTransferV3For(transfer.peerUid) &&
        _isConnectedTo(transfer.peerUid)) {
      await _sendFileTransferV3ControlTo(
        transfer.peerUid,
        FileTransferV3Control(
          action: FileTransferV3Action.cancel,
          transferId: transfer.transferId,
          durableOffset: transfer.committedBytes,
          size: transfer.size,
          errorCode: '',
          errorMessage: '',
        ),
      );
    }
    if (_transferRuntime.activeIncomingFor(transfer.peerUid) == transferId) {
      await _clearActiveIncomingTransfer(transferId, flush: true);
      await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
    }
    if (_transferRuntime.activeOutgoingFor(transfer.peerUid) == transferId) {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingWindowSentAt.remove(transferId);
    _outgoingWindowEndOffsets.remove(transferId);
    _outgoingTransferSequences.remove(transferId);
  }

  Future<bool> sendPickedFileTo(String peerId, PickedTransferFile item) async {
    if (item.isAndroidContentUri) {
      return sendAndroidContentUriTo(
        peerId,
        uri: item.androidContentUri!,
        name: item.name,
        size: item.size,
        fileTimestamp: item.lastModified,
      );
    }
    final path = item.path;
    if (path == null || path.isEmpty) {
      return false;
    }
    return sendFileTo(peerId, path);
  }

  Future<bool> sendFileTo(String peerId, String path) async {
    final canUseLegacySink = _hasLegacySinkFor(peerId);
    if (peerId.isEmpty || (!_isConnectedTo(peerId) && !canUseLegacySink)) {
      return false;
    }
    if (!_supportsFileTransferV3For(peerId)) {
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
    final fileName = p.basename(path);
    if (size < 0 ||
        size > fileTransferV3MaxFileSize ||
        !validateIncomingFileName(fileName)) {
      _notify('文件名或文件大小不符合传输要求');
      return false;
    }
    late final String checksumValue;
    try {
      checksumValue = await checksumForTransferSource(
        source,
        algorithm: fileTransferV3ChecksumAlgorithm,
      );
      if (await source.length() != size) {
        throw const FileSystemException('源文件在校验期间发生变化');
      }
    } catch (error) {
      _notify(_outgoingTransferErrorMessage(error));
      return false;
    }
    final timestamp = (await file.lastModified()).millisecondsSinceEpoch;
    return _persistAndOfferOutgoingTransfer(
      peerId: peerId,
      sourcePath: path,
      fileName: fileName,
      size: size,
      fileTimestamp: timestamp,
      checksumValue: checksumValue,
    );
  }

  Future<bool> sendAndroidContentUriTo(
    String peerId, {
    required String uri,
    required String name,
    required int size,
    required int fileTimestamp,
  }) async {
    final canUseLegacySink = _hasLegacySinkFor(peerId);
    if (peerId.isEmpty || (!_isConnectedTo(peerId) && !canUseLegacySink)) {
      return false;
    }
    if (uri.isEmpty || !isAndroidContentUri(uri)) {
      return false;
    }
    if (!_supportsFileTransferV3For(peerId)) {
      _notify('当前设备版本不支持无复制文件发送');
      return false;
    }
    final fileName = name.isNotEmpty ? name : 'document';
    if (size < 0 ||
        size > fileTransferV3MaxFileSize ||
        !validateIncomingFileName(fileName)) {
      _notify('文件名或文件大小不符合传输要求');
      return false;
    }
    final source = _sourceFor(uri, size);
    late final String checksumValue;
    try {
      if (!await source.exists()) {
        return false;
      }
      if (await source.length() != size) {
        throw const FileSystemException(
          '文件实际大小与选择时记录的大小不一致',
        );
      }
      checksumValue = await checksumForTransferSource(
        source,
        algorithm: fileTransferV3ChecksumAlgorithm,
        expectedLength: size,
      );
      if (await source.length() != size) {
        throw const FileSystemException('文件在校验期间发生变化');
      }
    } catch (error) {
      _notify(_outgoingTransferErrorMessage(error));
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return _persistAndOfferOutgoingTransfer(
      peerId: peerId,
      sourcePath: uri,
      fileName: fileName,
      size: size,
      fileTimestamp: fileTimestamp > 0 ? fileTimestamp : now,
      checksumValue: checksumValue,
    );
  }

  Future<bool> _persistAndOfferOutgoingTransfer({
    required String peerId,
    required String sourcePath,
    required String fileName,
    required int size,
    required int fileTimestamp,
    required String checksumValue,
  }) {
    return _sendFileLock.synchronized(() async {
      if (!_isConnectedTo(peerId) && !_hasLegacySinkFor(peerId)) {
        return false;
      }
      final metadata = FileTransferV3Metadata(
        checksumValue: checksumValue,
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
      final admission = await _database().admitFileTransfer(
        message: draft,
        transfer: transfer,
      );
      if (admission.decision != FileTransferAdmission.admitted) {
        _notify('文件传输队列已满');
        return false;
      }
      final message = admission.message!;
      _dispatchTransferData(admission.transfer!);
      _dispatchOutgoingMessage(message);
      return _sendFileTransferV3OfferTo(peerId, message);
    });
  }

  /// fileOffer/fileData/fileReady/fileAck/fileComplete/fileCancel/fileError
  /// 帧入口(原 svrmanager `_handleWhisperFrameV3` 的非 message 分支);
  /// message 帧由 svrmanager 自行处理,不会转发到这里。
  Future<void> handleFrame(
    String authenticatedPeerId,
    WhisperFrameV3 frame, {
    required void Function() requireCurrent,
  }) async {
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
    final lockEntry = _incomingFrameLocks.putIfAbsent(
      frame.transferId,
      _IncomingFrameLockEntry.new,
    );
    lockEntry.users++;
    try {
      await lockEntry.lock.synchronized(() async {
        requireBoundSession();
        await _handleFrameLocked(
          authenticatedPeerId,
          frame,
          requireCurrent: requireBoundSession,
        );
      });
    } finally {
      lockEntry.users--;
      if (lockEntry.users == 0 &&
          identical(_incomingFrameLocks[frame.transferId], lockEntry)) {
        _incomingFrameLocks.remove(frame.transferId);
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
          await _sendFileOfferError(message, 'invalid_size');
          return;
        }
        wireValidation.requireAccepted();
        if (message.path.isNotEmpty) {
          await _sendFileOfferError(message, 'invalid_path');
          return;
        }
        if (!validateIncomingFileName(message.name)) {
          await _sendFileOfferError(message, 'invalid_name');
          return;
        }
        late final FileTransferV3Metadata metadata;
        try {
          metadata = FileTransferV3Metadata.parseOffer(
            message.content,
            size: message.size,
          );
        } on FileTransferV3MetadataException catch (error) {
          await _sendFileOfferError(message, error.reason);
          return;
        }
        final existing = await _database().fetchFileTransfer(frame.transferId);
        requireCurrent();
        if (existing != null && existing.peerUid != authenticatedPeerId) {
          throw const WireInputRejected(
            WireInputReason.transferPeerMismatch,
          );
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
          throw const WireInputRejected(
            WireInputReason.transferFrameMismatch,
          );
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
                  ? 'message_missing'
                  : 'queue_full',
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
          throw const WireInputRejected(
            WireInputReason.transferPeerMismatch,
          );
        }
        final expectedOffset = _receivingTransferOffsets[transfer.transferId] ??
            transfer.committedBytes;
        final expectedSequence =
            _receivingTransferSequences[transfer.transferId] ?? 0;
        final validation = WireInputPolicy.validateFileData(
          frame: frame,
          transfer: transfer,
          authenticatedPeerId: authenticatedPeerId,
          expectedOffset: expectedOffset,
          expectedSequence: expectedSequence,
          isActive: _transferRuntime.activeIncomingFor(transfer.peerUid) ==
              transfer.transferId,
        );
        if (validation.isIgnored) {
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
        } catch (error, stackTrace) {
          if (error is WireInputRejected) {
            rethrow;
          }
          await _handleIncomingFileTransferV3Error(
            frame.transferId,
            error,
            stackTrace,
          );
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
        final transfer =
            await _database().fetchFileTransfer(control.transferId);
        requireCurrent();
        if (transfer == null) {
          throw const WireInputRejected(WireInputReason.transferNotFound);
        }
        if (transfer.peerUid != authenticatedPeerId) {
          throw const WireInputRejected(
            WireInputReason.transferPeerMismatch,
          );
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
        } catch (error, stackTrace) {
          if (error is WireInputRejected) {
            rethrow;
          }
          if (transfer.direction == FileTransferDirection.incoming) {
            await _handleIncomingFileTransferV3Error(
              control.transferId,
              error,
              stackTrace,
            );
          } else {
            await _handleOutgoingFileTransferV3Error(
              control.transferId,
              error,
              stackTrace,
            );
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

  bool _matchesIncomingFileOffer(
    MessageData persisted,
    MessageData incoming,
  ) {
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
    if (persistRecoverable) {
      await _markRecoverableTransfersWaitingReconnect();
    }
    await _closeResumableHandles();
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
      committedBytes:
          committedBytes == null ? const Value.absent() : Value(committedBytes),
      lastError: lastError == null ? const Value.absent() : Value(lastError),
      finalPath: finalPath == null ? const Value.absent() : Value(finalPath),
      tempPath: tempPath == null ? const Value.absent() : Value(tempPath),
      checksumValue:
          checksumValue == null ? const Value.absent() : Value(checksumValue),
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
      if (item.direction == FileTransferDirection.incoming) {
        await _clearActiveIncomingTransfer(
          item.transferId,
          flush: true,
          releaseRuntime: false,
        );
      }
      _outgoingWindowSentAt.remove(item.transferId);
      _outgoingWindowEndOffsets.remove(item.transferId);
      _outgoingTransferSequences.remove(item.transferId);
      await _updateTransfer(
        item.transferId,
        state: FileTransferState.waitingReconnect,
        lastError: '',
      );
    }
  }

  Future<bool> _sendFileTransferV3OfferTo(
    String peerId,
    MessageData message,
  ) {
    _outgoingTransferSequences[message.uuid] = 0;
    _outgoingWindowEndOffsets.remove(message.uuid);
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
    );
  }

  Future<bool> _sendFileTransferV3ControlTo(
    String peerId,
    FileTransferV3Control control,
  ) {
    final type = switch (control.action) {
      FileTransferV3Action.ready => WhisperFrameType.fileReady,
      FileTransferV3Action.ack => WhisperFrameType.fileAck,
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
    );
  }

  Future<bool> _sendFileTransferV3FrameTo(
    String peerId,
    WhisperFrameV3 frame,
  ) async {
    return _sendBytesToPeer(peerId, frame.encode());
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
    String errorCode,
  ) async {
    await _sendFileTransferV3ControlTo(
      message.sender,
      FileTransferV3Control(
        action: FileTransferV3Action.error,
        transferId: message.uuid,
        durableOffset: 0,
        size: math.max(0, message.size),
        errorCode: errorCode,
        errorMessage: errorCode,
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
    if (isTerminalFileTransferState(transfer.state)) {
      requireCurrent();
      await _ackMessage(message);
      requireCurrent();
      await _replayIncomingTransferTerminal(transfer);
      return;
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
        await _sendFileOfferError(message, 'storage');
        _notify('接收 ${message.name} 失败：存储空间不足');
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
    final errorCode = transfer.state == FileTransferState.failed
        ? switch (transfer.lastError) {
            'queue_full' => 'queue_full',
            'storage' => 'storage',
            'integrity' => 'integrity',
            _ => 'receiver',
          }
        : '';
    await _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: action,
        transferId: transfer.transferId,
        durableOffset: transfer.state == FileTransferState.completed
            ? transfer.size
            : transfer.committedBytes,
        size: transfer.size,
        errorCode: errorCode,
        errorMessage: errorCode,
      ),
    );
  }

  Future<void> _sendFileTransferV3Ready(
    String transferId, {
    void Function()? requireCurrent,
  }) async {
    var transfer = await _database().fetchFileTransfer(transferId);
    requireCurrent?.call();
    if (transfer == null || isTerminalFileTransferState(transfer.state)) {
      return;
    }
    if (transfer.resumeProofResetCount == pendingResumeProofResetMarker &&
        transfer.committedBytes > 0) {
      transfer = await _completePendingIncomingResumeProofReset(
        transfer,
        requireCurrent: requireCurrent ?? () {},
      );
      if (transfer == null) return;
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.incoming,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return;
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
    final checksum = await streamingChecksumForFilePrefix(
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
    if (updated != null) {
      _receivingTransfers[updated.transferId] = updated;
      _receivingChecksums[updated.transferId] = checksum;
      _receivingTransferOffsets[updated.transferId] = durableOffset;
      _receivingTransferSequences[updated.transferId] = 0;
      if (durableOffset == updated.size) {
        await _finalizeIncomingFileTransferV3(updated);
        return;
      }
    }
    await _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.ready,
        transferId: transfer.transferId,
        durableOffset: durableOffset,
        size: transfer.size,
        errorCode: '',
        errorMessage: '',
        resumeProofSha256: resumeProofSha256,
        resumeProofLength: math.min(
          fileTransferV3ResumeProofWindowSize,
          durableOffset,
        ),
      ),
    );
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
        await _handleFileTransferV3Ack(
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
    final transfer = await _database().fetchFileTransfer(control.transferId);
    requireCurrent();
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final message =
        await _database().fetchAssociatedFileTransferMessage(transfer);
    requireCurrent();
    if (message == null) {
      return;
    }
    final source = _transferSourceForMessage(message, transfer);
    late final bool sourceIsValid;
    try {
      sourceIsValid =
          await source.exists() && await source.length() == transfer.size;
    } catch (error, stackTrace) {
      requireCurrent();
      await _handleOutgoingTransferError(
        transfer,
        error,
        stackTrace,
      );
      return;
    }
    requireCurrent();
    if (!sourceIsValid) {
      await _failOutgoingFileTransferV3(
        transfer,
        '源文件不存在或已变化，无法继续传输',
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
      } catch (error, stackTrace) {
        requireCurrent();
        await _handleOutgoingTransferError(transfer, error, stackTrace);
        return;
      }
      requireCurrent();
      if (sourceProof != control.resumeProofSha256) {
        _outgoingWindowEndOffsets.remove(transfer.transferId);
        _outgoingTransferSequences[transfer.transferId] = 0;
        await _sendFileTransferV3ControlTo(
          transfer.peerUid,
          FileTransferV3Control(
            action: FileTransferV3Action.error,
            transferId: transfer.transferId,
            durableOffset: control.durableOffset,
            size: transfer.size,
            errorCode: 'resume_proof_mismatch',
            errorMessage: '续传校验失败，将从头开始传输',
          ),
        );
        return;
      }
    }
    final activeOutgoing = _transferRuntime.activeOutgoingFor(transfer.peerUid);
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
    final offset = math.min(control.durableOffset, transfer.size);
    _outgoingWindowEndOffsets[transfer.transferId] = offset;
    _outgoingTransferSequences[transfer.transferId] = 0;
    final updated = await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.transferring,
      committedBytes: offset,
      lastError: '',
    );
    if (updated == null) {
      return;
    }
    await _sendFileTransferV3WindowSafely(
      updated,
      message,
      offset: offset,
    );
  }

  Future<void> _failOutgoingFileTransferV3(
    FileTransferData transfer,
    String message,
  ) async {
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.failed,
      lastError: message,
    );
    _transferRuntime.complete(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.outgoing,
    );
    _outgoingWindowSentAt.remove(transfer.transferId);
    _outgoingWindowEndOffsets.remove(transfer.transferId);
    _outgoingTransferSequences.remove(transfer.transferId);
    await _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.error,
        transferId: transfer.transferId,
        durableOffset: transfer.committedBytes,
        size: transfer.size,
        errorCode: 'source',
        errorMessage: message,
      ),
    );
    _notify(message);
  }

  Future<void> _handleOutgoingFileTransferV3Error(
    String transferId,
    Object error,
    StackTrace stackTrace,
  ) async {
    final transfer = await _database().fetchFileTransfer(transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final message = _outgoingFileTransferV3ErrorMessage(error);
    logger.i(
      'file transfer v3 outgoing failed transfer=$transferId '
      'peer=${transfer.peerUid} type=${error.runtimeType}',
    );
    await _failOutgoingFileTransferV3(
      transfer,
      message,
    );
  }

  String _outgoingFileTransferV3ErrorMessage(Object error) {
    if (error is FileSystemException) {
      final detail = error.message.isNotEmpty
          ? error.message
          : error.osError?.message ?? error.toString();
      return '发送文件失败：$detail';
    }
    return '发送文件失败：$error';
  }

  Future<void> _sendFileTransferV3WindowSafely(
    FileTransferData transfer,
    MessageData message, {
    required int offset,
  }) async {
    try {
      await _sendFileTransferV3Window(
        transfer,
        message,
        offset: offset,
      );
    } catch (error, stackTrace) {
      await _handleOutgoingFileTransferV3Error(
        transfer.transferId,
        error,
        stackTrace,
      );
    }
  }

  Future<void> _sendFileTransferV3Window(
    FileTransferData transfer,
    MessageData message, {
    required int offset,
  }) async {
    if (!_isConnectedTo(transfer.peerUid) &&
        transfer.peerUid != _defaultPeerId()) {
      return;
    }
    if (_transferRuntime.activeOutgoingFor(transfer.peerUid) !=
        transfer.transferId) {
      return;
    }
    final source = _transferSourceForMessage(message, transfer);
    final durableOffset = math.min(offset, transfer.size);
    final windowEnd =
        math.min(transfer.size, durableOffset + fileTransferV3WindowSize);
    _outgoingWindowSentAt[transfer.transferId] =
        DateTime.now().microsecondsSinceEpoch;
    var sequence = _outgoingTransferSequences[transfer.transferId] ?? 0;
    var cursor =
        _outgoingWindowEndOffsets[transfer.transferId] ?? durableOffset;
    if (cursor < durableOffset || cursor > windowEnd) {
      cursor = durableOffset;
    }
    while (cursor < windowEnd) {
      if (_transferRuntime.activeOutgoingFor(transfer.peerUid) !=
          transfer.transferId) {
        return;
      }
      final length =
          math.min(fileTransferV3FramePayloadSize, windowEnd - cursor);
      final payload = await source.readRange(cursor, length);
      if (payload.length != length) {
        throw const FileSystemException(
          'Unexpected EOF while reading transfer frame',
        );
      }
      final sent = await _sendFileTransferV3FrameTo(
        transfer.peerUid,
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: transfer.transferId,
          offset: cursor,
          sequence: sequence,
          payload: payload,
        ),
      );
      if (!sent) {
        return;
      }
      cursor += payload.length;
      sequence++;
      _outgoingWindowEndOffsets[transfer.transferId] = cursor;
      await _yieldAfterFileTransferFrame();
    }
    _outgoingTransferSequences[transfer.transferId] = sequence;
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
    final expectedOffset = _receivingTransferOffsets[transfer.transferId] ??
        transfer.committedBytes;
    if (frame.offset != expectedOffset) {
      final durableOffset = await _flushIncomingFileTransferV3(
        transfer,
        expectedOffset,
      );
      await _sendFileTransferV3Ack(transfer, durableOffset);
      return;
    }

    var tempFile = await _validatedIncomingTempFile(transfer);
    var transitionStarted = false;
    if (!await tempFile.exists()) {
      tempFile = await _validatedIncomingTempFile(transfer);
      await tempFile.parent.create(recursive: true);
      tempFile = await _validatedIncomingTempFile(transfer);
      await tempFile.create(exclusive: true);
      transitionStarted = true;
    }
    var writer = _receivingTransferWritersV3[transfer.transferId];
    if (writer == null) {
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
      _receivingTransfers[transfer.transferId] = transfer;
      _receivingTransferOffsets[transfer.transferId] = frame.offset;
    }

    var checksum = _receivingChecksums[transfer.transferId];
    if (checksum == null) {
      tempFile = await _validatedIncomingTempFile(transfer);
      checksum = await streamingChecksumForFilePrefix(
        tempFile,
        algorithm: transfer.checksumAlgorithm,
        end: frame.offset,
      );
      requireCurrent();
      _receivingChecksums[transfer.transferId] = checksum;
    }
    await _validatedIncomingTempFile(transfer);
    await writer.writeFrom(frame.payload);
    checksum.add(frame.payload);
    final committedBytes = frame.offset + frame.payload.length;
    _receivingTransferOffsets[transfer.transferId] = committedBytes;
    _dispatchTransferProgress(
      transfer,
      committedBytes: committedBytes,
      state: committedBytes >= transfer.size
          ? FileTransferState.verifying
          : FileTransferState.transferring,
    );

    if (committedBytes >= transfer.size) {
      final durableOffset = await _flushIncomingFileTransferV3(
        transfer,
        transfer.size,
      );
      final updated = await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.verifying,
        committedBytes: durableOffset,
        lastError: '',
      );
      if (updated != null) {
        await _finalizeIncomingFileTransferV3(updated);
      }
      return;
    }

    if (committedBytes - transfer.committedBytes >=
        fileTransferV3AckIntervalSize) {
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
    StackTrace stackTrace,
  ) async {
    final transfer = _receivingTransfers[transferId] ??
        await _database().fetchFileTransfer(transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }

    final message = _incomingFileTransferV3ErrorMessage(error);
    final durableOffset =
        _receivingTransferOffsets[transferId] ?? transfer.committedBytes;
    logger.i(
      'file transfer v3 incoming failed transfer=$transferId '
      'peer=${transfer.peerUid} type=${error.runtimeType}',
    );
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.failed,
      committedBytes: math.min(durableOffset, transfer.size),
      lastError: message,
    );
    await _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.error,
        transferId: transfer.transferId,
        durableOffset: math.min(durableOffset, transfer.size),
        size: transfer.size,
        errorCode: 'receiver',
        errorMessage: message,
      ),
    );
    await _clearFailedIncomingFileTransferV3(transfer);
    await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
    _notify(message);
  }

  String _incomingFileTransferV3ErrorMessage(Object error) {
    if (error is FileSystemException) {
      final detail = error.message.isNotEmpty
          ? error.message
          : error.osError?.message ?? error.toString();
      return '接收文件失败：$detail';
    }
    return '接收文件失败：$error';
  }

  Future<void> _clearFailedIncomingFileTransferV3(
    FileTransferData transfer,
  ) async {
    try {
      await _closeReceivingTransferFile(transfer.transferId, flush: false);
    } catch (error, stackTrace) {
      logger.i(
        'file transfer v3 failed close ignored transfer=${transfer.transferId} '
        'error=$error\n$stackTrace',
      );
    }
    _receivingTransfers.remove(transfer.transferId);
    _receivingChecksums.remove(transfer.transferId);
    _receivingTransferOffsets.remove(transfer.transferId);
    _receivingTransferSequences.remove(transfer.transferId);
    _transferRuntime.complete(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.incoming,
    );
  }

  void _dispatchTransferProgress(
    FileTransferData transfer, {
    required int committedBytes,
    required FileTransferState state,
  }) {
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
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<int> _flushIncomingFileTransferV3(
    FileTransferData transfer,
    int offset,
  ) async {
    final writer = _receivingTransferWritersV3[transfer.transferId];
    if (writer != null) {
      await writer.flush();
      return math.min(offset, transfer.size);
    }
    final sink = _receivingTransferSinks[transfer.transferId];
    if (sink != null) {
      await sink.flush();
    }
    return math.min(offset, transfer.size);
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
        errorCode: '',
        errorMessage: '',
      ),
    );
  }

  Future<void> _handleFileTransferV3Ack(
    FileTransferV3Control control, {
    required void Function() requireCurrent,
  }) async {
    final transfer = await _database().fetchFileTransfer(control.transferId);
    requireCurrent();
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final durableOffset = math.min(control.durableOffset, transfer.size);
    if (durableOffset < transfer.committedBytes) {
      _outgoingWindowEndOffsets[control.transferId] = durableOffset;
    }
    final updated = await _updateTransfer(
      transfer.transferId,
      state: durableOffset >= transfer.size
          ? FileTransferState.verifying
          : FileTransferState.transferring,
      committedBytes: durableOffset,
      lastError: '',
    );
    if (updated == null || durableOffset >= updated.size) {
      _outgoingWindowSentAt.remove(control.transferId);
      _outgoingWindowEndOffsets.remove(control.transferId);
      return;
    }
    final message =
        await _database().fetchAssociatedFileTransferMessage(updated);
    if (message == null) {
      return;
    }
    await _sendFileTransferV3WindowSafely(
      updated,
      message,
      offset: durableOffset,
    );
  }

  Future<void> _startQueuedOutgoingFileTransferV3(String? transferId) async {
    if (transferId == null || transferId.isEmpty) {
      return;
    }
    final transfer = await _database().fetchFileTransfer(transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.outgoing,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return;
    }
    final message =
        await _database().fetchAssociatedFileTransferMessage(transfer);
    if (message == null) {
      return;
    }
    final offset = math.min(transfer.committedBytes, transfer.size);
    final updated = await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.transferring,
      committedBytes: offset,
      lastError: '',
    );
    if (updated == null) {
      return;
    }
    await _sendFileTransferV3WindowSafely(
      updated,
      message,
      offset: offset,
    );
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
    String? nextTransferId;
    if (transfer != null) {
      nextTransferId = _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingWindowSentAt.remove(control.transferId);
    _outgoingWindowEndOffsets.remove(control.transferId);
    _outgoingTransferSequences.remove(control.transferId);
    await _startQueuedOutgoingFileTransferV3(nextTransferId);
  }

  Future<void> _handleFileTransferV3Cancel(
    FileTransferV3Control control, {
    required void Function() requireCurrent,
  }) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.canceled,
      lastError: control.errorMessage,
      requireCurrent: requireCurrent,
    );
    final transfer = await _database().fetchFileTransfer(control.transferId);
    if (transfer == null) {
      return;
    }
    if (transfer.direction == FileTransferDirection.incoming) {
      await _clearActiveIncomingTransfer(transfer.transferId, flush: true);
      await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
    } else {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingTransferSequences.remove(transfer.transferId);
  }

  Future<void> _handleFileTransferV3Error(
    FileTransferV3Control control, {
    required void Function() requireCurrent,
  }) async {
    final existing = await _database().fetchFileTransfer(control.transferId);
    requireCurrent();
    if (existing != null &&
        existing.direction == FileTransferDirection.incoming &&
        control.errorCode == 'resume_proof_mismatch' &&
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
        prefixMatches = await tempFile.exists() &&
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
      lastError: control.errorMessage,
      requireCurrent: requireCurrent,
    );
    final transfer = await _database().fetchFileTransfer(control.transferId);
    if (transfer != null) {
      if (transfer.direction == FileTransferDirection.incoming) {
        await _clearActiveIncomingTransfer(transfer.transferId, flush: true);
        await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
      } else {
        _transferRuntime.complete(
          peerId: transfer.peerUid,
          transferId: transfer.transferId,
          direction: FileTransferDirection.outgoing,
        );
      }
    }
    _outgoingTransferSequences.remove(control.transferId);
    if (control.errorMessage.isNotEmpty) {
      _notify(control.errorMessage);
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
      logger.i(
        'resume proof reset filesystem recovery deferred '
        'transfer=${transfer.transferId} type=${error.runtimeType}',
      );
      _receivingTransfers.remove(transfer.transferId);
      _receivingChecksums.remove(transfer.transferId);
      _receivingTransferOffsets.remove(transfer.transferId);
      _receivingTransferSequences.remove(transfer.transferId);
      return null;
    }
    _receivingTransfers.remove(transfer.transferId);
    _receivingChecksums.remove(transfer.transferId);
    _receivingTransferOffsets[transfer.transferId] = 0;
    _receivingTransferSequences[transfer.transferId] = 0;
    try {
      return await _database().completeIncomingResumeProofReset(
        transfer.transferId,
        expectedOffset: transfer.committedBytes,
      );
    } catch (error) {
      logger.i(
        'resume proof reset completion deferred '
        'transfer=${transfer.transferId} type=${error.runtimeType}',
      );
      return null;
    }
  }

  Future<void> _finalizeIncomingFileTransferV3(
    FileTransferData transfer,
  ) async {
    await _closeReceivingTransferFile(transfer.transferId, flush: true);
    var tempFile = await _validatedIncomingTempFile(transfer);
    _receivingChecksums.remove(transfer.transferId)?.close();
    VerifiedTransferSnapshot? snapshot;
    try {
      snapshot = await VerifiedTransferSnapshot.open(
        tempFile,
        expectedSize: transfer.size,
        expectedSha256: transfer.checksumValue,
      );
    } on FileSystemException {
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
      await _sendFileTransferV3ControlTo(
        transfer.peerUid,
        FileTransferV3Control(
          action: FileTransferV3Action.error,
          transferId: transfer.transferId,
          durableOffset: transfer.size,
          size: transfer.size,
          errorCode: 'integrity',
          errorMessage: '文件完整性校验失败',
        ),
      );
      await _clearActiveIncomingTransfer(transfer.transferId, flush: false);
      await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
      return;
    }
    try {
      try {
        final message =
            await _database().fetchAssociatedFileTransferMessage(transfer);
        if (message == null) {
          throw StateError('incoming file message is missing');
        }
        final root = await _downloadDirectory();
        final reservation = await reserveUniqueDownloadFile(root, message.name);
        late final File published;
        late final FileTransferData completed;
        try {
          published = await publishVerifiedSnapshot(snapshot, reservation);
          final fileTimestamp = message.fileTimestamp ?? 0;
          if (fileTimestamp > 0) {
            await _setPublishedFileTimestamp(published, fileTimestamp);
            await refreshPublishedDownloadReservation(reservation);
          }
          completed = await _database().completeIncomingFileTransfer(
            transferId: transfer.transferId,
            finalPath: published.path,
            size: transfer.size,
          );
        } catch (_) {
          try {
            await discardDownloadReservation(reservation);
          } catch (cleanupError, cleanupStackTrace) {
            logger.i(
              'file transfer reservation cleanup failed '
              'transfer=${transfer.transferId} type=${cleanupError.runtimeType}\n'
              '$cleanupStackTrace',
            );
          }
          rethrow;
        }
        await releaseDownloadReservation(reservation);

        try {
          _dispatchTransferData(completed);
        } catch (error) {
          logger.i(
            'file transfer completion dispatch failed '
            'transfer=${transfer.transferId} type=${error.runtimeType}',
          );
        }
        try {
          tempFile = await _validatedIncomingTempFile(transfer);
          if (await tempFile.exists()) {
            tempFile = await _validatedIncomingTempFile(transfer);
            await tempFile.delete();
          }
        } catch (error) {
          logger.i(
            'file transfer temp cleanup failed '
            'transfer=${transfer.transferId} type=${error.runtimeType}',
          );
        }
        try {
          await _notifyFileVisible(published.path);
        } catch (error) {
          logger.i(
            'file transfer visibility notification failed '
            'transfer=${transfer.transferId} type=${error.runtimeType}',
          );
        }
        await _sendFileTransferV3ControlTo(
          transfer.peerUid,
          FileTransferV3Control(
            action: FileTransferV3Action.complete,
            transferId: transfer.transferId,
            durableOffset: transfer.size,
            size: transfer.size,
            errorCode: '',
            errorMessage: '',
          ),
        );
      } finally {
        await _clearActiveIncomingTransfer(transfer.transferId, flush: false);
        await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
      }
    } finally {
      await snapshot.close();
    }
  }

  FileTransferSource _transferSourceForMessage(
    MessageData message,
    FileTransferData transfer,
  ) {
    return _sourceFor(message.path, transfer.size);
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
    StackTrace stackTrace,
  ) async {
    final errorMessage = _outgoingTransferErrorMessage(error);
    logger.i(
      'outgoing transfer failed transfer=${transfer.transferId} '
      'peer=${transfer.peerUid} type=${error.runtimeType}',
    );
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.failed,
      lastError: errorMessage,
    );
    if (_transferRuntime.activeOutgoingFor(transfer.peerUid) ==
        transfer.transferId) {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingWindowSentAt.remove(transfer.transferId);
    _outgoingWindowEndOffsets.remove(transfer.transferId);
    _notify(errorMessage);
  }

  String _outgoingTransferErrorMessage(Object error) {
    if (error is FileSystemException) {
      final detail = error.message.isNotEmpty
          ? error.message
          : error.osError?.message ?? error.toString();
      return '发送文件失败：$detail';
    }
    return '发送文件失败：$error';
  }

  Future<void> _startNextQueuedIncomingTransfer({String? peerId}) async {
    final peerIds = <String>{
      if (peerId?.isNotEmpty ?? false) peerId!,
      ..._connectedPeerIds(),
      if (_defaultPeerId().isNotEmpty) _defaultPeerId(),
    };
    for (final candidatePeerId in peerIds) {
      if (_transferRuntime.activeIncomingFor(candidatePeerId) != null) {
        continue;
      }
      final items = await _database().fetchRecoverableFileTransfersForPeer(
        candidatePeerId,
        direction: FileTransferDirection.incoming,
      );
      items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final item in items) {
        if (item.state == FileTransferState.queued ||
            item.state == FileTransferState.waitingReconnect) {
          // WSP2 可续传栈已删除,排队中的接收任务统一走 V3 就绪握手。
          await _sendFileTransferV3Ready(item.transferId);
          return;
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
      await _updateTransfer(
        item.transferId,
        state: FileTransferState.waitingReconnect,
      );
    }
  }

  Future<void> _closeReceivingTransferFile(
    String transferId, {
    bool flush = false,
  }) async {
    final writer = _receivingTransferWritersV3.remove(transferId);
    if (writer != null) {
      if (flush) {
        await writer.flush();
      }
      await writer.close();
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
    final writers = _receivingTransferWritersV3.values.toList(growable: false);
    _receivingTransferWritersV3.clear();
    for (final writer in writers) {
      if (flush) {
        await writer.flush();
      }
      await writer.close();
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
    bool releaseRuntime = true,
  }) async {
    final transfer = _receivingTransfers[transferId] ??
        await _database().fetchFileTransfer(transferId);
    await _closeReceivingTransferFile(transferId, flush: flush);
    _receivingTransfers.remove(transferId);
    _receivingChecksums.remove(transferId);
    _receivingTransferOffsets.remove(transferId);
    _receivingTransferSequences.remove(transferId);
    if (releaseRuntime && transfer != null) {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: transferId,
        direction: FileTransferDirection.incoming,
      );
    }
  }

  Future<void> _closeResumableHandles() async {
    await _closeAllReceivingTransferFiles(flush: true);
    _receivingTransfers.clear();
    _receivingChecksums.clear();
    _receivingTransferOffsets.clear();
    _receivingTransferSequences.clear();
    _receivingTransferWritersV3.clear();
    _transferRuntime.clearAll();
    _outgoingWindowSentAt.clear();
    _outgoingTransferSequences.clear();
    _outgoingWindowEndOffsets.clear();
  }

  /// 原 svrmanager `_resumeRecoverableOutgoingTransfers`:
  /// 鉴权成功后重新对可恢复的 outgoing 传输发 offer。
  Future<void> resumeRecoverableOutgoing() async {
    final peerIds = <String>{
      ..._connectedPeerIds(),
      if (_defaultPeerId().isNotEmpty) _defaultPeerId(),
    };
    for (final peerId in peerIds) {
      if (!_supportsFileTransferV3For(peerId)) {
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
        final message =
            await _database().fetchAssociatedFileTransferMessage(item);
        if (message != null) {
          await _sendFileTransferV3OfferTo(item.peerUid, message);
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
