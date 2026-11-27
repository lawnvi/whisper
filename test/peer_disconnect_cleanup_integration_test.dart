import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/mount/remote_mounts.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';

void main() {
  // J13 guardrail: disconnecting peer-a over a real socket must clean up every
  // subsystem for peer-a (audio, remote input, window stream, file browse,
  // mount, remote clipboard, and file transfer) while peer-b stays intact.
  test(
    'disconnecting one peer cleans up all subsystems for that peer without affecting another connected peer',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '_uuid': 'hub-peer',
        '_name': 'hub-peer',
        '_clipboard': true,
        '_clipboard_auto_sync': true,
      });

      final tempDir = await Directory.systemTemp.createTemp(
        'whisper_disconnect_cleanup_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final sharedRootDir = await Directory('${tempDir.path}/shared').create();
      await File('${sharedRootDir.path}/probe.txt').writeAsString('ok');
      final downloadDirA = await Directory('${tempDir.path}/dl_a').create();
      final downloadDirB = await Directory('${tempDir.path}/dl_b').create();
      final downloadDirHub = await Directory('${tempDir.path}/dl_hub').create();

      final largeFileA = File('${tempDir.path}/to_a.bin');
      await largeFileA.writeAsBytes(
        Uint8List.fromList(List<int>.generate(2 * 1024 * 1024, (i) => i & 255)),
        flush: true,
      );
      final smallFileB = File('${tempDir.path}/to_b.bin');
      final smallBytesB = Uint8List.fromList(
        List<int>.generate(64 * 1024, (i) => (i * 13) & 255),
      );
      await smallFileB.writeAsBytes(smallBytesB, flush: true);

      final dbHub = LocalDatabase.forTesting(NativeDatabase.memory());
      final dbA = LocalDatabase.forTesting(NativeDatabase.memory());
      final dbB = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(dbHub.close);
      addTearDown(dbA.close);
      addTearDown(dbB.close);

      final hubAudio = AudioShareManager();
      final hubInput = RemoteInputManager();
      final hubTokens = SessionUpgradeTokenRegistry();

      const audioSessionA = '11111111-1111-4111-8111-111111111111';
      const audioSessionB = '22222222-2222-4222-8222-222222222222';
      const inputSessionA = '33333333-3333-4333-8333-333333333333';
      const inputSessionB = '44444444-4444-4444-8444-444444444444';

      final hubEvents = _RecordingEvents();
      final eventsA = _RecordingEvents();
      final eventsB = _RecordingEvents();

      final hub = WsSvrManager.forTesting(
        database: dbHub,
        identityStore: _identityStore(1),
        localPeerProfileLoader: () async => _profile('hub-peer'),
        autoConnectEnabled: () async => true,
        manageSharedCoordinators: false,
        audioManager: hubAudio,
        remoteInputManager: hubInput,
        sessionUpgradeTokens: hubTokens,
        audioGroupClaimValidator: (claim) =>
            (claim.peerId == 'peer-a' && claim.sessionId == audioSessionA) ||
            (claim.peerId == 'peer-b' && claim.sessionId == audioSessionB),
        mediaPeerClaimValidator: (_) => true,
        transferDownloadDirectory: () async => downloadDirHub,
      );
      final peerA = WsSvrManager.forTesting(
        database: dbA,
        identityStore: _identityStore(33),
        localPeerProfileLoader: () async => _profile('peer-a'),
        autoConnectEnabled: () async => true,
        manageSharedCoordinators: false,
        transferDownloadDirectory: () async => downloadDirA,
      );
      final peerB = WsSvrManager.forTesting(
        database: dbB,
        identityStore: _identityStore(65),
        localPeerProfileLoader: () async => _profile('peer-b'),
        autoConnectEnabled: () async => true,
        manageSharedCoordinators: false,
        transferDownloadDirectory: () async => downloadDirB,
      );
      hub.setEvent(hubEvents);
      peerA.setEvent(eventsA);
      peerB.setEvent(eventsB);
      addTearDown(
        () => hub.closeGracefully(closeServer: true, forceServerClose: true),
      );
      addTearDown(() => peerA.closeGracefully(closeServer: true));
      addTearDown(() => peerB.closeGracefully(closeServer: true));

      final hubStarted = await hub.startServer(0);
      expect(hubStarted.isSuccess, isTrue);

      // Route peer-a through a pausing TCP proxy so an outgoing transfer from
      // hub -> peer-a stays actively mid-flight when peer-a disconnects.
      final proxyA = await _PausingTcpProxy.start(
        targetPort: hubStarted.port,
        pauseServerToClientAfterBytes: 256 * 1024,
      );
      addTearDown(proxyA.close);

      final connA = await peerA
          .connectToServer(
            ConnectionAttemptRequest(
              requestId: 'cleanup-a',
              endpoint: PeerEndpoint.loopbackForTesting(port: proxyA.port),
              expectedPeerId: 'hub-peer',
              mode: ConnectionAttemptMode.interactive,
            ),
          )
          .timeout(const Duration(seconds: 5));
      final connB = await peerB
          .connectToServer(
            ConnectionAttemptRequest(
              requestId: 'cleanup-b',
              endpoint: PeerEndpoint.loopbackForTesting(port: hubStarted.port),
              expectedPeerId: 'hub-peer',
              mode: ConnectionAttemptMode.interactive,
            ),
          )
          .timeout(const Duration(seconds: 5));
      expect(connA.isAuthenticated, isTrue);
      expect(connB.isAuthenticated, isTrue);
      expect(hub.connectedPeerIds, <String>{'peer-a', 'peer-b'});

      // 1. Audio + 2. Remote Input: attach real /audio and /input channels for
      // both peer-a and peer-b on hub.
      hubInput.acceptOffer(
        const RemoteInputControlMessage(
          action: RemoteInputControlAction.offer,
          sessionId: inputSessionA,
          sourcePeerId: 'peer-a',
          sinkPeerId: 'hub-peer',
          layoutEdge: RemoteInputEdge.right,
          remoteClipboardV1: true,
        ),
        remoteClipboardV1: true,
      );
      hubInput.acceptOffer(
        const RemoteInputControlMessage(
          action: RemoteInputControlAction.offer,
          sessionId: inputSessionB,
          sourcePeerId: 'peer-b',
          sinkPeerId: 'hub-peer',
          layoutEdge: RemoteInputEdge.left,
          remoteClipboardV1: true,
        ),
        remoteClipboardV1: true,
      );

      final keyA = Uint8List.fromList(List<int>.generate(32, (i) => i + 10));
      final keyB = Uint8List.fromList(List<int>.generate(32, (i) => i + 50));

      final audioChanA = await _openMediaChannel(
        port: hubStarted.port,
        tokens: hubTokens,
        route: '/audio',
        namespace: 'audio-group',
        sessionId: audioSessionA,
        peerId: 'peer-a',
        mediaKey: keyA,
      );
      final audioChanB = await _openMediaChannel(
        port: hubStarted.port,
        tokens: hubTokens,
        route: '/audio',
        namespace: 'audio-group',
        sessionId: audioSessionB,
        peerId: 'peer-b',
        mediaKey: keyB,
      );
      final inputChanA = await _openMediaChannel(
        port: hubStarted.port,
        tokens: hubTokens,
        route: '/input',
        namespace: 'remote-input',
        sessionId: inputSessionA,
        peerId: 'peer-a',
        mediaKey: keyA,
      );
      final inputChanB = await _openMediaChannel(
        port: hubStarted.port,
        tokens: hubTokens,
        route: '/input',
        namespace: 'remote-input',
        sessionId: inputSessionB,
        peerId: 'peer-b',
        mediaKey: keyB,
      );
      addTearDown(() async {
        await audioChanA.sink.close();
        await audioChanB.sink.close();
        await inputChanA.sink.close();
        await inputChanB.sink.close();
      });
      await _waitUntil(
        () => hubAudio.activeChannelCount == 2 && hubInput.activeChannelCount == 2,
        label: 'media channels open',
      );

      // 3. Window stream: both peers are registered in WindowStreamViewer.
      expect(WindowStreamViewer.shared.isConnected('peer-a'), isTrue);
      expect(WindowStreamViewer.shared.isConnected('peer-b'), isTrue);

      // 4. File browse + 5. Mount: wire real FileBrowseHost (for peer-a &
      // peer-b) and RemoteMounts (on hub) over the real sockets.
      final prevHostSender = FileBrowseHost.shared.sender;
      final prevHostSendData = FileBrowseHost.shared.sendData;
      final prevClientSender = RemoteFilesClient.sender;
      final prevClientLocal = RemoteFilesClient.localPeerId;
      addTearDown(() {
        FileBrowseHost.shared.sender = prevHostSender;
        FileBrowseHost.shared.sendData = prevHostSendData;
        RemoteFilesClient.sender = prevClientSender;
        RemoteFilesClient.localPeerId = prevClientLocal;
        FileBrowseHost.shared.closePeer('hub-peer');
        FileBrowseHost.shared.closePeer('peer-a');
        FileBrowseHost.shared.closePeer('peer-b');
      });
      FileBrowseHost.shared.sender = (targetPeerId, msg) {
        if (targetPeerId == 'hub-peer') {
          if (msg.hostPeerId == 'peer-a') {
            return peerA.sendFileBrowseControlTo('hub-peer', msg);
          }
          return peerB.sendFileBrowseControlTo('hub-peer', msg);
        }
        return hub.sendFileBrowseControlTo(targetPeerId, msg);
      };
      FileBrowseHost.shared.sendData = (peerId, tid, reqId, off, data) async {
        return true;
      };
      await FileBrowseHost.shared.permissions.setAlways('hub-peer', true);
      RemoteFilesClient.sender = hub.sendFileBrowseControlTo;
      RemoteFilesClient.localPeerId = hub.localPeerIdFor;

      var stoppedA = 0;
      var stoppedB = 0;
      late String rootIdB;
      final mounts = RemoteMounts(
        gracePeriod: const Duration(seconds: 30),
        reconnectWait: const Duration(milliseconds: 200),
        peerIdentityKey: hub.remoteIdentityPublicKeyFor,
        startMount: (source, roots, peerId, name) async {
          if (peerId == 'peer-b') rootIdB = roots.first.id;
          return (
            path: '${tempDir.path}/mnt_$peerId',
            stop: () async {
              if (peerId == 'peer-a') stoppedA += 1;
              if (peerId == 'peer-b') stoppedB += 1;
            },
          );
        },
      );
      addTearDown(mounts.unmountAll);

      await mounts.mount('peer-a', 'Peer A');
      await mounts.mount('peer-b', 'Peer B');
      expect(mounts.of('peer-a'), isNotNull);
      expect(mounts.of('peer-b'), isNotNull);
      final sourceB = mounts.sourceOf('peer-b')!;

      // 6. Remote clipboard: publish active clipboard offers for peer-a & peer-b.
      final clipFile = File('${tempDir.path}/clip.txt');
      await clipFile.writeAsString('clipboard-payload');
      final clipItem = RemoteClipboardLocalItem(
        name: 'clip.txt',
        size: await clipFile.length(),
        openRead: clipFile.openRead,
        resolvePath: () async => clipFile.path,
      );
      expect(
        await hub.publishRemoteClipboard(
          peerId: 'peer-a',
          sessionId: inputSessionA,
          items: <RemoteClipboardLocalItem>[clipItem],
        ),
        isTrue,
      );
      expect(
        await hub.publishRemoteClipboard(
          peerId: 'peer-b',
          sessionId: inputSessionB,
          items: <RemoteClipboardLocalItem>[clipItem],
        ),
        isTrue,
      );

      // 7. File transfer: start an active transfer to peer-a (pauses mid-flight
      // at proxyA) AND verify peer-b can still transfer after peer-a drops.
      expect(await hub.sendFileTo('peer-a', largeFileA.path), isTrue);
      await proxyA.paused.timeout(const Duration(seconds: 5));
      await _waitUntil(
        () => hubEvents.transfers.any(
          (t) =>
              t.peerUid == 'peer-a' &&
              (t.state == FileTransferState.transferring ||
                  t.state == FileTransferState.negotiating),
        ),
        label: 'transfer to peer-a active',
      );

      // Drop hub's upstream TCP socket at the proxy (abrupt network drop) so
      // hub detects peer-a's disconnect immediately without waiting for a
      // WebSocket close handshake through the paused proxy or closing peerA's
      // shared in-process FileBrowseHost singleton for hub-peer.
      proxyA.dropUpstream();
      await _waitUntil(() => !hub.isConnectedTo('peer-a'), label: 'peer-a disconnected');

      // Assert EVERY subsystem cleaned up for peer-a while peer-b stays alive:
      // 1. Audio: peer-a closed, peer-b still open.
      await _waitUntil(() => hubAudio.activeChannelCount == 1, label: 'audio count 1');
      // 2. Remote input: peer-a closed, peer-b still open.
      await _waitUntil(() => hubInput.activeChannelCount == 1, label: 'input count 1');
      // 3. Window stream: peer-a removed, peer-b still connected.
      expect(WindowStreamViewer.shared.isConnected('peer-a'), isFalse);
      expect(WindowStreamViewer.shared.isConnected('peer-b'), isTrue);
      // 4 & 5. File browse + Mount: peer-a entered grace (not unmounted on
      // transient drop), peer-b stays mounted and readable.
      await _waitUntil(() => mounts.isSuspended('peer-a'), label: 'mount peer-a suspended');
      expect(mounts.isSuspended('peer-b'), isFalse);
      expect(stoppedA, 0);
      expect(stoppedB, 0);
      expect(await sourceB.stat(rootIdB, ''), isNotNull);
      // 6. Clipboard: peer-a session no longer accepts clipboard publish/paste,
      // while peer-b's session stays valid.
      expect(
        await hub.publishRemoteClipboard(
          peerId: 'peer-a',
          sessionId: inputSessionA,
          items: <RemoteClipboardLocalItem>[clipItem],
        ),
        isFalse,
      );
      expect(
        await hub.publishRemoteClipboard(
          peerId: 'peer-b',
          sessionId: inputSessionB,
          items: <RemoteClipboardLocalItem>[clipItem],
        ),
        isTrue,
      );
      // 7. File transfer: peer-a moved to waitingReconnect; peer-b can still
      // send and complete a real file transfer.
      await _waitUntil(
        () => hubEvents.transfers.any(
          (t) =>
              t.peerUid == 'peer-a' &&
              t.state == FileTransferState.waitingReconnect,
        ),
        label: 'peer-a transfer waitingReconnect',
      );
      expect(await hub.sendFileTo('peer-b', smallFileB.path), isTrue);
      await _waitUntil(
        () => eventsB.transfers.any(
          (t) =>
              t.direction == FileTransferDirection.incoming &&
              t.state == FileTransferState.completed,
        ),
        timeout: const Duration(seconds: 8),
        label: 'peer-b transfer completed',
      );
      final completedB = eventsB.transfers.lastWhere(
        (t) =>
            t.direction == FileTransferDirection.incoming &&
            t.state == FileTransferState.completed,
      );
      expect(await File(completedB.finalPath).readAsBytes(), smallBytesB);

      // Explicit manual disconnect of peer-b cleans up peer-b completely,
      // including immediate unmount (via peerRevoked).
      await hub.disconnectPeer('peer-b');
      await mounts.peerRevoked('peer-b');
      await _waitUntil(
        () =>
            !hub.isConnectedTo('peer-b') &&
            hubAudio.activeChannelCount == 0 &&
            hubInput.activeChannelCount == 0,
        label: 'peer-b disconnected and channels closed',
      );
      expect(WindowStreamViewer.shared.isConnected('peer-b'), isFalse);
      expect(mounts.of('peer-b'), isNull);
      expect(stoppedB, 1);
    },
  );
}

