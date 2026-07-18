import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/helper/folder_transfer_stager.dart';

const int desktopQuickSendMaxDrafts = 32;
const int desktopQuickSendMaxFilesPerDraft = 64;
const int desktopQuickSendMaxTextLength = 256 * 1024;
const int desktopQuickSendMaxPathLength = 4096;

enum DesktopQuickSendSource { commandLine, systemService, clipboardShortcut }

class DesktopQuickSendDraft {
  const DesktopQuickSendDraft({
    required this.id,
    required this.source,
    required this.text,
    required this.filePaths,
    required this.receivedAt,
    this.targetPeerId = '',
    this.pinnedPublicKeyHash = '',
    this.deliveredPeerId = '',
    this.deliveredFileCount = 0,
    this.stagedSourcePath = '',
    this.stagedPath = '',
  });

  final String id;
  final DesktopQuickSendSource source;
  final String text;
  final List<String> filePaths;
  final int receivedAt;
  final String targetPeerId;
  final String pinnedPublicKeyHash;
  final String deliveredPeerId;
  final int deliveredFileCount;
  final String stagedSourcePath;
  final String stagedPath;

  bool get hasContent => text.isNotEmpty || filePaths.isNotEmpty;

  String? get preferredTargetPeerId {
    if (targetPeerId.isNotEmpty) {
      return targetPeerId;
    }
    return deliveredPeerId.isEmpty ? null : deliveredPeerId;
  }

  DesktopQuickSendDraft copyWith({
    String? text,
    List<String>? filePaths,
    String? targetPeerId,
    String? pinnedPublicKeyHash,
    String? deliveredPeerId,
    int? deliveredFileCount,
    String? stagedSourcePath,
    String? stagedPath,
  }) {
    return DesktopQuickSendDraft(
      id: id,
      source: source,
      text: text ?? this.text,
      filePaths: List<String>.unmodifiable(filePaths ?? this.filePaths),
      receivedAt: receivedAt,
      targetPeerId: targetPeerId ?? this.targetPeerId,
      pinnedPublicKeyHash: pinnedPublicKeyHash ?? this.pinnedPublicKeyHash,
      deliveredPeerId: deliveredPeerId ?? this.deliveredPeerId,
      deliveredFileCount: deliveredFileCount ?? this.deliveredFileCount,
      stagedSourcePath: stagedSourcePath ?? this.stagedSourcePath,
      stagedPath: stagedPath ?? this.stagedPath,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'source': source.name,
    'text': text,
    'filePaths': filePaths,
    'receivedAt': receivedAt,
    'targetPeerId': targetPeerId,
    'pinnedPublicKeyHash': pinnedPublicKeyHash,
    'deliveredPeerId': deliveredPeerId,
    'deliveredFileCount': deliveredFileCount,
    'stagedSourcePath': stagedSourcePath,
    'stagedPath': stagedPath,
  };

  static DesktopQuickSendDraft? fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      return null;
    }
    final id = (value['id'] as String?)?.trim() ?? '';
    final sourceName = value['source'] as String? ?? '';
    final receivedAt = (value['receivedAt'] as num?)?.toInt() ?? 0;
    if (id.isEmpty || receivedAt <= 0) {
      return null;
    }
    final source = DesktopQuickSendSource.values
        .where((candidate) => candidate.name == sourceName)
        .firstOrNull;
    if (source == null) {
      return null;
    }
    final textValue = value['text'];
    final filePathsValue = value['filePaths'];
    if (textValue is! String || filePathsValue is! List<Object?>) {
      return null;
    }
    final filePaths = filePathsValue.whereType<String>().toList(
      growable: false,
    );
    if (filePaths.length != filePathsValue.length ||
        _validateQuickSendContent(textValue, filePaths) != null) {
      return null;
    }
    final targetPeerId = (value['targetPeerId'] as String? ?? '').trim();
    final pinnedPublicKeyHash = (value['pinnedPublicKeyHash'] as String? ?? '')
        .trim();
    final deliveredPeerId = (value['deliveredPeerId'] as String? ?? '').trim();
    final deliveredFileCount =
        (value['deliveredFileCount'] as num?)?.toInt() ?? 0;
    final stagedSourcePath = (value['stagedSourcePath'] as String? ?? '');
    final stagedPath = (value['stagedPath'] as String? ?? '');
    if (deliveredFileCount < 0 ||
        deliveredFileCount > desktopQuickSendMaxFilesPerDraft ||
        (deliveredFileCount > 0 && deliveredPeerId.isEmpty)) {
      return null;
    }
    if ((stagedSourcePath.isEmpty != stagedPath.isEmpty) ||
        stagedSourcePath.contains('\u0000') ||
        stagedPath.contains('\u0000') ||
        stagedSourcePath.length > desktopQuickSendMaxPathLength ||
        stagedPath.length > desktopQuickSendMaxPathLength ||
        (stagedSourcePath.isNotEmpty &&
            (filePaths.isEmpty || filePaths.first != stagedSourcePath))) {
      return null;
    }
    if (!_isValidDraftTargetBinding(
      targetPeerId: targetPeerId,
      pinnedPublicKeyHash: pinnedPublicKeyHash,
      deliveredPeerId: deliveredPeerId,
      deliveredFileCount: deliveredFileCount,
    )) {
      return null;
    }
    final draft = DesktopQuickSendDraft(
      id: id,
      source: source,
      text: textValue,
      filePaths: filePaths,
      receivedAt: receivedAt,
      targetPeerId: targetPeerId,
      pinnedPublicKeyHash: pinnedPublicKeyHash,
      deliveredPeerId: deliveredPeerId,
      deliveredFileCount: deliveredFileCount,
      stagedSourcePath: stagedSourcePath,
      stagedPath: stagedPath,
    );
    return draft.hasContent ? draft : null;
  }
}

