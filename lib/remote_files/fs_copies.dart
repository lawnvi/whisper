import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../model/file_transfer.dart';
import 'files_log.dart';
import 'fs_placement.dart';

/// Where a copy is, as one would say it.
enum FileCopyPhase {
  /// Asking the other device, sending the first offers.
  starting,
  running,

  /// The connection dropped; it carries on once the device is back.
  waiting,

  /// Stopped part way; it can carry on.
  paused,
  done,
  failed,
  canceled,
}

/// One copy the user made (a paste, a drop): a file or several, maybe
/// folders, between this device and another one.
/// Where a copy that leaves the app goes ([FileCopyBatch.target]): into
/// the system's file manager (dragged or pasted there).
enum FilesOutside { fileManager }

class FileCopyBatch {
  FileCopyBatch._({
    required this.id,
    required this.upload,
    required this.peerId,
    required this.deviceName,
    required this.folder,
    required this.names,
    required this.signature,
    required this.started,
    this.target,
    this.again,
  });

  final String id;

  /// This device sends (else the other device sends to this one).
  final bool upload;
  final String peerId;
  final String deviceName;

  /// The folder the items go into, as shown.
  final String folder;
  final List<String> names;
  final String signature;
  final DateTime started;
  DateTime? ended;

  /// Where the items go, for the file manager to show it (opaque here).
  final Object? target;

  /// Asks the other device to send the items again (copies it sends).
  final Future<List<String>> Function()? again;

  /// Still asking the other device and sending the offers.
  bool starting = true;
  final transfers = <String, TransferSnapshot?>{};

  /// When each transfer joined, to notice one that never starts.
  final _joinedMs = <String, int>{};

  /// Transfers the other device announced but never started: counted as
  /// failed (and can be asked for again) instead of "preparing" forever.
  final noShow = <String>{};

  /// Where copies to this device were moved into [target], by transfer: a
  /// name already taken there gives one another name.
  final landed = <String, String>{};

  /// The items' names in [target], as they landed where that is known.
  List<String> get landedNames => landed.isEmpty
      ? names
      : [for (final path in landed.values) p.basename(path)];

  /// Bytes per second, smoothed over the last seconds.
  double speed = 0;
  final _samples = <(int, int)>[];

  int get totalBytes {
    var total = 0;
    for (final copy in transfers.values) {
      total += copy?.size ?? 0;
    }
    return total;
  }

  int get doneBytes {
    var done = 0;
    for (final copy in transfers.values) {
      if (copy == null) {
        continue;
      }
      done += copy.state == FileTransferState.completed
          ? copy.size
          : math.min(copy.committedBytes, copy.size);
    }
    return done;
  }

  double get fraction {
    final total = totalBytes;
    return total <= 0 ? 0 : (doneBytes / total).clamp(0.0, 1.0);
  }

  int get itemsTotal => math.max(names.length, transfers.length);

  int get itemsDone => transfers.values
      .where((copy) => copy?.state == FileTransferState.completed)
      .length;

  /// Files moved so far inside the folders being copied, where known.
  int? get filesDone {
    int? files;
    for (final copy in transfers.values) {
      final count = copy?.filesDone;
      if (count != null) {
        files = (files ?? 0) + count;
      }
    }
    return files;
  }

  /// Time left at the current speed, while it is moving.
  Duration? get remaining {
    if (phase != FileCopyPhase.running || speed < 1) {
      return null;
    }
    final left = totalBytes - doneBytes;
    if (left <= 0) {
      return null;
    }
    return Duration(seconds: (left / speed).ceil());
  }

  /// The first one that failed, for saying why.
  String get lastError {
    for (final copy in transfers.values) {
      if (copy != null && copy.lastError.isNotEmpty) {
        return copy.lastError;
      }
    }
    return noShow.isEmpty ? '' : FileCopies.noShowError;
  }

  FileCopyPhase get phase {
    final states = [
      for (final entry in transfers.entries)
        entry.value?.state ??
            (noShow.contains(entry.key) ? FileTransferState.failed : null),
    ];
    if (states.isEmpty) {
      return starting ? FileCopyPhase.starting : FileCopyPhase.failed;
    }
    bool any(Set<FileTransferState?> wanted) => states.any(wanted.contains);
    if (any(const {
      null,
      FileTransferState.queued,
      FileTransferState.negotiating,
      FileTransferState.transferring,
      FileTransferState.verifying,
    })) {
      return states.every((state) => state == null)
          ? FileCopyPhase.starting
          : FileCopyPhase.running;
    }
    if (any(const {FileTransferState.waitingReconnect})) {
      return FileCopyPhase.waiting;
    }
    if (any(const {FileTransferState.paused})) {
      return FileCopyPhase.paused;
    }
    if (starting) {
      return FileCopyPhase.running;
    }
    if (states.every((state) => state == FileTransferState.canceled)) {
      return FileCopyPhase.canceled;
    }
    if (any(const {FileTransferState.failed, FileTransferState.canceled})) {
      return FileCopyPhase.failed;
    }
    return FileCopyPhase.done;
  }