Future<IOWebSocketChannel> _openMediaChannel({
  required int port,
  required SessionUpgradeTokenRegistry tokens,
  required String route,
  required String namespace,
  required String sessionId,
  required String peerId,
  required Uint8List mediaKey,
}) async {
  final token = tokens.issue(
    route: route,
    namespace: namespace,
    sessionId: sessionId,
    peerId: peerId,
    mediaMacKey: mediaKey,
    connectionGeneration: 1,
    now: DateTime.now(),
  );
  final uri = buildPeerPacketUri(
    host: '127.0.0.1',
    port: port,
    path: route,
    queryParameters: <String, String>{'session': sessionId, 'token': token},
  );
  final raw = IOWebSocketChannel.connect(uri);
  await raw.ready;
  await authenticateMediaWebSocketClient(
    raw,
    uri: uri,
    route: route,
    namespace: namespace,
    sessionId: sessionId,
    peerId: peerId,
    mediaMacKey: mediaKey,
  );
  return raw;
}

DeviceIdentityStore _identityStore(int seedStart) => DeviceIdentityStore(
  storage: _SeedStorage(
    Uint8List.fromList(List<int>.generate(32, (index) => seedStart + index)),
  ),
);

PeerProfile _profile(String uid) => PeerProfile(
  device: DeviceData(
    id: 0,
    uid: uid,
    name: uid,
    host: '127.0.0.1',
    port: 10002,
    password: '',
    platform: 'test',
    isServer: true,
    online: true,
    clipboard: true,
    auth: false,
    lastTime: 1,
    around: true,
  ),
  trustedPeerIds: const <String>[],
  autoApproveNewDevices: false,
  autoConnectEnabled: true,
  protocolVersion: PeerSocketSession.protocolVersion,
  capabilities: const PeerCapabilities(
    fileTransferV3: true,
    remoteFilesV1: true,
    remoteInputSourceV1: true,
    remoteInputSinkV1: true,
    windowStreamOfferV1: true,
  ),
);

