import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:whisper/helper/android_document_picker.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';

enum MediaFileKind { image, video, audio, other }

@immutable
class MediaViewerImage {
  const MediaViewerImage({required this.path, required this.name});

  final String path;
  final String name;
}

const Set<String> _previewableImageMimeTypes = <String>{
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/bmp',
  'image/x-ms-bmp',
  'image/vnd.wap.wbmp',
};

const int _mediaPreviewCacheWidth = 2400;
const int _maxOriginalImageBytes = 128 * 1024 * 1024;
const double _mediaPreviewMinAspectRatio = 9 / 20;
const double _mediaPreviewMaxAspectRatio = 20 / 9;
const double _mediaPreviewMaxHeightFactor = 4 / 3;

bool _isAndroidContentUri(String path) => path.startsWith('content://');

final LinkedHashMap<String, Future<Uint8List>> _mediaThumbnailCache =
    LinkedHashMap<String, Future<Uint8List>>();

Future<Uint8List> _androidMediaThumbnail(
  String uri, {
  required int width,
  required int height,
}) {
  final key = '$uri:$width:$height';
  final cached = _mediaThumbnailCache.remove(key);
  if (cached != null) {
    _mediaThumbnailCache[key] = cached;
    return cached;
  }
  while (_mediaThumbnailCache.length >= 24) {
    _mediaThumbnailCache.remove(_mediaThumbnailCache.keys.first);
  }
  final future = AndroidDocumentPicker.shared
      .loadThumbnail(uri: uri, width: width, height: height)
      .catchError((Object _) => Uint8List(0));
  _mediaThumbnailCache[key] = future;
  return future;
}

Future<Uint8List> _androidFullResolutionImage(String uri) async {
  try {
    final metadata = await AndroidDocumentPicker.shared.metadata(uri);
    final size = metadata?.size ?? -1;
    if (size > 0 && size <= _maxOriginalImageBytes) {
      final bytes = await AndroidDocumentPicker.shared.readBytes(
        uri: uri,
        offset: 0,
        length: size,
      );
      if (bytes.isNotEmpty) {
        return bytes;
      }
    }
  } on Object {
    // Providers may not expose a stable size or seekable descriptor.
  }
  return _androidMediaThumbnail(
    uri,
    width: _mediaPreviewCacheWidth,
    height: _mediaPreviewCacheWidth,
  );
}

Size mediaPreviewSizeFor({
  required double maxWidth,
  required double sourceAspectRatio,
  double? maxHeight,
}) {
  final safeMaxWidth = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 300.0;
  final heightLimit = safeMaxWidth * _mediaPreviewMaxHeightFactor;
  final safeMaxHeight = maxHeight != null && maxHeight.isFinite
      ? math.min(maxHeight, heightLimit)
      : heightLimit;
  final safeAspectRatio = sourceAspectRatio.isFinite && sourceAspectRatio > 0
      ? sourceAspectRatio
      : 4 / 3;
  final displayAspectRatio = safeAspectRatio
      .clamp(_mediaPreviewMinAspectRatio, _mediaPreviewMaxAspectRatio)
      .toDouble();
  var width = safeMaxWidth;
  var height = width / displayAspectRatio;
  if (height > safeMaxHeight) {
    height = safeMaxHeight;
    width = height * displayAspectRatio;
  }
  return Size(width, height);
}

MediaFileKind mediaFileKindFor({required String name, required String path}) {
  final mimeType =
      (name.isEmpty ? null : lookupMimeType(name))?.toLowerCase() ??
      lookupMimeType(path)?.toLowerCase();
  if (_previewableImageMimeTypes.contains(mimeType)) {
    return MediaFileKind.image;
  }
  if (mimeType?.startsWith('video/') == true) {
    return MediaFileKind.video;
  }
  if (mimeType?.startsWith('audio/') == true) {
    return MediaFileKind.audio;
  }
  return MediaFileKind.other;
}

class MediaMessagePreview extends StatelessWidget {
  const MediaMessagePreview({
    super.key,
    required this.kind,
    required this.path,
    required this.name,
    required this.status,
    required this.contentAvailable,
    this.progress,
    this.verifying = false,
    this.failed = false,
    this.onRetry,
    this.onCancel,
  });