class DesktopQuickSendArguments {
  const DesktopQuickSendArguments({
    required this.text,
    required this.filePaths,
    required this.captureClipboard,
  });

  final String text;
  final List<String> filePaths;
  final bool captureClipboard;

  bool get hasContent => text.isNotEmpty || filePaths.isNotEmpty;

  static DesktopQuickSendArguments parse(List<String> arguments) {
    var text = '';
    final paths = <String>[];
    var requestedQuickSend = false;
    var index = 0;
    while (index < arguments.length) {
      final argument = arguments[index];
      if (argument == '--quick-send-text' && index + 1 < arguments.length) {
        text = arguments[index + 1];
        index += 2;
        continue;
      }
      if (argument == '--quick-send-file' && index + 1 < arguments.length) {
        paths.add(arguments[index + 1]);
        index += 2;
        continue;
      }
      if (argument == '--quick-send') {
        requestedQuickSend = true;
        paths.addAll(arguments.skip(index + 1));
        break;
      }
      index++;
    }
    return DesktopQuickSendArguments(
      text: text,
      filePaths: List<String>.unmodifiable(paths),
      captureClipboard: requestedQuickSend && text.isEmpty && paths.isEmpty,
    );
  }
}

enum DesktopQuickSendRejectionReason {
  draftLimitExceeded,
  fileLimitExceeded,
  textLimitExceeded,
  pathLimitExceeded,
  invalidPath,
  clipboardSnapshotUnavailable,
}

class DesktopQuickSendRejection {
  const DesktopQuickSendRejection({required this.reason, required this.limit});

  final DesktopQuickSendRejectionReason reason;
  final int limit;

  Map<String, Object?> toPlatformValue() => <String, Object?>{
    'reason': reason.name,
    'limit': limit,
  };
}

class DesktopQuickSendNativeEntry {
  const DesktopQuickSendNativeEntry._({
    required this.id,
    required this.arguments,
    required this.rejection,
  });

  const DesktopQuickSendNativeEntry.arguments({
    required String id,
    required List<String> arguments,
  }) : this._(id: id, arguments: arguments, rejection: null);

  const DesktopQuickSendNativeEntry.rejection({
    required String id,
    required DesktopQuickSendRejection rejection,
  }) : this._(id: id, arguments: const <String>[], rejection: rejection);

  final String id;
  final List<String> arguments;
  final DesktopQuickSendRejection? rejection;

  static DesktopQuickSendNativeEntry? fromPlatformValue(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return null;
    }
    final id = (value['id'] as String?)?.trim() ?? '';
    if (id.isEmpty || id.length > 200 || id.contains('\u0000')) {
      return null;
    }
    final argumentsValue = value['arguments'];
    if (argumentsValue is List<Object?> && argumentsValue.isNotEmpty) {
      final arguments = argumentsValue.whereType<String>().toList(
        growable: false,
      );
      if (arguments.length != argumentsValue.length) {
        return null;
      }
      return DesktopQuickSendNativeEntry.arguments(
        id: id,
        arguments: List<String>.unmodifiable(arguments),
      );
    }
    final rejectionValue = value['rejection'];
    if (rejectionValue is! Map<Object?, Object?>) {
      return null;
    }
    final reasonName = rejectionValue['reason'] as String? ?? '';
    final reason = DesktopQuickSendRejectionReason.values
        .where((candidate) => candidate.name == reasonName)
        .firstOrNull;
    final limit = (rejectionValue['limit'] as num?)?.toInt();
    if (reason == null || limit == null || limit < 0) {
      return null;
    }
    return DesktopQuickSendNativeEntry.rejection(
      id: id,
      rejection: DesktopQuickSendRejection(reason: reason, limit: limit),
    );
  }
}

class _DesktopQuickSendPendingRejection {
  const _DesktopQuickSendPendingRejection({
    required this.rejection,
    this.nativeEntryId,
  });

  final DesktopQuickSendRejection rejection;
  final String? nativeEntryId;
}

class _DesktopClipboardCaptureRequest {
  _DesktopClipboardCaptureRequest(this.nativeEntryId);

  final String? nativeEntryId;
  DesktopQuickSendEnqueueResult? processedResult;
}

enum DesktopQuickSendEnqueueStatus { accepted, empty, deferred, rejected }

class DesktopQuickSendEnqueueResult {
  const DesktopQuickSendEnqueueResult._({required this.status, this.rejection});

  const DesktopQuickSendEnqueueResult.accepted()
    : this._(status: DesktopQuickSendEnqueueStatus.accepted);

  const DesktopQuickSendEnqueueResult.empty()
    : this._(status: DesktopQuickSendEnqueueStatus.empty);

  const DesktopQuickSendEnqueueResult.deferred()
    : this._(status: DesktopQuickSendEnqueueStatus.deferred);

  const DesktopQuickSendEnqueueResult.rejected(
    DesktopQuickSendRejection rejection,
  ) : this._(
        status: DesktopQuickSendEnqueueStatus.rejected,
        rejection: rejection,
      );

  final DesktopQuickSendEnqueueStatus status;
  final DesktopQuickSendRejection? rejection;

  bool get isAccepted => status == DesktopQuickSendEnqueueStatus.accepted;

