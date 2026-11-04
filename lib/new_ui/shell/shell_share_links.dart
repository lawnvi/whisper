import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/shell/shell_link_create.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/page/remote_files/files_share_sheet.dart';
import 'package:whisper/share_links/share_link.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/context_menu_region.dart';

/// The system's panel can take files and folders at once only on macOS.
bool get shellPickerTakesBoth => Platform.isMacOS;

/// Picks what to share and makes a link of it. Several can be picked.
Future<void> shellNewShareLink(BuildContext context) async {
  final List<String> paths;
  if (shellPickerTakesBoth) {
    paths = await FilePicker.pickFileAndDirectoryPaths() ?? const [];
  } else {
    final picked = await FilePicker.pickFiles(allowMultiple: true);
    paths = [
      for (final file in picked?.files ?? const <PlatformFile>[])
        if (file.path != null) file.path!,
    ];
  }
  if (paths.isEmpty || !context.mounted) return;
  await showShareLinkSheet(
    context,
    items: [
      for (final path in paths)
        ShareSource(
          absolutePath: path,
          name: p.basename(path),
          isDir: FileSystemEntity.isDirectorySync(path),
        ),
    ],
  );
}

Future<void> shellNewFolderLink(BuildContext context) async {
  final path = await WhisperFilePicker.pickFolder();
  if (path == null || !context.mounted) return;
  await showShareLinkSheet(
    context,
    items: [
      ShareSource(absolutePath: path, name: p.basename(path), isDir: true),
    ],
  );
}

/// 新建: what to share is a choice, and a menu keeps both one click away.
Future<void> showShellNewLinkMenu(BuildContext context) async {
  if (shellPickerTakesBoth) return shellNewShareLink(context);
  final box = context.findRenderObject() as RenderBox?;
  if (box == null) return;
  final l10n = context.shellL10n;
  await showWhisperActionMenu(
    context,
    anchor: box.localToGlobal(Offset.zero) & box.size,
    items: [
      ContextMenuActionItem(
        label: l10n.shellLinksChoose,
        icon: Icons.insert_drive_file_outlined,
        onSelected: () => unawaited(shellNewShareLink(context)),
      ),
      ContextMenuActionItem(
        label: l10n.shellLinksChooseFolder,
        icon: Icons.folder_outlined,
        onSelected: () => unawaited(shellNewFolderLink(context)),
      ),
    ],
  );
}

/// A device on more than one network: which address the links go out with.
void _pickAddress(BuildContext context, ShareLinkStore store) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null) return;
  unawaited(
    showWhisperActionMenu(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      items: [
        for (final address in store.addresses)
          ContextMenuActionItem(
            label: address,
            icon: address == store.address ? Icons.check : Icons.lan_outlined,
            onSelected: () => store.preferAddress(address),
          ),
      ],
    ),
  );
}

/// docs/design/surfaces.md「共享链接」, the prototype's `placeLinks`.
class ShellLinksPage extends StatefulWidget {
  const ShellLinksPage({super.key, this.touch = false});

  final bool touch;

  @override
  State<ShellLinksPage> createState() => _ShellLinksPageState();
}

class _ShellLinksPageState extends State<ShellLinksPage> {
  ShareLinkStore get store => ShareLinkStore.shared;

