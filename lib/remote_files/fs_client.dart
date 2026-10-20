import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'files_log.dart';
import 'fs_host.dart';
import 'fs_host_files.dart';
import 'fs_paths.dart';
import 'fs_placement.dart';
import 'fs_protocol.dart';

/// What a browsed device offers once its user said yes.
class RemoteFsRoot {
  const RemoteFsRoot({
    required this.id,
    required this.shortcuts,
    this.kind = 'home',
    this.name = '',
    this.drive = '',
    this.removable = false,
  });

  final String id;
  final List<FsShortcut> shortcuts;

  /// home, storage, documents, drive or volume (older hosts: home or
  /// storage, by id).
  final String kind;

  /// The volume's own name, when it has one.
  final String name;

  /// Windows drive letter, for drives.
  final String drive;
  final bool removable;
}

class RemoteFsInfo {
  const RemoteFsInfo({
    required this.roots,
    required this.platform,
    required this.hasTrash,
    this.canRead = false,
  });

  final List<RemoteFsRoot> roots;
  final String platform;
  final bool hasTrash;

  /// Answers [RemoteFilesClient.read] (newer hosts), so that its files can
  /// be mounted here.
  final bool canRead;
}

/// A request the other device refused or could not do.
class RemoteFsException implements Exception {
  const RemoteFsException(this.reason);

  /// One of [FileBrowseError], or 'denied' / 'noAnswer' / 'canceled' /
  /// 'offline' / 'timeout'.
  final String reason;

  @override
  String toString() => 'RemoteFsException($reason)';
}

/// Ordinary transfer that carries a copy.
typedef RemoteFsSendPath =
    Future<bool> Function(String peerId, String path, String transferId);

/// Browsing one other device's files: one session, request ids, paced
/// thumbnails. Copies in both directions are ordinary transfers placed by
/// [TransferPlacements] when they complete.
class RemoteFilesClient {
  RemoteFilesClient(this.peerId, {String? sessionId})
    : sessionId = sessionId ?? _uuid.v4();

  static FileBrowseSender? sender;
  static String Function(String peerId)? localPeerId;
  static RemoteFsSendPath? sendFile;
  static RemoteFsSendPath? sendFolder;
  static final _clients = <String, RemoteFilesClient>{};
  static const _uuid = Uuid();

  final String peerId;
  final String sessionId;
  int _nextRequest = 1;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _reads = <int, Completer<Uint8List>>{};
  Completer<RemoteFsInfo>? _opening;
  RemoteFsInfo? info;
  int _thumbsRunning = 0;
  final _thumbQueue = <Completer<void>>[];
  final _gone = Completer<RemoteFsException>();

  /// Completes when the session ends over there: the device went offline,
  /// or it stopped letting this one browse.
  Future<RemoteFsException> get gone => _gone.future;

  /// Routes a host's reply to the client that asked.
  static void handle(
    FileBrowseMessage message, {
    required String remotePeerId,
  }) {
    final client = _clients[message.sessionId];
    if (client == null || client.peerId != remotePeerId || !message.fromHost) {
      return;
    }
    client._onMessage(message);
  }

  /// Bytes a [read] asked for, from a `browseData` frame.
  static void handleData({
    required String remotePeerId,
    required String sessionId,
    required int requestId,
    required Uint8List data,
  }) {
    final client = _clients[sessionId];
    if (client == null || client.peerId != remotePeerId) {
      return;
    }
    client._reads.remove(requestId)?.complete(data);
  }

  /// The browsed device disconnected.
  static void peerGone(String peerId) {
    for (final client in _clients.values.toList()) {
      if (client.peerId == peerId) {
        client._fail(const RemoteFsException('offline'));
      }
    }
  }

  FileBrowseMessage _message(
    FileBrowseAction action, {
    int requestId = 0,
    Map<String, Object?> payload = const {},
  }) {
    return FileBrowseMessage(
      action: action,
      sessionId: sessionId,
      clientPeerId: localPeerId?.call(peerId) ?? '',
      hostPeerId: peerId,
      requestId: requestId,
      payload: payload,
    );
  }