final class _SeedStorage implements DeviceIdentitySeedStorage {
  _SeedStorage(this.seed);
  final Uint8List seed;

  @override
  Future<String?> readSeed() async =>
      base64Url.encode(seed).replaceAll('=', '');

  @override
  Future<void> writeSeed(String value) async {}
}

final class _RecordingEvents implements ISocketEvent {
  final List<TransferSnapshot> transfers = <TransferSnapshot>[];

  @override
  void afterAuth(bool allow, DeviceData? device) {}

  @override
  void onPairing(PairingRequest request, void Function(bool) resolve) {
    resolve(true);
  }

  @override
  void onClose() {}

  @override
  void onConnect() {}

  @override
  void onError(String message, {String? peerId}) {}

  @override
  void onMessage(MessageData messageData) {}

  @override
  void onNotice(String message) {}

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    transfers.add(snapshot);
  }
}

final class _PausingTcpProxy {
  _PausingTcpProxy._(this._server, this._pauseAfterBytes, this._targetPort);

  final ServerSocket _server;
  final int _pauseAfterBytes;
  final int _targetPort;
  final Completer<void> _paused = Completer<void>();
  final List<Socket> _sockets = <Socket>[];
  final List<Socket> _upstreamSockets = <Socket>[];
  bool _upstreamDropped = false;
  int _forwardedServerBytes = 0;

