import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../helper/helper.dart' show copyToClipboard;
import '../../l10n/app_localizations.dart';
import '../../remote_files/fs_host_files.dart' show FsEntry;
import '../../share_links/share_link_store.dart';
import '../../share_links/share_names.dart';
import '../window_stream/flow_space_theme.dart';
import '../window_stream/flow_space_widgets.dart';
import 'files_confirm.dart';
import 'files_icons.dart';
import 'files_menu.dart';
import 'files_share_sheet.dart';

/// The share links on this device and the file server behind them, laid
/// out like an iOS settings page: the server's switch and addresses in
/// one group, then one row per link with its state (dot, word, chevron).
/// A row opens the link's page; a right-click or long press has the
/// quick actions (copy, QR code, turn on or off, delete).
class FilesSharesList extends StatefulWidget {
  const FilesSharesList({
    super.key,
    ShareLinkStore? store,
    this.grouped = false,
  }) : _store = store;

  final ShareLinkStore? _store;

  /// Rows in rounded groups on a grey canvas (phones), else bordered
  /// groups on the window's white.
  final bool grouped;

  ShareLinkStore get store => _store ?? ShareLinkStore.shared;

  @override
  State<FilesSharesList> createState() => _FilesSharesListState();
}

class _FilesSharesListState extends State<FilesSharesList> {
  Timer? _refresh;

  ShareLinkStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
    // Files can be moved or deleted while the list is up.
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(store.refreshAvailability());
    });
  }

  Future<void> _prepare() async {
    await store.initialize();
    await store.refreshAddresses();
    await store.refreshAvailability();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grouped = widget.grouped;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final text = AppLocalizations.of(context)!;
        final links = store.links;
        return LayoutBuilder(
          builder: (context, constraints) {
            final side = grouped ? 16.0 : 24.0;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(side, grouped ? 8 : 20, side, 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Group(
                        grouped: grouped,
                        children: [
                          _ServiceRow(store: store),
                          if (store.serviceOn && store.serverState.isRunning)
                            for (final address in store.addresses)
                              _AddressRow(
                                label: text.shareLinkAddress,
                                value: '$address:${store.port}',
                              ),
                        ],
                      ),
                      _Footer(text.shareLinksServiceFooter),
                      const SizedBox(height: 22),
                      _Header(text.shareLinksTitle),
                      if (links.isEmpty)
                        _Group(
                          grouped: grouped,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: FlowEmptyState(
                                icon: CupertinoIcons.link,
                                title: text.shareLinksEmpty,
                                detail: grouped
                                    ? text.shareLinksEmptyDetailPhone
                                    : text.shareLinksEmptyDetailDesktop,
                              ),
                            ),
                          ],
                        )
                      else
                        _Group(
                          grouped: grouped,
                          children: [
                            for (final link in links)
                              _LinkRow(
                                key: ValueKey(link.id),
                                link: link,
                                store: store,
                                touch: grouped,
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// iOS system colours for the dots and the switch.
const _green = Color(0xFF34C759);
const _orange = Color(0xFFFF9500);
const _red = Color(0xFFFF3B30);

Color _accent(FlowSpaceColors colors) =>
    colors.dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);

const _mono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: [
    'SF Mono',
    'Consolas',
    'Cascadia Mono',
    'Roboto Mono',
    'DejaVu Sans Mono',
    'Noto Sans Mono',
    'monospace',
  ],
);

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
      child: Text(
        title,
        style: TextStyle(
          color: FlowSpaceColors.of(context).secondaryLabel,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
      child: Text(
        text,
        style: TextStyle(
          color: FlowSpaceColors.of(context).secondaryLabel,
          fontSize: 12.5,
          height: 1.4,
        ),
      ),
    );
  }
}

/// A rounded group of rows with inset hairlines between them.
class _Group extends StatelessWidget {
  const _Group({required this.children, required this.grouped});

  final List<Widget> children;
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 62),
            child: Container(height: 0.5, color: colors.hairline),
          ),
        );
      }
      rows.add(children[i]);
    }
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(grouped ? 14 : 12),
      side: grouped
          ? BorderSide.none
          : BorderSide(color: colors.hairline, width: 0.5),
    );
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: colors.raised, shape: shape),
        child: AnimatedSize(
          duration: FlowSpaceTokens.quickDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(children: rows),
        ),
      ),
    );
  }
}