  final MediaFileKind kind;
  final String path;
  final String name;
  final String status;
  final bool contentAvailable;
  final double? progress;
  final bool verifying;
  final bool failed;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    if (kind == MediaFileKind.audio) {
      final playable = contentAvailable && progress == null && !failed;
      final phase = playable
          ? 'playable:$path'
          : failed
          ? 'failed'
          : progress != null || verifying
          ? 'transfer'
          : 'unavailable';
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      return AnimatedSwitcher(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: KeyedSubtree(
          key: ValueKey<String>('audio:$phase'),
          child: playable
              ? AudioMessagePlayer(path: path, name: name, status: status)
              : _AudioTransferPreview(
                  name: name,
                  status: status,
                  progress: progress,
                  verifying: verifying,
                  failed: failed,
                  onRetry: onRetry,
                  onCancel: onCancel,
                ),
        ),
      );
    }

    if (kind == MediaFileKind.video) {
      return _VideoAttachmentPreview(
        name: name,
        status: status,
        progress: progress,
        verifying: verifying,
        failed: failed,
        onRetry: onRetry,
        onCancel: onCancel,
      );
    }

    return _VisualMediaPreview(
      kind: kind,
      path: path,
      name: name,
      status: status,
      contentAvailable: contentAvailable,
      progress: progress,
      verifying: verifying,
      failed: failed,
      onRetry: onRetry,
      onCancel: onCancel,
    );
  }
}

class _VisualMediaPreview extends StatelessWidget {
  const _VisualMediaPreview({
    required this.kind,
    required this.path,
    required this.name,
    required this.status,
    required this.contentAvailable,
    required this.progress,
    required this.verifying,
    required this.failed,
    required this.onRetry,
    required this.onCancel,
  });

  final MediaFileKind kind;
  final String path;
  final String name;
  final String status;
  final bool contentAvailable;
  final double? progress;
  final bool verifying;
  final bool failed;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return AnimatedSize(
      duration: duration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Stack(
        children: [
          AnimatedSwitcher(
            duration: duration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: contentAvailable
                ? switch (kind) {
                    MediaFileKind.image => _ImagePreview(
                      key: ValueKey<String>('image:$path'),
                      path: path,
                      name: name,
                    ),
                    _ => const SizedBox.shrink(),
                  }
                : _MediaPlaceholder(
                    key: ValueKey<String>('placeholder:${kind.name}'),
                    kind: kind,
                  ),
          ),
          if (progress != null || failed || verifying)
            Positioned.fill(
              child: _TransferStateOverlay(
                progress: progress ?? 0,
                status: status,
                verifying: verifying,
                failed: failed,
                onRetry: onRetry,
              ),
            ),
          if (onCancel != null)
            Positioned(
              top: 8,
              right: 8,
              child: _OverlayIconButton(
                icon: Icons.close_rounded,
                tooltip: AppLocalizations.of(context)?.cancel ?? '取消',
                onPressed: onCancel!,
              ),
            ),
        ],
      ),
    );
  }
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({super.key, required this.path, required this.name});

  final String path;
  final String name;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Uint8List? _contentUriBytes;
  double? _aspectRatio;

  @override
  void initState() {
    super.initState();
    _loadContentUriThumbnail();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _ImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _contentUriBytes = null;
      _aspectRatio = null;
      _loadContentUriThumbnail();
      if (!_isAndroidContentUri(widget.path)) {
        _resolveImage();
      }
    }
  }

  Future<void> _loadContentUriThumbnail() async {
    if (!_isAndroidContentUri(widget.path)) {
      return;
    }
    final path = widget.path;
    final bytes = await _androidMediaThumbnail(
      path,
      width: _mediaPreviewCacheWidth,
      height: _mediaPreviewCacheWidth,
    );
    if (!mounted || path != widget.path) {
      return;
    }
    setState(() => _contentUriBytes = bytes);
    _resolveImage();
  }

  void _resolveImage() {
    final bytes = _contentUriBytes;
    if (_isAndroidContentUri(widget.path) && (bytes == null || bytes.isEmpty)) {
      return;
    }
    final ImageProvider provider = _isAndroidContentUri(widget.path)
        ? MemoryImage(bytes!)
        : ResizeImage(
            FileImage(File(widget.path)),
            width: _mediaPreviewCacheWidth,
          );
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (_stream?.key == stream.key) {
      return;
    }
    final previousListener = _listener;
    if (previousListener != null) {
      _stream?.removeListener(previousListener);
    }
    _stream = stream;
    final listener = ImageStreamListener((info, synchronousCall) {
      final width = info.image.width;
      final height = info.image.height;
      if (!mounted || width <= 0 || height <= 0) {
        return;
      }
      final ratio = width / height;
      if (_aspectRatio != ratio) {
        if (synchronousCall) {
          _aspectRatio = ratio;
        } else {
          setState(() => _aspectRatio = ratio);
        }
      }
    }, onError: (Object error, StackTrace? stackTrace) {});
    _listener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    final listener = _listener;
    if (listener != null) {
      _stream?.removeListener(listener);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    final bytes = _contentUriBytes;
    final contentUri = _isAndroidContentUri(widget.path);
    final ImageProvider? provider = contentUri
        ? bytes == null || bytes.isEmpty
              ? null
              : MemoryImage(bytes)
        : FileImage(File(widget.path));
    return _AdaptiveVisualMediaFrame(
      frameKey: const ValueKey<String>('image-preview-frame'),
      sourceAspectRatio: _aspectRatio ?? 4 / 3,
      child: ColoredBox(
        color: palette.surfaceMuted,
        child: provider == null
            ? Center(
                child: bytes == null
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : Icon(
                        Icons.broken_image_outlined,
                        color: palette.textMuted,
                        size: 38,
                      ),
              )
            : Image(
                image: provider,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
                semanticLabel: widget.name,
                errorBuilder: (context, error, stackTrace) => Icon(
                  Icons.broken_image_outlined,
                  color: palette.textMuted,
                  size: 38,
                ),
              ),
      ),
    );
  }
}

