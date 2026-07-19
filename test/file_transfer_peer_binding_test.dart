import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/socket/wire_message_replay.dart';

const _transferId = '01234567-89ab-4cde-8fab-0123456789ab';
const _secondTransferId = '21234567-89ab-4cde-8fab-0123456789ab';

TransferConnectionBinding _connection(String peerId) =>
    TransferConnectionBinding(peerId: peerId, generation: 1);

final class _DelayedUpdateDatabase extends LocalDatabase {
  _DelayedUpdateDatabase() : super.forTesting(NativeDatabase.memory());

  bool _delayNextUpdate = false;
  Completer<void> updateStarted = Completer<void>();
  Completer<void> resumeUpdate = Completer<void>();

  void delayNextUpdate() {
    _delayNextUpdate = true;
    updateStarted = Completer<void>();
    resumeUpdate = Completer<void>();
  }

  @override
  Future<int> updateFileTransfer(
    String transferId, {
    Value<FileTransferState> state = const Value.absent(),
    Value<int> committedBytes = const Value.absent(),
    Value<String> lastError = const Value.absent(),
    Value<String> finalPath = const Value.absent(),
    Value<String> tempPath = const Value.absent(),
    Value<String> checksumValue = const Value.absent(),
    Value<int> updatedAt = const Value.absent(),
  }) async {
    if (_delayNextUpdate) {
      _delayNextUpdate = false;
      updateStarted.complete();
      await resumeUpdate.future;
    }
    return super.updateFileTransfer(
      transferId,
      state: state,
      committedBytes: committedBytes,
      lastError: lastError,
      finalPath: finalPath,
      tempPath: tempPath,
      checksumValue: checksumValue,
      updatedAt: updatedAt,
    );
  }
}

FileTransferEngine _engine(
  LocalDatabase database, {
  void Function()? onSend,
  void Function()? onTransferUpdated,
  void Function()? onAck,
  void Function()? onDispatch,
  FutureOr<bool> Function(String peerId, Object bytes)? sendBytesToPeer,
  WireMessageReplayGuard? replayGuard,
}) {
  return FileTransferEngine(
    currentConnectionBinding: (peerId) =>
        TransferConnectionBinding(peerId: peerId, generation: 1),
    authenticatedIdentityHashForConnection: (_) => null,
    sendBytesToConnection: (binding, bytes) {
      onSend?.call();
      return sendBytesToPeer?.call(binding.peerId, bytes) ?? true;
    },
    markPeerUnresponsive: (_) => false,
    emitTransferUpdated: (_) => onTransferUpdated?.call(),
    notify: (_) {},
    remoteProfileFor: (_) => null,
    isConnectedTo: (_) => true,
    connectedPeerIds: () => const <String>{'peer-a'},
    defaultPeerId: () => '',
    hasLegacySinkFor: (_) => false,
    localPeerIdFor: (_) => 'local',
    buildMessage:
        (
          type,
          content,
          msg,
          fileName,
          size,
          clipboard, {
          md5 = '',
          path = '',
          uid,
          fileTimestamp = 0,
          receiverOverride,
        }) => throw UnimplementedError(),
    dispatchOutgoingMessage: (_) => onDispatch?.call(),
    ackMessage: (_) => onAck?.call(),
    wireMessageReplayGuard: replayGuard ?? WireMessageReplayGuard(),
    database: () => database,
  );
}

String _validMetadata() => jsonEncode(<String, Object>{
  ...const FileTransferV3Metadata(
    checksumValue:
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  ).toJson(),
});

MessageData _offer({
  String sender = 'peer-a',
  String uuid = _transferId,
  int size = 8,
  String? content,
}) {
  return MessageData(
    id: 0,
    sender: sender,
    receiver: 'local',
    name: 'payload.bin',
    clipboard: false,
    size: size,
    type: MessageEnum.File,
    content: content ?? _validMetadata(),
    message: '',
    timestamp: 1,
    uuid: uuid,
    acked: false,
    path: '',
    md5: '',
  );
}

WhisperFrameV3 _offerFrame(MessageData offer) {
  return WhisperFrameV3(
    type: WhisperFrameType.fileOffer,
    transferId: offer.uuid,
    offset: 0,
    sequence: 0,
    payload: Uint8List.fromList(utf8.encode(encodeWireMessage(offer))),
  );
}