  int get port => _server.port;
  Future<void> get paused => _paused.future;

  static Future<_PausingTcpProxy> start({
    required int targetPort,
    required int pauseServerToClientAfterBytes,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _PausingTcpProxy._(
      server,
      pauseServerToClientAfterBytes,
      targetPort,
    );
    server.listen(proxy._accept);
    return proxy;
  }

  Future<void> _accept(Socket client) async {
    _sockets.add(client);
    late final Socket upstream;
    try {
      upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _targetPort,
      );
    } catch (_) {
      client.destroy();
      return;
    }
    _sockets.add(upstream);
    _upstreamSockets.add(upstream);
    client.listen(
      upstream.add,
      onError: (Object _) => upstream.destroy(),
      onDone: () => upstream.destroy(),
    );
    late final StreamSubscription<Uint8List> sToC;
    sToC = upstream.listen(
      (data) {
        client.add(data);
        _forwardedServerBytes += data.length;
        if (_forwardedServerBytes >= _pauseAfterBytes && !_paused.isCompleted) {
          sToC.pause();
          _paused.complete();
        }
      },
      onError: (Object _) {
        if (!_upstreamDropped) client.destroy();
      },
      onDone: () {
        if (!_upstreamDropped) client.destroy();
      },
    );
  }

  void dropUpstream() {
    _upstreamDropped = true;
    for (final s in _upstreamSockets) {
      s.destroy();
    }
    _upstreamSockets.clear();
  }

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    _sockets.clear();
    await _server.close();
  }
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
  String label = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TimeoutException('$label was not reached');
}
