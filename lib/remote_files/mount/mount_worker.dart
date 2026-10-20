import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../fs_host_files.dart';
import 'mount_frontend.dart';
import 'mount_tree.dart';

/// Runs one mount in an isolate of its own: the system's requests, the
/// folder listings and the block cache live there, and only what has to
/// come over the network is asked of this isolate's [MountSource].
///
/// The system calls back into Whisper for every file it shows, and the
/// app's own thread sometimes asks it something synchronously (a file
/// dialog's sidebar, a stat). Answered from here, that never waits on the
/// very thread that is waiting; what does need the network gives up after
/// [_patience] instead of hanging the app.
class MountWorker {
  MountWorker._(this.path, this._isolate, this._commands);

  final String path;
  final Isolate _isolate;
  final SendPort _commands;

  /// The system took it away itself (ejected in the file manager), or the
  /// worker died. Told even when that happened before this was set.
  void Function()? get onEnded => _onEnded;
  set onEnded(void Function()? callback) {
    _onEnded = callback;
    if (_ended && callback != null) {
      callback();
    }
  }

  void Function()? _onEnded;
  bool _ended = false;

  /// It ended because the worker died, not because the system let go:
  /// the mount may still be there, with nothing answering it.
  bool died = false;

  void _end() {
    if (_ended || _stopped.isCompleted) {
      return;
    }
    _ended = true;
    _onEnded?.call();
  }

  final _stopped = Completer<void>();

  static const _patience = Duration(seconds: 30);

  /// Mounts [roots] of [source] as [name] at [path] with this system's
  /// [kind] of frontend (see [MountFrontend.create]).
  static Future<MountWorker> start({
    required MountSource source,
    required List<MountRoot> roots,
    required String kind,
    required String path,
    required String device,
    required String name,
    required bool showHiddenFiles,
  }) async {
    final events = ReceivePort();
    final requests = ReceivePort();
    final exits = ReceivePort();
    final errors = ReceivePort();
    final ready = Completer<SendPort>();
    MountWorker? worker;
    events.listen((message) {
      switch (message) {
        case ('ready', final SendPort commands):
          ready.complete(commands);
        case ('failed', final String error):
          if (!ready.isCompleted) {
            ready.completeError(StateError(error));
          }
          events.close();
          requests.close();
        case ('ended', _):
          worker?._end();
        case ('log', final String line):
          mountLog(line);
        case ('stopped', _):
          events.close();
          requests.close();
          if (!(worker?._stopped.isCompleted ?? true)) {
            worker!._stopped.complete();
          }
      }
    });
    // A stray error is told here and the mount goes on serving: tearing a
    // disk out from under the file manager is worse than one failed call.
    errors.listen((error) {
      mountLog('mount worker: $error');
    });
    // Gone without being stopped: whatever it served is gone with it.
    exits.listen((_) {
      exits.close();
      errors.close();
      if (!ready.isCompleted) {
        ready.completeError(StateError('mount worker exited'));
      }
      final current = worker;
      if (current != null && !current._stopped.isCompleted) {
        mountLog('mount worker exited');
        current.died = true;
        current._end();
        current._stopped.complete();
      }
    });
    requests.listen((message) {
      final (
        int id,
        String op,
        String root,
        String rel,
        int offset,
        int length,
        SendPort reply,
      ) = message as (int, String, String, String, int, int, SendPort);
      unawaited(_serve(source, id, op, root, rel, offset, length, reply));
    });
    final isolate = await Isolate.spawn(
      _main,
      (
        events.sendPort,
        requests.sendPort,
        roots,
        kind,
        path,
        device,
        name,
        showHiddenFiles,
      ),
      debugName: 'mount $name',
      errorsAreFatal: false,
      onExit: exits.sendPort,
      onError: errors.sendPort,
    );
    final SendPort commands;
    try {
      commands = await ready.future;
    } catch (_) {
      isolate.kill();
      rethrow;
    }
    worker = MountWorker._(path, isolate, commands);
    return worker;
  }

  static Future<void> _serve(
    MountSource source,
    int id,
    String op,
    String root,
    String rel,
    int offset,
    int length,
    SendPort reply,
  ) async {
    try {
      if (op == 'list') {
        reply.send((id, await source.list(root, rel), null));
      } else {
        final data = await source.read(root, rel, offset, length);
        reply.send((id, TransferableTypedData.fromList([data]), null));
      }
    } on MountException catch (error) {
      reply.send((id, null, error.error.index));
    } catch (_) {
      reply.send((id, null, MountError.io.index));
    }
  }

  /// Unmounts and ends the isolate.
  Future<void> stop() async {
    if (_stopped.isCompleted) {
      return;
    }
    _commands.send('stop');
    await _stopped.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => _isolate.kill(priority: Isolate.immediate),
    );
  }

  static Future<void> _main(
    (SendPort, SendPort, List<MountRoot>, String, String, String, String, bool)
    args,
  ) async {
    final (events, requests, roots, kind, path, device, name, showHidden) =
        args;
    mountLog = (line) => events.send(('log', line));
    final source = _PortSource(requests);
    final tree = MountTree(source, roots, showHiddenFiles: showHidden);
    final frontend = MountFrontend.create(kind, path, device);
    final commands = ReceivePort();
    frontend.onEnded = () => events.send(('ended', null));
    try {
      await frontend.start(tree, name);
    } catch (error) {
      events.send(('failed', '$error'));
      commands.close();
      source.close();
      return;
    }
    events.send(('ready', commands.sendPort));
    await for (final command in commands) {
      if (command == 'stop') {
        try {
          await frontend.stop();
        } finally {
          commands.close();
          source.close();
          events.send(('stopped', null));
        }
      }
    }
  }
}

/// The worker's way to the other device: through the app's isolate, which
/// holds the connection.
class _PortSource implements MountSource {
  _PortSource(this._requests) {
    _replies.listen(_onReply);
  }

  final SendPort _requests;
  final _replies = ReceivePort();
  final _waiting = <int, Completer<Object?>>{};
  int _next = 1;

  void _onReply(Object? message) {
    final (int id, Object? value, int? error) = message as (int, Object?, int?);
    final waiting = _waiting.remove(id);
    if (waiting == null) {
      return;
    }
    if (error != null) {
      waiting.completeError(MountException(MountError.values[error]));
    } else {
      waiting.complete(value);
    }
  }

  Future<Object?> _ask(
    String op,
    String root,
    String path, [
    int offset = 0,
    int length = 0,
  ]) {
    final id = _next++;
    final waiting = Completer<Object?>();
    _waiting[id] = waiting;
    _requests.send((id, op, root, path, offset, length, _replies.sendPort));
    return waiting.future.timeout(
      MountWorker._patience,
      onTimeout: () {
        _waiting.remove(id);
        throw const MountException(MountError.io);
      },
    );
  }

  @override
  Future<List<FsEntry>> list(String root, String path) async =>
      (await _ask('list', root, path)) as List<FsEntry>;

  @override
  Future<Uint8List> read(
    String root,
    String path,
    int offset,
    int length,
  ) async =>
      ((await _ask('read', root, path, offset, length))
              as TransferableTypedData)
          .materialize()
          .asUint8List();

  void close() {
    _replies.close();
    for (final waiting in _waiting.values) {
      waiting.completeError(const MountException(MountError.offline));
    }
    _waiting.clear();
  }
}