  /// Asks the other device; its user may take a while to answer.
  Future<RemoteFsInfo> open() async {
    final existing = info;
    if (existing != null) {
      return existing;
    }
    final opening = _opening ??= Completer<RemoteFsInfo>();
    _clients[sessionId] = this;
    final sent = await sender?.call(peerId, _message(FileBrowseAction.open));
    if (sent != true) {
      _opening = null;
      _clients.remove(sessionId);
      throw const RemoteFsException('offline');
    }
    return opening.future.timeout(
      const Duration(seconds: 75),
      onTimeout: () {
        // The other device asks for a minute; past that its answer was
        // lost. Its question goes away too.
        _opening = null;
        _clients.remove(sessionId);
        unawaited(sender?.call(peerId, _message(FileBrowseAction.close)));
        throw const RemoteFsException('timeout');
      },
    );
  }

  /// Stops waiting for the other device to allow browsing; the question
  /// shown there goes away.
  Future<void> cancelOpen() async {
    final opening = _opening;
    if (opening == null) {
      return;
    }
    _opening = null;
    _clients.remove(sessionId);
    if (!opening.isCompleted) {
      opening.completeError(const RemoteFsException('canceled'));
    }
    await sender?.call(peerId, _message(FileBrowseAction.close));
  }

  Future<Map<String, Object?>> _request(
    FileBrowseAction action,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final id = _nextRequest++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _clients[sessionId] = this;
    final sent = await sender?.call(
      peerId,
      _message(action, requestId: id, payload: payload),
    );
    if (sent != true) {
      _pending.remove(id);
      throw const RemoteFsException('offline');
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw const RemoteFsException('timeout');
      },
    );
  }

  void _onMessage(FileBrowseMessage message) {
    switch (message.action) {
      case FileBrowseAction.opened:
        final payload = message.payload;
        final roots = [
          for (final root in (payload['roots'] as List? ?? const []))
            if (root is Map && root['id'] is String)
              RemoteFsRoot(
                id: root['id'] as String,
                kind: root['kind'] is String
                    ? root['kind'] as String
                    : (root['id'] == 'storage' ? 'storage' : 'home'),
                name: root['name'] is String ? root['name'] as String : '',
                drive: root['drive'] is String ? root['drive'] as String : '',
                removable: root['removable'] == true,
                shortcuts: [
                  for (final shortcut
                      in (root['shortcuts'] as List? ?? const []))
                    if (shortcut is Map &&
                        shortcut['kind'] is String &&
                        shortcut['path'] is String)
                      FsShortcut(
                        kind: shortcut['kind'] as String,
                        path: shortcut['path'] as String,
                      ),
                ],
              ),
        ];
        final opened = RemoteFsInfo(
          roots: roots,
          platform: payload['platform'] is String
              ? payload['platform'] as String
              : '',
          hasTrash: payload['trash'] == true,
          canRead:
              payload['read'] is int &&
              (payload['read'] as int) >= FileBrowseRead.version,
        );
        info = opened;
        final completer = _opening;
        _opening = null;
        if (completer != null && !completer.isCompleted) {
          completer.complete(opened);
        }
      case FileBrowseAction.denied:
        // Nobody answered there (a newer Whisper says so), or a real no.
        _fail(
          RemoteFsException(
            message.payload['reason'] == 'noAnswer' ? 'noAnswer' : 'denied',
          ),
        );
      case FileBrowseAction.result:
        _pending.remove(message.requestId)?.complete(message.payload);
      case FileBrowseAction.failed:
        final reason = message.payload['reason'];
        final error = RemoteFsException(
          reason is String ? reason : FileBrowseError.io,
        );
        _pending.remove(message.requestId)?.completeError(error);
        _reads.remove(message.requestId)?.completeError(error);
      default:
        break;
    }
  }

  void _fail(RemoteFsException error) {
    final opening = _opening;
    _opening = null;
    if (opening != null && !opening.isCompleted) {
      opening.completeError(error);
    }
    for (final completer in [..._pending.values, ..._reads.values]) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pending.clear();
    _reads.clear();
    info = null;
    _clients.remove(sessionId);
    if (!_gone.isCompleted) {
      _gone.complete(error);
    }
  }

  Future<FsPage> list(
    String root,
    String path, {
    int offset = 0,
    bool showHidden = false,
  }) async {
    final result = await _request(FileBrowseAction.list, {
      'root': root,
      'path': path,
      'offset': offset,
      if (showHidden) 'hidden': true,
    });
    return FsPage(
      entries: [
        for (final entry in (result['entries'] as List? ?? const []))
          if (entry is Map) FsEntry.fromJson(entry.cast<String, Object?>()),
      ],
      total: (result['total'] as num?)?.toInt() ?? 0,
      offset: (result['offset'] as num?)?.toInt() ?? offset,
    );
  }

  /// [length] bytes of a file from [offset] (fewer at its end), for hosts
  /// whose [RemoteFsInfo.canRead].
  Future<Uint8List> read(
    String root,
    String path,
    int offset,
    int length, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final id = _nextRequest++;
    final completer = Completer<Uint8List>();
    _reads[id] = completer;
    _clients[sessionId] = this;
    final sent = await sender?.call(
      peerId,
      _message(
        FileBrowseAction.read,
        requestId: id,
        payload: {
          'root': root,
          'path': path,
          'offset': offset,
          'length': length,
        },
      ),
    );
    if (sent != true) {
      _reads.remove(id);
      throw const RemoteFsException('offline');
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _reads.remove(id);
        throw const RemoteFsException('timeout');
      },
    );
  }

  /// Thumbnails go two at a time: each is real work on the other device.
  Future<Uint8List?> thumbnail(
    String root,
    String path, {
    int size = 256,
  }) async {
    if (_thumbsRunning >= 2) {
      final turn = Completer<void>();
      _thumbQueue.add(turn);
      await turn.future;
    }
    _thumbsRunning++;
    try {
      final result = await _request(FileBrowseAction.thumb, {
        'root': root,
        'path': path,
        'size': size,
      });
      final jpeg = result['jpeg'];
      return jpeg is String ? base64Decode(jpeg) : null;
    } on RemoteFsException {
      return null;
    } finally {
      _thumbsRunning--;
      if (_thumbQueue.isNotEmpty) {
        _thumbQueue.removeAt(0).complete();
      }
    }
  }

  Future<String> mkdir(String root, String parent, String name) async {
    final result = await _request(FileBrowseAction.mkdir, {
      'root': root,
      'parent': parent,
      'name': name,
    });
    return result['path'] as String? ?? '';
  }

  Future<String> rename(String root, String path, String name) async {
    final result = await _request(FileBrowseAction.rename, {
      'root': root,
      'path': path,
      'name': name,
    });
    return result['path'] as String? ?? '';
  }

  /// To the trash where there is one; [permanent] after the user agreed
  /// to delete for good (Android).
  Future<void> remove(String root, String path, {bool permanent = false}) =>
      _request(FileBrowseAction.remove, {
        'root': root,
        'path': path,
        if (permanent) 'permanent': true,
      });

  /// Copies remote items into [localFolder] on this device. Returns the
  /// transfer ids; progress shows like any other transfer.
  Future<List<String>> fetch(
    List<({String root, String path})> items,
    String localFolder,
  ) async {
    final result = await _request(FileBrowseAction.fetch, {
      'items': [
        for (final item in items) {'root': item.root, 'path': item.path},
      ],
    });
    final ids = <String>[];
    for (final transfer in (result['transfers'] as List? ?? const [])) {
      if (transfer is Map && transfer['id'] is String) {
        final id = transfer['id'] as String;
        TransferPlacements.shared.expect(id, localFolder);
        ids.add(id);
      }
    }
    return ids;
  }

  /// Copies local files and folders into [folder] on the other device.
  /// [onStarted] hears of each one as it starts.
  Future<List<String>> upload(
    List<String> localPaths,
    String root,
    String folder, {
    void Function(String transferId)? onStarted,
  }) async {
    final ids = <String>[];
    for (final path in localPaths) {
      final id = _uuid.v4();
      await _request(FileBrowseAction.incoming, {
        'transferId': id,
        'root': root,
        'folder': folder,
      });
      final isFolder =
          await FileSystemEntity.type(path) == FileSystemEntityType.directory;
      final send = isFolder ? sendFolder : sendFile;
      if (await send?.call(peerId, path, id) == true) {
        ids.add(id);
        onStarted?.call(id);
      } else {
        FilesLog.write('upload: ${FilesLog.id(id)} could not be sent');
      }
    }
    return ids;
  }

  Future<void> close() async {
    if (_opening != null) {
      // Left while still asking: the question there goes away too.
      await cancelOpen();
      return;
    }
    _clients.remove(sessionId);
    if (info != null) {
      info = null;
      await sender?.call(peerId, _message(FileBrowseAction.close));
    }
  }
}
