import 'package:whisper/theme/whisper_ui.dart';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:whisper/helper/android_document_picker.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart' show showPhoneSheet;
import 'package:whisper/new_ui/picker/quick_send_sheet.dart';

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/helper/helper.dart' show formatSize;
import 'package:whisper/helper/memory_bounded_image.dart';
import 'package:whisper/helper/video_thumbnail.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/widget/media_message_preview.dart'
    show MediaFileKind, mediaFileKindFor;

/// One piece of content waiting in quick send: a text or a file.
class QuickSendItem {
  const QuickSendItem.text(this.text)
    : name = '',
      source = '',
      mimeType = '',
      size = null;

  const QuickSendItem.file({
    required this.name,
    required this.source,
    this.mimeType = '',
    this.size,
  }) : text = '';

  final String text;
  final String name;

  /// A local path, or an Android `content://` uri.
  final String source;
  final String mimeType;
  final int? size;

  bool get isText => text.isNotEmpty;

  MediaFileKind get kind {
    final type = mimeType.toLowerCase();
    if (type.startsWith('image/')) {
      return MediaFileKind.image;
    }
    if (type.startsWith('video/')) {
      return MediaFileKind.video;
    }
    return mediaFileKindFor(name: name, path: source);
  }

  bool get isVisualMedia =>
      kind == MediaFileKind.image || kind == MediaFileKind.video;
}

/// A connected, trusted device quick send can deliver to.
/// Quick send only offers devices that are connected and trusted, by name.
List<QuickSendTarget> connectedQuickSendTargets({
  required Iterable<DeviceData> devices,
  required bool Function(String peerId) isConnected,
  required String? Function(String peerId) trustedIdentityHashFor,
}) {
  final targetsById = <String, QuickSendTarget>{};
  for (final candidate in devices) {
    if (!isConnected(candidate.uid) ||
        trustedIdentityHashFor(candidate.uid) == null) {
      continue;
    }
    targetsById[candidate.uid] = QuickSendTarget(
      id: candidate.uid,
      name: candidate.name,
      platform: candidate.platform,
    );
  }
  final targets = targetsById.values.toList()
    ..sort((left, right) => left.name.compareTo(right.name));
  return List<QuickSendTarget>.unmodifiable(targets);
}

class QuickSendTarget {
  const QuickSendTarget({
    required this.id,
    required this.name,
    this.platform = '',
  });

  final String id;
  final String name;
  final String platform;
}

enum QuickSendChooserLayout { sheet, dialog }

/// Shows quick send as a bottom sheet; resolves to the chosen device id, or
/// null when the user leaves the content for later.
Future<String?> showQuickSendSheet(
  BuildContext context, {
  required List<QuickSendItem> items,
  required ValueListenable<List<QuickSendTarget>> targets,
  String? initialTargetId,
}) {
  return showPhoneSheet<String>(
    context,
    builder: (context) => QuickSendPicker(
      touch: true,
      items: items,
      targets: targets,
      initialTargetId: initialTargetId,
    ),
  );
}

/// Text, photo and file previews for content waiting in quick send.
class QuickSendContentPreview extends StatelessWidget {
  const QuickSendContentPreview({super.key, required this.items});

  static const int maxFileRows = 3;

  final List<QuickSendItem> items;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.wc;
    final text = items
        .where((item) => item.isText)
        .map((item) => item.text.trim())
        .where((value) => value.isNotEmpty)
        .join('\n');
    final files = items.where((item) => !item.isText).toList(growable: false);
    final media = files
        .where((item) => item.isVisualMedia)
        .toList(growable: false);
    final others = files
        .where((item) => !item.isVisualMedia)
        .toList(growable: false);
    final children = <Widget>[
      if (text.isNotEmpty)
        Container(
          key: const ValueKey<String>('quick-send-text'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: palette.fill,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            // Long pastes only need enough to be recognised.
            text.length <= 500 ? text : text.substring(0, 500),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (media.isNotEmpty) QuickSendMediaStrip(items: media),
      for (final item in others.take(maxFileRows))
        _QuickSendFileRow(item: item),
      if (others.length > maxFileRows)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            l10n.quickSendMoreFiles(others.length - maxFileRows),
            style: TextStyle(fontSize: 12, color: palette.ink2),
          ),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < children.length; index += 1) ...[
          if (index > 0) const SizedBox(height: 10),
          children[index],
        ],
      ],
    );
  }
}

class QuickSendMediaStrip extends StatelessWidget {
  const QuickSendMediaStrip({super.key, required this.items});

  static const double _preferredTile = 72;
  static const double _gap = 8;