class _AdaptiveVisualMediaFrame extends StatelessWidget {
  const _AdaptiveVisualMediaFrame({
    required this.frameKey,
    required this.sourceAspectRatio,
    required this.child,
  });

  final Key frameKey;
  final double sourceAspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : 300.0;
        final size = mediaPreviewSizeFor(
          maxWidth: maxWidth,
          sourceAspectRatio: sourceAspectRatio,
          maxHeight: constraints.hasBoundedHeight
              ? constraints.maxHeight
              : null,
        );
        return SizedBox(
          key: frameKey,
          width: size.width,
          height: size.height,
          child: child,
        );
      },
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({super.key, required this.kind});

  final MediaFileKind kind;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    final icon = kind == MediaFileKind.video
        ? Icons.movie_outlined
        : Icons.image_outlined;
    return AspectRatio(
      aspectRatio: kind == MediaFileKind.video ? 16 / 9 : 4 / 3,
      child: ColoredBox(
        color: palette.surfaceMuted,
        child: Center(child: Icon(icon, size: 40, color: palette.textMuted)),
      ),
    );
  }
}

class _TransferStateOverlay extends StatelessWidget {
  const _TransferStateOverlay({
    required this.progress,
    required this.status,
    required this.verifying,
    required this.failed,
    required this.onRetry,
  });

