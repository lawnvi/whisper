import 'package:drift/drift.dart' show Value, Variable;
import 'package:mime/mime.dart';
import 'package:whisper/helper/device_form_factor.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';

import 'web_transfer_protocol.dart';
import 'web_transfer_session.dart';
import 'web_transfer_uploads.dart';
import 'web_transfer_visitor.dart';

/// What a visit leaves in the database: the visitor's device row, its
/// messages, and transfers for the files either way. The same tables as a
/// Whisper device's, so the conversation, the device list and the island show
/// them without knowing about browsers. Every change is announced through
/// [onMessage] and [onTransfer].
class WebTransferRecords {
  WebTransferRecords({
    required LocalDatabase Function() database,
    required this.onMessage,
    required this.onTransfer,
  }) : _database = database;

  final LocalDatabase Function() _database;
  final void Function(MessageData message) onMessage;
  final void Function(TransferSnapshot snapshot) onTransfer;
  final _progressAt = <String, int>{};

  LocalDatabase get db => _database();

  /// Transfers with a visitor left unfinished by an earlier run can never
  /// finish: the visit they belonged to is gone.
  Future<void> sweep() => db.customUpdate(
    "UPDATE file_transfer SET state = 'failed', updated_at = ? "
    "WHERE peer_uid LIKE '$webVisitorPrefix%' "
    "AND state NOT IN ('completed', 'failed', 'canceled')",
    variables: [Variable<int>(DateTime.now().millisecondsSinceEpoch)],
    updates: {db.fileTransfer},
  );

  /// The visitor's device row: what it is, and when it was last here.
  Future<void> saveVisitor(WebSession session, {required bool online}) async {
    final hello = session.hello;
    await db.upsertDevice(
      DeviceData(
        id: 0,
        uid: session.uid,
        name: webVisitorName(hello),
        host: session.client,
        port: 0,
        platform: webVisitorPlatform(hello),
        isServer: false,
        online: online,
        clipboard: false,
        auth: false,
        lastTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        around: false,
      ),
    );
    if (hello.kind == 'tablet' || hello.kind == 'phone') {
      await DeviceFormFactors.shared.record(session.uid, hello.kind);
    }
  }

  /// Puts the row back if someone deleted it while the visit went on.
  Future<void> ensureVisitor(WebSession session) async {
    if (await db.fetchDevice(session.uid) == null) {
      await saveVisitor(session, online: session.live);
    }
  }

  /// A text, unless one with [uuid] is already here (the page sends again
  /// what it is not sure arrived).
  Future<MessageData?> addText({
    required String sender,
    required String receiver,
    required String text,
    required String uuid,
    required bool acked,
  }) async {
    if (await db.fetchMessageByUuid(uuid) != null) {
      return null;
    }
    final message = await db.insertMessageReturning(
      _message(
        sender: sender,
        receiver: receiver,
        type: MessageEnum.Text,
        content: text,
        uuid: uuid,
      ),
      acked: acked,
    );
    onMessage(message);
    return message;
  }

  /// A file this device offers; the transfer starts when the page downloads.
  Future<MessageData> addOutgoingFile({
    required String sender,
    required String receiver,
    required String path,
    required String name,
    required int size,
    required String uuid,
  }) async {
    final message = await db.insertMessageReturning(
      _message(
        sender: sender,
        receiver: receiver,
        type: MessageEnum.File,
        name: name,
        size: size,
        path: path,
        uuid: uuid,
      ),
      acked: true,
    );
    onMessage(message);
    return message;
  }

