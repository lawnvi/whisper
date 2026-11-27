import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/socket/aead_engine.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory sharedDownloadDir;
  setUpAll(() async {
    sharedDownloadDir = await Directory.systemTemp.createTemp(
      'whisper-bp-downloads-',
    );
    SharedPreferences.setMockInitialValues({
      '_savePath': sharedDownloadDir.path,
    });
    WhisperAead.installNativeAcceleration(await SodiumInit.init());
    StreamingChecksum.installNativeSha256Acceleration();
  });
  tearDownAll(() async {
    if (await sharedDownloadDir.exists()) {
      await sharedDownloadDir.delete(recursive: true);
    }
  });

  // Regression (cc review round 2): dart:io WebSocket.close() throws StateError
  // while addStream() is blocked on a slow/stalled peer. disconnectPeer must
  // destroy the underlying socket and return promptly without uncaught errors.
  test(
    'disconnectPeer completes within 1s while addStream is blocked on a stalled peer',
    () async {
      final pair = await _PeerPair.start();
      addTearDown(pair.dispose);

      // Large enough to fill both kernel send/receive buffers and stall addStream.
      final payloadFile = await pair.createSourceFile(
        'stalled.bin',
        12 * 1024 * 1024,
      );
      final transferring = pair.peerAEvents.waitTransferState(
        FileTransferState.transferring,
      );
      expect(await pair.peerA.sendFileTo('peer-b', payloadFile.path), isTrue);
      await transferring.timeout(const Duration(seconds: 5));

      // Freeze forwarding A -> B so peer A's addStream blocks on TCP backpressure.
      pair.proxy.pauseAToB();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final sw = Stopwatch()..start();
      await pair.peerA
          .disconnectPeer('peer-b')
          .timeout(const Duration(seconds: 1));
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(pair.peerA.isConnectedTo('peer-b'), isFalse);
    },
  );

  // Regression (cc review A): guards against the full-duplex TCP circular wait
  // where peer A's inbound receive chain waits on A's outbound space/socket
  // write while peer B's inbound receive chain waits on B's outbound space.
  // Both peers transfer files simultaneously over a slow bidirectional proxy
  // while performing concurrent mount reads and exchanging text messages;
  // neither side may deadlock and text must arrive within the deadline.
  test(
    'bidirectional simultaneous transfers, mount reads, and text over a slow link do not deadlock',
    () async {
      final pair = await _PeerPair.start(
        // Throttle both directions (~4 MiB/s) so both sides hit real backpressure.
        throttlePauseEveryBytes: 128 * 1024,
        throttlePause: const Duration(milliseconds: 30),
        enableBrowseRead: true,
      );
      addTearDown(pair.dispose);

      final fileA = await pair.createSourceFile('from_a.bin', 6 * 1024 * 1024);
      final fileB = await pair.createSourceFile('from_b.bin', 6 * 1024 * 1024);
      final mountRelA = await pair.createBrowseFile('mount_a.bin', 512 * 1024);
      final mountRelB = await pair.createBrowseFile('mount_b.bin', 512 * 1024);

      final doneA = pair.peerAEvents.waitTransferState(
        FileTransferState.completed,
        direction: FileTransferDirection.outgoing,
      );
      final doneB = pair.peerBEvents.waitTransferState(
        FileTransferState.completed,
        direction: FileTransferDirection.outgoing,
      );

      expect(await pair.peerA.sendFileTo('peer-b', fileA.path), isTrue);
      expect(await pair.peerB.sendFileTo('peer-a', fileB.path), isTrue);

      // Exchange text messages AND mount read requests in both directions
      // while both large transfers are actively running.
      final textReachedB = pair.peerBEvents.waitText('bidi-ping-a-to-b');
      final textReachedA = pair.peerAEvents.waitText('bidi-ping-b-to-a');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final readFromB = pair.browseReadA!.read(
        pair.browseRootId!,
        mountRelB,
        0,
        256 * 1024,
      );
      final readFromA = pair.browseReadB!.read(
        pair.browseRootId!,
        mountRelA,
        0,
        256 * 1024,
      );
      expect(
        await pair.peerA.sendMessageTo('peer-b', 'bidi-ping-a-to-b'),
        isTrue,
      );
      expect(
        await pair.peerB.sendMessageTo('peer-a', 'bidi-ping-b-to-a'),
        isTrue,
      );

      await Future.wait(<Future<void>>[
        textReachedB,
        textReachedA,
      ]).timeout(const Duration(seconds: 15));
      final reads = await Future.wait(<Future<Uint8List>>[
        readFromB,
        readFromA,
      ]).timeout(const Duration(seconds: 20));
      expect(reads[0].length, 256 * 1024);
      expect(reads[1].length, 256 * 1024);
      await Future.wait(<Future<void>>[
        doneA,
        doneB,
      ]).timeout(const Duration(seconds: 30));

      expect(pair.peerA.isConnectedTo('peer-b'), isTrue);
      expect(pair.peerB.isConnectedTo('peer-a'), isTrue);
    },
  );
}

