import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/memory_bounded_image.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/page/remote_files/files_drag.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/folder_transfer_manifest.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/media_message_preview.dart'
    show MediaFileKind, mediaFileKindFor;

const _chatPeerKey = 'chatPeer';

/// What a file message puts in its drag, to tell it from a file from elsewhere.
Map<String, String> chatMessageDragData(String peerId, String path) => {
  _chatPeerKey: peerId,
  'path': path,
};

/// The conversation a dragged file message came from, or null when none of them
/// is one.
String? chatDragPeerOf(Iterable<Object?> localData) {
  for (final data in localData) {
    if (data is Map && data[_chatPeerKey] is String) {
      return data[_chatPeerKey] as String;
    }
  }
  return null;
}

/// Letting go of a file message in a conversation is changing one's mind: it is
/// already there.
bool isChatMessageDrag(DropSession session) =>
    chatDragPeerOf(session.items.map((item) => item.localData)) != null;

/// Whether a device in the list takes what is being dragged over it. A message
/// does not go back to its own conversation.
bool deviceTakesDrop({
  required bool connected,
  required String peerId,
  required String? fromPeer,
  required bool canCopy,
  required bool onlyFiles,
}) => connected && canCopy && onlyFiles && fromPeer != peerId;

Future<String?> readDroppedFilePath(DropItem item) async {
  final reader = item.dataReader;
  if (reader == null) return null;
  final completer = Completer<Uri?>();
  void complete(Uri? value) {
    if (!completer.isCompleted) completer.complete(value);
  }

  final progress = reader.getValue<Uri>(
    Formats.fileUri,
    complete,
    onError: (_) => complete(null),
  );
  if (progress == null) return null;
  final uri = await completer.future;
  return uri?.isScheme('file') == true ? uri!.toFilePath() : null;
}

/// A device in the list as a place to drop files on. Dropped ones are given to
/// [onPaths], which asks first.
class ShellDeviceDrop extends StatefulWidget {
  const ShellDeviceDrop({
    super.key,
    required this.peerId,
    required this.connected,
    required this.radius,
    required this.onPaths,
    required this.child,
  });

  final String peerId;
  final bool connected;
  final double radius;
  final ValueChanged<List<String>>? onPaths;
  final Widget child;

  @override
  State<ShellDeviceDrop> createState() => _ShellDeviceDropState();
}

class _ShellDeviceDropState extends State<ShellDeviceDrop> {
  bool _over = false;

  void _setOver(bool over) {
    if (mounted && over != _over) setState(() => _over = over);
  }

  @override
  Widget build(BuildContext context) {
    final onPaths = widget.onPaths;
    if (onPaths == null || !isDesktop()) return widget.child;
    return DropRegion(
      formats: const [Formats.fileUri],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropEnter: (_) => _setOver(true),
      onDropLeave: (_) => _setOver(false),
      onDropEnded: (_) => _setOver(false),
      onDropOver: (event) {
        final session = event.session;
        // The files page's own drag has its own target in the row.
        if (filesItemsOf(session) != null) return DropOperation.none;
        return deviceTakesDrop(
              connected: widget.connected,
              peerId: widget.peerId,
              fromPeer: chatDragPeerOf(session.items.map((i) => i.localData)),
              canCopy: session.allowedOperations.contains(DropOperation.copy),
              onlyFiles:
                  session.items.isNotEmpty &&
                  session.items.every((i) => i.canProvide(Formats.fileUri)),
            )
            ? DropOperation.copy
            : DropOperation.none;
      },
      onPerformDrop: (event) async {
        _setOver(false);
        final paths = await Future.wait(
          event.session.items.map(readDroppedFilePath),
        );
        final found = paths.whereType<String>().toList(growable: false);
        if (found.isNotEmpty) onPaths(found);
      },
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          color: _over ? context.wc.tintActive : null,
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        child: widget.child,
      ),
    );
  }
}

/// Asks before sending what was dropped on [device]. True when it should go.
Future<bool> showShellDropSend(
  BuildContext context, {
  required DeviceData device,
  required List<String> paths,
}) async =>
    await showShellSheet<bool>(
      context,
      // ShellSheetBody keeps its own margins and its buttons in reach.
      scrolls: false,
      // Narrower than a sheet: at 380 one file and two buttons lie flat.
      width: 320,
      builder: (_) => ShellDropSendSheet(
        name: device.name,
        paths: paths,
        art: deviceArtFor(device, size: 64),
      ),
    ) ==
    true;

/// DESIGN.md「提示框」: a question, so like a macOS alert. Who the files go
/// to at the top, what goes in the middle, the two answers sharing a row.
class ShellDropSendSheet extends StatelessWidget {
  const ShellDropSendSheet({
    super.key,
    required this.name,
    required this.paths,
    this.art,
  });

