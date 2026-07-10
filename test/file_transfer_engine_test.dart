import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/file_transfer_source.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/socket/wire_message_replay.dart';

FileTransferEngine _engine({
  FutureOr<bool> Function(String, Object)? sendBytesToPeer,
  TransferConnectionBinding? Function(String)? currentConnectionBinding,
  FutureOr<bool> Function(TransferConnectionBinding, Object)?
      sendBytesToConnection,
  void Function(String)? notify,
  LocalDatabase? database,
  Set<String> connectedPeerIds = const <String>{},
  bool supportsV3 = false,
  TransferMessageBuilder? buildMessage,
  void Function(MessageData)? dispatchOutgoingMessage,
  FileTransferSource Function(String sourcePath, int expectedSize)?
      transferSourceFactory,
  PrivacyLog? privacyLogger,
}) {
  return FileTransferEngine(
    currentConnectionBinding: currentConnectionBinding ??
        (peerId) => TransferConnectionBinding(peerId: peerId, generation: 1),
    sendBytesToConnection: (binding, bytes) =>
        sendBytesToConnection?.call(binding, bytes) ??
        sendBytesToPeer?.call(binding.peerId, bytes) ??
        true,
    markPeerUnresponsive: (_) => false,
    emitTransferUpdated: (_) {},
    notify: notify ?? (_) {},
    remoteProfileFor: (_) => supportsV3 ? _capablePeer() : null,
    isConnectedTo: (_) => true,
    connectedPeerIds: () => connectedPeerIds,
    defaultPeerId: () => '',
    hasLegacySinkFor: (_) => false,
    localPeerIdFor: (_) => 'local',
    buildMessage: buildMessage ??
        (type, content, msg, fileName, size, clipboard,
                {md5 = '',
                path = '',
                uid,
                fileTimestamp = 0,
                receiverOverride}) =>
            throw UnimplementedError('buildMessage 不应被本测试触达'),
    dispatchOutgoingMessage: dispatchOutgoingMessage ?? (_) {},
    ackMessage: (_) {},
    wireMessageReplayGuard: WireMessageReplayGuard(),
    transferSourceFactory: transferSourceFactory,
    privacyLogger: privacyLogger,
    database: database == null ? LocalDatabase.new : () => database,
  );
}

final class _MemoryTransferSource implements FileTransferSource {
  _MemoryTransferSource(
    this.bytes, {
    this.onRead,
  });

  final Uint8List bytes;
  final Future<void> Function()? onRead;

  @override
  Future<bool> exists() async => true;

  @override
  Future<int> length() async => bytes.length;

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    await onRead?.call();
    return Uint8List.fromList(bytes.sublist(offset, offset + length));
  }
}

final class _ThrowingTransferSource implements FileTransferSource {
  _ThrowingTransferSource(this.error);

  final Object error;

  @override
  Future<bool> exists() => Future<bool>.error(error);

  @override
  Future<int> length() => Future<int>.error(error);

  @override
  Future<Uint8List> readRange(int offset, int length) =>
      Future<Uint8List>.error(error);
}

final class _ErrorTextTrap {
  _ErrorTextTrap(this.secret);

  final String secret;
  bool toStringCalled = false;

  @override
  String toString() {
    toStringCalled = true;
    return secret;
  }
}

PeerProfile _capablePeer() => PeerProfile(
      device: const DeviceData(
        id: 0,
        uid: 'peer-a',
        name: 'Peer A',
        host: '192.168.1.2',
        port: 10002,
        password: '',
        platform: 'linux',
        isServer: false,
        online: true,
        clipboard: false,
        auth: true,
        lastTime: 1,
        around: true,
      ),
      trustedPeerIds: const <String>[],
      autoApproveNewDevices: false,
      autoConnectEnabled: true,
      capabilities: const PeerCapabilities(fileTransferV3: true),
    );

TransferMessageBuilder _messageBuilder() {
  var sequence = 0;
  return (type, content, msg, fileName, size, clipboard,
      {md5 = '', path = '', uid, fileTimestamp = 0, receiverOverride}) {
    sequence += 1;
    final suffix = sequence.toRadixString(16).padLeft(12, '0');
    return MessageData(
      id: 0,
      sender: 'local',
      receiver: receiverOverride ?? 'peer-a',
      name: fileName as String,
      clipboard: clipboard,
      size: size,
      type: type,
      content: content,
      message: msg as String,
      timestamp: 1,
      uuid: '01234567-89ab-4cde-8fab-$suffix',
      acked: false,
      path: path as String,
      md5: md5,
      fileTimestamp: fileTimestamp as int?,
    );
  };
}