final class _PeerPair {
  _PeerPair._({
    required this.root,
    required this.dbA,
    required this.dbB,
    required this.peerA,
    required this.peerB,
    required this.peerAEvents,
    required this.peerBEvents,
    required this.proxy,
    this.browseReadA,
    this.browseReadB,
    this.browseRootId,
    this.browseDir,
    this.restoreBrowseCallbacks,
  });

  final Directory root;
  final LocalDatabase dbA;
  final LocalDatabase dbB;
  final WsSvrManager peerA;
  final WsSvrManager peerB;
  final _TestEvents peerAEvents;
  final _TestEvents peerBEvents;
  final _ControllableTcpProxy proxy;
  final RemoteFilesClient? browseReadA;
  final RemoteFilesClient? browseReadB;
  final String? browseRootId;
  final Directory? browseDir;
  final void Function()? restoreBrowseCallbacks;

  static Future<_PeerPair> start({
    int? throttlePauseEveryBytes,
    Duration? throttlePause,
    bool enableBrowseRead = false,
  }) async {
    final root = await Directory.systemTemp.createTemp('whisper-bp-test-');

    final dbA = LocalDatabase.forTesting(NativeDatabase.memory());
    final dbB = LocalDatabase.forTesting(NativeDatabase.memory());
    final storeA = _seedStore(71);
    final storeB = _seedStore(81);
    final idA = await storeA.loadOrCreate();
    final idB = await storeB.loadOrCreate();

    await _trust(dbA, 'peer-b', idB.publicKeyBase64Url);
    await _trust(dbB, 'peer-a', idA.publicKeyBase64Url);

    final eventsA = _TestEvents();
    final eventsB = _TestEvents();
    final peerA = WsSvrManager.forTesting(
      database: dbA,
      identityStore: storeA,
      localPeerProfileLoader: () async => _profile('peer-a'),
      autoConnectEnabled: () async => false,
      manageSharedCoordinators: false,
    );
    final peerB = WsSvrManager.forTesting(
      database: dbB,
      identityStore: storeB,
      localPeerProfileLoader: () async => _profile('peer-b'),
      autoConnectEnabled: () async => false,
      manageSharedCoordinators: false,
    );
    peerA
      ..setSender('peer-a')
      ..setEvent(eventsA);
    peerB
      ..setSender('peer-b')
      ..setEvent(eventsB);

    final startedB = await peerB.startServer(0);
    expect(startedB.isSuccess, isTrue);

    final proxy = await _ControllableTcpProxy.start(
      upstreamPort: startedB.port,
      throttlePauseEveryBytes: throttlePauseEveryBytes,
      throttlePause: throttlePause,
    );

    final result = await peerA
        .connectToServer(
          ConnectionAttemptRequest(
            requestId: 'bp-connect',
            endpoint: PeerEndpoint.loopbackForTesting(port: proxy.port),
            expectedPeerId: 'peer-b',
            mode: ConnectionAttemptMode.interactive,
          ),
        )
        .timeout(const Duration(seconds: 5));
    expect(result.isAuthenticated, isTrue);

    RemoteFilesClient? browseReadA;
    RemoteFilesClient? browseReadB;
    String? browseRootId;
    Directory? browseDir;
    void Function()? restoreBrowse;
    if (enableBrowseRead) {
      // Wire the shared FileBrowseHost/RemoteFilesClient singletons for this
      // two-peer in-process test, routing outbound browse traffic by peerId.
      final prevHostSender = FileBrowseHost.shared.sender;
      final prevHostSendData = FileBrowseHost.shared.sendData;
      final prevClientSender = RemoteFilesClient.sender;
      final prevClientLocalPeer = RemoteFilesClient.localPeerId;

      await FileBrowseHost.shared.permissions.setAlways('peer-a', true);
      await FileBrowseHost.shared.permissions.setAlways('peer-b', true);
      WsSvrManager ownerFor(String targetPeerId) =>
          targetPeerId == 'peer-b' ? peerA : peerB;
      FileBrowseHost.shared.sender = (targetPeerId, msg) =>
          ownerFor(targetPeerId).sendFileBrowseControlTo(targetPeerId, msg);
      FileBrowseHost.shared.sendData =
          (targetPeerId, sessionId, requestId, offset, data) =>
              ownerFor(targetPeerId).sendFileBrowseData(
                targetPeerId,
                sessionId,
                requestId,
                offset,
                data,
              );
      RemoteFilesClient.sender = (targetPeerId, msg) =>
          ownerFor(targetPeerId).sendFileBrowseControlTo(targetPeerId, msg);
      RemoteFilesClient.localPeerId = (targetPeerId) =>
          targetPeerId == 'peer-b' ? 'peer-a' : 'peer-b';
      restoreBrowse = () {
        FileBrowseHost.shared
          ..sender = prevHostSender
          ..sendData = prevHostSendData;
        RemoteFilesClient.sender = prevClientSender;
        RemoteFilesClient.localPeerId = prevClientLocalPeer;
      };
      browseReadA = RemoteFilesClient('peer-b');
      browseReadB = RemoteFilesClient('peer-a');
      final infos = await Future.wait(<Future<RemoteFsInfo>>[
        browseReadA.open(),
        browseReadB.open(),
      ]).timeout(const Duration(seconds: 5));
      browseRootId = infos.first.roots.first.id;
      final rootDir = FileBrowseHost.shared.files.resolver.roots
          .firstWhere((r) => r.id == browseRootId)
          .directory;
      browseDir = await Directory(rootDir).createTemp('whisper_bp_browse_');
    }

    return _PeerPair._(
      root: root,
      dbA: dbA,
      dbB: dbB,
      peerA: peerA,
      peerB: peerB,
      peerAEvents: eventsA,
      peerBEvents: eventsB,
      proxy: proxy,
      browseReadA: browseReadA,
      browseReadB: browseReadB,
      browseRootId: browseRootId,
      browseDir: browseDir,
      restoreBrowseCallbacks: restoreBrowse,
    );
  }

