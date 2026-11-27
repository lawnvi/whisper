import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/helper/folder_transfer_store.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/remote_files/fs_host_uploads.dart';
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/remote_files/fs_protocol.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/file_transfer_engine.dart'
    show FolderSendOutcome;
import 'package:whisper/socket/media_channel_dial.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/socket/transfer_channel_manager.dart';
import 'package:whisper/socket/transfer_channel_protocol.dart';
import 'package:whisper/socket/transfer_data_isolate.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      '_uuid': 'peer-a',
      '_name': 'peer-a',
      '_clipboard': false,
      '_clipboard_auto_sync': false,
    });
  });

  test(
    'file and folder transfers use /transfer bulk isolate while mount read/write use separate browse TCP without queuing behind bulk',
    () async {
      final pair = await _ConnectedPair.create(
        name: 'bulk_and_browse',
        transferChannelA: true,
        transferChannelB: true,
      );
      addTearDown(pair.dispose);

      // Prepare a shared root on peerB for mounted-folder reads/writes.
      final sharedRootDir = await Directory(
        '${pair.tempDir.path}/shared',
      ).create();
      final readPayload = Uint8List.fromList(
        List<int>.generate(256 * 1024, (i) => (i * 17) & 255),
      );
      await File(
        '${sharedRootDir.path}/mount_read.bin',
      ).writeAsBytes(readPayload, flush: true);
      await File(
        '${sharedRootDir.path}/mount_write.bin',
      ).writeAsBytes(Uint8List.fromList(<int>[1, 2, 3, 4]), flush: true);

      // Wire a temp-scoped FileBrowseHost on peerB whose `browseData` replies
      // travel over peerB's real `/transfer` `browse` channel into peerA's
      // worker isolate -> RemoteFilesClient.handleData, and send `browseWrite`
      // over peerA's real `/transfer` `browse` channel to peerB.
      final tempHost = FileBrowseHost(
        files: FsHostFiles(
          resolver: FsPathResolver([
            FsRoot(id: 'home', directory: sharedRootDir.path),
          ]),
        ),
        permissions: _AlwaysAllowPermissions(),
      );
      final savedClientSender = RemoteFilesClient.sender;
      final savedClientLocal = RemoteFilesClient.localPeerId;
      final savedClientWrite = RemoteFilesClient.sendWrite;
      tempHost.sender = (peerId, msg) async {
        RemoteFilesClient.handle(msg, remotePeerId: 'peer-b');
        return true;
      };
      tempHost.sendData = pair.peerB.debugSendFileBrowseData;
      RemoteFilesClient.sender = (peerId, msg) async {
        await tempHost.handle(
          msg,
          remotePeerId: 'peer-a',
          deviceName: 'peer-a',
        );
        return true;
      };
      RemoteFilesClient.localPeerId = pair.peerA.localPeerIdFor;
      RemoteFilesClient.sendWrite = pair.peerA.debugSendFileBrowseWrite;
      addTearDown(() {
        tempHost.closePeer('peer-a');
        RemoteFilesClient.sender = savedClientSender;
        RemoteFilesClient.localPeerId = savedClientLocal;
        RemoteFilesClient.sendWrite = savedClientWrite;
      });

      final client = RemoteFilesClient('peer-b');
      addTearDown(client.close);
      final info = await client.open();
      expect(info.canRead, isTrue);
      expect(info.canWrite, isTrue);

      // Prepare a multi-MiB file and a folder on peerA.
      final fileBytes = Uint8List.fromList(
        List<int>.generate(3 * 1024 * 1024, (i) => (i * 31) & 255),
      );
      final sourceFile = File('${pair.tempDir.path}/big.bin');
      await sourceFile.writeAsBytes(fileBytes, flush: true);

      final sourceFolder = await Directory(
        '${pair.tempDir.path}/sample_folder',
      ).create();
      final subDir = await Directory('${sourceFolder.path}/sub').create();
      final nestedBytes = Uint8List.fromList(
        List<int>.generate(128 * 1024, (i) => (i * 7) & 255),
      );
      await File('${sourceFolder.path}/a.txt').writeAsString('hello transfer');
      await File('${subDir.path}/b.bin').writeAsBytes(nestedBytes, flush: true);

      // Launch the file transfer AND concurrently issue a mount read + a
      // browseWrite frame over the real `browse` /transfer channel to verify
      // Must-Fix A: mount traffic uses its own `browse` TCP channel and
      // completes promptly while `bulk` is active.
      final fileSendFuture = pair.peerA.sendFileTo('peer-b', sourceFile.path);
      final readWatch = Stopwatch()..start();
      final readBack = await client.read(
        'home',
        'mount_read.bin',
        0,
        readPayload.length,
      );
      readWatch.stop();
      expect(readBack, equals(readPayload));
      expect(readWatch.elapsed, lessThan(const Duration(seconds: 5)));

      expect(
        await pair.peerA.debugSendFileBrowseWrite(
          'peer-b',
          '${client.sessionId}/probe-upload',
          999,
          0,
          Uint8List.fromList(<int>[7, 8, 9]),
        ),
        isTrue,
      );

      expect(await fileSendFuture, isTrue);
      final receivedFile = await _waitForCompletedIncomingTransfer(
        pair.dbB,
        name: 'big.bin',
      );
      expect(
        await File(receivedFile.finalPath).readAsBytes(),
        equals(fileBytes),
      );

      // Folder transfer over the same `bulk` /transfer channel.
      expect(
        await pair.peerA.sendFolderTo('peer-b', sourceFolder.path),
        FolderSendOutcome.sent,
      );
      final receivedFolder = await _waitForCompletedIncomingTransfer(
        pair.dbB,
        name: 'sample_folder',
      );
      expect(
        await File('${receivedFolder.finalPath}/a.txt').readAsString(),
        'hello transfer',
      );
      expect(
        await File('${receivedFolder.finalPath}/sub/b.bin').readAsBytes(),
        equals(nestedBytes),
      );

      // Verify both independent `/transfer` channels were opened and used.
      final bulkId = pair.peerA.debugActiveTransferChannelId(
        'peer-b',
        TransferChannelKind.bulk,
      );
      final browseId = pair.peerA.debugActiveTransferChannelId(
        'peer-b',
        TransferChannelKind.browse,
      );
      expect(bulkId, isNotNull);
      expect(browseId, isNotNull);
      expect(bulkId, isNot(equals(browseId)));

      final statsA = pair.peerA.debugTransferChannelStats;
      final statsB = pair.peerB.debugTransferChannelStats;
      expect(statsA.bulkSent, greaterThan(0));
      expect(statsB.bulkReceived, greaterThan(0));
      expect(statsB.browseSent, greaterThan(0));
      expect(statsA.browseReceived, greaterThan(0));
      expect(statsA.browseSent, greaterThan(0));
      expect(statsB.browseReceived, greaterThan(0));
    },
  );

  test(
    'Must-Fix B: writeClose refuses truncated commit when size mismatches and client awaits in-flight writes before writeClose',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'whisper_mount_write_order_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final originalBytes = Uint8List.fromList(<int>[10, 20, 30, 40, 50]);
      final targetFile = File('${tempDir.path}/doc.bin');
      await targetFile.writeAsBytes(originalBytes, flush: true);

      final hostFiles = FsHostFiles(
        resolver: FsPathResolver([FsRoot(id: 'home', directory: tempDir.path)]),
      );
      final uploads = FsUploads(hostFiles);

      // 1) Direct host guard: partial write followed by writeClose with a
      // larger expectedSize must refuse to commit, delete temp, and leave the
      // original file intact (never truncated).
      final upload = await uploads.open(
        owner: 'session-1',
        device: 'peer-a',
        rootId: 'home',
        relative: 'doc.bin',
        truncate: true,
      );
      await upload.write(0, Uint8List.fromList(<int>[1, 2, 3]));
      await expectLater(
        uploads.close(upload.id, commit: true, expectedSize: 100),
        throwsA(isA<FsPathException>()),
      );
      expect(await File(upload.temp).exists(), isFalse);
      expect(await targetFile.readAsBytes(), equals(originalBytes));

      // 2) Client barrier: writeClose called concurrently while an in-flight
      // write is awaiting its reply MUST wait for the write reply before
      // sending writeClose, and then commit the full un-truncated payload.
      final writeGate = Completer<void>();
      final order = <String>[];
      final host = FileBrowseHost(
        files: hostFiles,
        permissions: _AlwaysAllowPermissions(),
      );
      final savedClientSender = RemoteFilesClient.sender;
      final savedClientLocal = RemoteFilesClient.localPeerId;
      final savedClientWrite = RemoteFilesClient.sendWrite;
      host.sender = (peerId, msg) async {
        RemoteFilesClient.handle(msg, remotePeerId: 'peer-b');
        return true;
      };
      RemoteFilesClient.localPeerId = (_) => 'peer-a';
      RemoteFilesClient.sender = (peerId, msg) async {
        if (msg.action == FileBrowseAction.writeClose) {
          order.add('writeClose_sent');
        }
        await host.handle(msg, remotePeerId: 'peer-a', deviceName: 'peer-a');
        return true;
      };
      RemoteFilesClient.sendWrite =
          (peerId, transferId, reqId, offset, data) async {
            await writeGate.future;
            order.add('write_delivered');
            await host.handleWrite(
              remotePeerId: 'peer-a',
              transferId: transferId,
              requestId: reqId,
              offset: offset,
              data: data,
            );
            return true;
          };
      addTearDown(() {
        host.closePeer('peer-a');
        RemoteFilesClient.sender = savedClientSender;
        RemoteFilesClient.localPeerId = savedClientLocal;
        RemoteFilesClient.sendWrite = savedClientWrite;
      });

      final client = RemoteFilesClient('peer-b');
      addTearDown(client.close);
      await client.open();
      final opened = await client.writeOpen('home', 'doc.bin', truncate: true);
      final fullPayload = Uint8List.fromList(
        List<int>.generate(4096, (i) => i & 255),
      );
      final writeFuture = client.write(opened.id, 0, fullPayload);
      final closeFuture = client.writeClose(opened.id, commit: true);

      // Give closeFuture a tick to ensure it is genuinely blocked behind write.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(order, isEmpty);

      writeGate.complete();
      expect(await writeFuture, fullPayload.length);
      final closed = await closeFuture;
      expect(closed.path, 'doc.bin');
      expect(order, <String>['write_delivered', 'writeClose_sent']);
      expect(await targetFile.readAsBytes(), equals(fullPayload));

      // 3) Failed write guard + immediate failInflightDataForPeer on both
      // in-flight reads and in-flight writes:
      final opened2 = await client.writeOpen('home', 'doc.bin', truncate: true);
      final stalledWrite = Completer<void>();
      RemoteFilesClient.sendWrite = (peerId, tid, reqId, offset, data) async {
        // Leave reply pending to simulate a stalled browse channel drop.
        stalledWrite.complete();
        return true;
      };
      final pendingWrite = client.write(
        opened2.id,
        0,
        Uint8List.fromList(<int>[9, 9, 9]),
      );
      await stalledWrite.future;
      final readStarted = Completer<void>();
      RemoteFilesClient.sender = (peerId, msg) async {
        if (msg.action == FileBrowseAction.read) {
          readStarted.complete();
          return true;
        }
        await host.handle(msg, remotePeerId: 'peer-a', deviceName: 'peer-a');
        return true;
      };
      final pendingRead = client.read('home', 'doc.bin', 0, 16);
      await readStarted.future;
      final writeFailed = expectLater(
        pendingWrite,
        throwsA(isA<RemoteFsException>().having((e) => e.reason, 'reason', 'io')),
      );
      final readFailed = expectLater(
        pendingRead,
        throwsA(isA<RemoteFsException>().having((e) => e.reason, 'reason', 'io')),
      );
      RemoteFilesClient.failInflightDataForPeer('peer-b');
      await Future.wait<void>(<Future<void>>[writeFailed, readFailed]);
      await expectLater(
        client.writeClose(opened2.id, commit: true),
        throwsA(isA<RemoteFsException>().having((e) => e.reason, 'reason', 'io')),
      );
      // Original file remains intact after refused commit.
      expect(await targetFile.readAsBytes(), equals(fullPayload));
    },
  );

  test(
    'Must-Fix C: mid-transfer /transfer drop recovers under same /chat generation with new channelId, and stale channelId frames are dropped',
    () async {
      final pair = await _ConnectedPair.create(
        name: 'mid_drop_recover',
        transferChannelA: true,
        transferChannelB: true,
        retryDelays: const <Duration>[
          Duration(milliseconds: 100),
          Duration(milliseconds: 200),
        ],
      );
      addTearDown(pair.dispose);

      // First warm up the bulk channel with a small transfer so we know its
      // initial channelId and chat generation.
      final genBefore = pair.peerA.connectionIdOf('peer-b');
      final warmup = File('${pair.tempDir.path}/warmup.bin');
      await warmup.writeAsBytes(Uint8List(64 * 1024), flush: true);
      expect(await pair.peerA.sendFileTo('peer-b', warmup.path), isTrue);
      await _waitForCompletedIncomingTransfer(pair.dbB, name: 'warmup.bin');
      final firstChannelId = pair.peerA.debugActiveTransferChannelId(
        'peer-b',
        TransferChannelKind.bulk,
      );
      expect(firstChannelId, isNotNull);

      // Drop ONLY the /transfer bulk channel on peerB (causing unexpected
      // remote_closed on peerA) while /chat stays up with the same generation.
      pair.peerB.debugDropTransferChannel('peer-a', TransferChannelKind.bulk);
      await _waitUntil(
        () =>
            pair.peerA.debugActiveTransferChannelId(
              'peer-b',
              TransferChannelKind.bulk,
            ) ==
            null,
        description: 'bulk channel closed on peerA',
      );
      expect(pair.peerA.isConnectedTo('peer-b'), isTrue);
      expect(pair.peerA.connectionIdOf('peer-b'), genBefore);

      // Sending a new file under the same /chat generation opens a fresh bulk
      // channel with a strictly newer channelId and completes intact.
      final nextBytes = Uint8List.fromList(
        List<int>.generate(512 * 1024, (i) => (i * 23) & 255),
      );
      final nextFile = File('${pair.tempDir.path}/after_drop.bin');
      await nextFile.writeAsBytes(nextBytes, flush: true);
      expect(await pair.peerA.sendFileTo('peer-b', nextFile.path), isTrue);
      final received = await _waitForCompletedIncomingTransfer(
        pair.dbB,
        name: 'after_drop.bin',
      );
      expect(await File(received.finalPath).readAsBytes(), equals(nextBytes));
      final secondChannelId = pair.peerA.debugActiveTransferChannelId(
        'peer-b',
        TransferChannelKind.bulk,
      );
      expect(secondChannelId, isNotNull);
      expect(secondChannelId!, greaterThan(firstChannelId!));
      expect(pair.peerA.connectionIdOf('peer-b'), genBefore);
    },
  );

  test(
    'security boundaries, reverse dial-back, glare convergence, and capability fallback',
    () async {
      // 1) Unauthorized / bad-origin / wrong-path upgrades on worker port.
      final pair = await _ConnectedPair.create(
        name: 'security_and_glare',
        transferChannelA: true,
        transferChannelB: true,
      );
      addTearDown(pair.dispose);

      final workerPort = pair.peerB.debugTransferWorkerPort;
      expect(workerPort, greaterThan(0));

      final httpClient = HttpClient();
      addTearDown(httpClient.close);

      // Missing credentials -> 401
      final reqNoToken = await httpClient.getUrl(
        Uri.parse('http://127.0.0.1:$workerPort/transfer'),
      );
      reqNoToken.persistentConnection = false;
      reqNoToken.headers.set('Connection', 'Upgrade');
      reqNoToken.headers.set('Upgrade', 'websocket');
      reqNoToken.headers.set('Sec-WebSocket-Version', '13');
      reqNoToken.headers.set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
      final resNoToken = await reqNoToken.close();
      expect(resNoToken.statusCode, HttpStatus.unauthorized);
      await resNoToken.drain<void>();

      // Browser Origin header -> 400
      final reqOrigin = await httpClient.getUrl(
        Uri.parse(
          'http://127.0.0.1:$workerPort/transfer?session=11111111-1111-4111-8111-111111111111&token=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        ),
      );
      reqOrigin.persistentConnection = false;
      reqOrigin.headers.set('Connection', 'Upgrade');
      reqOrigin.headers.set('Upgrade', 'websocket');
      reqOrigin.headers.set('Sec-WebSocket-Version', '13');
      reqOrigin.headers.set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
      reqOrigin.headers.set('Origin', 'https://evil.example');
      final resOrigin = await reqOrigin.close();
      expect(resOrigin.statusCode, HttpStatus.badRequest);
      await resOrigin.drain<void>();

      // 2) Glare: peerA and peerB send files simultaneously so both emit
      // `open(kind: bulk)` at the same time; both converge to one live bulk
      // channel without falling back to /chat.
      final bytesAB = Uint8List.fromList(
        List<int>.generate(256 * 1024, (i) => (i + 3) & 255),
      );
      final bytesBA = Uint8List.fromList(
        List<int>.generate(256 * 1024, (i) => (i + 9) & 255),
      );
      final fileAB = File('${pair.tempDir.path}/ab.bin')
        ..writeAsBytesSync(bytesAB, flush: true);
      final fileBA = File('${pair.tempDir.path}/ba.bin')
        ..writeAsBytesSync(bytesBA, flush: true);

      final results = await Future.wait<bool>(<Future<bool>>[
        pair.peerA.sendFileTo('peer-b', fileAB.path),
        pair.peerB.sendFileTo('peer-a', fileBA.path),
      ]);
      expect(results, <bool>[true, true]);

      final recvB = await _waitForCompletedIncomingTransfer(
        pair.dbB,
        name: 'ab.bin',
      );
      final recvA = await _waitForCompletedIncomingTransfer(
        pair.dbA,
        name: 'ba.bin',
      );
      expect(await File(recvB.finalPath).readAsBytes(), equals(bytesAB));
      expect(await File(recvA.finalPath).readAsBytes(), equals(bytesBA));
      expect(pair.peerA.debugTransferChannelStats.bulkSent, greaterThan(0));
      expect(pair.peerB.debugTransferChannelStats.bulkSent, greaterThan(0));

      // 3) Capability fallback: peer without transferChannelV1 transfers over
      // /chat seamlessly with 0 /transfer frames.
      final legacyPair = await _ConnectedPair.create(
        name: 'legacy_fallback',
        transferChannelA: true,
        transferChannelB: false,
      );
      addTearDown(legacyPair.dispose);

      final fallbackBytes = Uint8List.fromList(
        List<int>.generate(128 * 1024, (i) => (i * 5) & 255),
      );
      final fallbackFile = File('${legacyPair.tempDir.path}/fallback.bin')
        ..writeAsBytesSync(fallbackBytes, flush: true);
      expect(
        await legacyPair.peerA.sendFileTo('peer-b', fallbackFile.path),
        isTrue,
      );
      final recvFallback = await _waitForCompletedIncomingTransfer(
        legacyPair.dbB,
        name: 'fallback.bin',
      );
      expect(
        await File(recvFallback.finalPath).readAsBytes(),
        equals(fallbackBytes),
      );
      expect(legacyPair.peerA.debugTransferChannelStats.bulkSent, 0);
    },
  );

  test(
    'reverse dial-back succeeds when responder worker port is unreachable and disallowed frame types close /transfer',
    () async {
      // Allocate an immediately closed port to guarantee ECONNREFUSED on
      // forward dial so TransferChannelManager exercises reverse dial-back.
      final deadServer = await ServerSocket.bind('127.0.0.1', 0);
      final unreachablePort = deadServer.port;
      await deadServer.close();

      final keyAtoB = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final keyBtoA = Uint8List.fromList(List<int>.generate(32, (i) => i + 41));
      final tokensA = SessionUpgradeTokenRegistry();
      final tokensB = SessionUpgradeTokenRegistry();

      final receivedOnA = <TransferDataInboundFrame>[];
      final receivedOnB = <TransferDataInboundFrame>[];
      late _LoopbackTransferHost hostA;
      late _LoopbackTransferHost hostB;
      late TransferChannelManager mgrA;
      late TransferChannelManager mgrB;

      hostA = _LoopbackTransferHost(
        localPeerId: 'peer-a',
        remotePeerId: 'peer-b',
        sendKey: keyAtoB,
        receiveKey: keyBtoA,
        tokens: tokensA,
        onControlOut: (control) => mgrB.handleControl(
          remotePeerId: 'peer-a',
          localGeneration: 1,
          control: control,
        ),
        onInbound: receivedOnA.add,
      );
      hostB = _LoopbackTransferHost(
        localPeerId: 'peer-b',
        remotePeerId: 'peer-a',
        sendKey: keyBtoA,
        receiveKey: keyAtoB,
        tokens: tokensB,
        // Corrupt responder's accept port to unreachablePort to force dial-back!
        onControlOut: (control) {
          final rewritten = control.action == TransferChannelAction.accept
              ? TransferChannelControlMessage(
                  action: control.action,
                  kind: control.kind,
                  sessionId: control.sessionId,
                  sourcePeerId: control.sourcePeerId,
                  sinkPeerId: control.sinkPeerId,
                  transportToken: control.transportToken,
                  transferPort: unreachablePort,
                )
              : control;
          return mgrA.handleControl(
            remotePeerId: 'peer-b',
            localGeneration: 1,
            control: rewritten,
          );
        },
        onInbound: receivedOnB.add,
      );

      mgrA = TransferChannelManager(
        hostA,
        claimBrokerFactory: (m) =>
            _LoopbackClaimBroker(tokens: tokensA, sendKey: keyAtoB, manager: m),
        dialConnectTimeout: const Duration(milliseconds: 500),
      );
      mgrB = TransferChannelManager(
        hostB,
        claimBrokerFactory: (m) =>
            _LoopbackClaimBroker(tokens: tokensB, sendKey: keyBtoA, manager: m),
        dialConnectTimeout: const Duration(milliseconds: 500),
      );
      addTearDown(() async {
        await mgrA.stopWorker();
        await mgrB.stopWorker();
      });

      expect(await mgrA.startWorker(mainPort: 0), greaterThan(0));
      expect(await mgrB.startWorker(mainPort: 0), greaterThan(0));

      const bindingA = TransferConnectionBinding(
        peerId: 'peer-b',
        generation: 1,
      );
      final dataFrame = WhisperFrameV3(
        type: WhisperFrameType.fileData,
        transferId: const Uuid().v4(),
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
      ).encode();

      final sent = await mgrA.sendFrame(
        binding: bindingA,
        kind: TransferChannelKind.bulk,
        encodedFrame: dataFrame,
      );
      expect(sent, isTrue);
      expect(hostA.fallbackCount, 0);
      await _waitUntil(
        () => receivedOnB.length == 1,
        description: 'peerB receives fileData over dial-backed /transfer',
      );
      expect(receivedOnB.single.bytes, equals(dataFrame));

      // Sending a disallowed control frame (`WhisperFrameType.message`) over
      // the `bulk` /transfer channel must be rejected by peerB's worker and
      // close the channel without delivering it to peerB's business handler.
      final badControlFrame = WhisperFrameV3(
        type: WhisperFrameType.message,
        transferId: '',
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(<int>[0x7b, 0x7d]),
      ).encode();
      await mgrA.sendFrame(
        binding: bindingA,
        kind: TransferChannelKind.bulk,
        encodedFrame: badControlFrame,
      );
      await _waitUntil(
        () =>
            mgrB.activeChannelIdFor('peer-a', 1, TransferChannelKind.bulk) ==
            null,
        description: 'disallowed frame closes bulk channel on receiver',
      );
      expect(receivedOnB.length, 1);

      // Verify stale channelId frames are dropped when channel is not active.
      expect(
        mgrB.isChannelCurrent(
          peerId: 'peer-a',
          generation: 1,
          kind: TransferChannelKind.bulk,
          channelId: receivedOnB.single.channelId,
        ),
        isFalse,
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Test harnesses
// ---------------------------------------------------------------------------

final class _ConnectedPair {
  _ConnectedPair._({
    required this.tempDir,
    required this.dbA,
    required this.dbB,
    required this.peerA,
    required this.peerB,
  });

  final Directory tempDir;
  final LocalDatabase dbA;
  final LocalDatabase dbB;
  final WsSvrManager peerA;
  final WsSvrManager peerB;

  static Future<_ConnectedPair> create({
    required String name,
    required bool transferChannelA,
    required bool transferChannelB,
    List<Duration>? retryDelays,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'whisper_tc_${name}_',
    );
    final dlA = await Directory('${tempDir.path}/dl_a').create();
    final dlB = await Directory('${tempDir.path}/dl_b').create();
    final stageA = await Directory('${tempDir.path}/stage_a').create();
    final stageB = await Directory('${tempDir.path}/stage_b').create();
    final dbA = LocalDatabase.forTesting(NativeDatabase.memory());
    final dbB = LocalDatabase.forTesting(NativeDatabase.memory());

    final peerA = WsSvrManager.forTesting(
      database: dbA,
      identityStore: _identityStore(11),
      localPeerProfileLoader: () async =>
          _profile('peer-a', transferChannel: transferChannelA),
      autoConnectEnabled: () async => true,
      manageSharedCoordinators: false,
      transferDownloadDirectory: () async => dlA,
      folderTransferStore: FolderTransferStore(
        directory: () async => stageA,
      ),
      transferRetryDelays: retryDelays,
      enableTransferChannel: transferChannelA,
    );
    final peerB = WsSvrManager.forTesting(
      database: dbB,
      identityStore: _identityStore(77),
      localPeerProfileLoader: () async =>
          _profile('peer-b', transferChannel: transferChannelB),
      autoConnectEnabled: () async => true,
      manageSharedCoordinators: false,
      transferDownloadDirectory: () async => dlB,
      folderTransferStore: FolderTransferStore(
        directory: () async => stageB,
      ),
      transferRetryDelays: retryDelays,
      enableTransferChannel: transferChannelB,
    );
    peerA.registerEvent(_AutoApproveEvents(), uid: 'peer-a', primary: true);
    peerB.registerEvent(_AutoApproveEvents(), uid: 'peer-b', primary: true);

    final startA = await peerA.startServer(0);
    final startB = await peerB.startServer(0);
    expect(startA.isSuccess, isTrue);
    expect(startB.isSuccess, isTrue);

    final connected = await peerA
        .connectToServer(
          ConnectionAttemptRequest(
            requestId: 'tc-$name',
            endpoint: PeerEndpoint.loopbackForTesting(port: startB.port),
            expectedPeerId: 'peer-b',
            mode: ConnectionAttemptMode.interactive,
          ),
        )
        .timeout(const Duration(seconds: 5));
    expect(connected.isAuthenticated, isTrue);
    await _waitUntil(
      () => peerA.isConnectedTo('peer-b') && peerB.isConnectedTo('peer-a'),
      description: 'peers authenticated',
    );
    return _ConnectedPair._(
      tempDir: tempDir,
      dbA: dbA,
      dbB: dbB,
      peerA: peerA,
      peerB: peerB,
    );
  }

  Future<void> dispose() async {
    await peerA.close(closeServer: true);
    await peerB.close(closeServer: true);
    await dbA.close();
    await dbB.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}

final class _AutoApproveEvents implements ISocketEvent {
  @override void afterAuth(bool allow, DeviceData? device) {}
  @override void onClose() {}
  @override void onConnect() {}
  @override void onError(String message, {String? peerId}) {}
  @override void onMessage(MessageData message) {}
  @override void onNotice(String message) {}
  @override void onPairing(PairingRequest request, void Function(bool approved) resolve) => resolve(true);
  @override void onTransferUpdated(TransferSnapshot snapshot) {}
}

final class _AlwaysAllowPermissions extends FileBrowsePermissions {
  @override Future<bool> isAlways(String peerId) async => true;
  @override Future<bool> isReadOnly(String peerId) async => false;
}

final class _SeedStorage implements DeviceIdentitySeedStorage {
  _SeedStorage(this.seed);
  final Uint8List seed;
  @override Future<String?> readSeed() async => base64Url.encode(seed).replaceAll('=', '');
  @override Future<void> writeSeed(String value) async {}
}

DeviceIdentityStore _identityStore(int seedBase) => DeviceIdentityStore(
  storage: _SeedStorage(Uint8List.fromList(List<int>.generate(32, (i) => (seedBase + i) & 255))),
);

PeerProfile _profile(String uid, {required bool transferChannel}) => PeerProfile(
  device: DeviceData(
    id: 0, uid: uid, name: uid, host: '127.0.0.1', port: 0, password: '',
    platform: 'macos', isServer: false, online: true, clipboard: false,
    auth: false, lastTime: 0, around: true,
  ),
  trustedPeerIds: const <String>[], autoApproveNewDevices: true,
  autoConnectEnabled: true, protocolVersion: PeerSocketSession.protocolVersion,
  capabilities: PeerCapabilities(
    fileTransferV3: true, remoteFilesV1: true, transferChannelV1: transferChannel,
  ),
);

Future<FileTransferData> _waitForCompletedIncomingTransfer(
  LocalDatabase db, {
  required String name,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final rows = await db.select(db.fileTransfer).get();
    for (final row in rows) {
      if (row.direction == FileTransferDirection.incoming &&
          row.state == FileTransferState.completed &&
          row.finalPath.endsWith(name)) {
        return row;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  throw TimeoutException('incoming transfer $name did not complete in time');
}

Future<void> _waitUntil(
  bool Function() predicate, {
  required String description,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException('$description was not reached within $timeout');
}

final class _LoopbackTransferHost implements TransferChannelHost {
  _LoopbackTransferHost({
    required this.localPeerId,
    required this.remotePeerId,
    required this.sendKey,
    required this.receiveKey,
    required this.tokens,
    required this.onControlOut,
    required this.onInbound,
  });

  final String localPeerId;
  final String remotePeerId;
  final Uint8List sendKey;
  final Uint8List receiveKey;
  final SessionUpgradeTokenRegistry tokens;
  final Future<void> Function(TransferChannelControlMessage control)
  onControlOut;
  final void Function(TransferDataInboundFrame frame) onInbound;
  int fallbackCount = 0;

  @override
  bool get enabled => true;
  @override
  String localPeerIdFor(String peerId) => localPeerId;
  @override
  bool peerSupportsTransferChannel(String peerId) => peerId == remotePeerId;
  @override
  TransferConnectionBinding? currentBinding(String peerId) =>
      peerId == remotePeerId
      ? TransferConnectionBinding(peerId: remotePeerId, generation: 1)
      : null;
  @override
  String? dialHostFor(String peerId, int generation) =>
      peerId == remotePeerId && generation == 1 ? '127.0.0.1' : null;
  @override
  T? withSessionKeys<T>(
    String peerId,
    int generation,
    T Function(Uint8List sendKey, Uint8List receiveKey) action,
  ) => action(Uint8List.fromList(sendKey), Uint8List.fromList(receiveKey));
  @override
  String? issueTransferToken({
    required String peerId,
    required int generation,
    required String sessionId,
    required bool reverse,
  }) => tokens.issue(
    route: MediaRoute.transfer.path,
    namespace: MediaRoute.transfer.namespace,
    sessionId: sessionId,
    peerId: peerId,
    mediaMacKey: receiveKey,
    connectionGeneration: generation,
    reverse: reverse,
    now: DateTime.now(),
  );
  @override
  void revokeTransferToken({
    required String peerId,
    required String sessionId,
  }) => tokens.revoke(
    route: MediaRoute.transfer.path,
    namespace: MediaRoute.transfer.namespace,
    sessionId: sessionId,
    peerId: peerId,
  );
  @override
  Future<bool> sendControl(
    String peerId,
    TransferChannelControlMessage control,
  ) async {
    unawaited(onControlOut(control));
    return true;
  }

  @override
  Future<bool> sendFallbackOnChat(
    TransferConnectionBinding binding,
    Object payload,
  ) async {
    fallbackCount += 1;
    return true;
  }

  @override
  void handleInboundFrame(TransferDataInboundFrame frame) => onInbound(frame);
  @override
  void onUnexpectedChannelDrop(
    String peerId,
    int generation,
    TransferChannelKind kind,
  ) {}
}

final class _LoopbackClaimBroker implements TransferClaimBroker {
  _LoopbackClaimBroker({
    required this.tokens,
    required this.sendKey,
    required this.manager,
  });

  final SessionUpgradeTokenRegistry tokens;
  final Uint8List sendKey;
  final TransferChannelManager manager;

  @override
  TransferClaimLookupResult? lookup({
    required String sessionId,
    required String token,
    required Object remoteAddress,
  }) {
    final claim = tokens.lookup(
      route: MediaRoute.transfer.path,
      sessionId: sessionId,
      token: token,
      now: DateTime.now(),
    );
    if (claim == null) return null;
    final kind = manager.lookupPendingClaimKind(claim);
    if (kind == null) {
      claim.destroy();
      return null;
    }
    return TransferClaimLookupResult(
      claim: claim,
      kind: kind,
      sendKey: Uint8List.fromList(sendKey),
    );
  }

  @override
  bool consume({
    required String sessionId,
    required String token,
    required SessionUpgradeClaim expected,
  }) {
    if (!manager.consumePendingClaim(expected)) return false;
    final consumed = tokens.consume(
      route: MediaRoute.transfer.path,
      sessionId: sessionId,
      token: token,
      now: DateTime.now(),
      expected: expected,
    );
    consumed?.destroy();
    return consumed != null;
  }
}