void _cleanTransferFiles(
  LocalDatabase database, {
  List<String> transferIds = const <String>[_transferId],
}) {
  addTearDown(() async {
    for (final transferId in transferIds) {
      final transfer = await database.fetchFileTransfer(transferId);
      for (final path in <String>[
        transfer?.tempPath ?? '',
        transfer?.finalPath ?? '',
      ]) {
        if (path.isNotEmpty) {
          final file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        }
      }
    }
  });
}

FileTransferData _transfer({
  String peerUid = 'peer-a',
  FileTransferDirection direction = FileTransferDirection.incoming,
}) {
  return FileTransferData(
    transferId: _transferId,
    messageUuid: _transferId,
    messageRowId: 0,
    peerUid: peerUid,
    direction: direction,
    state: FileTransferState.transferring,
    finalPath: '/tmp/final.bin',
    tempPath: '/tmp/part.bin',
    size: 8,
    checksumAlgorithm: 'sha256',
    checksumValue:
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    chunkSize: fileTransferV3FramePayloadSize,
    committedBytes: 0,
    resumeProofResetCount: 0,
    lastError: '',
    createdAt: 1,
    updatedAt: 1,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final testDownloadDir = Directory.systemTemp.createTempSync(
    'whisper-peer-binding-',
  );
  SharedPreferences.setMockInitialValues(<String, Object>{
    '_savePath': testDownloadDir.path,
  });
  tearDownAll(() async {
    if (await testDownloadDir.exists()) {
      await testDownloadDir.delete(recursive: true);
    }
  });

  test(
    'file data from another authenticated peer is rejected before effects',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertFileTransfer(_transfer());
      var sends = 0;
      var updates = 0;
      final engine = _engine(
        database,
        onSend: () => sends++,
        onTransferUpdated: () => updates++,
      );
      final frame = WhisperFrameV3(
        type: WhisperFrameType.fileData,
        transferId: _transferId,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(const <int>[1]),
      );

      await expectLater(
        engine.handleFrame(_connection('peer-b'), frame, requireCurrent: () {}),
        throwsA(
          isA<WireInputRejected>().having(
            (error) => error.reason,
            'reason',
            WireInputReason.transferPeerMismatch,
          ),
        ),
      );

      expect(sends, 0);
      expect(updates, 0);
      expect(
        (await database.fetchFileTransfer(_transferId))?.committedBytes,
        0,
      );
    },
  );

  test(
    'file offer sender substitution is rejected before persistence or ACK',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      var sends = 0;
      var updates = 0;
      var acknowledgements = 0;
      var dispatches = 0;
      final engine = _engine(
        database,
        onSend: () => sends++,
        onTransferUpdated: () => updates++,
        onAck: () => acknowledgements++,
        onDispatch: () => dispatches++,
      );
      final offer = MessageData(
        id: 0,
        sender: 'peer-b',
        receiver: 'local',
        name: 'payload.bin',
        clipboard: false,
        size: 8,
        type: MessageEnum.File,
        content: _validMetadata(),
        message: '',
        timestamp: 1,
        uuid: _transferId,
        acked: false,
        path: '',
        md5: '',
      );
      final frame = WhisperFrameV3(
        type: WhisperFrameType.fileOffer,
        transferId: _transferId,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(utf8.encode(encodeWireMessage(offer))),
      );

      await expectLater(
        engine.handleFrame(_connection('peer-a'), frame, requireCurrent: () {}),
        throwsA(
          isA<WireInputRejected>().having(
            (error) => error.reason,
            'reason',
            WireInputReason.messageSenderMismatch,
          ),
        ),
      );

      expect(await database.fetchFileTransfer(_transferId), isNull);
      expect(await database.fetchMessageByUuid(_transferId), isNull);
      expect((sends, updates, acknowledgements, dispatches), (0, 0, 0, 0));
    },
  );

  test(
    'file control from another peer cannot mutate an outgoing transfer',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertFileTransfer(
        _transfer(direction: FileTransferDirection.outgoing),
      );
      var sends = 0;
      var updates = 0;
      final engine = _engine(
        database,
        onSend: () => sends++,
        onTransferUpdated: () => updates++,
      );
      const control = FileTransferV3Control(
        action: FileTransferV3Action.cancel,
        transferId: _transferId,
        durableOffset: 0,
        size: 8,
        failureReason: FileTransferFailureReason.none,
      );
      final frame = WhisperFrameV3(
        type: WhisperFrameType.fileCancel,
        transferId: _transferId,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(control.toJson()))),
      );

      await expectLater(
        engine.handleFrame(_connection('peer-b'), frame, requireCurrent: () {}),
        throwsA(
          isA<WireInputRejected>().having(
            (error) => error.reason,
            'reason',
            WireInputReason.transferPeerMismatch,
          ),
        ),
      );

      final stored = await database.fetchFileTransfer(_transferId);
      expect(stored?.state, FileTransferState.transferring);
      expect((sends, updates), (0, 0));
    },
  );

  test(
    'file offer cannot reuse an existing non-transfer message UUID',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.insertMessage(
        MessageData(
          id: 0,
          sender: 'peer-a',
          receiver: 'local',
          name: '',
          clipboard: false,
          size: 0,
          type: MessageEnum.Text,
          content: 'already used',
          message: '',
          timestamp: 1,
          uuid: _transferId,
          acked: false,
          path: '',
          md5: '',
        ),
      );
      var sends = 0;
      var acknowledgements = 0;
      final engine = _engine(
        database,
        onSend: () => sends++,
        onAck: () => acknowledgements++,
      );
      final offer = MessageData(
        id: 0,
        sender: 'peer-a',
        receiver: 'local',
        name: 'payload.bin',
        clipboard: false,
        size: 8,
        type: MessageEnum.File,
        content: _validMetadata(),
        message: '',
        timestamp: 2,
        uuid: _transferId,
        acked: false,
        path: '',
        md5: '',
      );
      final frame = WhisperFrameV3(
        type: WhisperFrameType.fileOffer,
        transferId: _transferId,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(utf8.encode(encodeWireMessage(offer))),
      );

      await expectLater(
        engine.handleFrame(_connection('peer-a'), frame, requireCurrent: () {}),
        throwsA(
          isA<WireInputRejected>().having(
            (error) => error.reason,
            'reason',
            WireInputReason.messageIdConflict,
          ),
        ),
      );

      expect(await database.fetchFileTransfer(_transferId), isNull);
      expect((sends, acknowledgements), (0, 0));
    },
  );

  test(
    'malformed file metadata returns an error before claiming its UUID',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      var sends = 0;
      final engine = _engine(database, onSend: () => sends++);

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(_offer(content: '{}')),
        requireCurrent: () {},
      );

      expect(await database.fetchMessageByUuid(_transferId), isNull);
      expect(await database.fetchFileTransfer(_transferId), isNull);
      expect(sends, 1);
    },
  );

  test(
    'stale generation inside control handling is normalized before mutation',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.upsertFileTransfer(
        _transfer(direction: FileTransferDirection.outgoing),
      );
      final engine = _engine(database);
      const control = FileTransferV3Control(
        action: FileTransferV3Action.cancel,
        transferId: _transferId,
        durableOffset: 0,
        size: 8,
        failureReason: FileTransferFailureReason.none,
      );
      final frame = WhisperFrameV3(
        type: WhisperFrameType.fileCancel,
        transferId: _transferId,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(control.toJson()))),
      );
      var checks = 0;

      await expectLater(
        engine.handleFrame(
          _connection('peer-a'),
          frame,
          requireCurrent: () {
            checks++;
            if (checks > 3) {
              throw StateError('session_expired');
            }
          },
        ),
        throwsA(
          isA<WireInputRejected>().having(
            (error) => error.reason,
            'reason',
            WireInputReason.sessionNotCurrent,
          ),
        ),
      );

      expect(checks, greaterThan(3));
      expect(
        (await database.fetchFileTransfer(_transferId))?.state,
        FileTransferState.transferring,
      );
    },
  );

  test(
    'slow file post-processing does not hold the global message claim lock',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      _cleanTransferFiles(database);
      final replayGuard = WireMessageReplayGuard();
      final sendStarted = Completer<void>();
      final finishSend = Completer<bool>();
      final engine = _engine(
        database,
        replayGuard: replayGuard,
        sendBytesToPeer: (_, __) {
          if (!sendStarted.isCompleted) {
            sendStarted.complete();
          }
          return finishSend.future;
        },
      );
      final offerFuture = engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(_offer()),
        requireCurrent: () {},
      );

      await sendStarted.future.timeout(const Duration(seconds: 2));
      try {
        final textClaim = await replayGuard
            .claim(
              MessageData(
                id: 0,
                sender: 'peer-b',
                receiver: 'local',
                name: '',
                clipboard: false,
                size: 0,
                type: MessageEnum.Text,
                content: 'independent',
                message: '',
                timestamp: 2,
                uuid: '11234567-89ab-4cde-8fab-0123456789ab',
                acked: false,
                path: '',
                md5: '',
              ),
              fetchExisting: (_) async => const <MessageData>[],
              persist: (message) async => message.copyWith(id: 99),
            )
            .timeout(const Duration(milliseconds: 300));

        expect(textClaim.decision, WireMessageReplayDecision.accept);
      } finally {
        if (!finishSend.isCompleted) {
          finishSend.complete(true);
        }
        await offerFuture;
      }
    },
  );

  test('concurrent peer offers cannot share one transfer UUID', () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    _cleanTransferFiles(database);
    var acknowledgements = 0;
    var dispatches = 0;
    final engine = _engine(
      database,
      onAck: () => acknowledgements++,
      onDispatch: () => dispatches++,
    );

    Future<Object?> receive(String peerId) async {
      try {
        await engine.handleFrame(
          _connection(peerId),
          _offerFrame(_offer(sender: peerId)),
          requireCurrent: () {},
        );
        return null;
      } catch (error) {
        return error;
      }
    }

    final results = await Future.wait(<Future<Object?>>[
      receive('peer-a'),
      receive('peer-b'),
    ]);

    expect(results.where((result) => result == null), hasLength(1));
    final rejection = results.whereType<WireInputRejected>().single;
    expect(rejection.reason, WireInputReason.transferPeerMismatch);
    final storedTransfer = await database.fetchFileTransfer(_transferId);
    final storedMessages = await database.fetchMessagesByUuid(_transferId);
    expect(storedTransfer, isNotNull);
    expect(storedMessages, hasLength(1));
    expect(storedMessages.single.sender, storedTransfer!.peerUid);
    expect((acknowledgements, dispatches), (1, 1));
  });

  test(
    'terminal transition finishes runtime cleanup after generation changes',
    () async {
      final database = _DelayedUpdateDatabase();
      addTearDown(database.close);
      _cleanTransferFiles(
        database,
        transferIds: const <String>[_transferId, _secondTransferId],
      );
      var sends = 0;
      final engine = _engine(database, onSend: () => sends++);
      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(_offer()),
        requireCurrent: () {},
      );
      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(_offer(uuid: _secondTransferId)),
        requireCurrent: () {},
      );
      expect(
        (await database.fetchFileTransfer(_secondTransferId))?.state,
        FileTransferState.queued,
      );
      final sendsBeforeCancel = sends;
      database.delayNextUpdate();
      var isCurrent = true;
      const cancel = FileTransferV3Control(
        action: FileTransferV3Action.cancel,
        transferId: _transferId,
        durableOffset: 0,
        size: 8,
        failureReason: FileTransferFailureReason.none,
      );
      final cancelFrame = WhisperFrameV3(
        type: WhisperFrameType.fileCancel,
        transferId: _transferId,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(cancel.toJson()))),
      );
      final cancelFuture = engine.handleFrame(
        _connection('peer-a'),
        cancelFrame,
        requireCurrent: () {
          if (!isCurrent) {
            throw StateError('session_expired');
          }
        },
      );

      await database.updateStarted.future.timeout(const Duration(seconds: 2));
      isCurrent = false;
      database.resumeUpdate.complete();
      await cancelFuture;

      expect(
        (await database.fetchFileTransfer(_transferId))?.state,
        FileTransferState.canceled,
      );
      expect(
        (await database.fetchFileTransfer(_secondTransferId))?.state,
        FileTransferState.negotiating,
      );
      expect(sends, greaterThan(sendsBeforeCancel));
    },
  );

  test('in-flight data after cancellation is safely ignored', () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.upsertFileTransfer(
      _transfer().copyWith(state: FileTransferState.canceled),
    );
    var sends = 0;
    var updates = 0;
    final engine = _engine(
      database,
      onSend: () => sends++,
      onTransferUpdated: () => updates++,
    );
    final frame = WhisperFrameV3(
      type: WhisperFrameType.fileData,
      transferId: _transferId,
      offset: 0,
      sequence: 0,
      payload: Uint8List.fromList(const <int>[1]),
    );

    await engine.handleFrame(
      _connection('peer-a'),
      frame,
      requireCurrent: () {},
    );

    expect((sends, updates), (0, 0));
    expect(
      (await database.fetchFileTransfer(_transferId))?.state,
      FileTransferState.canceled,
    );
  });
}