  Future<String> createBrowseFile(String name, int bytes) async {
    final dir = browseDir!;
    final file = File(p.join(dir.path, name));
    final chunk = Uint8List(256 * 1024);
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 19 + name.length) & 255;
    }
    final raf = await file.open(mode: FileMode.write);
    try {
      var remaining = bytes;
      while (remaining > 0) {
        final take = remaining < chunk.length ? remaining : chunk.length;
        await raf.writeFrom(chunk, 0, take);
        remaining -= take;
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
    return '${p.basename(dir.path)}/$name';
  }

  Future<File> createSourceFile(String name, int bytes) async {
    final file = File(p.join(root.path, name));
    final chunk = Uint8List(256 * 1024);
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 17 + name.length) & 255;
    }
    final raf = await file.open(mode: FileMode.write);
    try {
      var remaining = bytes;
      while (remaining > 0) {
        final take = remaining < chunk.length ? remaining : chunk.length;
        await raf.writeFrom(chunk, 0, take);
        remaining -= take;
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
    return file;
  }

  Future<void> dispose() async {
    restoreBrowseCallbacks?.call();
    await proxy.close();
    await peerA.closeGracefully(closeServer: true, forceServerClose: true);
    await peerB.closeGracefully(closeServer: true, forceServerClose: true);
    await dbA.close();
    await dbB.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
    if (browseDir != null && await browseDir!.exists()) {
      await browseDir!.delete(recursive: true);
    }
  }
}

final class _ControllableTcpProxy {
  _ControllableTcpProxy._(
    this._server,
    this._upstreamPort,
    this._throttlePauseEveryBytes,
    this._throttlePause,
  );

  final ServerSocket _server;
  final int _upstreamPort;
  final int? _throttlePauseEveryBytes;
  final Duration? _throttlePause;
  final List<Socket> _sockets = <Socket>[];
  StreamSubscription<Uint8List>? _aToBSub;
  bool _aToBPaused = false;

  int get port => _server.port;

