import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'files_log.dart';
import 'fs_host_files.dart';
import 'fs_host_uploads.dart';
import 'fs_paths.dart';
import 'fs_placement.dart';
import 'fs_platform.dart';
import 'fs_protocol.dart';

/// Sends a file-browse message to a peer; false when it could not.
typedef FileBrowseSender =
    Future<bool> Function(String peerId, FileBrowseMessage message);

/// Starts an ordinary transfer of [path] to [peerId] with [transferId].
typedef FileBrowseSendPath =
    Future<bool> Function(String peerId, String path, String transferId);

/// Sends the bytes a `read` asked for, as a `browseData` frame.
typedef FileBrowseSendData =
    Future<bool> Function(
      String peerId,
      String sessionId,
      int requestId,
      int offset,
      Uint8List data,
    );

enum FileBrowseDecision {
  deny,
  once,
  always,

  /// Nobody answered in time, or the device that asked gave up.
  noAnswer,
}

/// Someone asked to browse this device's files.
class FileBrowseRequest {
  const FileBrowseRequest({required this.peerId, required this.deviceName});

  final String peerId;
  final String deviceName;
}

/// The question "‹device› wants to browse your files", one at a time,
/// answered by whatever UI listens (see `FileBrowsePromptHost`).
class FileBrowseGate extends ChangeNotifier {
  final _queue = Queue<(FileBrowseRequest, Completer<FileBrowseDecision>)>();

  FileBrowseRequest? get pending => _queue.isEmpty ? null : _queue.first.$1;

  /// Asked users get a minute; silence is [FileBrowseDecision.noAnswer].
  Future<FileBrowseDecision> ask(FileBrowseRequest request) {
    final completer = Completer<FileBrowseDecision>();
    _queue.add((request, completer));
    notifyListeners();
    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _queue.removeWhere((item) => identical(item.$2, completer));
        notifyListeners();
        return FileBrowseDecision.noAnswer;
      },
    );
  }

  /// The device that asked gave up waiting: its question goes away here.
  void withdraw(FileBrowseRequest request) {
    final asked = _queue.where((item) => identical(item.$1, request)).toList();
    if (asked.isEmpty) {
      return;
    }
    _queue.removeWhere((item) => identical(item.$1, request));
    for (final (_, completer) in asked) {
      if (!completer.isCompleted) {
        completer.complete(FileBrowseDecision.noAnswer);
      }
    }
    notifyListeners();
  }

  void decide(FileBrowseDecision decision) {
    if (_queue.isEmpty) {
      return;
    }
    final (_, completer) = _queue.removeFirst();
    if (!completer.isCompleted) {
      completer.complete(decision);
    }
    notifyListeners();
  }
}

/// Devices allowed to browse without asking ("始终允许"), and devices that
/// may only read what they browse ("允许修改我的文件" off).
class FileBrowsePermissions {
  static const _key = 'remote_files.always_allowed';
  static const _readOnlyKey = 'remote_files.read_only';

  Future<bool> isAlways(String peerId) => _has(_key, peerId);

  Future<void> setAlways(String peerId, bool allowed) =>
      _set(_key, peerId, allowed);

  /// [peerId] may open and copy out, not create, rename, delete or write.
  Future<bool> isReadOnly(String peerId) => _has(_readOnlyKey, peerId);

  Future<void> setReadOnly(String peerId, bool readOnly) =>
      _set(_readOnlyKey, peerId, readOnly);

  Future<bool> _has(String key, String peerId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(key)?.contains(peerId) ?? false;
  }

  Future<void> _set(String key, String peerId, bool on) async {
    final prefs = await SharedPreferences.getInstance();
    final list = {...?prefs.getStringList(key)};
    on ? list.add(peerId) : list.remove(peerId);
    await prefs.setStringList(key, list.toList());
  }
}

/// A session this device answers.
class _Session {
  _Session(this.peerId, this.hostPeerId, this.deviceName);

  final String peerId;

  /// This device, as the session names it.
  final String hostPeerId;
  final String deviceName;
}

/// This device's files for other trusted devices: answers a session's
/// requests once its user allowed it.
class FileBrowseHost {
  FileBrowseHost({
    FsHostFiles? files,
    FileBrowseGate? gate,
    FileBrowsePermissions? permissions,
  }) : files = files ?? FsHostFiles(),
       gate = gate ?? FileBrowseGate(),
       permissions = permissions ?? FileBrowsePermissions() {
    uploads = FsUploads(this.files);
  }

