import 'package:whisper/new_ui/shell/shell_link_create.dart';
import 'package:whisper/new_ui/shell/shell_share_links.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../helper/toast.dart';
import '../../remote_files/fs_browser.dart' show LocalFsBrowser;
import '../../share_links/share_link_store.dart';
import 'files_model.dart';

/// Something on this device to give out through a share link.
class ShareSource {
  const ShareSource({
    required this.absolutePath,
    required this.name,
    required this.isDir,
  });

  final String absolutePath;
  final String name;
  final bool isDir;
}

/// Asks how to share [items] (route, short route, password), makes the
/// link and then shows it: address, QR code, copy. A card in the middle
/// on wide windows, a sheet from the bottom on phones. The link, or null
/// when nothing was made.
Future<ShareLink?> showShareLinkSheet(
  BuildContext context, {
  required List<ShareSource> items,
  ShareLinkStore? store,
}) async {
  if (items.isEmpty) {
    return null;
  }
  return showShellLinkCreate(
    context,
    paths: [for (final item in items) item.absolutePath],
    name: items.length == 1
        ? items.single.name
        : AppLocalizations.of(context)!.shareLinkDefaultName(items.length),
    store: store,
  );
}

/// An existing link: address, QR code, copy and delete.
Future<void> showShareLinkDetails(
  BuildContext context,
  ShareLink link, {
  ShareLinkStore? store,
}) => showShellLinkDetail(context, link, store ?? ShareLinkStore.shared);

/// The file manager's way in: [items] on this device (its own paths are
/// relative to a root) become a share link.
Future<ShareLink?> shareFilesItems(
  BuildContext context,
  FilesController controller,
  List<FilesItem> items,
) async {
  final browser = controller.deviceById(FilesDevice.localId)?.browser;
  if (browser is! LocalFsBrowser || items.isEmpty) {
    return null;
  }
  final text = AppLocalizations.of(context)!;
  final sources = <ShareSource>[];
  for (final item in items) {
    if (item.location.deviceId != FilesDevice.localId) {
      continue;
    }
    try {
      sources.add(
        ShareSource(
          absolutePath: await browser.realPath(item.location.root, item.path),
          name: item.name,
          isDir: item.isDir,
        ),
      );
    } on Object {
      // Gone since it was listed; the rest can still be shared.
    }
  }
  if (sources.isEmpty) {
    showAppToast(text.shareLinkItemsMissing, tone: AppToastTone.error);
    return null;
  }
  if (!context.mounted) {
    return null;
  }
  return showShareLinkSheet(context, items: sources);
}

/// Why the file server is not running, for a failed start.
String shareServerFailureText(AppLocalizations text, ShareLinkStore store) {
  final state = store.serverState;
  if (state.failure == ShareServerFailure.portsBusy) {
    final ports = state.ports ?? const <int>[];
    final (from, to) = ports.isEmpty
        ? store.portRange
        : (ports.reduce(math.min), ports.reduce(math.max));
    return text.shareLinksServicePortsBusy('$from', '$to');
  }
  return text.shareLinksServiceFailed;
}