  static Future<_ControllableTcpProxy> start({
    required int upstreamPort,
    int? throttlePauseEveryBytes,
    Duration? throttlePause,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _ControllableTcpProxy._(
      server,
      upstreamPort,
      throttlePauseEveryBytes,
      throttlePause,
    );
    server.listen(proxy._accept);
    return proxy;
  }

  void pauseAToB() {
    _aToBPaused = true;
    _aToBSub?.pause();
  }

  Future<void> _accept(Socket client) async {
    final upstream = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _upstreamPort,
    );
    _sockets.addAll(<Socket>[client, upstream]);

    _aToBSub = _pipe(client, upstream, isAToB: true);
    _pipe(upstream, client, isAToB: false);
    if (_aToBPaused) {
      _aToBSub?.pause();
    }
  }

  StreamSubscription<Uint8List> _pipe(
    Socket from,
    Socket to, {
    required bool isAToB,
  }) {
    var sincePause = 0;
    late final StreamSubscription<Uint8List> sub;
    sub = from.listen(
      (data) {
        try {
          to.add(data);
        } catch (_) {}
        final every = _throttlePauseEveryBytes;
        final pause = _throttlePause;
        if (every != null && pause != null) {
          sincePause += data.length;
          if (sincePause >= every) {
            sincePause = 0;
            sub.pause();
            Timer(pause, () {
              if (!(isAToB && _aToBPaused)) {
                sub.resume();
              }
            });
          }
        }
      },
      onError: (_) => to.destroy(),
      onDone: to.destroy,
    );
    return sub;
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
    await _server.close();
  }
}

final class _TestEvents implements ISocketEvent {
  final _transferWaiters =
      <
        ({
          FileTransferState state,
          FileTransferDirection? direction,
          Completer<void> completer,
        })
      >[];
  final _textWaiters = <String, Completer<void>>{};
  final _receivedTexts = <String>{};

  Future<void> waitTransferState(
    FileTransferState state, {
    FileTransferDirection? direction,
  }) {
    final completer = Completer<void>();
    _transferWaiters.add((
      state: state,
      direction: direction,
      completer: completer,
    ));
    return completer.future;
  }

  Future<void> waitText(String content) {
    if (_receivedTexts.contains(content)) {
      return Future<void>.value();
    }
    return (_textWaiters[content] ??= Completer<void>()).future;
  }

  @override
  void onPairing(PairingRequest request, void Function(bool) resolve) =>
      resolve(true);

  @override
  void afterAuth(bool allow, DeviceData? device) {}
  @override
  void onClose() {}
  @override
  void onConnect() {}
  @override
  void onError(String message, {String? peerId}) {}
  @override
  void onNotice(String message) {}

  @override
  void onMessage(MessageData message) {
    if (message.type == MessageEnum.Text && !message.acked) {
      final text = message.content ?? '';
      _receivedTexts.add(text);
      final waiter = _textWaiters.remove(text);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    for (final waiter in _transferWaiters.toList()) {
      if (waiter.state == snapshot.state &&
          (waiter.direction == null ||
              waiter.direction == snapshot.direction)) {
        _transferWaiters.remove(waiter);
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete();
        }
      }
    }
  }
}

DeviceIdentityStore _seedStore(int seedBase) {
  final seed = base64Url
      .encode(List<int>.generate(32, (index) => seedBase + index))
      .replaceAll('=', '');
  return DeviceIdentityStore(storage: _FixedSeedStorage(seed));
}

final class _FixedSeedStorage implements DeviceIdentitySeedStorage {
  _FixedSeedStorage(this._seed);
  final String _seed;
  @override
  Future<String?> readSeed() async => _seed;
  @override
  Future<void> writeSeed(String value) async => throw StateError('immutable');
}

PeerProfile _profile(String uid) => PeerProfile(
  device: DeviceData(
    id: 0,
    uid: uid,
    name: uid,
    host: InternetAddress.loopbackIPv4.address,
    port: 10002,
    password: '',
    platform: Platform.operatingSystem,
    isServer: true,
    online: true,
    clipboard: false,
    auth: false,
    lastTime: 1,
    around: true,
  ),
  trustedPeerIds: const [],
  autoApproveNewDevices: false,
  autoConnectEnabled: false,
  protocolVersion: PeerSocketSession.protocolVersion,
  capabilities: const PeerCapabilities(
    fileTransferV3: true,
    remoteFilesV1: true,
  ),
);

Future<void> _trust(LocalDatabase db, String peerId, String publicKey) async {
  await db.upsertDevice(_profile(peerId).device);
  await db.pinDeviceIdentity(peerId, publicKey);
  await db.authDeviceIfPinned(peerId, publicKey);
}