  static final FileBrowseHost shared = FileBrowseHost();

  final FsHostFiles files;
  final FileBrowseGate gate;
  final FileBrowsePermissions permissions;
  FileBrowseSender? sender;
  FileBrowseSendPath? sendFile;
  FileBrowseSendPath? sendFolder;
  FileBrowseSendData? sendData;

  /// Files being written from other devices' mounted folders.
  late final FsUploads uploads;

  final _sessions = <String, _Session>{};

  /// Devices allowed while they stay connected: once allowed, opening the
  /// file manager again does not ask again until they disconnect.
  final _allowedThisConnection = <String>{};

  /// Opens still waiting for an answer here, by session.
  final _asking = <String, FileBrowseRequest>{};

  int _thumbnailsRunning = 0;
  int _readsRunning = 0;
  final _readTurns = Queue<Completer<void>>();
  static const _maxReadsRunning = 8;
  static const _uuid = Uuid();

  @visibleForTesting
  bool isOpen(String sessionId) => _sessions.containsKey(sessionId);

  Future<void> handle(
    FileBrowseMessage message, {
    required String remotePeerId,
    required String deviceName,
  }) async {
    if (message.clientPeerId != remotePeerId || message.fromHost) {
      return;
    }
    if (message.action == FileBrowseAction.open) {
      await _open(message, remotePeerId, deviceName);
      return;
    }
    if (message.action == FileBrowseAction.close) {
      _sessions.remove(message.sessionId);
      await uploads.discardOwner(message.sessionId);
      // Closed while still waiting for an answer here: the question goes.
      final asking = _asking.remove(message.sessionId);
      if (asking != null) {
        gate.withdraw(asking);
      }
      return;
    }
    final session = _sessions[message.sessionId];
    if (session?.peerId != remotePeerId) {
      await _fail(message, FileBrowseError.notAllowed);
      return;
    }
    try {
      final payload = message.payload;
      String text(String key) {
        final value = payload[key];
        if (value is! String) {
          throw const FormatException('missing field');
        }
        return value;
      }

      int number(String key) {
        final value = payload[key];
        if (value is! int || value < 0) {
          throw const FormatException('missing number');
        }
        return value;
      }

      if (_changes(message) && await permissions.isReadOnly(remotePeerId)) {
        await _fail(message, FileBrowseError.readOnly);
        return;
      }
      switch (message.action) {
        case FileBrowseAction.list:
          final page = await files.list(
            text('root'),
            text('path'),
            offset: (payload['offset'] as num?)?.toInt() ?? 0,
            showHidden: payload['hidden'] == true,
          );
          await _ok(message, {
            'entries': [for (final entry in page.entries) entry.toJson()],
            'total': page.total,
            'offset': page.offset,
          });
        case FileBrowseAction.thumb:
          if (_thumbnailsRunning >= 2) {
            await _fail(message, FileBrowseError.busy);
            return;
          }
          _thumbnailsRunning++;
          try {
            final real = await files.resolver.resolveExisting(
              text('root'),
              text('path'),
            );
            final size = ((payload['size'] as num?)?.toInt() ?? 256).clamp(
              64,
              512,
            );
            final jpeg = await FsPlatform.thumbnail(real, size: size);
            if (jpeg == null) {
              await _fail(message, FileBrowseError.notFound);
            } else {
              await _ok(message, {'jpeg': base64Encode(jpeg)});
            }
          } finally {
            _thumbnailsRunning--;
          }
        case FileBrowseAction.mkdir:
          final path = await files.mkdir(
            text('root'),
            text('parent'),
            text('name'),
          );
          await _ok(message, {'path': path});
        case FileBrowseAction.rename:
          final path = await files.rename(
            text('root'),
            text('path'),
            text('name'),
          );
          await _ok(message, {'path': path});
        case FileBrowseAction.remove:
          if (payload['folder'] == true) {
            await files.removeFolder(text('root'), text('path'));
            await _ok(message);
          } else {
            await _remove(message, text('root'), text('path'));
          }
        case FileBrowseAction.fetch:
          await _fetch(message, remotePeerId);
        case FileBrowseAction.read:
          await _read(
            message,
            remotePeerId,
            text('root'),
            text('path'),
            (payload['offset'] as num?)?.toInt() ?? -1,
            (payload['length'] as num?)?.toInt() ?? 0,
            upload: payload['upload'] is String
                ? payload['upload'] as String
                : null,
          );
        case FileBrowseAction.incoming:
          // The client sends this file or folder next; once it completes,
          // it goes into this folder instead of Downloads.
          final transferId = text('transferId');
          final folder = await files.resolver.resolveExisting(
            text('root'),
            text('folder'),
          );
          if (await FileSystemEntity.type(folder) !=
              FileSystemEntityType.directory) {
            throw const FsPathException('not a folder');
          }
          TransferPlacements.shared.expect(transferId, folder);
          await _ok(message);
        case FileBrowseAction.create:
          final entry = await files.create(
            text('root'),
            text('parent'),
            text('name'),
          );
          await _ok(message, {'entry': entry.toJson()});
        case FileBrowseAction.move:
          final path = await files.move(
            text('root'),
            text('path'),
            text('parent'),
            text('name'),
          );
          await _ok(message, {'path': path});
        case FileBrowseAction.touch:
          await files.touch(text('root'), text('path'), number('modified'));
          await _ok(message);
        case FileBrowseAction.space:
          final folder = files.resolver.rootOf(text('root')).directory;
          final space = await FsPlatform.space(folder);
          await _ok(message, {
            if (space != null) ...{'total': space.total, 'free': space.free},
          });
        case FileBrowseAction.writeOpen:
          final upload = await uploads.open(
            owner: message.sessionId,
            device: session!.deviceName,
            rootId: text('root'),
            relative: text('path'),
            truncate: payload['truncate'] == true,
          );
          await _ok(message, {'upload': upload.id, 'size': upload.size});
        case FileBrowseAction.writeSize:
          final upload = _upload(message, text('upload'));
          await upload.resize(number('size'));
          await _ok(message);
        case FileBrowseAction.writeClose:
          final upload = _upload(message, text('upload'));
          final rootId = upload.rootId;
          final real = await uploads.close(
            upload.id,
            commit: payload['commit'] == true,
            modifiedMs: payload['modified'] is int
                ? payload['modified'] as int
                : null,
          );
          final path = await files.resolver.relativeOf(rootId, real);
          await _ok(message, {
            'path': path,
            if (payload['commit'] == true)
              'entry': (await files.stat(rootId, path)).toJson(),
          });
        default:
          break;
      }
    } on FsPathException catch (error) {
      await _fail(message, switch (error.reason) {
        'exists' => FileBrowseError.exists,
        'not found' => FileBrowseError.notFound,
        'not empty' => FileBrowseError.notEmpty,
        'bad name' => FileBrowseError.badName,
        'busy' => FileBrowseError.busy,
        _ => FileBrowseError.notAllowed,
      });
    } on FormatException {
      await _fail(message, FileBrowseError.notAllowed);
    } on FileSystemException {
      await _fail(message, FileBrowseError.io);
    }
  }