  bool get isEmpty => status == DesktopQuickSendEnqueueStatus.empty;

  Map<String, Object?> toPlatformValue() => <String, Object?>{
    'status': status.name,
    if (rejection != null) 'rejection': rejection!.toPlatformValue(),
  };
}

abstract class DesktopQuickSendStore {
  Future<List<DesktopQuickSendDraft>> load();

  Future<void> save(List<DesktopQuickSendDraft> drafts);
}

class SharedPreferencesDesktopQuickSendStore implements DesktopQuickSendStore {
  const SharedPreferencesDesktopQuickSendStore();

  static const String _key = '_desktop_quick_send_drafts_v1';

  @override
  Future<List<DesktopQuickSendDraft>> load() async {
    final encoded = (await SharedPreferences.getInstance()).getString(_key);
    if (encoded == null || encoded.isEmpty) {
      return const <DesktopQuickSendDraft>[];
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List<Object?>) {
        return const <DesktopQuickSendDraft>[];
      }
      return decoded
          .map((value) {
            if (value is! Map) {
              return null;
            }
            return DesktopQuickSendDraft.fromJson(
              value.map((key, value) => MapEntry(key.toString(), value)),
            );
          })
          .whereType<DesktopQuickSendDraft>()
          .toList(growable: false);
    } on Object {
      return const <DesktopQuickSendDraft>[];
    }
  }

  @override
  Future<void> save(List<DesktopQuickSendDraft> drafts) async {
    final encoded = jsonEncode(drafts.map((draft) => draft.toJson()).toList());
    final saved = await (await SharedPreferences.getInstance()).setString(
      _key,
      encoded,
    );
    if (!saved) {
      throw const FileSystemException('Failed to persist quick-send drafts');
    }
  }
}

typedef DesktopQuickSendArgumentsHandler =
    Future<DesktopQuickSendEnqueueResult> Function(
      DesktopQuickSendNativeEntry entry,
    );
typedef DesktopClipboardCaptureHandler =
    Future<DesktopQuickSendEnqueueResult> Function(String? nativeEntryId);

abstract class DesktopQuickSendPlatform {
  void setArgumentsHandler(DesktopQuickSendArgumentsHandler? handler);

  Future<List<DesktopQuickSendNativeEntry>> consumePendingEntries();

  Future<bool> acknowledge(String nativeEntryId);
}

