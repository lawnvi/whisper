import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';

const int remoteClipboardMaxFileBytes = 64 * 1024 * 1024;
const int remoteClipboardMaxBatchBytes = 128 * 1024 * 1024;
const int remoteClipboardMaxItems = 20;
const int remoteClipboardChunkBytes = 512 * 1024;

void traceRemoteClipboard(
  String stage, {
  int? count,
  bool? success,
  String? reason,
}) {
  final enabled =
      Platform.environment['WHISPER_REMOTE_INPUT_TRACE'] == '1' ||
      (!kReleaseMode && Platform.resolvedExecutable.endsWith('/whisper'));
  if (!enabled) {
    return;
  }
  final line =
      '[remote-clipboard]'
      ' time=${DateTime.now().toIso8601String()}'
      ' pid=$pid stage=$stage'
      '${count == null ? '' : ' count=$count'}'
      '${success == null ? '' : ' success=$success'}'
      '${reason == null ? '' : ' reason=$reason'}';
  privacyLog.event(PrivacyEvent.remoteInputDiagnostic, {
    PrivacyField.component: _privacyTraceCode('remote_clipboard'),
    PrivacyField.action: _privacyTraceCode(stage),
    if (count != null) PrivacyField.count: count,
    if (success != null) PrivacyField.success: success,
    if (reason != null) PrivacyField.reason: _privacyTraceCode(reason),
  });
  try {
    File(
      p.join(Directory.systemTemp.path, 'whisper_remote_clipboard_trace.log'),
    ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } on FileSystemException {
    // Diagnostics must never affect clipboard delivery.
  }
}

int _privacyTraceCode(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

enum RemoteClipboardPasteResult { notAvailable, prepared, failed }

typedef RemoteClipboardFrameSender =
    Future<bool> Function(
      TransferConnectionBinding binding,
      WhisperFrameV3 frame,
    );
typedef RemoteClipboardBindingProvider =
    TransferConnectionBinding? Function(String peerId);
typedef RemoteClipboardSessionValidator =
    bool Function({
      required String peerId,
      required String sessionId,
      required bool sourceIsLocal,
    });
typedef RemoteClipboardDirectoryProvider = Future<Directory> Function();

final class RemoteClipboardLocalItem {
  const RemoteClipboardLocalItem({
    required this.name,
    required this.size,
    required this.openRead,
    this.isImage = false,
  });

  factory RemoteClipboardLocalItem.file(ClipboardFileDraft draft) {
    return RemoteClipboardLocalItem(
      name: draft.fileName,
      size: draft.size,
      openRead: () => File(draft.path).openRead(),
    );
  }

  factory RemoteClipboardLocalItem.bytes(String name, Uint8List bytes) {
    return RemoteClipboardLocalItem(
      name: name,
      size: bytes.length,
      openRead: () => Stream<List<int>>.value(bytes),
      isImage: true,
    );
  }

  final String name;
  final int size;
  final Stream<List<int>> Function() openRead;
  final bool isImage;
}

final class RemoteClipboardOfferItem {
  const RemoteClipboardOfferItem({
    required this.name,
    required this.size,
    required this.isImage,
  });

  final String name;
  final int size;
  final bool isImage;
}

final class RemoteClipboardOfferSnapshot {
  const RemoteClipboardOfferSnapshot({
    required this.offerId,
    required this.sessionId,
    required this.peerId,
    required this.items,
  });

  final String offerId;
  final String sessionId;
  final String peerId;
  final List<RemoteClipboardOfferItem> items;
}

final class RemoteClipboardTransferEngine {
  RemoteClipboardTransferEngine({
    required RemoteClipboardFrameSender sendFrame,
    required RemoteClipboardBindingProvider currentBinding,
    required RemoteClipboardSessionValidator sessionValidator,
    DesktopClipboardFileWriter writer = const DesktopClipboardFileWriter(),
    RemoteClipboardDirectoryProvider? directoryProvider,
    Duration requestTimeout = const Duration(minutes: 2),
    Duration cacheTtl = const Duration(minutes: 10),
    Uuid uuid = const Uuid(),
  }) : _sendFrame = sendFrame,
       _currentBinding = currentBinding,
       _sessionValidator = sessionValidator,
       _writer = writer,
       _directoryProvider = directoryProvider ?? _defaultDirectory,
       _requestTimeout = requestTimeout,
       _cacheTtl = cacheTtl,
       _uuid = uuid;

  static const int protocolVersion = 1;

  final RemoteClipboardFrameSender _sendFrame;
  final RemoteClipboardBindingProvider _currentBinding;
  final RemoteClipboardSessionValidator _sessionValidator;
  final DesktopClipboardFileWriter _writer;
  final RemoteClipboardDirectoryProvider _directoryProvider;
  final Duration _requestTimeout;
  final Duration _cacheTtl;
  final Uuid _uuid;

  final Map<String, _SourceOffer> _sourceOffers = <String, _SourceOffer>{};
  final Map<String, _RemoteOffer> _remoteOffers = <String, _RemoteOffer>{};
  final Map<String, _IncomingRequest> _incoming = <String, _IncomingRequest>{};
  final Map<String, _CachedPaste> _cached = <String, _CachedPaste>{};
  final Map<String, Timer> _cacheTimers = <String, Timer>{};

  Future<bool> publish({
    required String peerId,
    required String sessionId,
    required List<RemoteClipboardLocalItem> items,
  }) async {
    traceRemoteClipboard('publish_start', count: items.length);
    if (!_sessionValidator(
      peerId: peerId,
      sessionId: sessionId,
      sourceIsLocal: true,
    )) {
      traceRemoteClipboard('publish_rejected', reason: 'session');
      return false;
    }
    final normalized = _validatedLocalItems(items);
    if (normalized == null) {
      traceRemoteClipboard('publish_rejected', reason: 'limits');
      await clearSession(sessionId, notifyPeer: true, peerId: peerId);
      return false;
    }
    await _removeSourceOffer(sessionId);
    final offerId = _uuid.v4();
    final offer = _SourceOffer(
      offerId: offerId,
      sessionId: sessionId,
      peerId: peerId,
      items: normalized,
    );
    _sourceOffers[sessionId] = offer;
    final binding = _currentBinding(peerId);
    if (binding == null) {
      traceRemoteClipboard('publish_rejected', reason: 'connection');
      _sourceOffers.remove(sessionId);
      return false;
    }
    final sent = await _sendFrame(
      binding,
      WhisperFrameV3(
        type: WhisperFrameType.clipboardOffer,
        transferId: offerId,
        offset: 0,
        sequence: 0,
        payload: _jsonBytes(<String, Object?>{
          'protocolVersion': protocolVersion,
          'sessionId': sessionId,
          'items': <Map<String, Object?>>[
            for (final item in normalized)
              <String, Object?>{
                'name': item.name,
                'size': item.size,
                'kind': item.isImage ? 'image' : 'file',
              },
          ],
        }),
      ),
    );
    if (!sent && identical(_sourceOffers[sessionId], offer)) {
      _sourceOffers.remove(sessionId);
    }
    traceRemoteClipboard('offer_sent', success: sent);
    return sent;
  }

  Future<void> clearSession(
    String sessionId, {
    bool notifyPeer = false,
    String peerId = '',
  }) async {
    await _removeSourceOffer(sessionId);
    final remote = _remoteOffers.remove(sessionId);
    final incoming = _incoming.remove(sessionId);
    incoming?.complete(RemoteClipboardPasteResult.failed);
    await incoming?.dispose(deleteDirectory: true);
    final cached = _cached.remove(sessionId);
    await cached?.dispose();
    if (notifyPeer && peerId.isNotEmpty) {
      final binding = _currentBinding(peerId);
      if (binding != null) {
        await _sendFrame(
          binding,
          WhisperFrameV3(
            type: WhisperFrameType.clipboardClear,
            transferId: remote?.offerId ?? '',
            offset: 0,
            sequence: 0,
            payload: _jsonBytes(<String, Object?>{
              'protocolVersion': protocolVersion,
              'sessionId': sessionId,
            }),
          ),
        );
      }
    }
  }

  Future<RemoteClipboardPasteResult> preparePaste({
    required String peerId,
    required String sessionId,
  }) async {
    traceRemoteClipboard('paste_prepare_start');
    if (!_sessionValidator(
      peerId: peerId,
      sessionId: sessionId,
      sourceIsLocal: false,
    )) {
      traceRemoteClipboard('paste_unavailable', reason: 'session');
      return RemoteClipboardPasteResult.notAvailable;
    }
    final offer = _remoteOffers[sessionId];
    if (offer == null || offer.peerId != peerId) {
      traceRemoteClipboard('paste_unavailable', reason: 'offer');
      return RemoteClipboardPasteResult.notAvailable;
    }
    final materialized = await _materializeRemoteOffer(offer);
    if (materialized != RemoteClipboardPasteResult.prepared) {
      traceRemoteClipboard('paste_prepare_done', reason: materialized.name);
      return materialized;
    }
    final cached = _cached[sessionId];
    if (cached == null || cached.offerId != offer.offerId) {
      return RemoteClipboardPasteResult.failed;
    }
    final written = await _writer.writeFilePaths(
      cached.paths,
      asImage: cached.asImage,
    );
    traceRemoteClipboard('clipboard_written', success: written);
    final result = written
        ? RemoteClipboardPasteResult.prepared
        : RemoteClipboardPasteResult.failed;
    traceRemoteClipboard('paste_prepare_done', reason: result.name);
    return result;
  }

  Future<RemoteClipboardPasteResult> _materializeRemoteOffer(
    _RemoteOffer offer,
  ) async {
    final sessionId = offer.sessionId;
    final peerId = offer.peerId;
    final cached = _cached[sessionId];
    if (cached != null &&
        cached.offerId == offer.offerId &&
        !cached.isExpired(_cacheTtl) &&
        await cached.filesExist()) {
      return RemoteClipboardPasteResult.prepared;
    }
    final existing = _incoming[sessionId];
    if (existing != null && existing.offer.offerId == offer.offerId) {
      return existing.completion.future.timeout(
        _requestTimeout,
        onTimeout: () => RemoteClipboardPasteResult.failed,
      );
    }
    await _removeCached(sessionId);
    if (existing != null) {
      existing.complete(RemoteClipboardPasteResult.failed);
      await existing.dispose(deleteDirectory: true);
    }
    final base = await _directoryProvider();
    final directory = Directory(
      p.join(base.path, 'whisper_remote_clipboard', sessionId, offer.offerId),
    );
    await directory.create(recursive: true);
    final request = await _IncomingRequest.create(offer, directory);
    _incoming[sessionId] = request;
    final binding = _currentBinding(peerId);
    if (binding == null ||
        !await _sendFrame(
          binding,
          WhisperFrameV3(
            type: WhisperFrameType.clipboardRequest,
            transferId: offer.offerId,
            offset: 0,
            sequence: 0,
            payload: _jsonBytes(<String, Object?>{
              'protocolVersion': protocolVersion,
              'sessionId': sessionId,
            }),
          ),
        )) {
      traceRemoteClipboard('request_sent', success: false);
      _incoming.remove(sessionId);
      request.complete(RemoteClipboardPasteResult.failed);
      await request.dispose(deleteDirectory: true);
      return RemoteClipboardPasteResult.failed;
    }
    traceRemoteClipboard('request_sent', success: true);
    final result = await request.completion.future.timeout(
      _requestTimeout,
      onTimeout: () => RemoteClipboardPasteResult.failed,
    );
    if (result == RemoteClipboardPasteResult.failed &&
        identical(_incoming[sessionId], request)) {
      _incoming.remove(sessionId);
      await request.dispose(deleteDirectory: true);
    }
    return result;
  }

  RemoteClipboardOfferSnapshot? remoteOffer({
    required String peerId,
    required String sessionId,
  }) {
    final offer = _remoteOffers[sessionId];
    if (offer == null || offer.peerId != peerId) {
      return null;
    }
    return RemoteClipboardOfferSnapshot(
      offerId: offer.offerId,
      sessionId: offer.sessionId,
      peerId: offer.peerId,
      items: List<RemoteClipboardOfferItem>.unmodifiable(
        offer.items.map(
          (item) => RemoteClipboardOfferItem(
            name: item.name,
            size: item.size,
            isImage: item.isImage,
          ),
        ),
      ),
    );
  }

  Future<bool> relayRemoteOffer({
    required String originPeerId,
    required String originSessionId,
    required String targetPeerId,
    required String targetSessionId,
  }) async {
    final origin = _remoteOffers[originSessionId];
    if (origin == null || origin.peerId != originPeerId) {
      return false;
    }
    final items = <RemoteClipboardLocalItem>[];
    for (var index = 0; index < origin.items.length; index++) {
      final item = origin.items[index];
      items.add(
        RemoteClipboardLocalItem(
          name: item.name,
          size: item.size,
          isImage: item.isImage,
          openRead: () => _openRelayedItem(origin, index),
        ),
      );
    }
    return publish(
      peerId: targetPeerId,
      sessionId: targetSessionId,
      items: items,
    );
  }

  Stream<List<int>> _openRelayedItem(_RemoteOffer offer, int index) async* {
    if (!identical(_remoteOffers[offer.sessionId], offer)) {
      throw const FileSystemException('workspace clipboard offer changed');
    }
    final result = await _materializeRemoteOffer(offer);
    final cached = _cached[offer.sessionId];
    if (result != RemoteClipboardPasteResult.prepared ||
        cached == null ||
        cached.offerId != offer.offerId ||
        index < 0 ||
        index >= cached.paths.length) {
      throw const FileSystemException('workspace clipboard relay failed');
    }
    yield* File(cached.paths[index]).openRead();
  }

  Future<void> handleFrame(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    traceRemoteClipboard('frame_received', reason: frame.type.name);
    switch (frame.type) {
      case WhisperFrameType.clipboardOffer:
        await _handleOffer(binding, frame);
        return;
      case WhisperFrameType.clipboardClear:
        await _handleClear(binding, frame);
        return;
      case WhisperFrameType.clipboardRequest:
        await _handleRequest(binding, frame);
        return;
      case WhisperFrameType.clipboardData:
        await _handleData(binding, frame);
        return;
      case WhisperFrameType.clipboardComplete:
        await _handleComplete(binding, frame);
        return;
      case WhisperFrameType.clipboardError:
        await _handleError(binding, frame);
        return;
      default:
        throw const FormatException('not a remote clipboard frame');
    }
  }

  Future<void> _handleOffer(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    final json = _frameJson(frame);
    final sessionId = json['sessionId'];
    final rawItems = json['items'];
    if (json['protocolVersion'] != protocolVersion ||
        sessionId is! String ||
        sessionId.isEmpty ||
        rawItems is! List ||
        frame.transferId.isEmpty ||
        frame.offset != 0 ||
        frame.sequence != 0 ||
        !_sessionValidator(
          peerId: binding.peerId,
          sessionId: sessionId,
          sourceIsLocal: false,
        )) {
      throw const FormatException('invalid remote clipboard offer');
    }
    final items = <_RemoteItem>[];
    var total = 0;
    for (final raw in rawItems) {
      if (raw is! Map) {
        throw const FormatException('invalid remote clipboard item');
      }
      final item = Map<String, dynamic>.from(raw);
      final name = item['name'];
      final size = item['size'];
      final kind = item['kind'];
      if (name is! String ||
          !_isSafeName(name) ||
          size is! int ||
          (kind != 'file' && kind != 'image') ||
          size < 0 ||
          size > remoteClipboardMaxFileBytes) {
        throw const FormatException('invalid remote clipboard item');
      }
      total += size;
      items.add(_RemoteItem(name: name, size: size, isImage: kind == 'image'));
    }
    if (items.isEmpty ||
        items.length > remoteClipboardMaxItems ||
        total > remoteClipboardMaxBatchBytes) {
      throw const FormatException('remote clipboard offer exceeds limits');
    }
    await _replaceRemoteOffer(
      _RemoteOffer(
        offerId: frame.transferId,
        sessionId: sessionId,
        peerId: binding.peerId,
        items: items,
      ),
    );
    traceRemoteClipboard('offer_received', count: items.length);
  }

  Future<void> _handleClear(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    final json = _frameJson(frame);
    final sessionId = json['sessionId'];
    if (json['protocolVersion'] != protocolVersion || sessionId is! String) {
      throw const FormatException('invalid remote clipboard clear');
    }
    final offer = _remoteOffers[sessionId];
    if (offer != null && offer.peerId == binding.peerId) {
      await _removeRemoteOffer(sessionId);
    }
  }

  Future<void> _handleRequest(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    final json = _frameJson(frame);
    final sessionId = json['sessionId'];
    final offer = sessionId is String ? _sourceOffers[sessionId] : null;
    if (json['protocolVersion'] != protocolVersion ||
        offer == null ||
        offer.peerId != binding.peerId ||
        offer.offerId != frame.transferId ||
        !_sessionValidator(
          peerId: binding.peerId,
          sessionId: offer.sessionId,
          sourceIsLocal: true,
        )) {
      await _sendError(binding, frame.transferId, sessionId as String? ?? '');
      traceRemoteClipboard('request_rejected');
      return;
    }
    traceRemoteClipboard('request_received');
    unawaited(_streamOffer(binding, offer));
  }

  Future<void> _streamOffer(
    TransferConnectionBinding binding,
    _SourceOffer offer,
  ) async {
    traceRemoteClipboard('stream_start', count: offer.items.length);
    try {
      for (var index = 0; index < offer.items.length; index++) {
        final item = offer.items[index];
        var offset = 0;
        await for (final block in item.openRead()) {
          var start = 0;
          while (start < block.length) {
            final end = (start + remoteClipboardChunkBytes).clamp(
              0,
              block.length,
            );
            final chunk = Uint8List.fromList(block.sublist(start, end));
            if (chunk.isEmpty || offset + chunk.length > item.size) {
              throw const FileSystemException('clipboard source size changed');
            }
            final current = _sourceOffers[offer.sessionId];
            if (!identical(current, offer) ||
                _currentBinding(offer.peerId) != binding ||
                !await _sendFrame(
                  binding,
                  WhisperFrameV3(
                    type: WhisperFrameType.clipboardData,
                    transferId: offer.offerId,
                    offset: offset,
                    sequence: index,
                    payload: chunk,
                  ),
                )) {
              throw const FileSystemException('clipboard peer disconnected');
            }
            offset += chunk.length;
            start = end;
          }
        }
        if (offset != item.size) {
          throw const FileSystemException('clipboard source size changed');
        }
      }
      await _sendFrame(
        binding,
        WhisperFrameV3(
          type: WhisperFrameType.clipboardComplete,
          transferId: offer.offerId,
          offset: offer.items.fold<int>(0, (sum, item) => sum + item.size),
          sequence: offer.items.length,
          payload: _jsonBytes(<String, Object?>{
            'protocolVersion': protocolVersion,
            'sessionId': offer.sessionId,
          }),
        ),
      );
      traceRemoteClipboard('stream_complete', success: true);
    } catch (error) {
      traceRemoteClipboard(
        'stream_complete',
        success: false,
        reason: error.runtimeType.toString(),
      );
      await _sendError(binding, offer.offerId, offer.sessionId);
    }
  }

  Future<void> _handleData(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    if (frame.payload.isEmpty ||
        frame.payload.length > remoteClipboardChunkBytes) {
      throw const FormatException('invalid remote clipboard data');
    }
    final request = _incoming.values
        .where((item) => item.offer.offerId == frame.transferId)
        .firstOrNull;
    if (request == null || request.offer.peerId != binding.peerId) {
      return;
    }
    try {
      await request.add(frame);
    } catch (_) {
      _incoming.remove(request.offer.sessionId);
      request.complete(RemoteClipboardPasteResult.failed);
      await request.dispose(deleteDirectory: true);
      rethrow;
    }
  }

  Future<void> _handleComplete(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    final json = _frameJson(frame);
    final sessionId = json['sessionId'];
    final request = sessionId is String ? _incoming[sessionId] : null;
    if (json['protocolVersion'] != protocolVersion ||
        request == null ||
        request.offer.peerId != binding.peerId ||
        request.offer.offerId != frame.transferId ||
        frame.sequence != request.offer.items.length ||
        frame.offset != request.offer.totalSize) {
      throw const FormatException('invalid remote clipboard completion');
    }
    _incoming.remove(sessionId);
    try {
      final paths = await request.finish();
      final cached = _CachedPaste(
        offerId: request.offer.offerId,
        directory: request.directory,
        paths: paths,
        createdAt: DateTime.now(),
        asImage:
            request.offer.items.length == 1 &&
            request.offer.items.single.isImage,
      );
      _cached[sessionId] = cached;
      _cacheTimers.remove(sessionId)?.cancel();
      _cacheTimers[sessionId] = Timer(_cacheTtl, () {
        if (identical(_cached[sessionId], cached)) {
          unawaited(_removeCached(sessionId));
        }
      });
      request.complete(RemoteClipboardPasteResult.prepared);
      traceRemoteClipboard('cache_ready', success: true);
    } catch (error) {
      traceRemoteClipboard(
        'cache_ready',
        success: false,
        reason: error.runtimeType.toString(),
      );
      request.complete(RemoteClipboardPasteResult.failed);
      await request.dispose(deleteDirectory: true);
    }
  }

  Future<void> _handleError(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    final json = _frameJson(frame);
    final sessionId = json['sessionId'];
    final request = sessionId is String ? _incoming[sessionId] : null;
    if (request == null ||
        request.offer.peerId != binding.peerId ||
        request.offer.offerId != frame.transferId) {
      return;
    }
    _incoming.remove(sessionId);
    request.complete(RemoteClipboardPasteResult.failed);
    await request.dispose(deleteDirectory: true);
  }

  Future<void> _sendError(
    TransferConnectionBinding binding,
    String offerId,
    String sessionId,
  ) {
    return _sendFrame(
      binding,
      WhisperFrameV3(
        type: WhisperFrameType.clipboardError,
        transferId: offerId,
        offset: 0,
        sequence: 0,
        payload: _jsonBytes(<String, Object?>{
          'protocolVersion': protocolVersion,
          'sessionId': sessionId,
        }),
      ),
    ).then((_) {});
  }

  List<RemoteClipboardLocalItem>? _validatedLocalItems(
    List<RemoteClipboardLocalItem> items,
  ) {
    if (items.isEmpty || items.length > remoteClipboardMaxItems) {
      return null;
    }
    var total = 0;
    for (final item in items) {
      if (!_isSafeName(item.name) ||
          item.size < 0 ||
          item.size > remoteClipboardMaxFileBytes) {
        return null;
      }
      total += item.size;
      if (total > remoteClipboardMaxBatchBytes) {
        return null;
      }
    }
    return List<RemoteClipboardLocalItem>.unmodifiable(items);
  }

  Future<void> _replaceRemoteOffer(_RemoteOffer offer) async {
    await _removeRemoteOffer(offer.sessionId);
    _remoteOffers[offer.sessionId] = offer;
  }

  Future<void> _removeRemoteOffer(String sessionId) async {
    _remoteOffers.remove(sessionId);
    final request = _incoming.remove(sessionId);
    request?.complete(RemoteClipboardPasteResult.failed);
    await request?.dispose(deleteDirectory: true);
    await _removeCached(sessionId);
  }

  Future<void> _removeCached(String sessionId) async {
    _cacheTimers.remove(sessionId)?.cancel();
    await _cached.remove(sessionId)?.dispose();
  }

  bool ownsClipboardPaths(String sessionId, List<String> paths) {
    final cached = _cached[sessionId];
    if (cached == null || paths.length != cached.paths.length) {
      return false;
    }
    for (var index = 0; index < paths.length; index++) {
      if (p.normalize(paths[index]) != p.normalize(cached.paths[index])) {
        return false;
      }
    }
    return true;
  }

  Future<void> _removeSourceOffer(String sessionId) async {
    _sourceOffers.remove(sessionId);
  }

  Map<String, dynamic> _frameJson(WhisperFrameV3 frame) {
    if (frame.payload.length > 64 * 1024) {
      throw const FormatException('remote clipboard control too large');
    }
    final decoded = jsonDecode(utf8.decode(frame.payload));
    if (decoded is! Map) {
      throw const FormatException('invalid remote clipboard control');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static Uint8List _jsonBytes(Map<String, Object?> value) {
    return Uint8List.fromList(utf8.encode(jsonEncode(value)));
  }

  static bool _isSafeName(String value) {
    return value.isNotEmpty &&
        value.length <= 255 &&
        value != '.' &&
        value != '..' &&
        p.basename(value) == value &&
        !value.contains('\u0000');
  }

  static Future<Directory> _defaultDirectory() async => Directory.systemTemp;
}

final class _SourceOffer {
  const _SourceOffer({
    required this.offerId,
    required this.sessionId,
    required this.peerId,
    required this.items,
  });

  final String offerId;
  final String sessionId;
  final String peerId;
  final List<RemoteClipboardLocalItem> items;
}

final class _RemoteOffer {
  const _RemoteOffer({
    required this.offerId,
    required this.sessionId,
    required this.peerId,
    required this.items,
  });

  final String offerId;
  final String sessionId;
  final String peerId;
  final List<_RemoteItem> items;
  int get totalSize => items.fold<int>(0, (sum, item) => sum + item.size);
}

final class _RemoteItem {
  const _RemoteItem({
    required this.name,
    required this.size,
    required this.isImage,
  });

  final String name;
  final int size;
  final bool isImage;
}

final class _IncomingRequest {
  _IncomingRequest._({
    required this.offer,
    required this.directory,
    required this.paths,
    required this.files,
  });

  static Future<_IncomingRequest> create(
    _RemoteOffer offer,
    Directory directory,
  ) async {
    final paths = <String>[];
    final files = <RandomAccessFile>[];
    final usedNames = <String>{};
    try {
      for (final item in offer.items) {
        final name = _uniqueName(item.name, usedNames);
        final path = p.join(directory.path, name);
        paths.add(path);
        files.add(await File(path).open(mode: FileMode.write));
      }
      return _IncomingRequest._(
        offer: offer,
        directory: directory,
        paths: paths,
        files: files,
      );
    } catch (_) {
      await Future.wait(files.map((file) => file.close().catchError((_) {})));
      rethrow;
    }
  }

  final _RemoteOffer offer;
  final Directory directory;
  final List<String> paths;
  final List<RandomAccessFile> files;
  final Completer<RemoteClipboardPasteResult> completion =
      Completer<RemoteClipboardPasteResult>();
  late final List<int> offsets = List<int>.filled(offer.items.length, 0);
  bool _closed = false;

  Future<void> add(WhisperFrameV3 frame) async {
    final index = frame.sequence;
    if (_closed || index < 0 || index >= offer.items.length) {
      throw const FormatException('invalid remote clipboard item index');
    }
    final expected = offsets[index];
    final item = offer.items[index];
    if (frame.offset != expected ||
        frame.payload.length > item.size - expected) {
      throw const FormatException('invalid remote clipboard offset');
    }
    await files[index].writeFrom(frame.payload);
    offsets[index] += frame.payload.length;
  }

  Future<List<String>> finish() async {
    if (_closed ||
        List<int>.generate(
          offer.items.length,
          (index) => index,
        ).any((index) => offsets[index] != offer.items[index].size)) {
      throw const FormatException('incomplete remote clipboard transfer');
    }
    _closed = true;
    await Future.wait(files.map((file) => file.close()));
    return List<String>.unmodifiable(paths);
  }

  void complete(RemoteClipboardPasteResult result) {
    if (!completion.isCompleted) {
      completion.complete(result);
    }
  }

  Future<void> dispose({required bool deleteDirectory}) async {
    if (!_closed) {
      _closed = true;
      await Future.wait(files.map((file) => file.close().catchError((_) {})));
    }
    if (deleteDirectory && await directory.exists()) {
      await directory.delete(recursive: true).catchError((_) => directory);
    }
  }

  static String _uniqueName(String original, Set<String> used) {
    var candidate = original;
    var suffix = 2;
    final extension = p.extension(original);
    final stem = p.basenameWithoutExtension(original);
    while (!used.add(candidate.toLowerCase())) {
      candidate = '$stem-$suffix$extension';
      suffix++;
    }
    return candidate;
  }
}

final class _CachedPaste {
  const _CachedPaste({
    required this.offerId,
    required this.directory,
    required this.paths,
    required this.createdAt,
    required this.asImage,
  });

  final String offerId;
  final Directory directory;
  final List<String> paths;
  final DateTime createdAt;
  final bool asImage;

  bool isExpired(Duration ttl) => DateTime.now().difference(createdAt) > ttl;

  Future<bool> filesExist() async {
    for (final path in paths) {
      if (!await File(path).exists()) {
        return false;
      }
    }
    return true;
  }

  Future<void> dispose() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true).catchError((_) => directory);
    }
  }
}