  /// Whether [message] would change something here.
  static bool _changes(FileBrowseMessage message) => switch (message.action) {
    FileBrowseAction.mkdir ||
    FileBrowseAction.rename ||
    FileBrowseAction.remove ||
    FileBrowseAction.incoming ||
    FileBrowseAction.create ||
    FileBrowseAction.move ||
    FileBrowseAction.touch ||
    FileBrowseAction.writeOpen ||
    FileBrowseAction.writeSize => true,
    FileBrowseAction.writeClose => message.payload['commit'] == true,
    _ => false,
  };

  /// An upload of [message]'s own session.
  FsUpload _upload(FileBrowseMessage message, String id) {
    final upload = uploads[id];
    if (upload == null || upload.owner != message.sessionId) {
      throw const FsPathException('not found');
    }
    return upload;
  }

  /// Bytes a mounted folder writes, from a `browseWrite` frame whose
  /// transferId is `<session>/<upload>`; answered like any request of
  /// that session, with the file's size so far.
  Future<void> handleWrite({
    required String remotePeerId,
    required String transferId,
    required int requestId,
    required int offset,
    required Uint8List data,
  }) async {
    final slash = transferId.indexOf('/');
    if (slash < 0) {
      return;
    }
    final sessionId = transferId.substring(0, slash);
    final session = _sessions[sessionId];
    if (session == null || session.peerId != remotePeerId) {
      return;
    }
    final request = FileBrowseMessage(
      action: FileBrowseAction.writeSize,
      sessionId: sessionId,
      clientPeerId: remotePeerId,
      hostPeerId: session.hostPeerId,
      requestId: requestId,
    );
    try {
      // Taken in the order the frames came: writes that overlap land as
      // they were made. A device made read-only has no uploads left.
      final upload = _upload(request, transferId.substring(slash + 1));
      final size = await upload.write(offset, data);
      await _ok(request, {'size': size});
    } on FsPathException {
      await _fail(request, FileBrowseError.notFound);
    } on FileSystemException {
      await _fail(request, FileBrowseError.io);
    }
  }