class MethodChannelDesktopQuickSendPlatform
    implements DesktopQuickSendPlatform {
  MethodChannelDesktopQuickSendPlatform({
    MethodChannel channel = const MethodChannel(
      'com.vireen.whisper/desktop_quick_send',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  void setArgumentsHandler(DesktopQuickSendArgumentsHandler? handler) {
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'quickSendReceived') {
        return null;
      }
      // Native events are wake signals only. Reading their arguments as a
      // fallback can duplicate a share when startup and this handler race to
      // drain the same native queue.
      final results = <Map<String, Object?>>[];
      for (final entry in await consumePendingEntries()) {
        results.add(<String, Object?>{
          'id': entry.id,
          ...((await handler(entry)).toPlatformValue()),
        });
      }
      return results;
    });
  }

  @override
  Future<List<DesktopQuickSendNativeEntry>> consumePendingEntries() async {
    try {
      final values = await _channel.invokeListMethod<Object?>(
        'consumePendingQuickSends',
      );
      return (values ?? const <Object?>[])
          .map(DesktopQuickSendNativeEntry.fromPlatformValue)
          .whereType<DesktopQuickSendNativeEntry>()
          .toList(growable: false);
    } on MissingPluginException {
      return const <DesktopQuickSendNativeEntry>[];
    } on PlatformException {
      return const <DesktopQuickSendNativeEntry>[];
    }
  }

  @override
  Future<bool> acknowledge(String nativeEntryId) async {
    try {
      return await _channel.invokeMethod<bool>(
            'acknowledgeQuickSend',
            nativeEntryId,
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

enum DesktopQuickSendOutcome {
  completed,
  retained,
  targetConflict,
  targetIdentityInvalid,
}

class DesktopQuickSendResult {
  const DesktopQuickSendResult({
    required this.sentDrafts,
    required this.remainingDrafts,
    required this.outcome,
    this.failedPath,
  });

  final int sentDrafts;
  final int remainingDrafts;
  final DesktopQuickSendOutcome outcome;
  final String? failedPath;

  bool get isComplete => remainingDrafts == 0;
}

typedef DesktopQuickSendTrustedIdentityResolver =
    String? Function(String peerId);

Future<Set<String>> recoverableFolderTransferAndDesktopDraftPaths({
  ActiveTransferPathsProvider databasePathsProvider =
      recoverableFolderTransferPaths,
  DesktopQuickSendInbox? inbox,
}) async {
  return <String>{
    ...await databasePathsProvider(),
    ...(inbox ?? DesktopQuickSendInbox.shared).stagedArchivePaths,
  };
}

class DesktopQuickSendInbox extends ChangeNotifier {
  DesktopQuickSendInbox({
    DesktopQuickSendStore? store,
    DesktopQuickSendPlatform? platform,
    DateTime Function()? now,
    String Function()? idFactory,
  }) : _store = store ?? const SharedPreferencesDesktopQuickSendStore(),
       _platform = platform ?? MethodChannelDesktopQuickSendPlatform(),
       _now = now ?? DateTime.now,
       _idFactory = idFactory ?? const Uuid().v4 {
    _platform.setArgumentsHandler(_handlePlatformArguments);
  }

  static final DesktopQuickSendInbox shared = DesktopQuickSendInbox();

  final DesktopQuickSendStore _store;
  final DesktopQuickSendPlatform _platform;
  final DateTime Function() _now;
  final String Function() _idFactory;
  final Lock _persistenceLock = Lock();
  final Lock _nativeAcknowledgementLock = Lock();
  final List<DesktopQuickSendDraft> _drafts = <DesktopQuickSendDraft>[];
  Future<void>? _initialization;
  Future<DesktopQuickSendResult>? _sendFuture;
  Future<void>? _clipboardCaptureFuture;
  DesktopClipboardCaptureHandler? _clipboardCaptureHandler;
  final List<_DesktopClipboardCaptureRequest> _clipboardCaptureRequests =
      <_DesktopClipboardCaptureRequest>[];
  bool _clipboardCaptureBlocked = false;
  final List<_DesktopQuickSendPendingRejection> _pendingRejections =
      <_DesktopQuickSendPendingRejection>[];
  final Set<String> _queuedNativeRejectionIds = <String>{};
  final List<String> _presentedNativeRejectionIds = <String>[];
  bool _presentationRequested = false;
  bool _disposed = false;

  List<DesktopQuickSendDraft> get drafts =>
      List<DesktopQuickSendDraft>.unmodifiable(_drafts);

  Set<String> get stagedArchivePaths => Set<String>.unmodifiable(
    _drafts.map((draft) => draft.stagedPath).where((path) => path.isNotEmpty),
  );

  bool get hasPendingDrafts => _drafts.isNotEmpty;

  bool get isSending => _sendFuture != null;

  bool takePresentationRequest() {
    final requested = _presentationRequested;
    _presentationRequested = false;
    return requested;
  }

  DesktopQuickSendRejection? takePendingRejection() {
    if (_pendingRejections.isEmpty) {
      return null;
    }
    final pending = _pendingRejections.removeAt(0);
    final nativeEntryId = pending.nativeEntryId;
    if (nativeEntryId != null) {
      _queuedNativeRejectionIds.remove(nativeEntryId);
      _presentedNativeRejectionIds.add(nativeEntryId);
    }
    if (_pendingRejections.isNotEmpty && !_disposed) {
      scheduleMicrotask(notifyListeners);
    }
    return pending.rejection;
  }

  Future<bool> acknowledgePresentedRejection() async {
    return _nativeAcknowledgementLock.synchronized(() async {
      if (_presentedNativeRejectionIds.isEmpty) {
        return true;
      }
      final nativeEntryId = _presentedNativeRejectionIds.first;
      if (!await _platform.acknowledge(nativeEntryId)) {
        return false;
      }
      _presentedNativeRejectionIds.removeAt(0);
      _clipboardCaptureRequests.removeWhere(
        (request) => request.nativeEntryId == nativeEntryId,
      );
      _clipboardCaptureBlocked = false;
      if (_clipboardCaptureRequests.isNotEmpty && !_disposed) {
        unawaited(_drainClipboardCaptureRequest());
      }
      return true;
    });
  }

  Future<void> initialize({List<String> initialArguments = const []}) {
    return _initialization ??= _initialize(initialArguments);
  }

  Future<void> _initialize(List<String> initialArguments) async {
    _drafts
      ..clear()
      ..addAll(await _store.load());
    await _addArguments(
      initialArguments,
      source: DesktopQuickSendSource.commandLine,
      persist: false,
    );
    final entriesToAcknowledge = <String>[];
    for (final entry in await _platform.consumePendingEntries()) {
      final result = await _ingestNativeEntry(entry, persist: false);
      if (result.status == DesktopQuickSendEnqueueStatus.accepted ||
          result.status == DesktopQuickSendEnqueueStatus.empty) {
        entriesToAcknowledge.add(entry.id);
      }
    }
    await _persistAndNotify();
    for (final nativeEntryId in entriesToAcknowledge) {
      await _platform.acknowledge(nativeEntryId);
    }
  }

  Future<DesktopQuickSendEnqueueResult> _handlePlatformArguments(
    DesktopQuickSendNativeEntry entry,
  ) async {
    await initialize();
    final result = await _ingestNativeEntry(entry);
    await _drainClipboardCaptureRequest();
    if (result.status == DesktopQuickSendEnqueueStatus.accepted ||
        result.status == DesktopQuickSendEnqueueStatus.empty) {
      await _platform.acknowledge(entry.id);
    }
    return result;
  }

  Future<DesktopQuickSendEnqueueResult> _ingestNativeEntry(
    DesktopQuickSendNativeEntry entry, {
    bool persist = true,
  }) async {
    final rejection = entry.rejection;
    if (rejection != null) {
      return _reject(rejection, nativeEntryId: entry.id);
    }
    return _addArguments(
      entry.arguments,
      source: DesktopQuickSendSource.systemService,
      persist: persist,
      nativeEntryId: entry.id,
    );
  }

  Future<void> setClipboardCaptureHandler(
    DesktopClipboardCaptureHandler? handler,
  ) async {
    _clipboardCaptureHandler = handler;
    if (handler == null || _disposed) {
      return;
    }
    await initialize();
    await _drainClipboardCaptureRequest();
  }

  Future<DesktopQuickSendEnqueueResult> addClipboard({
    required String text,
    required Iterable<String> filePaths,
    String? nativeEntryId,
  }) async {
    await initialize();
    return _addContent(
      text: text,
      filePaths: filePaths,
      source: DesktopQuickSendSource.clipboardShortcut,
      draftId: nativeEntryId == null ? null : _nativeDraftId(nativeEntryId),
      nativeEntryId: nativeEntryId,
    );
  }

  Future<DesktopQuickSendEnqueueResult> addSystemShare({
    String text = '',
    Iterable<String> filePaths = const <String>[],
  }) async {
    await initialize();
    return _addContent(
      text: text,
      filePaths: filePaths,
      source: DesktopQuickSendSource.systemService,
    );
  }

  Future<DesktopQuickSendEnqueueResult> _addArguments(
    List<String> arguments, {
    required DesktopQuickSendSource source,
    bool persist = true,
    String? nativeEntryId,
  }) async {
    final parsed = DesktopQuickSendArguments.parse(arguments);
    if (parsed.captureClipboard) {
      if (nativeEntryId != null &&
          (_queuedNativeRejectionIds.contains(nativeEntryId) ||
              _presentedNativeRejectionIds.contains(nativeEntryId))) {
        return const DesktopQuickSendEnqueueResult.deferred();
      }
      if (nativeEntryId == null ||
          !_clipboardCaptureRequests.any(
            (request) => request.nativeEntryId == nativeEntryId,
          )) {
        _clipboardCaptureRequests.add(
          _DesktopClipboardCaptureRequest(nativeEntryId),
        );
      }
      return const DesktopQuickSendEnqueueResult.deferred();
    }
    if (!parsed.hasContent) {
      return const DesktopQuickSendEnqueueResult.empty();
    }
    return _addContent(
      text: parsed.text,
      filePaths: parsed.filePaths,
      source: source,
      persist: persist,
      draftId: nativeEntryId == null ? null : _nativeDraftId(nativeEntryId),
      nativeEntryId: nativeEntryId,
    );
  }

  Future<void> _drainClipboardCaptureRequest() {
    final active = _clipboardCaptureFuture;
    if (active != null) {
      return active;
    }
    final handler = _clipboardCaptureHandler;
    if (_clipboardCaptureRequests.isEmpty || handler == null || _disposed) {
      return Future<void>.value();
    }
    _clipboardCaptureBlocked = false;
    final future = _drainClipboardCaptureRequests(handler);
    _clipboardCaptureFuture = future;
    return future.whenComplete(() {
      _clipboardCaptureFuture = null;
      if (_clipboardCaptureRequests.isNotEmpty &&
          !_clipboardCaptureBlocked &&
          !_disposed) {
        unawaited(_drainClipboardCaptureRequest());
      }
    });
  }

  Future<void> _drainClipboardCaptureRequests(
    DesktopClipboardCaptureHandler handler,
  ) async {
    while (_clipboardCaptureRequests.isNotEmpty && !_disposed) {
      final request = _clipboardCaptureRequests.first;
      final nativeEntryId = request.nativeEntryId;
      var result = request.processedResult;
      if (result == null) {
        if (nativeEntryId != null &&
            _drafts.any((draft) => draft.id == _nativeDraftId(nativeEntryId))) {
          result = const DesktopQuickSendEnqueueResult.accepted();
        } else {
          try {
            result = await handler(nativeEntryId);
          } on Object {
            _clipboardCaptureBlocked = true;
            rethrow;
          }
        }
        request.processedResult = result;
      }
      if (result.status == DesktopQuickSendEnqueueStatus.rejected) {
        if (nativeEntryId == null) {
          _clipboardCaptureRequests.removeAt(0);
          continue;
        }
        _clipboardCaptureBlocked = true;
        return;
      }
      if (result.status != DesktopQuickSendEnqueueStatus.accepted &&
          result.status != DesktopQuickSendEnqueueStatus.empty) {
        _clipboardCaptureBlocked = true;
        return;
      }
      if (nativeEntryId != null &&
          !await _platform.acknowledge(nativeEntryId)) {
        _clipboardCaptureBlocked = true;
        return;
      }
      _clipboardCaptureRequests.removeAt(0);
    }
  }

  Future<DesktopQuickSendEnqueueResult> _addContent({
    required String text,
    required Iterable<String> filePaths,
    required DesktopQuickSendSource source,
    bool persist = true,
    String? draftId,
    String? nativeEntryId,
  }) async {
    final paths = List<String>.unmodifiable(filePaths);
    if (text.isEmpty && paths.isEmpty) {
      return const DesktopQuickSendEnqueueResult.empty();
    }
    final invalidContent = _validateQuickSendContent(text, paths);
    if (invalidContent != null) {
      return _reject(invalidContent, nativeEntryId: nativeEntryId);
    }
    var added = false;
    final result = await _persistenceLock.synchronized(() async {
      if (draftId != null && _drafts.any((draft) => draft.id == draftId)) {
        return const DesktopQuickSendEnqueueResult.accepted();
      }
      if (_drafts.length >= desktopQuickSendMaxDrafts) {
        return const DesktopQuickSendEnqueueResult.rejected(
          DesktopQuickSendRejection(
            reason: DesktopQuickSendRejectionReason.draftLimitExceeded,
            limit: desktopQuickSendMaxDrafts,
          ),
        );
      }
      final draft = DesktopQuickSendDraft(
        id: draftId ?? _idFactory(),
        source: source,
        text: text,
        filePaths: paths,
        receivedAt: _now().millisecondsSinceEpoch,
      );
      if (persist) {
        await _store.save(<DesktopQuickSendDraft>[..._drafts, draft]);
      }
      _drafts.add(draft);
      added = true;
      return const DesktopQuickSendEnqueueResult.accepted();
    });
    if (result.rejection != null) {
      return _reject(result.rejection!, nativeEntryId: nativeEntryId);
    }
    if (added) {
      _presentationRequested = true;
    }
    if (persist && !_disposed) {
      notifyListeners();
    }
    return result;
  }

  DesktopQuickSendEnqueueResult _reject(
    DesktopQuickSendRejection rejection, {
    String? nativeEntryId,
  }) {
    if (nativeEntryId != null &&
        !_queuedNativeRejectionIds.add(nativeEntryId)) {
      return DesktopQuickSendEnqueueResult.rejected(rejection);
    }
    _pendingRejections.add(
      _DesktopQuickSendPendingRejection(
        rejection: rejection,
        nativeEntryId: nativeEntryId,
      ),
    );
    if (!_disposed) {
      notifyListeners();
    }
    return DesktopQuickSendEnqueueResult.rejected(rejection);
  }

  Future<DesktopQuickSendResult> sendPendingTo({
    required String peerId,
    required DesktopQuickSendTrustedIdentityResolver trustedIdentityHashFor,
    required Future<bool> Function(
      String peerId,
      String draftId,
      String pinnedPublicKeyHash,
      String text,
    )
    sendText,
    required Future<bool> Function(
      String peerId,
      String fileIntentId,
      String pinnedPublicKeyHash,
      String path,
    )
    sendFile,
    Future<String> Function(String directoryPath)? stageDirectory,
    Future<void> Function(String stagedPath)? releaseUnownedStagedFile,
  }) {
    final active = _sendFuture;
    if (active != null) {
      return active;
    }
    final future = _sendPendingTo(
      peerId: peerId,
      trustedIdentityHashFor: trustedIdentityHashFor,
      sendText: sendText,
      sendFile: sendFile,
      stageDirectory: stageDirectory,
      releaseUnownedStagedFile: releaseUnownedStagedFile,
    );
    _sendFuture = future;
    notifyListeners();
    return future.whenComplete(() {
      _sendFuture = null;
      if (!_disposed) {
        notifyListeners();
      }
    });
  }

  Future<DesktopQuickSendResult> _sendPendingTo({
    required String peerId,
    required DesktopQuickSendTrustedIdentityResolver trustedIdentityHashFor,
    required Future<bool> Function(
      String peerId,
      String draftId,
      String pinnedPublicKeyHash,
      String text,
    )
    sendText,
    required Future<bool> Function(
      String peerId,
      String fileIntentId,
      String pinnedPublicKeyHash,
      String path,
    )
    sendFile,
    required Future<String> Function(String directoryPath)? stageDirectory,
    required Future<void> Function(String stagedPath)? releaseUnownedStagedFile,
  }) async {
    var sentDrafts = 0;
    String? failedPath;
    while (_drafts.isNotEmpty) {
      var draft = _drafts.first;
      final preparation = await _prepareDraftTarget(
        draft,
        peerId: peerId,
        trustedIdentityHashFor: trustedIdentityHashFor,
      );
      if (preparation.draft == null) {
        return DesktopQuickSendResult(
          sentDrafts: sentDrafts,
          remainingDrafts: _drafts.length,
          outcome: preparation.outcome,
        );
      }
      draft = preparation.draft!;
      if (draft.text.isNotEmpty) {
        if (!_hasCurrentTargetIdentity(draft, trustedIdentityHashFor)) {
          return _clearInvalidTargetAndResult(draft, sentDrafts: sentDrafts);
        }
        final accepted = await sendText(
          peerId,
          draft.id,
          draft.pinnedPublicKeyHash,
          draft.text,
        );
        if (!accepted) {
          break;
        }
        final updated = draft.copyWith(text: '', deliveredPeerId: peerId);
        if (!await _replaceDraftAtomically(draft, updated)) {
          break;
        }
        draft = updated;
      }
      while (draft.filePaths.isNotEmpty) {
        if (!_hasCurrentTargetIdentity(draft, trustedIdentityHashFor)) {
          return _clearInvalidTargetAndResult(draft, sentDrafts: sentDrafts);
        }
        final sourcePath = draft.filePaths.first;
        var sendPath = sourcePath;
        try {
          final hasPersistedStage =
              draft.stagedSourcePath == sourcePath &&
              draft.stagedPath.isNotEmpty;
          if (hasPersistedStage) {
            sendPath = draft.stagedPath;
          } else {
            final type = await FileSystemEntity.type(
              sourcePath,
              followLinks: false,
            );
            if (type == FileSystemEntityType.directory) {
              if (stageDirectory == null) {
                failedPath = sourcePath;
                break;
              }
              sendPath = await stageDirectory(sourcePath);
              if (sendPath.isEmpty ||
                  sendPath.length > desktopQuickSendMaxPathLength ||
                  sendPath.contains('\u0000')) {
                if (sendPath.isNotEmpty) {
                  await releaseUnownedStagedFile?.call(sendPath);
                }
                failedPath = sourcePath;
                break;
              }
              final staged = draft.copyWith(
                stagedSourcePath: sourcePath,
                stagedPath: sendPath,
              );
              if (!await _replaceDraftAtomically(draft, staged)) {
                await releaseUnownedStagedFile?.call(sendPath);
                failedPath = sourcePath;
                break;
              }
              draft = staged;
            } else if (type != FileSystemEntityType.file) {
              failedPath = sourcePath;
              break;
            }
          }
          if (!_hasCurrentTargetIdentity(draft, trustedIdentityHashFor)) {
            return _clearInvalidTargetAndResult(draft, sentDrafts: sentDrafts);
          }
          final fileIntentId = jsonEncode(<Object>[
            draft.id,
            draft.pinnedPublicKeyHash,
            draft.deliveredFileCount,
            sourcePath,
          ]);
          if (!await sendFile(
            peerId,
            fileIntentId,
            draft.pinnedPublicKeyHash,
            sendPath,
          )) {
            final cleared = draft.copyWith(
              stagedSourcePath: '',
              stagedPath: '',
            );
            if (draft.stagedPath.isNotEmpty &&
                await _replaceDraftAtomically(draft, cleared)) {
              draft = cleared;
            }
            failedPath = sourcePath;
            break;
          }
        } on Object catch (error) {
          final cleared = draft.copyWith(stagedSourcePath: '', stagedPath: '');
          if (draft.stagedPath.isNotEmpty &&
              await _replaceDraftAtomically(draft, cleared)) {
            draft = cleared;
          }
          failedPath = sourcePath;
          if (error is FileSystemException) {
            break;
          }
          rethrow;
        }
        final updated = draft.copyWith(
          filePaths: draft.filePaths.skip(1).toList(),
          deliveredPeerId: peerId,
          deliveredFileCount: draft.deliveredFileCount + 1,
          stagedSourcePath: '',
          stagedPath: '',
        );
        if (!await _replaceDraftAtomically(draft, updated)) {
          break;
        }
        draft = updated;
      }
      if (draft.filePaths.isNotEmpty) {
        break;
      }
      if (!await _removeDraftAtomically(draft)) {
        break;
      }
      sentDrafts++;
    }
    return DesktopQuickSendResult(
      sentDrafts: sentDrafts,
      remainingDrafts: _drafts.length,
      outcome: _drafts.isEmpty
          ? DesktopQuickSendOutcome.completed
          : DesktopQuickSendOutcome.retained,
      failedPath: failedPath,
    );
  }

  Future<_DesktopQuickSendTargetPreparation> _prepareDraftTarget(
    DesktopQuickSendDraft draft, {
    required String peerId,
    required DesktopQuickSendTrustedIdentityResolver trustedIdentityHashFor,
  }) async {
    if (draft.targetPeerId.isNotEmpty &&
        !_hasCurrentTargetIdentity(draft, trustedIdentityHashFor)) {
      final cleared = draft.copyWith(targetPeerId: '', pinnedPublicKeyHash: '');
      if (!await _replaceDraftAtomically(draft, cleared)) {
        return const _DesktopQuickSendTargetPreparation.blocked(
          DesktopQuickSendOutcome.retained,
        );
      }
      return const _DesktopQuickSendTargetPreparation.blocked(
        DesktopQuickSendOutcome.targetIdentityInvalid,
      );
    }

    final normalizedPeerId = peerId.trim();
    final publicKeyHash = _currentTrustedIdentityHash(
      normalizedPeerId,
      trustedIdentityHashFor,
    );
    if (normalizedPeerId.isEmpty || publicKeyHash == null) {
      return const _DesktopQuickSendTargetPreparation.blocked(
        DesktopQuickSendOutcome.targetIdentityInvalid,
      );
    }
    if (draft.deliveredPeerId.isNotEmpty &&
        draft.deliveredPeerId != normalizedPeerId) {
      return const _DesktopQuickSendTargetPreparation.blocked(
        DesktopQuickSendOutcome.targetConflict,
      );
    }
    if (draft.targetPeerId == normalizedPeerId &&
        draft.pinnedPublicKeyHash == publicKeyHash) {
      return _DesktopQuickSendTargetPreparation.ready(draft);
    }

    final bound = draft.copyWith(
      targetPeerId: normalizedPeerId,
      pinnedPublicKeyHash: publicKeyHash,
    );
    if (!await _replaceDraftAtomically(draft, bound)) {
      return const _DesktopQuickSendTargetPreparation.blocked(
        DesktopQuickSendOutcome.retained,
      );
    }
    return _DesktopQuickSendTargetPreparation.ready(bound);
  }

  bool _hasCurrentTargetIdentity(
    DesktopQuickSendDraft draft,
    DesktopQuickSendTrustedIdentityResolver trustedIdentityHashFor,
  ) {
    return draft.targetPeerId.isNotEmpty &&
        draft.pinnedPublicKeyHash.isNotEmpty &&
        _currentTrustedIdentityHash(
              draft.targetPeerId,
              trustedIdentityHashFor,
            ) ==
            draft.pinnedPublicKeyHash;
  }

  Future<DesktopQuickSendResult> _clearInvalidTargetAndResult(
    DesktopQuickSendDraft draft, {
    required int sentDrafts,
  }) async {
    final cleared = draft.copyWith(targetPeerId: '', pinnedPublicKeyHash: '');
    final clearedPersistently = await _replaceDraftAtomically(draft, cleared);
    return DesktopQuickSendResult(
      sentDrafts: sentDrafts,
      remainingDrafts: _drafts.length,
      outcome: clearedPersistently
          ? DesktopQuickSendOutcome.targetIdentityInvalid
          : DesktopQuickSendOutcome.retained,
    );
  }

  Future<bool> _replaceDraftAtomically(
    DesktopQuickSendDraft current,
    DesktopQuickSendDraft replacement,
  ) async {
    try {
      final replaced = await _persistenceLock.synchronized(() async {
        final index = _drafts.indexWhere(
          (candidate) => identical(candidate, current),
        );
        if (index < 0) {
          return false;
        }
        final snapshot = List<DesktopQuickSendDraft>.of(_drafts);
        snapshot[index] = replacement;
        await _store.save(snapshot);
        _drafts[index] = replacement;
        return true;
      });
      if (replaced && !_disposed) {
        notifyListeners();
      }
      return replaced;
    } on Object {
      return false;
    }
  }

  Future<bool> _removeDraftAtomically(DesktopQuickSendDraft draft) async {
    try {
      final removed = await _persistenceLock.synchronized(() async {
        final index = _drafts.indexWhere(
          (candidate) => identical(candidate, draft),
        );
        if (index < 0) {
          return false;
        }
        final snapshot = List<DesktopQuickSendDraft>.of(_drafts)
          ..removeAt(index);
        await _store.save(snapshot);
        _drafts.removeAt(index);
        return true;
      });
      if (removed && !_disposed) {
        notifyListeners();
      }
      return removed;
    } on Object {
      return false;
    }
  }

  Future<void> remove(String id) async {
    await initialize();
    final removed = await _persistenceLock.synchronized(() async {
      final snapshot = List<DesktopQuickSendDraft>.of(_drafts)
        ..removeWhere((draft) => draft.id == id);
      if (snapshot.length == _drafts.length) {
        return false;
      }
      await _store.save(snapshot);
      _drafts
        ..clear()
        ..addAll(snapshot);
      return true;
    });
    if (removed && !_disposed) {
      notifyListeners();
    }
  }

  Future<void> clear() async {
    await initialize();
    final cleared = await _persistenceLock.synchronized(() async {
      if (_drafts.isEmpty) {
        return false;
      }
      await _store.save(const <DesktopQuickSendDraft>[]);
      _drafts.clear();
      return true;
    });
    if (cleared && !_disposed) {
      notifyListeners();
    }
  }

  Future<void> _persistAndNotify() async {
    final snapshot = List<DesktopQuickSendDraft>.of(_drafts);
    await _persistenceLock.synchronized(() => _store.save(snapshot));
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _clipboardCaptureHandler = null;
    _clipboardCaptureRequests.clear();
    _platform.setArgumentsHandler(null);
    super.dispose();
  }
}

class _DesktopQuickSendTargetPreparation {
  const _DesktopQuickSendTargetPreparation.ready(this.draft)
    : outcome = DesktopQuickSendOutcome.completed;

  const _DesktopQuickSendTargetPreparation.blocked(this.outcome) : draft = null;

  final DesktopQuickSendDraft? draft;
  final DesktopQuickSendOutcome outcome;
}

String? _currentTrustedIdentityHash(
  String peerId,
  DesktopQuickSendTrustedIdentityResolver trustedIdentityHashFor,
) {
  if (peerId.isEmpty) {
    return null;
  }
  try {
    final hash = trustedIdentityHashFor(peerId)?.trim() ?? '';
    return _isCanonicalIdentityHash(hash) ? hash : null;
  } on Object {
    return null;
  }
}

bool _isCanonicalIdentityHash(String value) {
  return value.length == 43 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
}

bool _isValidDraftTargetBinding({
  required String targetPeerId,
  required String pinnedPublicKeyHash,
  required String deliveredPeerId,
  required int deliveredFileCount,
}) {
  bool isValidPeerId(String value) {
    return value.length <= desktopQuickSendMaxPathLength &&
        !value.contains('\u0000');
  }

  if (!isValidPeerId(targetPeerId) ||
      !isValidPeerId(deliveredPeerId) ||
      deliveredFileCount < 0 ||
      deliveredFileCount > desktopQuickSendMaxFilesPerDraft ||
      (deliveredFileCount > 0 && deliveredPeerId.isEmpty)) {
    return false;
  }
  final hasTarget = targetPeerId.isNotEmpty;
  if (hasTarget != pinnedPublicKeyHash.isNotEmpty ||
      (pinnedPublicKeyHash.isNotEmpty &&
          !_isCanonicalIdentityHash(pinnedPublicKeyHash))) {
    return false;
  }
  return deliveredPeerId.isEmpty ||
      !hasTarget ||
      deliveredPeerId == targetPeerId;
}

DesktopQuickSendRejection? _validateQuickSendContent(
  String text,
  List<String> paths,
) {
  if (text.length > desktopQuickSendMaxTextLength) {
    return const DesktopQuickSendRejection(
      reason: DesktopQuickSendRejectionReason.textLimitExceeded,
      limit: desktopQuickSendMaxTextLength,
    );
  }
  if (paths.length > desktopQuickSendMaxFilesPerDraft) {
    return const DesktopQuickSendRejection(
      reason: DesktopQuickSendRejectionReason.fileLimitExceeded,
      limit: desktopQuickSendMaxFilesPerDraft,
    );
  }
  for (final path in paths) {
    if (path.length > desktopQuickSendMaxPathLength) {
      return const DesktopQuickSendRejection(
        reason: DesktopQuickSendRejectionReason.pathLimitExceeded,
        limit: desktopQuickSendMaxPathLength,
      );
    }
    if (path.isEmpty || path.contains('\u0000')) {
      return const DesktopQuickSendRejection(
        reason: DesktopQuickSendRejectionReason.invalidPath,
        limit: 0,
      );
    }
  }
  return null;
}

String _nativeDraftId(String nativeEntryId) => 'desktop-native-$nativeEntryId';
