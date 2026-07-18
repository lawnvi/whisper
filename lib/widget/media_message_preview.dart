import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mime/mime.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';

enum MediaFileKind { image, video, audio, other }

const Set<String> _previewableImageMimeTypes = <String>{
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/bmp',
  'image/x-ms-bmp',
  'image/vnd.wap.wbmp',
};

const int _mediaPreviewCacheWidth = 1200;
const double _mediaPreviewMinAspectRatio = 9 / 20;
const double _mediaPreviewMaxAspectRatio = 20 / 9;
const double _mediaPreviewMaxHeightFactor = 4 / 3;

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
                    MediaFileKind.video => _VideoPreview(
                      key: ValueKey<String>('video:$path'),
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
          if (progress == null && !failed && !verifying)
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: _MediaStatusPill(text: status),
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
  double? _aspectRatio;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _ImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _aspectRatio = null;
      _resolveImage();
    }
  }

  void _resolveImage() {
    final provider = ResizeImage(
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
    return _AdaptiveVisualMediaFrame(
      frameKey: const ValueKey<String>('image-preview-frame'),
      sourceAspectRatio: _aspectRatio ?? 4 / 3,
      child: ColoredBox(
        color: palette.surfaceMuted,
        child: Image.file(
          File(widget.path),
          cacheWidth: _mediaPreviewCacheWidth,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
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

class _VideoPreviewData {
  const _VideoPreviewData({
    required this.bytes,
    required this.duration,
    required this.aspectRatio,
  });

  final Uint8List? bytes;
  final Duration duration;
  final double aspectRatio;
}

final LinkedHashMap<String, Future<_VideoPreviewData?>> _videoPreviewCache =
    LinkedHashMap<String, Future<_VideoPreviewData?>>();
final LinkedHashSet<String> _pendingVideoPreviewKeys = LinkedHashSet<String>();
Future<void> _videoPreviewQueue = Future<void>.value();

Future<_VideoPreviewData?> _cachedVideoPreview(String path) {
  try {
    final stat = File(path).statSync();
    final key = '$path:${stat.size}:${stat.modified.millisecondsSinceEpoch}';
    final cached = _videoPreviewCache.remove(key);
    if (cached != null) {
      _videoPreviewCache[key] = cached;
      return cached;
    }
    while (_videoPreviewCache.length >= 24) {
      final evicted = _videoPreviewCache.keys.first;
      _videoPreviewCache.remove(evicted);
      _pendingVideoPreviewKeys.remove(evicted);
    }
    while (_pendingVideoPreviewKeys.length >= 6) {
      final evicted = _pendingVideoPreviewKeys.first;
      _pendingVideoPreviewKeys.remove(evicted);
      _videoPreviewCache.remove(evicted);
    }
    late final Future<_VideoPreviewData?> preview;
    preview = _videoPreviewQueue.then((_) async {
      if (!_videoPreviewCache.containsKey(key)) {
        return null;
      }
      try {
        return await _extractVideoPreview(path);
      } catch (_) {
        return null;
      }
    });
    _videoPreviewQueue = preview.then<void>((_) {});
    _videoPreviewCache[key] = preview;
    _pendingVideoPreviewKeys.add(key);
    unawaited(
      preview.then((value) {
        _pendingVideoPreviewKeys.remove(key);
        if (value == null && identical(_videoPreviewCache[key], preview)) {
          _videoPreviewCache.remove(key);
        }
      }),
    );
    return preview;
  } catch (_) {
    return Future<_VideoPreviewData?>.value();
  }
}

Future<_VideoPreviewData?> _extractVideoPreview(String path) async {
  MediaKit.ensureInitialized();
  final player = Player(configuration: const PlayerConfiguration(muted: true));
  final controller = VideoController(
    player,
    configuration: const VideoControllerConfiguration(width: 480),
  );
  try {
    // A paused player can expose metadata before it has decoded a frame. Start
    // muted, wait for the video output, then pause before taking the snapshot.
    await player.open(Media(Uri.file(path).toString()), play: true);
    var duration = player.state.duration;
    if (duration == Duration.zero) {
      try {
        duration = await player.stream.duration
            .firstWhere((value) => value > Duration.zero)
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        duration = player.state.duration;
      }
    }
    final seekMs = math.min(1000, math.max(0, duration.inMilliseconds ~/ 5));
    if (seekMs > 0) {
      await player.seek(Duration(milliseconds: seekMs));
    }
    try {
      await controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 3),
      );
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 240));
    }
    await player.pause();
    final width = player.state.width;
    final height = player.state.height;
    final videoParamsAspectRatio = player.state.videoParams.aspect;
    final aspectRatio = width != null && height != null && height > 0
        ? width / height
        : videoParamsAspectRatio != null && videoParamsAspectRatio > 0
        ? videoParamsAspectRatio
        : 16 / 9;

    Uint8List? bytes;
    for (var attempt = 0; attempt < 4; attempt++) {
      bytes = await player.screenshot(format: 'image/jpeg');
      if (bytes?.isNotEmpty == true) {
        break;
      }
      await player.play();
      await Future<void>.delayed(const Duration(milliseconds: 160));
      await player.pause();
    }
    if (bytes == null || bytes.isEmpty) {
      return duration > Duration.zero
          ? _VideoPreviewData(
              bytes: null,
              duration: duration,
              aspectRatio: aspectRatio,
            )
          : null;
    }
    return _VideoPreviewData(
      bytes: bytes,
      duration: duration,
      aspectRatio: aspectRatio,
    );
  } finally {
    await player.dispose();
  }
}

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({super.key, required this.path, required this.name});

  final String path;
  final String name;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  late Future<_VideoPreviewData?> _preview;

  @override
  void initState() {
    super.initState();
    _preview = _cachedVideoPreview(widget.path);
  }

  @override
  void didUpdateWidget(covariant _VideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _preview = _cachedVideoPreview(widget.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: widget.name,
      button: true,
      child: FutureBuilder<_VideoPreviewData?>(
        future: _preview,
        builder: (context, snapshot) {
          final preview = snapshot.data;
          final thumbnailBytes = preview?.bytes;
          return _AdaptiveVisualMediaFrame(
            frameKey: const ValueKey<String>('video-preview-frame'),
            sourceAspectRatio: preview?.aspectRatio ?? 16 / 9,
            child: ColoredBox(
              color: palette.surfaceMuted,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedSwitcher(
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: thumbnailBytes != null
                        ? Image.memory(
                            thumbnailBytes,
                            key: ValueKey<String>('thumbnail:${widget.path}'),
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.medium,
                            gaplessPlayback: true,
                          )
                        : Icon(
                            Icons.movie_outlined,
                            key: const ValueKey<String>('video-placeholder'),
                            color: palette.textMuted,
                            size: 40,
                          ),
                  ),
                  Center(
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.68),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.34),
                        ),
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        size: 32,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  if (preview != null && preview.duration > Duration.zero)
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: _MediaStatusPill(
                        text: _formatDuration(preview.duration),
                        dark: true,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
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

class _MediaStatusPill extends StatelessWidget {
  const _MediaStatusPill({required this.text, this.dark = false});

  final String text;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return Container(
      constraints: const BoxConstraints(maxWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: dark
            ? Colors.black.withValues(alpha: 0.68)
            : Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.2)
              : palette.borderSubtle,
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: dark ? Colors.white : palette.textMuted,
          fontSize: 11,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
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
  return status.trim().replaceFirstMapped(
    RegExp(r'\s+(\d{1,3})%$'),
    (match) => ' · ${match.group(1)}%',
  );
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
  MediaKit.ensureInitialized();
  final player = Player();
  try {
    await player.open(Media(Uri.file(path).toString()), play: false);
    var duration = player.state.duration;
    if (duration == Duration.zero) {
      try {
        duration = await player.stream.duration
            .firstWhere((value) => value > Duration.zero)
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        duration = player.state.duration;
      }
    }
    return duration;
  } finally {
    await player.dispose();
  }
}

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
  Player? _player;
  final List<StreamSubscription<Object?>> _subscriptions = [];
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
      final attemptSubscriptions = <StreamSubscription<Object?>>[];
      try {
        MediaKit.ensureInitialized();
        player = Player();
        _player = player;
        attemptSubscriptions.addAll([
          player.stream.playing.listen((value) {
            if (mounted) setState(() => _playing = value);
          }),
          player.stream.position.listen((value) {
            if (mounted) setState(() => _position = value);
          }),
          player.stream.duration.listen((value) {
            if (mounted) setState(() => _duration = value);
          }),
          player.stream.completed.listen((completed) {
            if (completed && mounted) {
              setState(() {
                _playing = false;
                _position = Duration.zero;
              });
            }
          }),
        ]);
        _subscriptions.addAll(attemptSubscriptions);
        await player.open(Media(Uri.file(widget.path).toString()), play: true);
        final duration = player.state.duration;
        if (mounted && duration > Duration.zero) {
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
    await player.playOrPause();
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
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (context) => _MediaViewerPage(
        kind: kind,
        path: path,
        name: name,
        onOpenExternally: onOpenExternally,
      ),
    ),
  );
}

class _MediaViewerPage extends StatelessWidget {
  const _MediaViewerPage({
    required this.kind,
    required this.path,
    required this.name,
    required this.onOpenExternally,
  });

  final MediaFileKind kind;
  final String path;
  final String name;
  final VoidCallback onOpenExternally;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: IconButton(
          tooltip: AppLocalizations.of(context)?.close ?? '关闭',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
        actions: [
          IconButton(
            tooltip: AppLocalizations.of(context)?.open ?? '打开',
            onPressed: onOpenExternally,
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: switch (kind) {
          MediaFileKind.image => Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Image.file(File(path), fit: BoxFit.contain),
            ),
          ),
          MediaFileKind.video => _VideoPlayer(path: path),
          MediaFileKind.audio => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: AudioMessagePlayer(path: path, name: name, compact: false),
            ),
          ),
          MediaFileKind.other => const SizedBox.shrink(),
        },
      ),
    );
  }
}

class _VideoPlayer extends StatefulWidget {
  const _VideoPlayer({required this.path});

  final String path;

  @override
  State<_VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<_VideoPlayer> {
  late final Player _player;
  late final VideoController _controller;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    _player = Player();
    _controller = VideoController(_player);
    unawaited(
      _player.open(Media(Uri.file(widget.path).toString()), play: true),
    );
  }

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Video(
        controller: _controller,
        fit: BoxFit.contain,
        fill: Colors.black,
      ),
    );
  }
}