  Future<void> _open(
    FileBrowseMessage message,
    String peerId,
    String deviceName,
  ) async {
    var allowed =
        _allowedThisConnection.contains(peerId) ||
        await permissions.isAlways(peerId);
    if (!allowed) {
      final request = FileBrowseRequest(peerId: peerId, deviceName: deviceName);
      _asking[message.sessionId] = request;
      final decision = await gate.ask(request);
      if (!identical(_asking.remove(message.sessionId), request)) {
        // The device that asked gave up waiting; nobody to answer.
        return;
      }
      if (decision == FileBrowseDecision.always) {
        await permissions.setAlways(peerId, true);
      }
      allowed =
          decision == FileBrowseDecision.once ||
          decision == FileBrowseDecision.always;
      if (decision == FileBrowseDecision.once) {
        // "始终允许" is kept by the setting; this one by the connection.
        _allowedThisConnection.add(peerId);
      }
      if (!allowed) {
        // Silence is said apart from a no: the other side offers to try
        // again instead of saying it was refused.
        await sender?.call(
          peerId,
          message.reply(FileBrowseAction.denied, {
            if (decision == FileBrowseDecision.noAnswer) 'reason': 'noAnswer',
          }),
        );
        return;
      }
    }
    _sessions[message.sessionId] = _Session(
      peerId,
      message.hostPeerId,
      deviceName,
    );
    final readOnly = await permissions.isReadOnly(peerId);
    // Drives and volumes come and go; list what is there now.
    await files.refreshRoots();
    final roots = <Map<String, Object?>>[];
    for (final root in files.resolver.roots) {
      roots.add({
        ...root.toJson(),
        'shortcuts': [
          for (final shortcut in root.shortcuts)
            if (await Directory('${root.directory}/${shortcut.path}').exists())
              {'kind': shortcut.kind, 'path': shortcut.path},
        ],
      });
    }
    await sender?.call(
      peerId,
      message.reply(FileBrowseAction.opened, {
        'roots': roots,
        'platform': Platform.operatingSystem,
        'trash': FsPlatform.hasTrash,
        if (sendData != null) 'read': FileBrowseRead.version,
        if (readOnly) 'readOnly': true else 'write': FileBrowseWrite.version,
      }),
    );
  }

  Future<void> _remove(
    FileBrowseMessage message,
    String root,
    String path,
  ) async {
    final real = await files.resolver.resolveEntry(root, path);
    // For good where there is no trash (Android), after the user confirmed
    // on the client; and what a mounted folder made itself (a save's
    // leftovers), which the trash would only fill up with.
    if (message.payload['permanent'] == true) {
      await files.deletePermanently(root, path);
      await _ok(message);
      return;
    }
    if (!FsPlatform.hasTrash) {
      await _fail(message, FileBrowseError.noTrash);
      return;
    }
    if (await FsPlatform.trash(real)) {
      await _ok(message);
    } else {
      await _fail(message, FileBrowseError.io);
    }
  }

  Future<void> _fetch(FileBrowseMessage message, String peerId) async {
    final items = message.payload['items'];
    if (items is! List || items.isEmpty || items.length > 500) {
      throw const FormatException('bad items');
    }
    final starts = <(String, String, bool)>[];
    final transfers = <Map<String, Object?>>[];
    for (final item in items) {
      if (item is! Map || item['root'] is! String || item['path'] is! String) {
        throw const FormatException('bad item');
      }
      final real = await files.resolver.resolveExisting(
        item['root'] as String,
        item['path'] as String,
      );
      final folder =
          await FileSystemEntity.type(real) == FileSystemEntityType.directory;
      final id = _uuid.v4();
      starts.add((real, id, folder));
      transfers.add({
        'id': id,
        'name': real.split(Platform.pathSeparator).last,
        'folder': folder,
      });
    }
    // The ids reach the client before the offers do (same channel), so it
    // knows where each one goes when it arrives.
    await _ok(message, {'transfers': transfers});
    FilesLog.write('host: asked for ${starts.length} item(s)');
    for (final (real, id, folder) in starts) {
      final send = folder ? sendFolder : sendFile;
      final sent = await send?.call(peerId, real, id) ?? false;
      if (!sent) {
        // The other side gives up waiting for it after a while.
        FilesLog.write('host: ${FilesLog.id(id)} could not be sent');
      }
    }
  }