  /// A file the page is about to send, and its transfer.
  Future<void> addUpload({
    required WebSession session,
    required String receiver,
    required WebUpload upload,
  }) async {
    final offer = upload.offer;
    final message = await db.insertMessageReturning(
      _message(
        sender: session.uid,
        receiver: receiver,
        type: MessageEnum.File,
        name: webSafeFileName(offer.name),
        size: offer.size,
        uuid: offer.id,
        fileTimestamp: upload.modified?.millisecondsSinceEpoch,
      ),
      acked: true,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final transfer = FileTransferData(
      transferId: offer.id,
      messageUuid: offer.id,
      messageRowId: message.id,
      peerUid: session.uid,
      direction: FileTransferDirection.incoming,
      state: FileTransferState.transferring,
      finalPath: '',
      tempPath: upload.tempPath,
      size: offer.size,
      checksumAlgorithm: '',
      checksumValue: '',
      chunkSize: webMaxChunkBytes,
      committedBytes: 0,
      resumeProofResetCount: 0,
      lastError: '',
      createdAt: now,
      updatedAt: now,
    );
    await db.upsertFileTransfer(transfer);
    onMessage(message);
    onTransfer(db.snapshotForTransfer(transfer));
  }

  /// Where [upload] is, without writing it down: at most four times a
  /// second.
  void uploading(WebSession session, WebUpload upload) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_due(upload.transferId, now)) {
      return;
    }
    onTransfer(
      TransferSnapshot(
        transferId: upload.transferId,
        messageUuid: upload.transferId,
        peerUid: session.uid,
        direction: FileTransferDirection.incoming,
        state: FileTransferState.transferring,
        finalPath: '',
        tempPath: upload.tempPath,
        size: upload.offer.size,
        committedBytes: upload.committed,
        lastError: '',
        updatedAt: now,
      ),
    );
  }

  /// Writes down a transfer that is still under way, and announces it.
  Future<void> update(
    String transferId, {
    FileTransferState? state,
    int? committed,
  }) async {
    await db.updateFileTransfer(
      transferId,
      state: state == null ? const Value.absent() : Value(state),
      committedBytes: committed == null
          ? const Value.absent()
          : Value(committed),
      updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
    );
    await _emit(transferId);
  }

  Future<void> completeUpload(WebUpload upload, String path) async {
    final completed = await db.completeIncomingFileTransfer(
      transferId: upload.transferId,
      finalPath: path,
      size: upload.offer.size,
    );
    onTransfer(db.snapshotForTransfer(completed));
  }

  /// A file this device sent to [session]'s visitor, by its message id.
  Future<MessageData?> outgoing(WebSession session, String id) async {
    final message = await db.fetchMessageByUuid(id);
    if (message == null ||
        message.type != MessageEnum.File ||
        message.receiver != session.uid ||
        message.path.isEmpty) {
      return null;
    }
    return message;
  }

  /// How far a download of [message] got: [end] bytes in, [done] when the
  /// last byte reached the page.
  Future<void> served(
    WebSession session,
    MessageData message, {
    required int end,
    required bool done,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!done && !_due(message.uuid, now)) {
      return;
    }
    final existing = await db.fetchFileTransfer(message.uuid);
    if (existing?.state == FileTransferState.completed) {
      return;
    }
    final transfer = FileTransferData(
      transferId: message.uuid,
      messageUuid: message.uuid,
      messageRowId: message.id,
      peerUid: session.uid,
      direction: FileTransferDirection.outgoing,
      state: done
          ? FileTransferState.completed
          : FileTransferState.transferring,
      finalPath: message.path,
      tempPath: '',
      size: message.size,
      checksumAlgorithm: '',
      checksumValue: '',
      chunkSize: 0,
      committedBytes: done ? message.size : end.clamp(0, message.size),
      resumeProofResetCount: 0,
      lastError: '',
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await db.upsertFileTransfer(transfer);
    onTransfer(db.snapshotForTransfer(transfer));
  }

  /// The last [webHistoryLimit] messages, oldest first, for `welcome`. Texts
  /// this device sent while the page was away count as delivered now.
  Future<List<Map<String, Object?>>> history(WebSession session) async {
    final messages = await db.fetchMessageList(
      session.uid,
      limit: webHistoryLimit,
    );
    final transfers = await db.fetchFileTransfersByIds([
      for (final message in messages)
        if (message.type == MessageEnum.File) message.uuid,
    ]);
    final entries = <Map<String, Object?>>[];
    for (final message in messages.reversed) {
      final mine = message.sender == session.uid;
      if (message.type == MessageEnum.Text) {
        entries.add({
          'id': message.uuid,
          'kind': 'text',
          'from': mine ? 'me' : 'host',
          'body': message.content ?? '',
          'time': message.timestamp * 1000,
        });
        if (!mine && !message.acked) {
          final acked = await db.ackMessage(message);
          if (acked != null) {
            onMessage(acked);
          }
        }
      } else if (message.type == MessageEnum.File) {
        final state = transfers[message.uuid]?.state;
        entries.add({
          ...fileFields(message, from: mine ? 'me' : 'host'),
          'kind': 'file',
          if (mine)
            'state': session.uploads.containsKey(message.uuid)
                ? 'queued'
                : state == FileTransferState.completed
                ? 'sent'
                : 'failed',
        });
      }
    }
    return entries;
  }

  /// A `file` frame's fields.
  static Map<String, Object?> fileFields(
    MessageData message, {
    required String from,
  }) => {
    'id': message.uuid,
    'from': from,
    'name': message.name,
    'size': message.size,
    'type': lookupMimeType(message.name.toLowerCase()) ?? '',
    'time': message.timestamp * 1000,
  };

  Future<void> _emit(String transferId) async {
    final transfer = await db.fetchFileTransfer(transferId);
    if (transfer != null) {
      onTransfer(db.snapshotForTransfer(transfer));
    }
  }

  bool _due(String id, int now) {
    final last = _progressAt[id] ?? 0;
    if (now - last < 250) {
      return false;
    }
    _progressAt[id] = now;
    if (_progressAt.length > 256) {
      _progressAt.removeWhere((_, at) => now - at > 60000);
    }
    return true;
  }

  static MessageData _message({
    required String sender,
    required String receiver,
    required MessageEnum type,
    required String uuid,
    String content = '',
    String name = '',
    int size = 0,
    String path = '',
    int? fileTimestamp,
  }) => MessageData(
    id: 0,
    sender: sender,
    receiver: receiver,
    name: name,
    clipboard: false,
    size: size,
    type: type,
    content: content,
    message: '',
    timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    acked: true,
    uuid: uuid,
    path: path,
    md5: '',
    fileTimestamp: fileTimestamp,
  );
}