  final double progress;
  final String status;
  final bool verifying;
  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    final progressValue = progress.clamp(0, 1).toDouble();
    final displayStatus = _visualTransferStatusLabel(status);
    return Semantics(
      liveRegion: true,
      label: displayStatus,
      value: verifying ? displayStatus : '${(progressValue * 100).round()}%',
      child: ColoredBox(
        key: const ValueKey<String>('visual-transfer-overlay'),
        color: Colors.black.withValues(alpha: 0.28),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failed)
                IconButton(
                  key: const ValueKey<String>('visual-transfer-retry'),
                  tooltip: AppLocalizations.of(context)?.retry ?? '重试',
                  onPressed: onRetry,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.42),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 26),
                )
              else
                SizedBox.square(
                  key: const ValueKey<String>('visual-transfer-progress'),
                  dimension: 52,
                  child: CircularProgressIndicator(
                    value: verifying ? null : progressValue,
                    strokeWidth: 3.2,
                    color: Colors.white,
                    backgroundColor: Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Text(
                  displayStatus,
                  key: const ValueKey<String>('visual-transfer-status'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: failed ? palette.danger : Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    shadows: const [
                      Shadow(
                        color: Color(0x99000000),
                        blurRadius: 5,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _visualTransferStatusLabel(String status) {
  final trimmed = status.trim();
  final progressMatch = RegExp(r'(\d{1,3})%$').firstMatch(trimmed);
  return progressMatch?.group(0) ?? trimmed;
}

class _OverlayIconButton extends StatelessWidget {
  const _OverlayIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey<String>('visual-transfer-cancel'),
      tooltip: tooltip,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.46),
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
    );
  }
}

class _VideoAttachmentPreview extends StatelessWidget {
  const _VideoAttachmentPreview({
    required this.name,
    required this.status,
    required this.progress,
    required this.verifying,
    required this.failed,
    required this.onRetry,
    required this.onCancel,
  });

  final String name;
  final String status;
  final double? progress;
  final bool verifying;
  final bool failed;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final transferring = progress != null || verifying;
    return SizedBox(
      key: const ValueKey<String>('video-message-card'),
      width: 248,
      height: 72,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            SizedBox.square(
              key: const ValueKey<String>('video-message-action'),
              dimension: 42,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: failed
                    ? IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: AppLocalizations.of(context)?.retry ?? '重试',
                        onPressed: onRetry,
                        icon: Icon(
                          Icons.refresh_rounded,
                          color: palette.danger,
                          size: 22,
                        ),
                      )
                    : transferring
                    ? Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox.square(
                            dimension: 29,
                            child: CircularProgressIndicator(
                              value: verifying ? null : progress?.clamp(0, 1),
                              strokeWidth: 2.4,
                              color: colorScheme.primary,
                              backgroundColor: colorScheme.primary.withValues(
                                alpha: 0.14,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.movie_outlined,
                            color: colorScheme.primary,
                            size: 16,
                          ),
                        ],
                      )
                    : Icon(
                        Icons.play_arrow_rounded,
                        color: colorScheme.primary,
                        size: 27,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    key: const ValueKey<String>('video-message-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    status,
                    key: const ValueKey<String>('video-message-meta'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: failed
                          ? palette.danger
                          : colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            if (onCancel != null)
              IconButton(
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                tooltip: AppLocalizations.of(context)?.cancel ?? '取消',
                onPressed: onCancel,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

class _AudioTransferPreview extends StatelessWidget {
  const _AudioTransferPreview({
    required this.name,
    required this.status,
    required this.progress,
    required this.verifying,
    required this.failed,
    required this.onRetry,
    required this.onCancel,
  });

  final String name;
  final String status;
  final double? progress;
  final bool verifying;
  final bool failed;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final unavailable =
        progress == null && !verifying && !failed && onCancel == null;
    final indicator = SizedBox.square(
      key: const ValueKey<String>('audio-message-action'),
      dimension: 42,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.primary.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: failed
            ? IconButton(
                padding: EdgeInsets.zero,
                tooltip: AppLocalizations.of(context)?.retry ?? '重试',
                onPressed: onRetry,
                icon: Icon(
                  Icons.refresh_rounded,
                  color: palette.danger,
                  size: 22,
                ),
              )
            : unavailable
            ? Icon(
                Icons.play_arrow_rounded,
                color: colorScheme.onSurfaceVariant,
                size: 25,
              )
            : Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.square(
                    dimension: 28,
                    child: CircularProgressIndicator(
                      value: verifying ? null : progress?.clamp(0, 1),
                      strokeWidth: 2.5,
                      color: colorScheme.primary,
                      backgroundColor: colorScheme.primary.withValues(
                        alpha: 0.14,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.music_note_rounded,
                    color: colorScheme.primary,
                    size: 16,
                  ),
                ],
              ),
      ),
    );
    return SizedBox(
      key: const ValueKey<String>('audio-message-card'),
      width: 240,
      height: 72,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            indicator,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    key: const ValueKey<String>('audio-message-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    status,
                    key: const ValueKey<String>('audio-message-meta'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: failed
                          ? palette.danger
                          : colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            if (onCancel != null)
              IconButton(
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                tooltip: AppLocalizations.of(context)?.cancel ?? '取消',
                onPressed: onCancel,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

String audioMessageMetaFor({
  required String status,
  required Duration duration,
}) {
  final values = <String>[
    if (status.trim().isNotEmpty) status.trim(),
    if (duration > Duration.zero) _formatDuration(duration),
  ];
  return values.join(' · ');
}

final LinkedHashMap<String, Future<Duration>> _audioDurationCache =
    LinkedHashMap<String, Future<Duration>>();
final LinkedHashSet<String> _pendingAudioDurationKeys = LinkedHashSet<String>();
Future<void> _audioDurationQueue = Future<void>.value();

Future<Duration> _cachedAudioDuration(String path) {
  try {
    final stat = File(path).statSync();
    if (stat.type != FileSystemEntityType.file) {
      return Future<Duration>.value(Duration.zero);
    }
    final key = '$path:${stat.size}:${stat.modified.millisecondsSinceEpoch}';
    final cached = _audioDurationCache.remove(key);
    if (cached != null) {
      _audioDurationCache[key] = cached;
      return cached;
    }
    while (_audioDurationCache.length >= 48) {
      final evicted = _audioDurationCache.keys.first;
      _audioDurationCache.remove(evicted);
      _pendingAudioDurationKeys.remove(evicted);
    }
    while (_pendingAudioDurationKeys.length >= 8) {
      final evicted = _pendingAudioDurationKeys.first;
      _pendingAudioDurationKeys.remove(evicted);
      _audioDurationCache.remove(evicted);
    }
    late final Future<Duration> duration;
    duration = _audioDurationQueue.then((_) async {
      if (!_audioDurationCache.containsKey(key)) {
        return Duration.zero;
      }
      try {
        return await _extractAudioDuration(path);
      } catch (_) {
        return Duration.zero;
      }
    });
    _audioDurationQueue = duration.then<void>((_) {});
    _audioDurationCache[key] = duration;
    _pendingAudioDurationKeys.add(key);
    unawaited(
      duration.then((_) {
        _pendingAudioDurationKeys.remove(key);
      }),
    );
    return duration;
  } catch (_) {
    return Future<Duration>.value(Duration.zero);
  }
}

Future<Duration> _extractAudioDuration(String path) async {
  final player = AudioPlayer();
  try {
    await player.setSource(_audioSourceFor(path));
    return await player.getDuration() ?? Duration.zero;
  } finally {
    await player.dispose();
  }
}

Source _audioSourceFor(String path) =>
    _isAndroidContentUri(path) ? UrlSource(path) : DeviceFileSource(path);

class AudioMessagePlayer extends StatefulWidget {
  const AudioMessagePlayer({
    super.key,
    required this.path,
    required this.name,
    this.status = '',
    this.compact = true,
  });

  final String path;
  final String name;
  final String status;
  final bool compact;

  @override
  State<AudioMessagePlayer> createState() => _AudioMessagePlayerState();
}

class _AudioMessagePlayerState extends State<AudioMessagePlayer> {
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      _cachedAudioDuration(widget.path).then((duration) {
        if (mounted && duration > Duration.zero && _duration == Duration.zero) {
          setState(() => _duration = duration);
        }
      }),
    );
  }

  Future<void> _togglePlayback() async {
    if (_loading) {
      return;
    }
    var player = _player;
    if (player == null) {
      setState(() {
        _loading = true;
        _failed = false;
      });
      final attemptSubscriptions = <StreamSubscription<dynamic>>[];
      try {
        player = AudioPlayer();
        _player = player;
        attemptSubscriptions.addAll([
          player.onPlayerStateChanged.listen((value) {
            if (mounted) {
              setState(() => _playing = value == PlayerState.playing);
            }
          }),
          player.onPositionChanged.listen((value) {
            if (mounted) setState(() => _position = value);
          }),
          player.onDurationChanged.listen((value) {
            if (mounted) setState(() => _duration = value);
          }),
          player.onPlayerComplete.listen((_) {
            if (mounted) {
              setState(() {
                _playing = false;
                _position = Duration.zero;
              });
            }
          }),
        ]);
        _subscriptions.addAll(attemptSubscriptions);
        await player.play(_audioSourceFor(widget.path));
        final duration = await player.getDuration();
        if (mounted && duration != null && duration > Duration.zero) {
          setState(() => _duration = duration);
        }
      } catch (_) {
        for (final subscription in attemptSubscriptions) {
          await subscription.cancel();
          _subscriptions.remove(subscription);
        }
        if (player != null) {
          await player.dispose();
        }
        _player = null;
        if (mounted) setState(() => _failed = true);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
      return;
    }
    if (_playing) {
      await player.pause();
    } else if (player.state == PlayerState.completed) {
      await player.play(_audioSourceFor(widget.path));
    } else {
      await player.resume();
    }
  }

  Future<void> _seekToFraction(double fraction) async {
    if (_duration == Duration.zero) {
      return;
    }
    await _player?.seek(
      Duration(milliseconds: (_duration.inMilliseconds * fraction).round()),
    );
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    final player = _player;
    if (player != null) {
      unawaited(player.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact) {
      return _buildCompactAudioCard(context);
    }
    return _buildDetailedPlayer(context);
  }

  String _playbackTooltip(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _failed
        ? (l10n?.retry ?? '重试')
        : _playing
        ? (l10n?.mediaActionPause ?? '暂停')
        : (l10n?.mediaActionPlay ?? '播放');
  }

  Widget _buildCompactAudioCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final metadata = audioMessageMetaFor(
      status: widget.status,
      duration: _duration,
    );
    final action = _loading
        ? const SizedBox.square(
            key: ValueKey<String>('audio-message-loading'),
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : _failed
        ? Icon(
            Icons.refresh_rounded,
            key: const ValueKey<String>('audio-message-retry'),
            color: colorScheme.error,
            size: 24,
          )
        : Icon(
            _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            key: const ValueKey<String>('audio-message-playback-icon'),
            color: colorScheme.primary,
            size: 26,
          );
    return SizedBox(
      key: const ValueKey<String>('audio-message-card'),
      width: 240,
      height: 72,
      child: Tooltip(
        message: _playbackTooltip(context),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _togglePlayback,
            child: Semantics(
              button: true,
              label: '${widget.name}, $metadata',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    SizedBox.square(
                      key: const ValueKey<String>('audio-message-action'),
                      dimension: 42,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Center(child: action),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.name,
                            key: const ValueKey<String>('audio-message-name'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colorScheme.onSurface,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            metadata,
                            key: const ValueKey<String>('audio-message-meta'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 12,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailedPlayer(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final progress = _duration.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / _duration.inMilliseconds)
              .clamp(0, 1)
              .toDouble();
    final timeline = _duration > Duration.zero
        ? '${_formatDuration(_position)} / ${_formatDuration(_duration)}'
        : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 10),
      child: Row(
        children: [
          IconButton.filledTonal(
            tooltip: _playbackTooltip(context),
            onPressed: _togglePlayback,
            icon: _loading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    _failed
                        ? Icons.refresh_rounded
                        : _playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                _WaveformScrubber(
                  progress: progress,
                  enabled: _duration > Duration.zero,
                  onSeek: _seekToFraction,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (timeline.isNotEmpty)
                      Text(
                        timeline,
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    if (timeline.isNotEmpty && widget.status.isNotEmpty)
                      const Spacer(),
                    if (widget.status.isNotEmpty)
                      Flexible(
                        child: Text(
                          widget.status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformScrubber extends StatelessWidget {
  const _WaveformScrubber({
    required this.progress,
    required this.enabled,
    required this.onSeek,
  });

  final double progress;
  final bool enabled;
  final ValueChanged<double> onSeek;

  void _handlePosition(Offset localPosition, double width) {
    if (!enabled || width <= 0) {
      return;
    }
    onSeek((localPosition.dx / width).clamp(0, 1));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Semantics(
          slider: true,
          enabled: enabled,
          value: '${(progress * 100).round()}%',
          onIncrease: enabled
              ? () => onSeek((progress + 0.05).clamp(0, 1).toDouble())
              : null,
          onDecrease: enabled
              ? () => onSeek((progress - 0.05).clamp(0, 1).toDouble())
              : null,
          child: MouseRegion(
            cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) =>
                  _handlePosition(details.localPosition, width),
              onHorizontalDragUpdate: (details) =>
                  _handlePosition(details.localPosition, width),
              child: SizedBox(
                height: 24,
                width: double.infinity,
                child: CustomPaint(
                  painter: _WaveformPainter(
                    progress: progress,
                    activeColor: colorScheme.primary,
                    inactiveColor: palette.textMuted.withValues(alpha: 0.34),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  static const _pattern = <double>[
    0.34,
    0.62,
    0.46,
    0.82,
    0.54,
    1,
    0.68,
    0.42,
    0.76,
    0.5,
    0.9,
    0.58,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final count = math.max(12, (size.width / 5).floor());
    final gap = size.width / count;
    final barWidth = math.min(2.6, gap * 0.52);
    final activeX = size.width * progress.clamp(0, 1);
    for (var i = 0; i < count; i++) {
      final x = (i + 0.5) * gap;
      final height = 5 + (size.height - 5) * _pattern[i % _pattern.length];
      final paint = Paint()
        ..color = x <= activeX ? activeColor : inactiveColor
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return progress != oldDelegate.progress ||
        activeColor != oldDelegate.activeColor ||
        inactiveColor != oldDelegate.inactiveColor;
  }
}

String _formatDuration(Duration value) {
  if (value.inHours > 0) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${value.inHours}:$minutes:$seconds';
  }
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

Future<void> showMediaViewer(
  BuildContext context, {
  required MediaFileKind kind,
  required String path,
  required String name,
  required VoidCallback onOpenExternally,
  List<MediaViewerImage>? imageGallery,
  int initialImageIndex = 0,
}) {
  if (kind == MediaFileKind.video) {
    onOpenExternally();
    return Future<void>.value();
  }
  final resolvedImageGallery = kind == MediaFileKind.image
      ? List<MediaViewerImage>.unmodifiable(
          imageGallery?.isNotEmpty == true
              ? imageGallery!
              : <MediaViewerImage>[MediaViewerImage(path: path, name: name)],
        )
      : const <MediaViewerImage>[];
  final resolvedInitialImageIndex = resolvedImageGallery.isEmpty
      ? 0
      : initialImageIndex.clamp(0, resolvedImageGallery.length - 1);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocalizations.of(context)?.close ?? '关闭',
    barrierColor: Colors.black,
    transitionDuration: const Duration(milliseconds: 180),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (context, animation, secondaryAnimation) =>
        _FullscreenMediaViewer(
          kind: kind,
          path: path,
          name: name,
          imageGallery: resolvedImageGallery,
          initialImageIndex: resolvedInitialImageIndex,
        ),
  );
}

class _FullscreenMediaViewer extends StatefulWidget {
  const _FullscreenMediaViewer({
    required this.kind,
    required this.path,
    required this.name,
    required this.imageGallery,
    required this.initialImageIndex,
  });

  final MediaFileKind kind;
  final String path;
  final String name;
  final List<MediaViewerImage> imageGallery;
  final int initialImageIndex;

  @override
  State<_FullscreenMediaViewer> createState() => _FullscreenMediaViewerState();
}

class _FullscreenMediaViewerState extends State<_FullscreenMediaViewer> {
  late final PageController _imagePageController;
  final Set<int> _zoomedImages = <int>{};
  late int _currentImageIndex;

  bool get _usesImmersiveMode =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  bool get _hasMultipleImages =>
      widget.kind == MediaFileKind.image && widget.imageGallery.length > 1;

  @override
  void initState() {
    super.initState();
    _currentImageIndex = widget.initialImageIndex;
    _imagePageController = PageController(initialPage: _currentImageIndex);
    if (_usesImmersiveMode) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
    }
  }

  @override
  void dispose() {
    _imagePageController.dispose();
    if (_usesImmersiveMode) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).pop();
    final safeTop = MediaQuery.viewPaddingOf(context).top;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): close,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _changeImage(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _changeImage(1),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildContent(context),
              Positioned(
                top: math.max(12, safeTop + 8),
                right: 14,
                child: IconButton(
                  key: const ValueKey<String>('media-viewer-close'),
                  tooltip: AppLocalizations.of(context)?.close ?? '关闭',
                  onPressed: close,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.46),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _changeImage(int offset) {
    if (!_hasMultipleImages || !_imagePageController.hasClients) {
      return;
    }
    final index = _currentImageIndex + offset;
    if (index < 0 || index >= widget.imageGallery.length) {
      return;
    }
    _imagePageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutQuart,
    );
  }

  Widget _buildContent(BuildContext context) => switch (widget.kind) {
    MediaFileKind.image => PageView.builder(
      key: const ValueKey<String>('media-viewer-gallery'),
      controller: _imagePageController,
      itemCount: widget.imageGallery.length,
      allowImplicitScrolling: true,
      physics: _zoomedImages.contains(_currentImageIndex)
          ? const NeverScrollableScrollPhysics()
          : const BouncingScrollPhysics(),
      onPageChanged: (index) => setState(() => _currentImageIndex = index),
      itemBuilder: (context, index) => _buildImagePage(index),
    ),
    MediaFileKind.video => const SizedBox.shrink(),
    MediaFileKind.audio => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: AudioMessagePlayer(
          path: widget.path,
          name: widget.name,
          compact: false,
        ),
      ),
    ),
    MediaFileKind.other => const SizedBox.shrink(),
  };

  Widget _buildImagePage(int index) {
    final image = widget.imageGallery[index];
    return RepaintBoundary(
      child: _FullscreenImage(
        path: image.path,
        name: image.name,
        onZoomChanged: (zoomed) => _handleImageZoomChanged(index, zoomed),
      ),
    );
  }

  void _handleImageZoomChanged(int index, bool zoomed) {
    final changed = zoomed
        ? _zoomedImages.add(index)
        : _zoomedImages.remove(index);
    if (changed && index == _currentImageIndex) {
      setState(() {});
    }
  }
}

class _FullscreenImage extends StatefulWidget {
  const _FullscreenImage({
    required this.path,
    required this.name,
    required this.onZoomChanged,
  });

  final String path;
  final String name;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_FullscreenImage> createState() => _FullscreenImageState();
}

class _FullscreenImageState extends State<_FullscreenImage> {
  Future<Uint8List>? _contentUriBytes;
  final TransformationController _transformationController =
      TransformationController();
  Offset? _doubleTapPosition;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(_handleTransformationChanged);
    if (_isAndroidContentUri(widget.path)) {
      _contentUriBytes = _androidFullResolutionImage(widget.path);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onZoomChanged(false);
      }
    });
  }

  @override
  void dispose() {
    _transformationController.removeListener(_handleTransformationChanged);
    _transformationController.dispose();
    super.dispose();
  }

  void _handleTransformationChanged() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (_zoomed == zoomed) {
      return;
    }
    setState(() => _zoomed = zoomed);
    widget.onZoomChanged(zoomed);
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapPosition = details.localPosition;
  }

  void _handleDoubleTap() {
    _transformationController.value = _zoomed
        ? Matrix4.identity()
        : _zoomMatrixAt(_doubleTapPosition ?? Offset.zero);
  }

  Matrix4 _zoomMatrixAt(Offset position) {
    const scale = 2.5;
    return Matrix4.identity()
      ..translate(-position.dx * (scale - 1), -position.dy * (scale - 1))
      ..scale(scale);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAndroidContentUri(widget.path)) {
      return _buildViewer(
        Image.file(
          File(widget.path),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          semanticLabel: widget.name,
        ),
      );
    }
    return FutureBuilder<Uint8List>(
      future: _contentUriBytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        if (bytes.isEmpty) {
          return const Center(
            child: Icon(
              Icons.broken_image_outlined,
              color: Colors.white70,
              size: 48,
            ),
          );
        }
        return _buildViewer(
          Image.memory(
            bytes,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            semanticLabel: widget.name,
          ),
        );
      },
    );
  }

  Widget _buildViewer(Widget image) {
    return GestureDetector(
      key: const ValueKey<String>('fullscreen-image-interaction'),
      behavior: HitTestBehavior.opaque,
      onDoubleTapDown: _handleDoubleTapDown,
      onDoubleTap: _handleDoubleTap,
      child: IgnorePointer(
        key: const ValueKey<String>('fullscreen-image-gesture-gate'),
        ignoring: !_zoomed,
        child: InteractiveViewer(
          key: const ValueKey<String>('fullscreen-image-viewer'),
          transformationController: _transformationController,
          minScale: 1,
          maxScale: 5,
          child: SizedBox.expand(child: image),
        ),
      ),
    );
  }
}