  /// A mounted folder on the other device reads part of a file: the bytes
  /// go back as one frame, fewer than asked at the end of the file.
  Future<void> _read(
    FileBrowseMessage message,
    String peerId,
    String root,
    String path,
    int offset,
    int length, {
    String? upload,
  }) async {
    final send = sendData;
    if (send == null) {
      await _fail(message, FileBrowseError.notAllowed);
      return;
    }
    if (offset < 0 || length <= 0 || length > FileBrowseRead.maxLength) {
      throw const FormatException('bad range');
    }
    if (upload != null) {
      // Read back while it is being written.
      final data = await _upload(message, upload).read(offset, length);
      if (_sessions[message.sessionId]?.peerId == peerId) {
        await send(peerId, message.sessionId, message.requestId, offset, data);
      }
      return;
    }
    final real = await files.resolver.resolveExisting(root, path);
    if (_readsRunning >= _maxReadsRunning) {
      final turn = Completer<void>();
      _readTurns.add(turn);
      await turn.future;
    }
    _readsRunning++;
    Uint8List data;
    try {
      final file = await File(real).open();
      try {
        // One read() may return early (a phone's shared storage does):
        // keep on until the range is in or the file ends.
        final size = await file.length();
        final buffer = Uint8List((size - offset).clamp(0, length));
        await file.setPosition(offset);
        var got = 0;
        while (got < buffer.length) {
          final n = await file.readInto(buffer, got);
          if (n == 0) {
            break;
          }
          got += n;
        }
        data = Uint8List.sublistView(buffer, 0, got);
      } finally {
        await file.close();
      }
    } finally {
      _readsRunning--;
      if (_readTurns.isNotEmpty) {
        _readTurns.removeFirst().complete();
      }
    }
    if (_sessions[message.sessionId]?.peerId != peerId) {
      return;
    }
    await send(peerId, message.sessionId, message.requestId, offset, data);
  }

  Future<void> _ok(
    FileBrowseMessage message, [
    Map<String, Object?> payload = const {},
  ]) async {
    final peerId = _sessions[message.sessionId]?.peerId ?? message.clientPeerId;
    await sender?.call(peerId, message.reply(FileBrowseAction.result, payload));
  }

  Future<void> _fail(FileBrowseMessage message, String reason) async {
    await sender?.call(
      message.clientPeerId,
      message.reply(FileBrowseAction.failed, {'reason': reason}),
    );
  }

  /// A browsing device disconnected: forget its sessions.
  void closePeer(String peerId) {
    for (final MapEntry(key: id, value: session)
        in _sessions.entries.toList()) {
      if (session.peerId == peerId) {
        _sessions.remove(id);
        unawaited(uploads.discardOwner(id));
      }
    }
    _allowedThisConnection.remove(peerId);
    for (final entry in _asking.entries.toList()) {
      if (entry.value.peerId == peerId) {
        _asking.remove(entry.key);
        gate.withdraw(entry.value);
      }
    }
  }

  /// "允许修改我的文件" for [peerId]: off, what it was writing is dropped at
  /// once, and every change it asks for is refused from now on.
  Future<void> setReadOnly(String peerId, bool readOnly) async {
    await permissions.setReadOnly(peerId, readOnly);
    if (readOnly) {
      for (final MapEntry(key: id, value: session) in _sessions.entries) {
        if (session.peerId == peerId) {
          await uploads.discardOwner(id);
        }
      }
    }
  }

  /// Takes back "始终允许": [peerId] is asked again next time, and what it
  /// has open now closes, so the change holds at once.
  Future<void> revokeAlways(String peerId) async {
    await permissions.setAlways(peerId, false);
    closePeer(peerId);
  }
}
