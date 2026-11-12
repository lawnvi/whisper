import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:whisper/state/peer_aliases.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart' show showPhoneSheet;
import 'package:whisper/new_ui/picker/quick_send_sheet.dart';

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/helper/helper.dart' show formatSize;
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
    ..sort(
      (left, right) => PeerAliases.shared
          .labelOf(left.id, left.name)
          .compareTo(PeerAliases.shared.labelOf(right.id, right.name)),
    );
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