  static const _shown = 4;

  final String name;
  final List<String> paths;

  /// The device the files go to.
  final Widget? art;

  /// For more than one: how many, and how much when they are all files.
  String? _summary(AppLocalizations l10n) {
    if (paths.length < 2) return null;
    var bytes = 0;
    for (final path in paths) {
      final stat = FileStat.statSync(path);
      if (stat.type != FileSystemEntityType.file) {
        return l10n.shellDropSendItems(paths.length);
      }
      bytes += stat.size;
    }
    return l10n.shellDropSendFiles(paths.length, formatSize(bytes));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    const type = WhisperType(touch: false);
    void close(bool send) => Navigator.of(context).pop(send);
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.enter) {
          close(true);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ShellSheetBody(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // An alert stands taller than a sheet: room above the art and
            // between the parts.
            if (art case final art?) ...[
              const SizedBox(height: 8),
              Center(child: art),
              const SizedBox(height: 14),
            ],
            Text(
              l10n.shellDropSendTitle(name),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: type.head,
                fontWeight: FontWeight.w600,
                color: c.ink,
              ),
            ),
            if (_summary(l10n) case final summary?) ...[
              const SizedBox(height: 4),
              Text(
                summary,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: type.note, color: c.ink2),
              ),
            ],
            const SizedBox(height: 18),
            ShellGroup(
              flat: true,
              inset: 60,
              children: [
                for (final path in paths.take(_shown)) _DroppedFile(path: path),
              ],
            ),
            if (paths.length > _shown) ...[
              const SizedBox(height: 8),
              Text(
                l10n.shellDropSendMore(paths.length - _shown),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: type.note, color: c.ink2),
              ),
            ],
            // The answers stand apart from the list: 24 above them.
            const SizedBox(height: 10),
          ],
        ),
        actions: Row(
          children: [
            Expanded(
              child: ShellButton(
                label: l10n.cancel,
                large: true,
                onTap: () => close(false),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ShellButton(
                label: l10n.shellDropSendConfirm,
                kind: ShellButtonKind.primary,
                large: true,
                onTap: () => close(true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DroppedFile extends StatelessWidget {
  const _DroppedFile({required this.path});

  final String path;

  /// As in a file message: a picture shows itself, a folder is a folder,
  /// everything else a sheet of paper.
  Widget _picture(bool folder) {
    if (folder) return const WhisperFolderArt(size: 32);
    final kind = mediaFileKindFor(name: p.basename(path), path: path);
    if (kind != MediaFileKind.image) return const WhisperDocArt(size: 32);
    return ClipRRect(
      borderRadius: BorderRadius.circular(WhisperRadius.xs),
      child: Image(
        image: ResizeImage(
          MemoryBoundedFileImage(File(path)),
          width: 96,
          policy: ResizeImagePolicy.fit,
        ),
        width: 36,
        height: 36,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const WhisperDocArt(size: 32),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    final stat = FileStat.statSync(path);
    final folder = stat.type == FileSystemEntityType.directory;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 36,
            child: Center(child: _picture(folder)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.basename(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: type.body, color: c.ink),
                ),
                if (!folder)
                  Text(
                    formatSize(stat.size),
                    style: TextStyle(fontSize: type.note, color: c.ink2),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String folderSendFailureText(
  AppLocalizations l10n,
  FolderSendOutcome outcome,
) => switch (outcome) {
  FolderSendOutcome.peerUnsupported => l10n.folderSendUnsupported,
  FolderSendOutcome.invalidName => l10n.folderSendInvalidName,
  FolderSendOutcome.unreadable => l10n.folderSendUnreadable,
  FolderSendOutcome.tooManyEntries => l10n.folderSendTooManyEntries(
    folderManifestMaxEntries,
  ),
  FolderSendOutcome.tooLarge => l10n.folderSendTooLarge,
  _ => l10n.folderSendFailed,
};

/// Sends files and folders to a device, stopping at the first that cannot go and
/// saying why. True when all of them went.
Future<bool> sendDroppedPaths({
  required List<String> paths,
  required AppLocalizations l10n,
  required Future<bool> Function(String path) sendFile,
  required Future<FolderSendOutcome> Function(String path) sendFolder,
}) async {
  void say(String text) => showAppToast(text, tone: AppToastTone.error);
  try {
    for (final path in paths) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        final outcome = await sendFolder(path);
        if (outcome != FolderSendOutcome.sent) {
          say(folderSendFailureText(l10n, outcome));
          return false;
        }
      } else if (type != FileSystemEntityType.file || !await sendFile(path)) {
        say(l10n.fileDropRejected);
        return false;
      }
    }
    return true;
  } on Object {
    say(l10n.fileDropRejected);
    return false;
  }
}