  @override
  void initState() {
    super.initState();
    unawaited(store.initialize());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final l10n = context.shellL10n;
      final c = context.wc;
      final touch = widget.touch;
      final type = WhisperType(touch: touch);
      final links = store.links;
      final service = store.serviceOn;
      final anyOn = links.any((link) => link.enabled);
      final address = store.address;
      final failed =
          service && store.serverState.phase == ShareServerPhase.failed;
      final noNetwork = service && anyOn && address == null;
      final serviceLine = !service
          ? l10n.shellLinksServiceOff
          : failed
          ? shareServerFailureText(l10n, store)
          : noNetwork
          ? l10n.shareLinkNoNetwork
          : anyOn && address != null
          ? '$address:${store.port}'
          : l10n.shellLinksServiceIdle;
      final gutter = touch ? 16.0 : 20.0;
      Widget column(Widget child) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: child,
        ),
      );
      // The master switch does not scroll away: with many links it would be
      // far from wherever you are.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 6, gutter, 12),
            child: column(
              ShellGroup(
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  l10n.shareLinksService,
                                  style: TextStyle(
                                    fontSize: type.body,
                                    height: 1.3,
                                    color: c.ink,
                                  ),
                                ),
                                Text(
                                  serviceLine,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: type.note,
                                    height: 1.3,
                                    color: failed || noNetwork
                                        ? c.warn
                                        : c.ink2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (failed) ...[
                            const SizedBox(width: 8),
                            ShellButton(
                              touch: touch,
                              label: l10n.retry,
                              onTap: () => unawaited(store.retry()),
                            ),
                          ],
                          const SizedBox(width: 10),
                          ShellSwitch(
                            touch: touch,
                            label: l10n.shareLinksService,
                            value: service,
                            onChanged: (v) => unawaited(store.setServiceOn(v)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 28),
              children: [
                column(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (links.isEmpty)
                        _Empty(touch: touch)
                      else
                        ShellGroup(
                          children: [
                            for (final link in links)
                              _LinkRow(
                                key: ValueKey(link.id),
                                link: link,
                                store: store,
                                touch: touch,
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.touch});

  final bool touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    final type = WhisperType(touch: touch);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          WhisperIcon(WhisperGlyph.link, size: 40, weight: 1.2, color: c.ink2),
          const SizedBox(height: 10),
          Text(
            l10n.shellLinksEmptyTitle,
            style: TextStyle(
              fontSize: type.title,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: type.body * 32),
            child: Text(
              l10n.shellLinksEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: type.body, height: 1.5, color: c.ink2),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!shellPickerTakesBoth)
                ShellButton(
                  touch: touch,
                  large: true,
                  label: l10n.shellLinksChooseFolder,
                  onTap: () => unawaited(shellNewFolderLink(context)),
                ),
              ShellFilledButton(
                touch: touch,
                label: shellPickerTakesBoth
                    ? l10n.shellLinksChooseAny
                    : l10n.shellLinksChoose,
                onTap: () => unawaited(shellNewShareLink(context)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LinkRow extends StatefulWidget {
  const _LinkRow({
    super.key,
    required this.link,
    required this.store,
    required this.touch,
  });

  final ShareLink link;
  final ShareLinkStore store;
  final bool touch;

  @override
  State<_LinkRow> createState() => _LinkRowState();
}

class _LinkRowState extends State<_LinkRow> {
  bool _hover = false;

  String _when(BuildContext context, DateTime? at) {
    if (at == null) return '';
    final locale = Localizations.localeOf(context).toLanguageTag();
    return DateFormat.Md(locale).add_Hm().format(at);
  }

  ({String text, bool warn}) _subtitle(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    final link = widget.link;
    final store = widget.store;
    if (!store.serviceOn) return (text: l10n.shellLinksServiceOff, warn: false);
    if (!link.enabled) return (text: l10n.shellLinkOff, warn: false);
    final availability = store.availabilityOf(link);
    if (availability != ShareAvailability.available) {
      return (text: l10n.shellLinkMissing, warn: true);
    }
    final when = _when(context, link.lastVisitAt);
    return (
      text: [
        l10n.shellLinkVisits(link.visits),
        l10n.shellLinkDownloads(link.downloads),
        if (when.isNotEmpty) when,
      ].join(' · '),
      warn: false,
    );
  }

  List<ContextMenuActionItem> _menu(AppLocalizations l10n) {
    final link = widget.link;
    final store = widget.store;
    return [
      ContextMenuActionItem(
        label: l10n.shareLinkCopy,
        icon: Icons.copy_rounded,
        onSelected: () => unawaited(
          Clipboard.setData(ClipboardData(text: store.urlFor(link))),
        ),
      ),
      ContextMenuActionItem(
        label: l10n.shareLinkDelete,
        icon: Icons.delete_outline_rounded,
        destructive: true,
        onSelected: () => unawaited(store.remove(link.id)),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    final touch = widget.touch;
    final type = WhisperType(touch: touch);
    final link = widget.link;
    final store = widget.store;
    final live = link.enabled && store.serviceOn;
    final sub = _subtitle(context, l10n);
    final single = link.items.length == 1;
    final folder = single && link.items.first.isDir;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: ContextMenuRegion(
        items: _menu(l10n),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Opacity(
                  opacity: live ? 1 : .45,
                  child: SizedBox(
                    width: 30,
                    child: Center(
                      child: folder
                          ? const WhisperFolderArt(size: 28)
                          : const WhisperDocArt(size: 28),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Pressable(
                    onTap: () =>
                        unawaited(showShellLinkDetail(context, link, store)),
                    radius: WhisperRadius.xs,
                    scale: 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                link.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: type.body,
                                  height: 1.3,
                                  color: live ? c.ink : c.ink2,
                                ),
                              ),
                            ),
                            if (link.hasPassword) ...[
                              const SizedBox(width: 5),
                              WhisperIcon(
                                WhisperGlyph.lock,
                                size: 11,
                                color: c.ink2,
                              ),
                            ],
                          ],
                        ),
                        Row(
                          children: [
                            if (sub.warn) ...[
                              WhisperIcon(
                                WhisperGlyph.warn,
                                size: 12,
                                color: c.warn,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Flexible(
                              child: Text(
                                sub.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: type.note,
                                  height: 1.3,
                                  color: sub.warn ? c.warn : c.ink2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                // A phone has long press; a pointer sees it when it comes near.
                if (!touch) ...[
                  const SizedBox(width: 6),
                  Opacity(
                    opacity: _hover ? 1 : 0,
                    child: Builder(
                      builder: (buttonContext) => ShellIconButton(
                        glyph: WhisperGlyph.more,
                        iconSize: 15,
                        weight: 2.4,
                        label: l10n.shellMore,
                        onTap: () {
                          final box =
                              buttonContext.findRenderObject() as RenderBox?;
                          if (box == null) return;
                          unawaited(
                            showWhisperActionMenu(
                              buttonContext,
                              anchor: box.localToGlobal(Offset.zero) & box.size,
                              items: _menu(l10n),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                ShellSwitch(
                  touch: touch,
                  label: link.name,
                  value: link.enabled,
                  onChanged: (v) => unawaited(store.setEnabled(link.id, v)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `linkSheet`: the code, the address, what it has served.
Future<void> showShellLinkDetail(
  BuildContext context,
  ShareLink link,
  ShareLinkStore store,
) => showShellSheet<void>(
  context,
  scrolls: false,
  builder: (context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final c = context.wc;
      final l10n = context.shellL10n;
      const type = WhisperType(touch: false);
      final current = store.linkById(link.id);
      if (current == null) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            l10n.shellLinkDeleted,
            style: TextStyle(fontSize: type.note, color: c.ink2),
          ),
        );
      }
      final url = store.urlFor(current);
      final live = current.enabled && store.serviceOn;
      final address = store.address ?? '—';
      final last = current.lastVisitAt;
      Widget value(String text) => Flexible(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: type.body, color: c.ink2),
        ),
      );
      return ShellSheetBody(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              current.name,
              style: TextStyle(
                fontSize: type.head,
                fontWeight: FontWeight.w600,
                color: c.ink,
              ),
            ),
            const SizedBox(height: 14),
            if (live)
              Center(
                child: Container(
                  width: 148,
                  height: 148,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(WhisperRadius.m),
                    boxShadow: WhisperShadow.e1(Theme.of(context).brightness),
                  ),
                  child: QrImageView(
                    data: url,
                    padding: const EdgeInsets.all(10),
                    backgroundColor: Colors.transparent,
                  ),
                ),
              )
            else
              Text(
                store.serviceOn ? l10n.shellLinkOff : l10n.shellLinksServiceOff,
                style: TextStyle(
                  fontSize: type.note,
                  height: 1.5,
                  color: c.ink2,
                ),
              ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: c.fill,
                borderRadius: BorderRadius.circular(WhisperRadius.s),
              ),
              child: SelectableText(
                url,
                style: TextStyle(fontSize: 12, height: 1.4, color: c.ink),
              ),
            ),
            const SizedBox(height: 14),
            ShellGroup(
              flat: true,
              children: [
                ShellRow(
                  label: l10n.shellLinkEnabled,
                  trailing: ShellSwitch(
                    label: l10n.shellLinkEnabled,
                    value: current.enabled,
                    onChanged: (v) =>
                        unawaited(store.setEnabled(current.id, v)),
                  ),
                ),
                Builder(
                  builder: (rowContext) => ShellRow(
                    label: l10n.shellSelfAddress,
                    trailing: value(address),
                    chevron: store.addresses.length > 1,
                    onTap: store.addresses.length > 1
                        ? () => _pickAddress(rowContext, store)
                        : null,
                  ),
                ),
                ShellRow(
                  label: l10n.shareLinkRoute,
                  trailing: value(current.route),
                  chevron: true,
                  onTap: () => unawaited(
                    showShellLinkEditor(
                      context,
                      (_) => ShellLinkRouteEditor(store: store, link: current),
                    ),
                  ),
                ),
                ShellRow(
                  label: l10n.shellLinkPassword,
                  trailing: value(
                    current.hasPassword
                        ? l10n.shellLinkPasswordSet
                        : l10n.shellLinkPasswordNone,
                  ),
                  chevron: true,
                  onTap: () => unawaited(
                    showShellLinkEditor(
                      context,
                      (_) =>
                          ShellLinkPasswordEditor(store: store, link: current),
                    ),
                  ),
                ),
                ShellRow(
                  label: l10n.shellLinkVisitsLabel,
                  trailing: value(
                    [
                      l10n.shellLinkVisitsCount(current.visits),
                      if (last != null)
                        DateFormat.Md(
                          Localizations.localeOf(context).toLanguageTag(),
                        ).add_Hm().format(last),
                    ].join(' · '),
                  ),
                ),
                ShellRow(
                  label: l10n.shellLinkDownloadsLabel,
                  trailing: value(l10n.shellLinkVisitsCount(current.downloads)),
                ),
                ShellRow(
                  label: l10n.shareLinkSentLabel,
                  trailing: value(formatSize(current.bytesServed)),
                ),
              ],
            ),
          ],
        ),
        actions: Row(
          children: [
            ShellButton(
              label: l10n.shareLinkDelete,
              kind: ShellButtonKind.quiet,
              color: c.bad,
              onTap: () {
                Navigator.of(context).pop();
                unawaited(store.remove(current.id));
              },
            ),
            const Spacer(),
            ShellButton(
              label: l10n.shareLinkCopy,
              onTap: () =>
                  unawaited(Clipboard.setData(ClipboardData(text: url))),
            ),
            const SizedBox(width: 8),
            ShellButton(
              label: l10n.shellDone,
              kind: ShellButtonKind.primary,
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
    },
  ),
);