/// A coloured square with a white glyph, as in iOS Settings.
class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: ShapeDecoration(
        color: color,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(7.5),
        ),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 18, color: Colors.white),
    );
  }
}

/// The file server: its switch, and where it stands.
class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.store});

  final ShareLinkStore store;

  @override
  Widget build(BuildContext context) {
    final text = AppLocalizations.of(context)!;
    final colors = FlowSpaceColors.of(context);
    final state = store.serverState;
    final on = store.serviceOn;
    final (Color dot, String status) = !on
        ? (colors.tertiaryLabel, text.shareLinksServiceOff)
        : switch (state.phase) {
            ShareServerPhase.running => (
              _green,
              text.shareLinksServiceRunning('${state.port}'),
            ),
            ShareServerPhase.starting => (
              _orange,
              text.shareLinksServiceStarting,
            ),
            ShareServerPhase.failed => (
              _red,
              shareServerFailureText(text, store),
            ),
            ShareServerPhase.stopped => (
              colors.tertiaryLabel,
              text.shareLinksServiceIdle,
            ),
          };
    final failed = on && state.phase == ShareServerPhase.failed;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 14, 11),
        child: Row(
          children: [
            _Tile(
              icon: CupertinoIcons.antenna_radiowaves_left_right,
              color: on ? const Color(0xFF30B0C7) : const Color(0xFF8E8E93),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text.shareLinksService,
                    style: TextStyle(color: colors.label, fontSize: 15.5),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: _Dot(color: dot),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          status,
                          style: TextStyle(
                            color: colors.secondaryLabel,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      if (failed) ...[
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => unawaited(store.retry()),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Text(
                              text.retry,
                              style: TextStyle(
                                color: _accent(colors),
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (on && state.phase == ShareServerPhase.starting)
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: CupertinoActivityIndicator(radius: 8),
              ),
            CupertinoSwitch(
              value: on,
              activeTrackColor: _green,
              onChanged: (value) {
                HapticFeedback.selectionClick();
                unawaited(store.setServiceOn(value));
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// One of this device's addresses, selectable for copying by hand.
class _AddressRow extends StatelessWidget {
  const _AddressRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(62, 12, 16, 12),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: colors.label, fontSize: 15)),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value,
              maxLines: 1,
              textAlign: TextAlign.end,
              style: _mono.copyWith(
                color: colors.secondaryLabel,
                fontSize: 13.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// A link: its item's icon, name and route, then its state as a dot and
/// a word before the chevron. Nothing else on the row.
class _LinkRow extends StatefulWidget {
  const _LinkRow({
    super.key,
    required this.link,
    required this.store,
    required this.touch,
  });

  final ShareLink link;
  final ShareLinkStore store;

  /// Long press for the menu (phones); else right-click.
  final bool touch;

  @override
  State<_LinkRow> createState() => _LinkRowState();
}

class _LinkRowState extends State<_LinkRow> {
  bool _pressed = false;
  bool _hover = false;

  ShareLink get link => widget.link;
  ShareLinkStore get store => widget.store;

  void _open() => unawaited(showShareLinkDetails(context, link, store: store));

  Future<void> _menu(Offset at) async {
    final text = AppLocalizations.of(context)!;
    HapticFeedback.mediumImpact();
    await showFilesMenu(
      context,
      position: at,
      touch: widget.touch,
      items: [
        FilesMenuItem(
          label: text.shareLinkCopy,
          icon: CupertinoIcons.doc_on_doc,
          onSelected: () => unawaited(
            copyToClipboard(
              store.urlFor(link),
              suppressWatcher: true,
              sourcePeerId: 'share-link',
            ),
          ),
        ),
        FilesMenuItem(
          label: text.shareLinkQr,
          icon: CupertinoIcons.qrcode,
          onSelected: _open,
        ),
        FilesMenuItem(
          label: link.enabled ? text.shareLinkTurnOff : text.shareLinkTurnOn,
          icon: link.enabled
              ? CupertinoIcons.pause_circle
              : CupertinoIcons.play_circle,
          onSelected: () => unawaited(store.setEnabled(link.id, !link.enabled)),
        ),
        const FilesMenuItem.separator(),
        FilesMenuItem(
          label: text.shareLinkDelete,
          icon: CupertinoIcons.trash,
          destructive: true,
          onSelected: () => unawaited(_delete()),
        ),
      ],
    );
  }

  Future<void> _delete() async {
    final text = AppLocalizations.of(context)!;
    final confirmed = await showFilesConfirm(
      context,
      title: text.shareLinkDeleteTitle,
      detail: text.shareLinkDeleteDetail,
      confirmLabel: text.delete,
      names: [shareLinkTitle(text, link)],
      icon: CupertinoIcons.link,
    );
    if (confirmed) {
      await store.remove(link.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppLocalizations.of(context)!;
    final colors = FlowSpaceColors.of(context);
    final (dot, status) = shareLinkStatus(text, store, link);
    final subtitle = [
      '/${link.route}',
      if (link.visits > 0) text.shareLinkVisits(link.visits),
    ].join(' · ');
    final pressed = colors.dark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.05);
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: _open,
          onSecondaryTapUp: widget.touch
              ? null
              : (details) => unawaited(_menu(details.globalPosition)),
          onLongPressStart: widget.touch
              ? (details) {
                  setState(() => _pressed = false);
                  unawaited(_menu(details.globalPosition));
                }
              : null,
          child: AnimatedContainer(
            duration: Duration(milliseconds: _pressed ? 0 : 200),
            color: _pressed
                ? pressed
                : _hover && !widget.touch
                ? pressed.withValues(alpha: pressed.a * 0.6)
                : Colors.transparent,
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: Row(
              children: [
                SizedBox(width: 30, height: 30, child: _LinkIcon(link: link)),
                const SizedBox(width: 16),
                Expanded(
                  child: Opacity(
                    opacity: link.enabled ? 1 : 0.55,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                shareLinkTitle(text, link),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.label,
                                  fontSize: 15.5,
                                ),
                              ),
                            ),
                            if (link.hasPassword) ...[
                              const SizedBox(width: 5),
                              Icon(
                                CupertinoIcons.lock_fill,
                                size: 11,
                                color: colors.tertiaryLabel,
                                semanticLabel: text.shareLinkPasswordProtected,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 1),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.secondaryLabel,
                            fontSize: 12.5,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _Dot(color: dot),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.secondaryLabel,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  CupertinoIcons.chevron_forward,
                  size: 15,
                  color: colors.tertiaryLabel,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The dot colour and the word for a link's state.
(Color, String) shareLinkStatus(
  AppLocalizations text,
  ShareLinkStore store,
  ShareLink link,
) {
  if (!link.enabled) {
    return (const Color(0xFF8E8E93), text.shareLinkStatusOff);
  }
  return switch (store.availabilityOf(link)) {
    ShareAvailability.available => (
      store.serviceOn ? _green : const Color(0xFF8E8E93),
      text.shareLinkStatusOn,
    ),
    ShareAvailability.partlyMissing => (
      _orange,
      text.shareLinkStatusPartlyMissing,
    ),
    ShareAvailability.missing => (_orange, text.shareLinkStatusMissing),
  };
}

/// The link's item icon (one item) or a stack (several).
class _LinkIcon extends StatelessWidget {
  const _LinkIcon({required this.link});

  final ShareLink link;

  @override
  Widget build(BuildContext context) {
    final first = link.items.first;
    if (link.items.length == 1) {
      return FsFileIcon(
        entry: FsEntry(
          name: first.name,
          isDir: first.isDir,
          size: 0,
          modifiedMs: 0,
        ),
        size: 30,
      );
    }
    return const _Tile(
      icon: CupertinoIcons.square_stack_3d_up_fill,
      color: Color(0xFF5856D6),
    );
  }
}