MessageData _fileMessage(String id, {String peerId = 'peer-a'}) => MessageData(
      id: 0,
      sender: 'local',
      receiver: peerId,
      name: '$id.bin',
      clipboard: false,
      size: 1,
      type: MessageEnum.File,
      content: '{}',
      message: '',
      timestamp: 1,
      uuid: id,
      acked: false,
      path: '/local/$id.bin',
      md5: '',
    );

FileTransferData _outgoingTransfer(
  String id, {
  String peerId = 'peer-a',
  FileTransferState state = FileTransferState.queued,
}) =>
    FileTransferData(
      transferId: id,
      messageUuid: id,
      messageRowId: 0,
      peerUid: peerId,
      direction: FileTransferDirection.outgoing,
      state: state,
      finalPath: '/local/$id.bin',
      tempPath: '',
      size: 1,
      checksumAlgorithm: 'sha256',
      checksumValue:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      chunkSize: 512 * 1024,
      committedBytes: 0,
      resumeProofResetCount: 0,
      lastError: '',
      createdAt: 1,
      updatedAt: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('engine is constructible with injected fakes only', () {
    expect(_engine(), isNotNull);
  });

  test('sendFileTo rejects peer without fileTransferV3 and notifies', () async {
    final notices = <String>[];
    var sent = false;
    final engine = _engine(
      sendBytesToPeer: (_, __) {
        sent = true;
        return true;
      },
      notify: notices.add,
    );

    final ok =
        await engine.sendFileTo('peer-x', '/tmp/whisper-test-nonexistent.bin');

    expect(ok, isFalse);
    expect(sent, isFalse, reason: '能力不满足时不得发出任何字节');
    expect(notices, isNotEmpty, reason: '拒发必须通过 notify 告知');
  });

  test('outgoing offer hashes source while keeping its local path off wire',
      () async {
    final directory = await Directory.systemTemp.createTemp('whisper-send-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/payload.bin');
    await source.writeAsBytes(const <int>[1, 2, 3, 4]);
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final frames = <WhisperFrameV3>[];
    final engine = _engine(
      database: database,
      supportsV3: true,
      buildMessage: _messageBuilder(),
      sendBytesToPeer: (_, bytes) {
        frames.add(WhisperFrameV3.decode(bytes as Uint8List));
        return true;
      },
    );

    expect(await engine.sendFileTo('peer-a', source.path), isTrue);

    final offer = frames.single;
    expect(offer.type, WhisperFrameType.fileOffer);
    final wireMessage = decodeWireMessage(
      jsonDecode(utf8.decode(offer.payload)) as Map<String, dynamic>,
    );
    expect(wireMessage.path, isEmpty);
    expect(utf8.decode(offer.payload), isNot(contains(source.path)));
    final metadata = FileTransferV3Metadata.parseOffer(
      wireMessage.content,
      size: wireMessage.size,
    );
    expect(
      metadata.checksumValue,
      await fileChecksum(source, algorithm: 'sha256'),
    );
    final localMessage = await database.fetchMessageByUuid(wireMessage.uuid);
    expect(localMessage?.path, source.path);
    expect(
      (await database.fetchFileTransfer(wireMessage.uuid))?.checksumValue,
      metadata.checksumValue,
    );
  });

  test('slow source hashing does not hold the global send lock', () async {
    final directory = await Directory.systemTemp.createTemp('whisper-hash-');
    addTearDown(() => directory.delete(recursive: true));
    final slowFile = File('${directory.path}/slow.bin');
    final fastFile = File('${directory.path}/fast.bin');
    await slowFile.writeAsBytes(const <int>[1]);
    await fastFile.writeAsBytes(const <int>[2]);
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final slowReadStarted = Completer<void>();
    final releaseSlowRead = Completer<void>();
    final engine = _engine(
      database: database,
      supportsV3: true,
      buildMessage: _messageBuilder(),
      transferSourceFactory: (sourcePath, expectedSize) {
        return _MemoryTransferSource(
          Uint8List.fromList(
            sourcePath == slowFile.path ? const <int>[1] : const <int>[2],
          ),
          onRead: sourcePath == slowFile.path
              ? () async {
                  if (!slowReadStarted.isCompleted) slowReadStarted.complete();
                  await releaseSlowRead.future;
                }
              : null,
        );
      },
    );

    final slowSend = engine.sendFileTo('peer-a', slowFile.path);
    await slowReadStarted.future;
    final fastResult = await engine
        .sendFileTo('peer-a', fastFile.path)
        .timeout(const Duration(seconds: 1));
    expect(fastResult, isTrue);

    releaseSlowRead.complete();
    expect(await slowSend, isTrue);
  });

  test('delayed local offer stays bound to its captured generation', () async {
    final directory = await Directory.systemTemp.createTemp('whisper-gen-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/payload.bin');
    await source.writeAsBytes(const <int>[1]);
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    var current =
        const TransferConnectionBinding(peerId: 'peer-a', generation: 1);
    final readStarted = Completer<void>();
    final releaseRead = Completer<void>();
    final sentBindings = <TransferConnectionBinding>[];
    final engine = _engine(
      database: database,
      supportsV3: true,
      buildMessage: _messageBuilder(),
      currentConnectionBinding: (_) => current,
      sendBytesToConnection: (binding, _) {
        sentBindings.add(binding);
        return true;
      },
      transferSourceFactory: (_, __) => _MemoryTransferSource(
        Uint8List.fromList(const <int>[1]),
        onRead: () async {
          if (!readStarted.isCompleted) {
            readStarted.complete();
          }
          await releaseRead.future;
        },
      ),
    );

    final send = engine.sendFileTo('peer-a', source.path);
    await readStarted.future;
    current = const TransferConnectionBinding(peerId: 'peer-a', generation: 2);
    releaseRead.complete();

    expect(await send, isTrue);
    expect(sentBindings, hasLength(1));
    expect(sentBindings.single.generation, 1);
  });

  test('content uri stays local while its SHA-256 is sent', () async {
    const uri = 'content://documents/private/item';
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final frames = <WhisperFrameV3>[];
    final engine = _engine(
      database: database,
      supportsV3: true,
      buildMessage: _messageBuilder(),
      transferSourceFactory: (_, __) => _MemoryTransferSource(
        Uint8List.fromList(const <int>[4, 3, 2, 1]),
      ),
      sendBytesToPeer: (_, bytes) {
        frames.add(WhisperFrameV3.decode(bytes as Uint8List));
        return true;
      },
    );

    expect(
      await engine.sendAndroidContentUriTo(
        'peer-a',
        uri: uri,
        name: 'document.bin',
        size: 4,
        fileTimestamp: 1,
      ),
      isTrue,
    );

    final offer = frames.single;
    final payload = utf8.decode(offer.payload);
    final wireMessage = decodeWireMessage(
      jsonDecode(payload) as Map<String, dynamic>,
    );
    expect(wireMessage.path, isEmpty);
    expect(payload, isNot(contains(uri)));
    expect(
      (await database.fetchMessageByUuid(wireMessage.uuid))?.path,
      uri,
    );
    expect(
      FileTransferV3Metadata.parseOffer(
        wireMessage.content,
        size: 4,
      ).checksumValue,
      bytesChecksum(const <int>[4, 3, 2, 1], algorithm: 'sha256'),
    );
  });

  test('content uri size must exactly match fresh provider metadata', () async {
    for (final mismatch in <({int declared, int actual})>[
      (declared: 0, actual: 1),
      (declared: 4, actual: 3),
      (declared: 4, actual: 5),
    ]) {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      final frames = <WhisperFrameV3>[];
      var builds = 0;
      final engine = _engine(
        database: database,
        supportsV3: true,
        buildMessage: (type, content, msg, fileName, size, clipboard,
            {md5 = '', path = '', uid, fileTimestamp = 0, receiverOverride}) {
          builds += 1;
          return _messageBuilder()(
            type,
            content,
            msg,
            fileName,
            size,
            clipboard,
            md5: md5,
            path: path,
            uid: uid,
            fileTimestamp: fileTimestamp,
            receiverOverride: receiverOverride,
          );
        },
        transferSourceFactory: (_, __) => _MemoryTransferSource(
          Uint8List(mismatch.actual),
        ),
        sendBytesToPeer: (_, bytes) {
          frames.add(WhisperFrameV3.decode(bytes as Uint8List));
          return true;
        },
      );

      expect(
        await engine.sendAndroidContentUriTo(
          'peer-a',
          uri: 'content://documents/private/${mismatch.declared}',
          name: 'document.bin',
          size: mismatch.declared,
          fileTimestamp: 1,
        ),
        isFalse,
      );
      expect(builds, 0);
      expect(frames, isEmpty);
      expect(await database.fetchRecoverableFileTransfers(), isEmpty);
      await database.close();
    }
  });

  test('local transfer failure emits only a stable reason and error type',
      () async {
    const secret =
        'token=never-log-this content://private.provider/root/secret.txt';
    final failure = _ErrorTextTrap(secret);
    final notices = <String>[];
    final logLines = <String>[];
    final engine = _engine(
      supportsV3: true,
      notify: notices.add,
      privacyLogger: PrivacyLog(sink: logLines.add),
      transferSourceFactory: (_, __) => _ThrowingTransferSource(failure),
    );

    final result = await engine.sendAndroidContentUriTo(
      'peer-a',
      uri: 'content://documents/private/item',
      name: 'document.bin',
      size: 1,
      fileTimestamp: 1,
    );

    expect(result, isFalse);
    expect(failure.toStringCalled, isFalse);
    expect(notices, <String>[FileTransferFailureReason.source.wireCode]);
    expect(logLines, hasLength(1));
    expect(logLines.single, contains('"errorType":"unknown"'));
    expect(logLines.single, isNot(contains(secret)));
  });

  test('closeAll awaits recoverable transfer persistence', () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    const transferId = '91234567-89ab-4cde-8fab-0123456789ab';
    final message = await database.insertMessageReturning(
      _fileMessage(transferId).copyWith(
        size: 1024,
        path: '/tmp/archive.zip',
      ),
    );
    await database.upsertFileTransfer(
      FileTransferData(
        transferId: transferId,
        messageUuid: transferId,
        messageRowId: message.id,
        peerUid: 'peer-a',
        direction: FileTransferDirection.outgoing,
        state: FileTransferState.transferring,
        finalPath: '/tmp/archive.zip',
        tempPath: '/tmp/archive.zip.part',
        size: 1024,
        checksumAlgorithm: 'sha256',
        checksumValue: 'abc',
        chunkSize: 512,
        committedBytes: 256,
        resumeProofResetCount: 0,
        lastError: '',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    final engine = _engine(
      database: database,
    );

    await engine.closeAll();

    expect(
      (await database.fetchFileTransfer(transferId))?.state,
      FileTransferState.waitingReconnect,
    );
  });

  test('atomic admission allows only one concurrent contender for last slot',
      () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final results = await Future.wait(<Future<FileTransferAdmissionResult>>[
      database.admitFileTransfer(
        message: _fileMessage('transfer-a'),
        transfer: _outgoingTransfer('transfer-a'),
        perPeerLimit: 1,
        globalLimit: 1,
      ),
      database.admitFileTransfer(
        message: _fileMessage('transfer-b', peerId: 'peer-b'),
        transfer: _outgoingTransfer('transfer-b', peerId: 'peer-b'),
        perPeerLimit: 1,
        globalLimit: 1,
      ),
    ]);

    expect(
      results.where((item) => item.decision == FileTransferAdmission.admitted),
      hasLength(1),
    );
    expect(
      results.where(
        (item) => item.decision == FileTransferAdmission.globalLimit,
      ),
      hasLength(1),
    );
    expect(await database.fetchRecoverableFileTransfers(), hasLength(1));
    final persistedMessages = <MessageData>[
      ...await database.fetchMessagesByUuid('transfer-a'),
      ...await database.fetchMessagesByUuid('transfer-b'),
    ];
    expect(persistedMessages, hasLength(1));
  });

  test('retry from a terminal state reacquires capacity atomically', () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final retryMessage = await database.insertMessageReturning(
      _fileMessage('retry'),
    );
    final activeMessage = await database.insertMessageReturning(
      _fileMessage('active'),
    );
    await database.upsertFileTransfer(
      _outgoingTransfer('active', state: FileTransferState.transferring)
          .copyWith(messageRowId: activeMessage.id),
    );
    await database.upsertFileTransfer(
      _outgoingTransfer('retry', state: FileTransferState.failed).copyWith(
        messageRowId: retryMessage.id,
      ),
    );

    final blocked = await database.reacquireFileTransferCapacity(
      'retry',
      nextState: FileTransferState.negotiating,
      perPeerLimit: 1,
      globalLimit: 1,
    );
    expect(blocked, FileTransferAdmission.peerLimit);
    expect(
      (await database.fetchFileTransfer('retry'))?.state,
      FileTransferState.failed,
    );

    await database.updateFileTransfer(
      'active',
      state: const Value(FileTransferState.completed),
    );
    final admitted = await database.reacquireFileTransferCapacity(
      'retry',
      nextState: FileTransferState.negotiating,
      perPeerLimit: 1,
      globalLimit: 1,
    );
    expect(admitted, FileTransferAdmission.admitted);
    expect(
      (await database.fetchFileTransfer('retry'))?.state,
      FileTransferState.negotiating,
    );
  });

  test('production transfer limits are fixed at 32 per peer and 128 global',
      () {
    expect(maxNonterminalTransfersPerPeer, 32);
    expect(maxNonterminalTransfersGlobal, 128);
  });

  test('engine retry cannot revive a failed transfer beyond peer capacity',
      () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    const retryId = '61234567-89ab-4cde-8fab-0123456789ab';
    final retryMessage = await database.insertMessageReturning(
      _fileMessage(retryId),
    );
    await database.upsertFileTransfer(
      _outgoingTransfer(retryId, state: FileTransferState.failed).copyWith(
        messageRowId: retryMessage.id,
      ),
    );
    for (var index = 0; index < maxNonterminalTransfersPerPeer; index += 1) {
      final id =
          '60000000-0000-4000-8000-${index.toRadixString(16).padLeft(12, '0')}';
      await database.upsertFileTransfer(
        _outgoingTransfer(id, state: FileTransferState.queued),
      );
    }
    var sends = 0;
    final notices = <String>[];
    final engine = _engine(
      database: database,
      supportsV3: true,
      sendBytesToPeer: (_, __) {
        sends += 1;
        return true;
      },
      notify: notices.add,
    );

    await engine.retryTransfer(retryId);

    expect(
      (await database.fetchFileTransfer(retryId))?.state,
      FileTransferState.failed,
    );
    expect(sends, 0);
    expect(notices, isNotEmpty);
  });

  test('message deletion wins a race with an in-flight retry offer', () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    const retryId = '71234567-89ab-4cde-8fab-0123456789ab';
    final message =
        await database.insertMessageReturning(_fileMessage(retryId));
    await database.upsertFileTransfer(
      _outgoingTransfer(retryId, state: FileTransferState.failed).copyWith(
        messageRowId: message.id,
      ),
    );
    final sendStarted = Completer<void>();
    final releaseSend = Completer<void>();
    final engine = _engine(
      database: database,
      supportsV3: true,
      sendBytesToPeer: (_, __) async {
        sendStarted.complete();
        await releaseSend.future;
        return true;
      },
    );

    final retry = engine.retryTransfer(retryId);
    await sendStarted.future;
    await database.deleteMessage(message.id);
    releaseSend.complete();
    await retry;

    final transfer = await database.fetchFileTransfer(retryId);
    expect(transfer?.messageRowId, 0);
    expect(transfer?.state, FileTransferState.canceled);
    expect(transfer?.lastError, 'message_deleted');
  });

  test('device clearing wins a race with recoverable offer reconciliation',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'_uuid': 'local'});
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    const transferId = '81234567-89ab-4cde-8fab-0123456789ab';
    final message =
        await database.insertMessageReturning(_fileMessage(transferId));
    await database.upsertFileTransfer(
      _outgoingTransfer(transferId).copyWith(messageRowId: message.id),
    );
    final sendStarted = Completer<void>();
    final releaseSend = Completer<void>();
    final engine = _engine(
      database: database,
      supportsV3: true,
      connectedPeerIds: const <String>{'peer-a'},
      sendBytesToPeer: (_, __) async {
        sendStarted.complete();
        await releaseSend.future;
        return true;
      },
    );

    final resume = engine.resumeRecoverableOutgoing();
    await sendStarted.future;
    await database.clearDevices(const <String>['peer-a']);
    releaseSend.complete();
    await resume;

    final transfer = await database.fetchFileTransfer(transferId);
    expect(transfer?.messageRowId, 0);
    expect(transfer?.state, FileTransferState.canceled);
    expect(transfer?.lastError, 'device_cleared');
  });
}