  bool get finished => switch (phase) {
    FileCopyPhase.done ||
    FileCopyPhase.failed ||
    FileCopyPhase.canceled => true,
    _ => false,
  };

  /// Stopped and can carry on (or be tried again).
  bool get canResume => switch (phase) {
    FileCopyPhase.paused || FileCopyPhase.failed => upload || again != null,
    FileCopyPhase.waiting => upload,
    _ => false,
  };

  void _record(int nowMs) {
    if (phase != FileCopyPhase.running) {
      _samples.clear();
      speed = 0;
      return;
    }
    _samples.add((nowMs, doneBytes));
    _samples.removeWhere((sample) => nowMs - sample.$1 > 3000);
  }

  /// Once a second: the bytes of the last few seconds, smoothed.
  void _measure(int nowMs) {
    _record(nowMs);
    if (_samples.length < 2) {
      return;
    }
    final first = _samples.first;
    final last = _samples.last;
    final span = last.$1 - first.$1;
    if (span < 400) {
      return;
    }
    final now = math.max(0, last.$2 - first.$2) * 1000 / span;
    speed = speed == 0 ? now : speed * 0.5 + now * 0.5;
  }
}

/// Copies made in the file manager, for the island that shows them and the
/// list of transfers: grouped the way the user made them (one paste, one
/// batch) and kept while the app runs, whichever page is open.
class FileCopies extends ChangeNotifier {
  FileCopies({
    Stream<TransferSnapshot>? updates,
    Stream<PlacedTransfer>? placed,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _subscription = (updates ?? TransferPlacements.shared.updates).listen(
      _onUpdate,
    );
    _placedSubscription = (placed ?? TransferPlacements.shared.placed).listen(
      _onPlaced,
    );
  }

  static final FileCopies shared = FileCopies();

  /// [FileCopyBatch.lastError] of a transfer that never started.
  static const noShowError = 'noShow';

  /// How long an announced transfer may take to show up at all.
  static const noShowAfter = Duration(seconds: 90);

  final int Function() _nowMs;

  /// Updates of transfers no batch holds yet. A copy's first states can
  /// come before its batch hears the id (an offer answered at once, a
  /// quick rejection) and would otherwise be lost, leaving it "preparing".
  final _early = <String, TransferSnapshot>{};
  static const _earlyLimit = 256;

  /// Where transfers no batch holds yet landed, likewise.
  final _earlyLanded = <String, String>{};
  late final StreamSubscription<TransferSnapshot> _subscription;
  late final StreamSubscription<PlacedTransfer> _placedSubscription;
  Timer? _ticker;

  /// Carries a stopped transfer on (wired to the transfer engine).
  Future<void> Function(String transferId)? retry;
  Future<void> Function(String transferId)? cancel;

  /// Newest first.
  final batches = <FileCopyBatch>[];

  /// Bumped when the island should open to show [spotlit].
  final spotlight = ValueNotifier<int>(0);
  FileCopyBatch? spotlit;

  Iterable<FileCopyBatch> get active =>
      batches.where((batch) => !batch.finished);

  FileCopyBatch start({
    required bool upload,
    required String peerId,
    required String deviceName,
    required String folder,
    required List<String> names,
    required String signature,
    Object? target,
    Future<List<String>> Function()? again,
  }) {
    final batch = FileCopyBatch._(
      id: const Uuid().v4(),
      upload: upload,
      peerId: peerId,
      deviceName: deviceName,
      folder: folder,
      names: names,
      signature: signature,
      started: DateTime.fromMillisecondsSinceEpoch(_nowMs()),
      target: target,
      again: again,
    );
    batches.insert(0, batch);
    _changed();
    return batch;
  }

  void add(FileCopyBatch batch, String transferId) {
    _join(batch, transferId);
    _changed();
  }

  void _join(FileCopyBatch batch, String transferId) {
    final early = _early.remove(transferId);
    if (early != null) {
      batch.transfers[transferId] = early;
    } else {
      batch.transfers.putIfAbsent(transferId, () => null);
    }
    batch._joinedMs[transferId] ??= _nowMs();
    final landed = _earlyLanded.remove(transferId);
    if (landed != null) {
      batch.landed[transferId] = landed;
    }
  }

  /// Every offer is out (or none could be).
  void started(FileCopyBatch batch) {
    batch.starting = false;
    _changed();
  }

  /// The same items on their way to the same place, if they are.
  FileCopyBatch? copying(String signature) {
    for (final batch in active) {
      if (batch.signature == signature) {
        return batch;
      }
    }
    return null;
  }

  /// A copy of the same items to the same place that this one would only
  /// repeat: still under way, or made successfully a moment ago ([within]
  /// of starting), so a second paste is the same operation, not another.
  /// One that failed or was stopped can be made again at once.
  FileCopyBatch? sameAs(
    String signature, {
    Duration within = const Duration(seconds: 8),
  }) {
    final now = _nowMs();
    for (final batch in batches) {
      if (batch.signature != signature) {
        continue;
      }
      if (!batch.finished) {
        return batch;
      }
      if (batch.phase == FileCopyPhase.done &&
          now - batch.started.millisecondsSinceEpoch <= within.inMilliseconds) {
        return batch;
      }
    }
    return null;
  }

  void show(FileCopyBatch batch) {
    spotlit = batch;
    spotlight.value++;
  }

  Future<void> resume(FileCopyBatch batch) async {
    if (!batch.upload) {
      final again = batch.again;
      if (again == null) {
        return;
      }
      // The other device sends; ask it for what has not arrived.
      batch.transfers.removeWhere(
        (_, copy) => copy?.state != FileTransferState.completed,
      );
      batch.noShow.clear();
      batch.starting = true;
      batch.ended = null;
      _changed();
      try {
        for (final id in await again()) {
          _join(batch, id);
        }
      } finally {
        started(batch);
      }
      return;
    }
    batch.ended = null;
    final noShow = Set.of(batch.noShow);
    batch.noShow.clear();
    for (final entry in batch.transfers.entries.toList()) {
      final state = entry.value?.state;
      if (state == FileTransferState.paused ||
          state == FileTransferState.failed ||
          state == FileTransferState.waitingReconnect ||
          noShow.contains(entry.key)) {
        batch._joinedMs[entry.key] = _nowMs();
        await retry?.call(entry.key);
      }
    }
    _changed();
  }

  Future<void> stop(FileCopyBatch batch) async {
    for (final entry in batch.transfers.entries.toList()) {
      final state = entry.value?.state;
      if (state == null || !isTerminalFileTransferState(state)) {
        await cancel?.call(entry.key);
      }
    }
  }

  void remove(FileCopyBatch batch) {
    batches.remove(batch);
    _changed();
  }

  void clearFinished() {
    batches.removeWhere((batch) => batch.finished);
    _changed();
  }

  /// Every batch [transferId] serves (copies can share a transfer).
  Iterable<FileCopyBatch> _batchesOf(String transferId) =>
      batches.where((batch) => batch.transfers.containsKey(transferId));

  void _onUpdate(TransferSnapshot snapshot) {
    final serving = _batchesOf(snapshot.transferId).toList();
    if (serving.isEmpty) {
      _early
        ..remove(snapshot.transferId)
        ..[snapshot.transferId] = snapshot;
      if (_early.length > _earlyLimit) {
        _early.remove(_early.keys.first);
      }
      return;
    }
    for (final batch in serving) {
      batch.transfers[snapshot.transferId] = snapshot;
      batch.noShow.remove(snapshot.transferId);
    }
    _changed();
  }

  void _onPlaced(PlacedTransfer placed) {
    final serving = _batchesOf(placed.transferId).toList();
    if (serving.isEmpty) {
      _earlyLanded
        ..remove(placed.transferId)
        ..[placed.transferId] = placed.path;
      if (_earlyLanded.length > _earlyLimit) {
        _earlyLanded.remove(_earlyLanded.keys.first);
      }
      return;
    }
    for (final batch in serving) {
      batch.landed[placed.transferId] = placed.path;
    }
  }

  /// Transfers announced long ago that never showed up count as failed.
  void _noticeNoShows(int now) {
    for (final batch in batches) {
      if (batch.starting) {
        continue;
      }
      for (final entry in batch.transfers.entries) {
        final joined = batch._joinedMs[entry.key];
        if (entry.value == null &&
            joined != null &&
            now - joined >= noShowAfter.inMilliseconds &&
            batch.noShow.add(entry.key)) {
          FilesLog.write('transfer ${FilesLog.id(entry.key)} never started');
        }
      }
    }
  }

  void _changed({bool tick = false}) {
    final now = _nowMs();
    _noticeNoShows(now);
    for (final batch in batches) {
      final finished = batch.finished;
      if (finished && batch.ended == null) {
        batch.ended = DateTime.fromMillisecondsSinceEpoch(now);
      }
      tick ? batch._measure(now) : batch._record(now);
    }
    // While something moves, speed and time left keep up even between
    // updates (and fall when nothing arrives); one still starting is
    // watched for never showing up.
    final moving = batches.any(
      (batch) =>
          batch.phase == FileCopyPhase.running ||
          batch.phase == FileCopyPhase.starting,
    );
    if (moving && _ticker == null) {
      _ticker = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _changed(tick: true),
      );
    } else if (!moving) {
      _ticker?.cancel();
      _ticker = null;
    }
    notifyListeners();
  }

  /// What the once-a-second ticker does, for tests.
  @visibleForTesting
  void tick() => _changed(tick: true);

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_subscription.cancel());
    unawaited(_placedSubscription.cancel());
    spotlight.dispose();
    super.dispose();
  }
}
