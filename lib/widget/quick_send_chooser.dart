import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:whisper/helper/android_document_picker.dart';
import 'package:whisper/helper/device_form_factor.dart';
import 'package:whisper/helper/helper.dart'
    show formatSize, platformIcon, platformLabel;
import 'package:whisper/helper/memory_bounded_image.dart';
import 'package:whisper/helper/video_thumbnail.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_bottom_sheet.dart';
import 'package:whisper/widget/glass_dialog.dart';
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
  return showWhisperGlassBottomSheet<String>(
    context,
    builder: (context) => QuickSendChooser(
      layout: QuickSendChooserLayout.sheet,
      items: items,
      targets: targets,
      initialTargetId: initialTargetId,
    ),
  );
}

/// The content preview and device picker shared by Android system share and
/// desktop quick send. Only connected devices are offered, and the list
/// follows connections that come and go while it is open.
class QuickSendChooser extends StatefulWidget {
  const QuickSendChooser({
    super.key,
    required this.layout,
    required this.items,
    required this.targets,
    this.initialTargetId,
  });

  final QuickSendChooserLayout layout;
  final List<QuickSendItem> items;
  final ValueListenable<List<QuickSendTarget>> targets;
  final String? initialTargetId;

  @override
  State<QuickSendChooser> createState() => _QuickSendChooserState();
}

class _QuickSendChooserState extends State<QuickSendChooser> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialTargetId;
  }

  String? _resolveSelection(List<QuickSendTarget> targets) {
    if (targets.any((target) => target.id == _selectedId)) {
      return _selectedId;
    }
    // A single device needs no choice, including one that connects late.
    return targets.length == 1 ? targets.single.id : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<List<QuickSendTarget>>(
      valueListenable: widget.targets,
      builder: (context, targets, _) {
        final selectedId = _resolveSelection(targets);
        final content = _buildContent(context, targets, selectedId);
        final actions = <Widget>[
          WhisperDialogButton(
            label: l10n.quickSendLater,
            onPressed: () => Navigator.of(context).pop(),
          ),
          WhisperDialogButton(
            key: const ValueKey<String>('quick-send-confirm'),
            label: l10n.quickSendSend,
            prominent: true,
            onPressed: selectedId == null
                ? null
                : () => Navigator.of(context).pop(selectedId),
          ),
        ];
        final title = Text(l10n.quickSendTitle);
        switch (widget.layout) {
          case QuickSendChooserLayout.sheet:
            return WhisperGlassBottomSheet(
              maxSheetWidth: 560,
              maxContentWidth: 520,
              title: title,
              content: content,
              actions: actions,
            );
          case QuickSendChooserLayout.dialog:
            return WhisperGlassDialog(
              constraints: const BoxConstraints(
                minWidth: 320,
                maxWidth: 460,
                maxHeight: 640,
              ),
              borderRadius: 22,
              titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              actionsPadding: EdgeInsets.zero,
              title: DefaultTextStyle.merge(
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                child: title,
              ),
              content: SingleChildScrollView(child: content),
              actions: actions,
            );
        }
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    List<QuickSendTarget> targets,
    String? selectedId,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.whisperPalette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        QuickSendContentPreview(items: widget.items),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            l10n.quickSendTargets,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette.textMuted,
            ),
          ),
        ),
        if (targets.isEmpty)
          Padding(
            key: const ValueKey<String>('quick-send-no-targets'),
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(
              children: [
                Icon(
                  Icons.link_off_rounded,
                  size: 26,
                  color: palette.textMuted,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.quickSendNoConnectedDevices,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.textMuted),
                ),
              ],
            ),
          )
        else
          for (final target in targets)
            Padding(
              padding: EdgeInsets.only(
                bottom: identical(target, targets.last) ? 0 : 8,
              ),
              child: QuickSendTargetTile(
                target: target,
                selected: target.id == selectedId,
                onTap: () => setState(() => _selectedId = target.id),
              ),
            ),
      ],
    );
  }
}

class QuickSendTargetTile extends StatelessWidget {
  const QuickSendTargetTile({
    super.key,
    required this.target,
    required this.selected,
    required this.onTap,
  });

  final QuickSendTarget target;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final tablet = DeviceFormFactors.shared.isTablet(target.id);
    final platform = target.platform.trim().isEmpty
        ? ''
        : platformLabel(target.platform, tablet: tablet);
    return Semantics(
      selected: selected,
      button: true,
      child: WhisperGlassSurface(
        key: ValueKey<String>('quick-send-target-${target.id}'),
        borderRadius: BorderRadius.circular(14),
        showTopHighlight: false,
        showShadow: false,
        neutral: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.lightBlue,
                  child: Icon(
                    platformIcon(target.platform, tablet: tablet),
                    size: 18,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        target.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                      if (platform.isNotEmpty)
                        Text(
                          platform,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: selected
                      ? colors.primary
                      : palette.textMuted.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Text, photo and file previews for content waiting in quick send.
class QuickSendContentPreview extends StatelessWidget {
  const QuickSendContentPreview({super.key, required this.items});

  static const int maxFileRows = 3;

  final List<QuickSendItem> items;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.whisperPalette;
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
            color: palette.surfaceMuted,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            // Long pastes only need enough to be recognised.
            text.length <= 500 ? text : text.substring(0, 500),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (media.isNotEmpty) _QuickSendMediaStrip(items: media),
      for (final item in others.take(maxFileRows))
        _QuickSendFileRow(item: item),
      if (others.length > maxFileRows)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            l10n.quickSendMoreFiles(others.length - maxFileRows),
            style: TextStyle(fontSize: 12, color: palette.textMuted),
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

class _QuickSendMediaStrip extends StatelessWidget {
  const _QuickSendMediaStrip({required this.items});

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
    final palette = context.whisperPalette;
    final item = widget.item;
    final isVideo = item.kind == MediaFileKind.video;
    final placeholder = Center(
      child: Icon(
        isVideo ? Icons.videocam_outlined : Icons.image_outlined,
        color: palette.textMuted,
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
          ColoredBox(color: palette.surfaceMuted, child: image),
          if (isVideo)
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
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
              color: Colors.black.withValues(alpha: 0.45),
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

  Future<String?> _loadSizeText() {
    final item = widget.item;
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

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final colors = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
      decoration: BoxDecoration(
        color: palette.surfaceMuted,
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
                      style: TextStyle(fontSize: 12, color: palette.textMuted),
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
