import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:whisper/helper/android_document_picker.dart';
import 'package:whisper/helper/memory_bounded_image.dart';
import 'package:whisper/helper/video_thumbnail.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/media_message_preview.dart' show MediaFileKind;

/// A small picture of a photo or a video, filling whatever box it is given.
/// [source] is a local path or an Android `content://` uri. What cannot be
/// shown leaves the box in the fill colour, with an icon when [icon] is set.
class MediaThumbnail extends StatefulWidget {
  const MediaThumbnail({
    super.key,
    required this.source,
    required this.kind,
    this.name,
    this.pixels = 240,
    this.icon = true,
  });

  final String source;
  final MediaFileKind kind;

  /// Read out in place of the picture.
  final String? name;

  /// How large to decode it, on its longer side.
  final int pixels;
  final bool icon;

  @override
  State<MediaThumbnail> createState() => _MediaThumbnailState();
}

class _MediaThumbnailState extends State<MediaThumbnail> {
  late Future<Uint8List?>? _bytes = _load();

  @override
  void didUpdateWidget(covariant MediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source || oldWidget.kind != widget.kind) {
      _bytes = _load();
    }
  }

  /// What has to be fetched first; a local image decodes straight from its
  /// file instead.
  Future<Uint8List?>? _load() {
    final source = widget.source;
    if (source.startsWith('content://')) {
      return AndroidDocumentPicker.shared
          .loadThumbnail(
            uri: source,
            width: widget.pixels,
            height: widget.pixels,
          )
          .then<Uint8List?>((bytes) => bytes.isEmpty ? null : bytes)
          .catchError((Object _) => null);
    }
    if (widget.kind == MediaFileKind.video) {
      return VideoThumbnailCache.shared
          .load(source)
          .then((thumbnail) => thumbnail?.bytes)
          .catchError((Object _) => null);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final placeholder = widget.icon
        ? Center(
            child: Icon(
              widget.kind == MediaFileKind.video
                  ? Icons.videocam_outlined
                  : Icons.image_outlined,
              color: c.ink2,
              size: 24,
            ),
          )
        : const SizedBox.expand();
    final bytes = _bytes;
    final Widget image;
    if (bytes == null) {
      image = widget.source.isEmpty
          ? placeholder
          : Image(
              image: ResizeImage(
                MemoryBoundedFileImage(File(widget.source)),
                width: widget.pixels,
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.cover,
              semanticLabel: widget.name,
              errorBuilder: (context, error, stackTrace) => placeholder,
            );
    } else {
      image = FutureBuilder<Uint8List?>(
        future: bytes,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) return placeholder;
          return Image(
            image: MemoryBoundedMemoryImage(data),
            fit: BoxFit.cover,
            semanticLabel: widget.name,
            errorBuilder: (context, error, stackTrace) => placeholder,
          );
        },
      );
    }
    return ColoredBox(
      color: c.fill,
      child: SizedBox.expand(child: image),
    );
  }
}