  final List<QuickSendItem> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _preferredTile * 4 + _gap * 3;
        final perRow = math.max(
          1,
          ((width + _gap) / (_preferredTile + _gap)).floor(),
        );
        final tile = (width - _gap * (perRow - 1)) / perRow;
        final visible = math.min(items.length, perRow);
        final hidden = items.length - visible;
        return Row(
          key: const ValueKey<String>('quick-send-media'),
          children: [
            for (var index = 0; index < visible; index += 1) ...[
              if (index > 0) const SizedBox(width: _gap),
              SizedBox.square(
                dimension: tile,
                child: _QuickSendMediaTile(
                  item: items[index],
                  // The last visible tile counts what does not fit.
                  hiddenCount: index == visible - 1 && hidden > 0
                      ? hidden + 1
                      : 0,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _QuickSendMediaTile extends StatefulWidget {
  const _QuickSendMediaTile({required this.item, required this.hiddenCount});

  final QuickSendItem item;
  final int hiddenCount;

  @override
  State<_QuickSendMediaTile> createState() => _QuickSendMediaTileState();
}

class _QuickSendMediaTileState extends State<_QuickSendMediaTile> {
  static const int _thumbnailPixels = 240;

  Future<Uint8List?>? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _loadBytes();
  }

  @override
  void didUpdateWidget(covariant _QuickSendMediaTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.source != widget.item.source) {
      _bytes = _loadBytes();
    }
  }

  bool get _isContentUri => widget.item.source.startsWith('content://');

  Future<Uint8List?>? _loadBytes() {
    final item = widget.item;
    if (_isContentUri) {
      return AndroidDocumentPicker.shared
          .loadThumbnail(
            uri: item.source,
            width: _thumbnailPixels,
            height: _thumbnailPixels,
          )
          .then<Uint8List?>((bytes) => bytes.isEmpty ? null : bytes)
          .catchError((Object _) => null);
    }
    if (item.kind == MediaFileKind.video) {
      return VideoThumbnailCache.shared
          .load(item.source)
          .then((thumbnail) => thumbnail?.bytes)
          .catchError((Object _) => null);
    }
    // Local images decode straight from the file below.
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.wc;
    final item = widget.item;
    final isVideo = item.kind == MediaFileKind.video;
    final placeholder = Center(
      child: Icon(
        isVideo ? Icons.videocam_outlined : Icons.image_outlined,
        color: palette.ink2,
        size: 24,
      ),
    );
    Widget image;
    final bytes = _bytes;
    if (bytes == null) {
      image = Image(
        image: ResizeImage(
          MemoryBoundedFileImage(File(item.source)),
          width: _thumbnailPixels,
          policy: ResizeImagePolicy.fit,
        ),
        fit: BoxFit.cover,
        semanticLabel: item.name,
        errorBuilder: (context, error, stackTrace) => placeholder,
      );
    } else {
      image = FutureBuilder<Uint8List?>(
        future: bytes,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return placeholder;
          }
          return Image(
            image: MemoryBoundedMemoryImage(data),
            fit: BoxFit.cover,
            semanticLabel: item.name,
            errorBuilder: (context, error, stackTrace) => placeholder,
          );
        },
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: palette.fill, child: image),
          if (isVideo)
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Radix.blackA6,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
          if (widget.hiddenCount > 0)
            ColoredBox(
              color: Radix.blackA6,
              child: Center(
                child: Text(
                  '+${widget.hiddenCount}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// How big a file waiting in quick send is, when that can be known.
Future<String?> quickSendFileSizeText(QuickSendItem item) {
  final knownSize = item.size;
  if (knownSize != null) {
    return Future<String?>.value(formatSize(knownSize));
  }
  if (item.source.isEmpty || item.source.startsWith('content://')) {
    return Future<String?>.value();
  }
  return File(
    item.source,
  ).length().then<String?>(formatSize).catchError((Object _) => null);
}

class _QuickSendFileRow extends StatefulWidget {
  const _QuickSendFileRow({required this.item});

  final QuickSendItem item;

  @override
  State<_QuickSendFileRow> createState() => _QuickSendFileRowState();
}

class _QuickSendFileRowState extends State<_QuickSendFileRow> {
  late Future<String?> _sizeText = _loadSizeText();

  @override
  void didUpdateWidget(covariant _QuickSendFileRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.source != widget.item.source ||
        oldWidget.item.size != widget.item.size) {
      _sizeText = _loadSizeText();
    }
  }

  Future<String?> _loadSizeText() => quickSendFileSizeText(widget.item);

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final colors = Theme.of(context).colorScheme;
    final palette = context.wc;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
      decoration: BoxDecoration(
        color: palette.fill,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            item.kind == MediaFileKind.audio
                ? Icons.audio_file_rounded
                : Icons.insert_drive_file,
            size: 30,
            color: colors.primary.withValues(alpha: 0.86),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
                FutureBuilder<String?>(
                  future: _sizeText,
                  builder: (context, snapshot) {
                    final value = snapshot.data;
                    if (value == null) {
                      return const SizedBox.shrink();
                    }
                    return Text(
                      value,
                      style: TextStyle(fontSize: 12, color: palette.ink2),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
