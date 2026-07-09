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
import 'package:whisper/socket/file_transfer_source.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/peer_transfer_runtime.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_message_codec.dart';
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
    required TransferMessageBuilder buildMessage,
    required void Function(MessageData message) dispatchOutgoingMessage,
    required void Function(MessageData message) ackMessage,
    LocalDatabase Function() database = LocalDatabase.new,
  })  : _sendBytesToPeer = sendBytesToPeer,
        _emitTransferUpdated = emitTransferUpdated,
        _notify = notify,
        _remoteProfileFor = remoteProfileFor,
        _isConnectedTo = isConnectedTo,
        _connectedPeerIds = connectedPeerIds,
        _defaultPeerId = defaultPeerId,
        _hasLegacySinkFor = hasLegacySinkFor,
        _buildMessage = buildMessage,
        _dispatchOutgoingMessage = dispatchOutgoingMessage,
        _ackMessage = ackMessage,
        _database = database;

  static const int defaultTransferChunkSize = 32 * 1024 * 1024;
  static const String defaultTransferChecksumAlgorithm = 'none';
  static const int _transferChunkSize = defaultTransferChunkSize;

  final FutureOr<bool> Function(String peerId, Object bytes) _sendBytesToPeer;
  final void Function(TransferSnapshot snapshot) _emitTransferUpdated;
  final void Function(String message) _notify;
  final PeerProfile? Function(String peerId) _remoteProfileFor;
  final bool Function(String peerId) _isConnectedTo;
  final Set<String> Function() _connectedPeerIds;
  final String Function() _defaultPeerId;
  final bool Function(String peerId) _hasLegacySinkFor;
  final TransferMessageBuilder _buildMessage;
  final void Function(MessageData message) _dispatchOutgoingMessage;
  final void Function(MessageData message) _ackMessage;
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
  final Map<String, int> _outgoingWindowSentAt = <String, int>{};
  final Map<String, int> _outgoingTransferSequences = <String, int>{};
  final Map<String, int> _outgoingWindowEndOffsets = <String, int>{};

  bool _supportsFileTransferV3For(String peerId) =>
      _remoteProfileFor(peerId)?.capabilities.fileTransferV3 == true;

  Future<void> retryTransfer(String transferId) async {
    final transfer = await _database().fetchFileTransfer(transferId);
    if (transfer == null) {
      return;
    }
    if (transfer.state == FileTransferState.canceled ||
        transfer.state == FileTransferState.completed) {
      return;
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
      final message =
          await _database().fetchMessageByUuid(transfer.messageUuid);
      if (message != null) {
        await _sendFileTransferV3OfferTo(transfer.peerUid, message);
      }
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
    return _sendFileLock.synchronized(() async {
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
      final size = file.lengthSync();
      final timestamp = (await file.lastModified()).millisecondsSinceEpoch;
      final fileName = p.basename(path);
      final now = DateTime.now().millisecondsSinceEpoch;
      const checksumAlgorithm = defaultTransferChecksumAlgorithm;
      const checksumValue = '';
      final content = jsonEncode(
        _FileTransferMetadata(
          checksumAlgorithm: checksumAlgorithm,
          checksumValue: checksumValue,
          chunkSize: fileTransferV3WindowSize,
          protocolVersion: fileTransferV3ProtocolVersion,
        ).toJson(),
      );
      var message = _buildMessage(
          MessageEnum.File, content, "", fileName, size, false,
          path: path,
          md5: '',
          fileTimestamp: timestamp,
          receiverOverride: peerId);
      await _database().insertMessage(message);
      final metadata = _FileTransferMetadata.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
      );
      logger.i(
        'file transfer v3 offer transfer=${message.uuid} size=$size path=$path',
      );
      await _persistTransfer(
        FileTransferData(
          transferId: message.uuid,
          messageUuid: message.uuid,
          peerUid: peerId,
          direction: FileTransferDirection.outgoing,
          state: FileTransferState.queued,
          finalPath: path,
          tempPath: '',
          size: size,
          checksumAlgorithm: metadata.checksumAlgorithm,
          checksumValue: metadata.checksumValue,
          chunkSize: metadata.chunkSize,
          committedBytes: 0,
          lastError: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
      _dispatchOutgoingMessage(message);
      return _sendFileTransferV3OfferTo(peerId, message);
    });
  }

  Future<bool> sendAndroidContentUriTo(
    String peerId, {
    required String uri,
    required String name,
    required int size,
    required int fileTimestamp,
  }) async {
    return _sendFileLock.synchronized(() async {
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

      const checksumAlgorithm = defaultTransferChecksumAlgorithm;
      const checksumValue = '';
      final now = DateTime.now().millisecondsSinceEpoch;
      final content = jsonEncode(
        _FileTransferMetadata(
          checksumAlgorithm: checksumAlgorithm,
          checksumValue: checksumValue,
          chunkSize: fileTransferV3WindowSize,
          protocolVersion: fileTransferV3ProtocolVersion,
        ).toJson(),
      );
      final fileName = name.isNotEmpty ? name : 'document';
      final message = _buildMessage(
        MessageEnum.File,
        content,
        '',
        fileName,
        size,
        false,
        path: uri,
        md5: '',
        fileTimestamp: fileTimestamp > 0 ? fileTimestamp : now,
        receiverOverride: peerId,
      );
      await _database().insertMessage(message);
      final metadata = _FileTransferMetadata.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
      );
      logger.i(
        'resumable send android uri transfer=${message.uuid} size=$size '
        'checksum=$content uri=$uri',
      );
      await _persistTransfer(
        FileTransferData(
          transferId: message.uuid,
          messageUuid: message.uuid,
          peerUid: peerId,
          direction: FileTransferDirection.outgoing,
          state: FileTransferState.queued,
          finalPath: uri,
          tempPath: '',
          size: size,
          checksumAlgorithm: metadata.checksumAlgorithm,
          checksumValue: metadata.checksumValue,
          chunkSize: metadata.chunkSize,
          committedBytes: 0,
          lastError: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
      _dispatchOutgoingMessage(message);
      return _sendFileTransferV3OfferTo(peerId, message);
    });
  }

  /// fileOffer/fileData/fileReady/fileAck/fileComplete/fileCancel/fileError
  /// 帧入口(原 svrmanager `_handleWhisperFrameV3` 的非 message 分支);
  /// message 帧由 svrmanager 自行处理,不会转发到这里。
  Future<void> handleFrame(WhisperFrameV3 frame) async {
    switch (frame.type) {
      case WhisperFrameType.message:
        break;
      case WhisperFrameType.fileOffer:
        final message = decodeWireMessage(
          jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>,
        );
        await _handleFileTransferV3Offer(message);
        break;
      case WhisperFrameType.fileData:
        try {
          await _handleFileTransferV3Data(frame);
        } catch (error, stackTrace) {
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
        try {
          await _handleFileTransferV3Control(control);
        } catch (error, stackTrace) {
          await _handleOutgoingFileTransferV3Error(
            control.transferId,
            error,
            stackTrace,
          );
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

  Future<FileTransferData> _persistTransfer(FileTransferData data) async {
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
  }) async {
    await _database().updateFileTransfer(
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
    return _emitTransferById(transferId);
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
    return _sendFileTransferV3FrameTo(
      peerId,
      WhisperFrameV3(
        type: WhisperFrameType.fileOffer,
        transferId: message.uuid,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(utf8.encode(encodeWireMessage(message))),
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

  Future<void> _handleFileTransferV3Offer(MessageData message) async {
    final metadata = _FileTransferMetadata.fromContent(message.content);
    if (metadata == null ||
        metadata.protocolVersion != fileTransferV3ProtocolVersion) {
      await _sendFileTransferV3ControlTo(
        message.sender,
        FileTransferV3Control(
          action: FileTransferV3Action.error,
          transferId: message.uuid,
          durableOffset: 0,
          size: message.size,
          errorCode: 'protocol',
          errorMessage: '文件传输协议版本不支持',
        ),
      );
      return;
    }

    final db = _database();
    var transfer = await db.fetchFileTransfer(message.uuid);
    if (transfer == null) {
      final finalPath = await allocateFinalDownloadPath(message.name);
      final tempPath = await transferTempFilePath(message.uuid);
      final availableBytes =
          await availableBytesForPath((await downloadDir()).path);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!hasEnoughStorageForFile(
        fileSize: message.size,
        availableBytes: availableBytes,
      )) {
        transfer = FileTransferData(
          transferId: message.uuid,
          messageUuid: message.uuid,
          peerUid: message.sender,
          direction: FileTransferDirection.incoming,
          state: FileTransferState.failed,
          finalPath: finalPath,
          tempPath: tempPath,
          size: message.size,
          checksumAlgorithm: metadata.checksumAlgorithm,
          checksumValue: metadata.checksumValue,
          chunkSize: metadata.chunkSize,
          committedBytes: 0,
          lastError: '接收 ${message.name} 失败：存储空间不足',
          createdAt: now,
          updatedAt: now,
        );
        await _persistTransfer(transfer);
        await _sendFileTransferV3ControlTo(
          transfer.peerUid,
          FileTransferV3Control(
            action: FileTransferV3Action.error,
            transferId: transfer.transferId,
            durableOffset: 0,
            size: transfer.size,
            errorCode: 'storage',
            errorMessage: transfer.lastError,
          ),
        );
        _notify(transfer.lastError);
        return;
      }
      final decision = _transferRuntime.enqueue(
        peerId: message.sender,
        transferId: message.uuid,
        direction: FileTransferDirection.incoming,
      );
      transfer = FileTransferData(
        transferId: message.uuid,
        messageUuid: message.uuid,
        peerUid: message.sender,
        direction: FileTransferDirection.incoming,
        state: decision == TransferRuntimeDecision.started
            ? FileTransferState.negotiating
            : FileTransferState.queued,
        finalPath: finalPath,
        tempPath: tempPath,
        size: message.size,
        checksumAlgorithm: metadata.checksumAlgorithm,
        checksumValue: metadata.checksumValue,
        chunkSize: metadata.chunkSize,
        committedBytes: 0,
        lastError: '',
        createdAt: now,
        updatedAt: now,
      );
      await _persistTransfer(transfer);
    } else if (!isTerminalFileTransferState(transfer.state)) {
      _transferRuntime.enqueue(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.incoming,
      );
    }

    final existingMessage = await db.fetchMessageByUuid(message.uuid);
    if (existingMessage == null) {
      final json = message.toJson();
      json['path'] = transfer.finalPath;
      final newMessage = decodeWireMessage(json);
      await db.insertMessage(newMessage);
      _dispatchOutgoingMessage(newMessage);
    }
    _ackMessage(message);

    if (_transferRuntime.activeIncomingFor(transfer.peerUid) ==
        transfer.transferId) {
      await _sendFileTransferV3Ready(transfer.transferId);
    }
  }

  Future<void> _sendFileTransferV3Ready(String transferId) async {
    final transfer = await _database().fetchFileTransfer(transferId);
    if (transfer == null || isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.incoming,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return;
    }
    final tempFile = File(transfer.tempPath);
    if (!tempFile.existsSync()) {
      await tempFile.parent.create(recursive: true);
      await tempFile.create(recursive: true);
    }
    var durableOffset = await tempFile.length();
    if (durableOffset > transfer.size) {
      durableOffset = 0;
      await tempFile.writeAsBytes(const <int>[], flush: true);
    }
    final updated = await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.negotiating,
      committedBytes: durableOffset,
      lastError: '',
    );
    await _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.ready,
        transferId: transfer.transferId,
        durableOffset: durableOffset,
        size: transfer.size,
        errorCode: '',
        errorMessage: '',
      ),
    );
    if (updated != null) {
      _receivingTransfers[updated.transferId] = updated;
    }
  }

  Future<void> _handleFileTransferV3Control(
    FileTransferV3Control control,
  ) async {
    switch (control.action) {
      case FileTransferV3Action.ready:
        await _handleFileTransferV3Ready(control);
        break;
      case FileTransferV3Action.ack:
        await _handleFileTransferV3Ack(control);
        break;
      case FileTransferV3Action.complete:
        await _handleFileTransferV3Complete(control);
        break;
      case FileTransferV3Action.cancel:
        await _handleFileTransferV3Cancel(control);
        break;
      case FileTransferV3Action.error:
        await _handleFileTransferV3Error(control);
        break;
    }
  }

  Future<void> _handleFileTransferV3Ready(
    FileTransferV3Control control,
  ) async {
    final transfer = await _database().fetchFileTransfer(control.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final message = await _database().fetchMessageByUuid(transfer.messageUuid);
    if (message == null) {
      return;
    }
    final source = _transferSourceForMessage(message, transfer);
    try {
      if (!await source.exists() || await source.length() != transfer.size) {
        await _failOutgoingFileTransferV3(transfer, '源文件不存在或已变化，无法继续传输');
        return;
      }
    } catch (error, stackTrace) {
      await _handleOutgoingTransferError(transfer, error, stackTrace);
      return;
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
    final updated = await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.transferring,
      committedBytes: offset,
      lastError: '',
    );
    if (updated == null) {
      return;
    }
    await _sendFileTransferV3WindowSafely(updated, message, offset: offset);
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
      'peer=${transfer.peerUid} error=$error\n$stackTrace',
    );
    await _failOutgoingFileTransferV3(transfer, message);
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
      await _sendFileTransferV3Window(transfer, message, offset: offset);
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
        throw FileSystemException(
          'Unexpected EOF while reading transfer frame',
          message.path,
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

  Future<void> _handleFileTransferV3Data(WhisperFrameV3 frame) async {
    var transfer = _receivingTransfers[frame.transferId];
    transfer ??= await _database().fetchFileTransfer(frame.transferId);
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

    final tempFile = File(transfer.tempPath);
    if (!tempFile.existsSync()) {
      await tempFile.parent.create(recursive: true);
      await tempFile.create(recursive: true);
    }
    var writer = _receivingTransferWritersV3[transfer.transferId];
    if (writer == null) {
      final currentLength = await tempFile.length();
      if (currentLength > frame.offset) {
        final truncatingWriter = await tempFile.open(mode: FileMode.write);
        try {
          await truncatingWriter.truncate(frame.offset);
        } finally {
          await truncatingWriter.close();
        }
      } else if (currentLength < frame.offset) {
        await _sendFileTransferV3Ack(transfer, currentLength);
        return;
      }
      writer = await tempFile.open(mode: FileMode.writeOnlyAppend);
      _receivingTransferWritersV3[transfer.transferId] = writer;
      _receivingTransfers[transfer.transferId] = transfer;
      _receivingTransferOffsets[transfer.transferId] = frame.offset;
    }

    await writer.writeFrom(frame.payload);
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
      'peer=${transfer.peerUid} temp=${transfer.tempPath} error=$error\n$stackTrace',
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

  Future<void> _handleFileTransferV3Ack(FileTransferV3Control control) async {
    final transfer = await _database().fetchFileTransfer(control.transferId);
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
    final message = await _database().fetchMessageByUuid(updated.messageUuid);
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
    final message = await _database().fetchMessageByUuid(transfer.messageUuid);
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
    await _sendFileTransferV3WindowSafely(updated, message, offset: offset);
  }

  Future<void> _handleFileTransferV3Complete(
    FileTransferV3Control control,
  ) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.completed,
      committedBytes: control.size,
      lastError: '',
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
      FileTransferV3Control control) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.canceled,
      lastError: control.errorMessage,
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

  Future<void> _handleFileTransferV3Error(FileTransferV3Control control) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.failed,
      lastError: control.errorMessage,
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

  Future<void> _finalizeIncomingFileTransferV3(
    FileTransferData transfer,
  ) async {
    await _closeReceivingTransferFile(transfer.transferId, flush: true);
    final tempFile = File(transfer.tempPath);
    final finalFile = File(transfer.finalPath);
    if (finalFile.existsSync()) {
      await finalFile.delete();
    }
    final message = await _database().fetchMessageByUuid(transfer.messageUuid);
    if (message?.fileTimestamp != null && (message!.fileTimestamp ?? 0) > 0) {
      await tempFile.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(message.fileTimestamp!),
      );
    }
    await tempFile.rename(transfer.finalPath);
    await notifyFileVisibleToAndroidPickers(transfer.finalPath);
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.completed,
      committedBytes: transfer.size,
      lastError: '',
    );
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
    await _clearActiveIncomingTransfer(transfer.transferId, flush: false);
    await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
  }

  FileTransferSource _transferSourceForMessage(
    MessageData message,
    FileTransferData transfer,
  ) {
    if (isAndroidContentUri(message.path)) {
      return AndroidContentUriTransferSource(
        uri: message.path,
        expectedSize: transfer.size,
      );
    }
    return PathFileTransferSource(message.path);
  }

  Future<void> _handleOutgoingTransferError(
    FileTransferData transfer,
    Object error,
    StackTrace stackTrace,
  ) async {
    final errorMessage = _outgoingTransferErrorMessage(error);
    logger.i(
      'outgoing transfer failed transfer=${transfer.transferId} '
      'peer=${transfer.peerUid} error=$error\n$stackTrace',
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
        final message = await _database().fetchMessageByUuid(
          item.messageUuid,
        );
        if (message != null) {
          await _sendFileTransferV3OfferTo(item.peerUid, message);
        }
        await _updateTransfer(
          item.transferId,
          state: FileTransferState.negotiating,
        );
      }
    }
  }
}

class _FileTransferMetadata {
  const _FileTransferMetadata({
    required this.checksumAlgorithm,
    required this.checksumValue,
    required this.chunkSize,
    required this.protocolVersion,
  });

  final String checksumAlgorithm;
  final String checksumValue;
  final int chunkSize;
  final int protocolVersion;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'checksumAlgorithm': checksumAlgorithm,
      'checksumValue': checksumValue,
      'chunkSize': chunkSize,
      'protocolVersion': protocolVersion,
    };
  }

  static _FileTransferMetadata? fromContent(String? content) {
    if (content == null || content.isEmpty) {
      return null;
    }
    try {
      return _FileTransferMetadata.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  factory _FileTransferMetadata.fromJson(Map<String, dynamic> json) {
    return _FileTransferMetadata(
      checksumAlgorithm: json['checksumAlgorithm'] as String? ??
          FileTransferEngine.defaultTransferChecksumAlgorithm,
      checksumValue: json['checksumValue'] as String? ?? '',
      chunkSize:
          json['chunkSize'] as int? ?? FileTransferEngine._transferChunkSize,
      protocolVersion: json['protocolVersion'] as int? ?? 1,
    );
  }
}
