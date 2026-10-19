import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../widget/device_glyph.dart';
import '../../remote_files/fs_browser.dart';
import '../../remote_files/fs_copies.dart';
import '../../remote_files/fs_host_files.dart';
import '../../share_links/share_link_store.dart';
import '../../widget/island/sources/copy_source.dart' show IslandCopyHooks;
import '../window_stream/flow_space_theme.dart';
import '../window_stream/flow_space_widgets.dart';
import 'files_copy_island.dart';
import 'files_desktop.dart' show FinderColors;
import 'files_icons.dart';
import 'files_menu.dart';
import 'files_model.dart';
import 'files_share_sheet.dart';
import 'files_shares.dart';
import 'files_transfers.dart';
import 'remote_files_page.dart';

/// The file manager on a phone, laid out like the Files app: "浏览" lists
/// the devices and this phone's favorite folders; folders push in from the
/// right; "选择" picks items to copy to another device or delete.
class FilesPhoneView extends StatefulWidget {
  const FilesPhoneView({
    super.key,
    required this.controller,
    required this.actions,
    required this.startAtDevice,
  });

  final FilesController controller;
  final FilesActions actions;

  /// Opened for one device: start in its files rather than on "浏览".
  final bool startAtDevice;

  @override
  State<FilesPhoneView> createState() => _FilesPhoneViewState();
}

class _FilesPhoneViewState extends State<FilesPhoneView> {
  late bool _atRoot = !widget.startAtDevice;

  /// The list of copies is on screen (over wherever it was opened from).
  bool _transfers = false;

  /// This device's share links are shown (from the browse page).
  bool _shares = false;
  bool _selecting = false;
  bool _forward = true;

  /// Items picked with "拷贝到…", waiting for a destination.
  List<FilesItem>? _copying;
  final _search = TextEditingController();

  FilesController get controller => widget.controller;
  FilesActions get actions => widget.actions;

  /// Lends the app's island "show all" and "show in Files" while open.
  late final VoidCallback _detachIsland;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    controller.revealed.addListener(_onRevealed);
    _detachIsland = IslandCopyHooks.attach(
      showAll: _showTransfers,
      reveal: _reveal,
    );
  }

  @override
  void dispose() {
    _detachIsland();
    controller.removeListener(_onChanged);
    controller.revealed.removeListener(_onRevealed);
    _slowTimer?.cancel();
    _spotTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_search.text != controller.query) {
      _search.text = controller.query;
    }
    // Opening a folder: the page on screen stays while it loads, and the
    // next slides in with its contents. Only a slow one slides in first,
    // to say it is coming.
    final waiting =
        !_atRoot && !_transfers && !_shares && controller.showingPrevious;
    if (waiting && controller.location != _awaited) {
      _awaited = controller.location;
      _slow = false;
      _slowTimer?.cancel();
      _slowTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() => _slow = true);
        }
      });
    } else if (!waiting && _awaited != null) {
      _awaited = null;
      _slow = false;
      _slowTimer?.cancel();
    }
    setState(() {});
  }

  FilesLocation? _awaited;
  bool _slow = false;
  Timer? _slowTimer;

  /// Items just shown where a copy went: lit up for a moment, since a
  /// selection shows nothing here outside the select mode.
  Set<String> _spot = const {};
  int _spotGeneration = 0;
  Timer? _spotTimer;

  void _onRevealed() {
    final names = {...controller.selection};
    controller.clearSelection();
    _spotTimer?.cancel();
    setState(() {
      _spot = names;
      _spotGeneration++;
    });
    _spotTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _spot = const {});
      }
    });
  }

  /// The page last shown: 'browse', 'transfers' or a folder.
  Object? _shownPage;

  /// The page to show now.
  Object get _page {
    if (_transfers) {
      return 'transfers';
    }
    if (_shares) {
      return 'shares';
    }
    if (_atRoot) {
      return 'browse';
    }
    final shown = _shownPage;
    if (controller.showingPrevious && !_slow && shown != null) {
      return shown;
    }
    return controller.location ?? 'browse';
  }

  // ------------------------------------------------------------- navigation

  void _enter(Future<void> Function() go) {
    setState(() {
      _forward = true;
      _atRoot = false;
      _transfers = false;
      _shares = false;
      _selecting = false;
    });
    unawaited(go());
  }

  void _showTransfers() {
    if (_transfers) {
      return;
    }
    setState(() {
      _forward = true;
      _transfers = true;
      _shares = false;
      _selecting = false;
    });
  }

  void _showShares() {
    if (_shares) {
      return;
    }
    setState(() {
      _forward = true;
      _shares = true;
      _transfers = false;
      _selecting = false;
    });
  }

  void _reveal(FileCopyBatch batch) => _enter(() => controller.reveal(batch));

  void _goBack() {
    if (_selecting) {
      setState(() => _selecting = false);
      controller.clearSelection();
      return;
    }
    if (_transfers || _shares) {
      setState(() {
        _transfers = false;
        _shares = false;
        _forward = false;
      });
      return;
    }
    final here = controller.location;
    if (!_atRoot) {
      setState(() => _forward = false);
      if (here != null && here.path.isNotEmpty) {
        unawaited(controller.go(here.parent));
      } else {
        setState(() => _atRoot = true);
      }
      return;
    }
    if (_copying != null) {
      setState(() => _copying = null);
      return;
    }
    Navigator.of(context).maybePop();
  }

  String _backLabel(AppLocalizations l10n) {
    final page = _page;
    final here = page is FilesLocation ? page : null;
    final device = here == null ? null : controller.deviceById(here.deviceId);
    if (page == 'transfers' || page == 'shares') {
      return _atRoot ? l10n.remoteFilesBrowse : _title(l10n, folder: true);
    }
    if (page == 'browse' || here == null || device == null) {
      return l10n.back;
    }
    if (here.path.isEmpty || here.root.isEmpty) {
      return l10n.remoteFilesBrowse;
    }
    return _folderLabel(l10n, device, here.root, here.parent.path);
  }

  /// A device with one root (an iPhone's Whisper folder, a phone's own
  /// storage) is that root: its top reads as the device, as it was tapped,
  /// not as one of its favorites.
  static String _folderLabel(
    AppLocalizations l10n,
    FilesDevice device,
    String root,
    String path,
  ) {
    final only = _onlyRoot(device);
    if (path.isEmpty && only != null && only.root == root) {
      return filesDeviceName(l10n, device);
    }
    return fsFolderLabel(l10n, device, root, path);
  }

  static FsPlace? _onlyRoot(FilesDevice device) {
    final roots = [
      for (final place in device.browser?.places ?? const <FsPlace>[])
        if (place.kind == 'root') place,
    ];
    return roots.length == 1 ? roots.single : null;
  }

  String _title(AppLocalizations l10n, {bool folder = false}) {
    final page = _page;
    if (page == 'transfers' && !folder) {
      return l10n.remoteFilesTransfers;
    }
    if (page == 'shares' && !folder) {
      return l10n.shareLinksTitle;
    }
    // Under the list of copies: the folder it was opened over.
    final where = page is FilesLocation
        ? page
        : (_atRoot ? null : controller.location);
    final device = where == null ? null : controller.deviceById(where.deviceId);
    final here = where;
    if (page == 'browse' || here == null || device == null) {
      return l10n.remoteFilesBrowse;
    }
    if (here.root.isEmpty) {
      return filesDeviceName(l10n, device);
    }
    return _folderLabel(l10n, device, here.root, here.path);
  }

  // ------------------------------------------------------------- actions

  List<FsEntry> get _selectedEntries => [
    for (final entry in controller.entries)
      if (controller.selection.contains(entry.name)) entry,
  ];

  void _startCopy(List<FilesItem> items) {
    if (items.isEmpty) {
      return;
    }
    controller.clearSelection();
    setState(() {
      _copying = items;
      _selecting = false;
      _forward = false;
      _atRoot = true;
    });
  }

  Future<void> _copyHere() async {
    final items = _copying;
    final here = controller.location;
    if (items == null || here == null) {
      return;
    }
    if (await actions.copy(items, here) && mounted) {
      unawaited(HapticFeedback.lightImpact());
      setState(() => _copying = null);
    }
  }

  Future<void> _rename(FsEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await actions.askName(
      l10n.remoteFilesRename,
      entry.name,
      l10n.remoteFilesDone,
    );
    if (name != null) {
      await actions.rename(entry, name);
    }
    if (mounted) {
      setState(() => _selecting = false);
    }
  }

  Future<void> _newFolder() async {
    final l10n = AppLocalizations.of(context)!;
    final name = await actions.askName(
      l10n.remoteFilesNewFolder,
      actions.untitledFolder(),
      l10n.remoteFilesCreate,
    );
    if (name != null && name.isNotEmpty) {
      await actions.newFolder(name);
    }
  }

  Future<void> _delete(List<FilesItem> items) async {
    await actions.delete(items);
    if (mounted) {
      setState(() => _selecting = false);
    }
  }

  Future<void> _itemMenu(FsEntry entry, Offset at) async {
    final l10n = AppLocalizations.of(context)!;
    final here = controller.location!;
    final item = FilesItem(here, entry.name, isDir: entry.isDir);
    final width = MediaQuery.sizeOf(context).width;
    await showFilesMenu(
      context,
      touch: true,
      alignRight: true,
      position: Offset(width - 16, at.dy + 12),
      items: [
        FilesMenuItem(
          label: l10n.remoteFilesCopyToMenu,
          icon: CupertinoIcons.doc_on_doc,
          onSelected: () => _startCopy([item]),
        ),
        FilesMenuItem(
          label: l10n.remoteFilesRename,
          icon: CupertinoIcons.pencil,
          onSelected: () => unawaited(_rename(entry)),
        ),
        if (here.deviceId == FilesDevice.localId && shareLinksSupported())
          FilesMenuItem(
            label: l10n.shareLinkMenuCreate,
            icon: CupertinoIcons.link,
            onSelected: () =>
                unawaited(shareFilesItems(context, controller, [item])),
          ),
        const FilesMenuItem.separator(),
        FilesMenuItem(
          label: controller.hasTrash
              ? l10n.remoteFilesMoveToTrash
              : l10n.remoteFilesDelete,
          icon: CupertinoIcons.trash,
          destructive: true,
          onSelected: () => unawaited(_delete([item])),
        ),
      ],
    );
  }

  /// Long press on the folder itself, below its items.
  Future<void> _folderMenu(Offset at) async {
    final l10n = AppLocalizations.of(context)!;
    final here = controller.location;
    unawaited(HapticFeedback.mediumImpact());
    await showFilesMenu(
      context,
      touch: true,
      position: at,
      items: [
        FilesMenuItem(
          label: l10n.remoteFilesNewFolder,
          icon: CupertinoIcons.folder_badge_plus,
          onSelected: () => unawaited(_newFolder()),
        ),
        if (here != null && controller.clipboard.isNotEmpty)
          FilesMenuItem(
            label: l10n.remoteFilesPastePlain,
            icon: CupertinoIcons.doc_on_clipboard,
            onSelected: () =>
                unawaited(actions.copy(controller.clipboard, here)),
          ),
        FilesMenuItem(
          label: l10n.remoteFilesSelect,
          icon: CupertinoIcons.checkmark_circle,
          enabled: controller.entries.isNotEmpty,
          onSelected: () => setState(() => _selecting = true),
        ),
      ],
    );
  }

  Future<void> _moreMenu(BuildContext anchor) async {
    final l10n = AppLocalizations.of(context)!;
    final box = anchor.findRenderObject()! as RenderBox;
    await showFilesMenu(
      context,
      touch: true,
      alignRight: true,
      position: box.localToGlobal(Offset(box.size.width, box.size.height + 8)),
      items: [
        FilesMenuItem(
          label: l10n.remoteFilesSelect,
          icon: CupertinoIcons.checkmark_circle,
          enabled: controller.entries.isNotEmpty,
          onSelected: () => setState(() => _selecting = true),
        ),
        FilesMenuItem(
          label: l10n.remoteFilesNewFolder,
          icon: CupertinoIcons.folder_badge_plus,
          onSelected: () => unawaited(_newFolder()),
        ),
        const FilesMenuItem.separator(),
        for (final (sort, label) in [
          (FilesSort.name, l10n.remoteFilesColumnName),
          (FilesSort.modified, l10n.remoteFilesColumnModified),
          (FilesSort.size, l10n.remoteFilesColumnSize),
          (FilesSort.kind, l10n.remoteFilesColumnKind),
        ])
          FilesMenuItem(
            label: label,
            checked: controller.sort == sort,
            icon: controller.sort == sort
                ? (controller.ascending
                      ? CupertinoIcons.chevron_up
                      : CupertinoIcons.chevron_down)
                : null,
            onSelected: () => controller.setSort(sort),
          ),
        const FilesMenuItem.separator(),
        FilesMenuItem(
          label: l10n.remoteFilesShowHidden,
          icon: CupertinoIcons.eye,
          checked: controller.showHidden,
          onSelected: controller.toggleHidden,
        ),
      ],
    );
  }

  // ------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = FlowSpaceColors.of(context);
    final ready =
        !_atRoot &&
        !_transfers &&
        !_shares &&
        controller.device?.browser != null;
    final page = _shownPage = _page;
    final key = ValueKey(page);
    final grouped = _atRoot || _transfers || _shares;
    return PopScope(
      canPop:
          _atRoot && !_transfers && !_shares && !_selecting && _copying == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _goBack();
        }
      },
      // Grouped grey behind "浏览", plain white behind a folder's list.
      child: AnimatedContainer(
        duration: FlowSpaceTokens.quickDuration,
        color: grouped || colors.dark ? colors.canvas : colors.raised,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildNavBar(context, l10n, colors, ready),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      final incoming = child.key == key;
                      final dx = (_forward ? 1 : -1) * (incoming ? 0.3 : -0.3);
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(
                            begin: Offset(dx, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: KeyedSubtree(
                      key: key,
                      child: page == 'shares'
                          ? const FilesSharesList(grouped: true)
                          : page == 'transfers'
                          ? FilesTransfersList(
                              copies: controller.copyList,
                              grouped: true,
                              onReveal: _reveal,
                            )
                          : page is FilesLocation
                          ? _buildFolder(context, l10n, colors, page)
                          : _buildBrowse(context, l10n, colors),
                    ),
                  ),
                ),
                if (_selecting) _buildSelectBar(context, l10n, colors),
                if (_copying != null) _buildCopyBar(context, l10n, colors),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavBar(
    BuildContext context,
    AppLocalizations l10n,
    FlowSpaceColors colors,
    bool ready,
  ) {
    final Widget leading = _selecting
        ? _GlassPill(
            onPressed: controller.selectAll,
            child: Text(l10n.remoteFilesSelectAll),
          )
        : _GlassPill(
            round: true,
            semanticLabel: _backLabel(l10n),
            onPressed: _goBack,
            child: const Icon(CupertinoIcons.chevron_back, size: 22),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: SizedBox(
            height: 46,
            child: Row(
              children: [
                leading,
                const Spacer(),
                if (ready && !_selecting && _copying == null)
                  Builder(
                    builder: (context) => _GlassPill(
                      round: true,
                      semanticLabel: l10n.remoteFilesMore,
                      onPressed: () => unawaited(_moreMenu(context)),
                      child: const Icon(CupertinoIcons.ellipsis, size: 20),
                    ),
                  ),
                if (_selecting)
                  _GlassPill(
                    prominent: true,
                    round: true,
                    semanticLabel: l10n.remoteFilesDone,
                    onPressed: _goBack,
                    child: const Icon(CupertinoIcons.checkmark_alt, size: 22),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: Text(
            _title(l10n),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.label,
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
            ),
          ),
        ),
        if (!_atRoot && !_transfers && !_shares && controller.device != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Row(
              children: [
                DeviceGlyph(
                  filesDeviceIcon(controller.device!),
                  size: 13,
                  color: colors.secondaryLabel,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    filesDeviceName(l10n, controller.device!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.secondaryLabel,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (ready)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: CupertinoSearchTextField(
              controller: _search,
              placeholder: l10n.remoteFilesSearch,
              onChanged: controller.setQuery,
              style: TextStyle(color: colors.label),
            ),
          )
        else
          const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildBrowse(
    BuildContext context,
    AppLocalizations l10n,
    FlowSpaceColors colors,
  ) {
    final local = controller.deviceById(FilesDevice.localId)!;
    final accent = FinderColors.of(context).accent;
    final only = _onlyRoot(local);
    final favorites = [
      for (final place in local.browser!.places)
        if (only == null || place.kind != 'root') place,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
      children: [
        if (_copying != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              l10n.remoteFilesChooseDestination,
              style: TextStyle(color: colors.secondaryLabel, fontSize: 14),
            ),
          ),
        _GroupLabel(l10n.remoteFilesLocations),
        _Group(
          children: [
            for (final device in controller.devices)
              _GroupRow(
                icon: filesDeviceIcon(device),
                iconColor: accent,
                title: filesDeviceName(l10n, device),
                subtitle: _deviceStatus(l10n, device),
                dimmed:
                    device.state == FilesDeviceState.offline ||
                    device.state == FilesDeviceState.unsupported,
                trailing: device.state == FilesDeviceState.waiting
                    ? const CupertinoActivityIndicator(radius: 8)
                    : null,
                onTap: () => _enter(() => _openDevice(device)),
              ),
          ],
        ),
        const SizedBox(height: 24),
        ListenableBuilder(
          listenable: controller.copyList,
          builder: (context, _) {
            final busy = controller.copyList.active.firstOrNull;
            return _Group(
              children: [
                _GroupRow(
                  icon: CupertinoIcons.arrow_up_arrow_down,
                  iconColor: accent,
                  title: l10n.remoteFilesTransfers,
                  subtitle: busy == null
                      ? null
                      : '${copyTitle(l10n, busy)} · ${copyStatus(l10n, busy)}',
                  trailing: busy == null
                      ? null
                      : CopyRing(batch: busy, size: 18, track: colors.hairline),
                  onTap: _showTransfers,
                ),
                if (shareLinksSupported())
                  ListenableBuilder(
                    listenable: ShareLinkStore.shared,
                    builder: (context, _) {
                      final on = ShareLinkStore.shared.enabledCount;
                      return _GroupRow(
                        icon: CupertinoIcons.link,
                        iconColor: accent,
                        title: l10n.shareLinksTitle,
                        subtitle: on == 0 || !ShareLinkStore.shared.serviceOn
                            ? null
                            : l10n.shareLinksActiveCount(on),
                        onTap: _showShares,
                      );
                    },
                  ),
              ],
            );
          },
        ),
        // "本机" already opens a sole root: favorites list only what lies
        // under it (an iPhone has none).
        if (favorites.isNotEmpty) ...[
          const SizedBox(height: 24),
          _GroupLabel(l10n.remoteFilesFavorites),
          _Group(
            children: [
              for (final place in favorites)
                _GroupRow(
                  icon: fsPlaceGlyph(place),
                  iconColor: accent,
                  title: fsPlaceLabel(l10n, place),
                  onTap: () => _enter(
                    () => controller.go(
                      FilesLocation(local.id, place.root, place.path),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _openDevice(FilesDevice device) {
    final places = device.browser?.places;
    if (places == null || places.isEmpty) {
      return controller.open(device);
    }
    return controller.go(
      FilesLocation(device.id, places.first.root, places.first.path),
    );
  }

  String? _deviceStatus(AppLocalizations l10n, FilesDevice device) {
    if (device.isLocal) {
      return null;
    }
    return switch (device.state) {
      FilesDeviceState.waiting => l10n.remoteFilesWaitingAllow(device.name),
      FilesDeviceState.denied => l10n.remoteFilesDenied(device.name),
      FilesDeviceState.noAnswer => l10n.remoteFilesNoAnswer(device.name),
      FilesDeviceState.offline => l10n.remoteFilesOffline(device.name),
      FilesDeviceState.unsupported => l10n.remoteFilesUnsupported(device.name),
      _ => null,
    };
  }

  Widget _buildFolder(
    BuildContext context,
    AppLocalizations l10n,
    FlowSpaceColors colors,
    FilesLocation page,
  ) {
    final device = controller.deviceById(page.deviceId);
    if (device == null) {
      return const SizedBox.shrink();
    }
    final name = filesDeviceName(l10n, device);
    final Widget? message = switch (device.state) {
      FilesDeviceState.waiting => FlowEmptyState(
        icon: CupertinoIcons.lock_shield,
        title: l10n.remoteFilesWaitingAllow(name),
        detail: l10n.remoteFilesWaitingDetail,
        busy: true,
        actionLabel: l10n.cancel,
        onAction: () => unawaited(controller.cancelOpen(device)),
      ),
      FilesDeviceState.idle => FlowEmptyState(
        icon: CupertinoIcons.lock_shield,
        title: l10n.remoteFilesNotAsked(name),
        actionLabel: l10n.remoteFilesAskAgain,
        onAction: () => unawaited(controller.retry()),
      ),
      FilesDeviceState.noAnswer => FlowEmptyState(
        icon: CupertinoIcons.clock,
        title: l10n.remoteFilesNoAnswer(name),
        detail: l10n.remoteFilesNoAnswerDetail,
        actionLabel: l10n.windowStreamRetry,
        onAction: () => unawaited(controller.retry()),
      ),
      FilesDeviceState.denied => FlowEmptyState(
        icon: CupertinoIcons.hand_raised,
        title: l10n.remoteFilesDenied(name),
        actionLabel: l10n.remoteFilesAskAgain,
        onAction: () => unawaited(controller.retry()),
      ),
      FilesDeviceState.offline => FlowEmptyState(
        icon: CupertinoIcons.wifi_slash,
        title: l10n.remoteFilesOffline(name),
        actionLabel: l10n.windowStreamRetry,
        onAction: () => unawaited(controller.retry()),
      ),
      FilesDeviceState.unsupported => FlowEmptyState(
        icon: CupertinoIcons.arrow_up_circle,
        title: l10n.remoteFilesUnsupported(name),
      ),
      FilesDeviceState.ready => null,
    };
    if (message != null) {
      return message;
    }
    // A slow folder: its page is up, its contents still on the way.
    if (controller.shownLocation != page) {
      return const Center(child: CupertinoActivityIndicator());
    }
    final entries = controller.entries;
    if (entries.isEmpty) {
      if (controller.loading) {
        return const Center(child: CupertinoActivityIndicator());
      }
      if (controller.error != null) {
        return FlowEmptyState(
          icon: CupertinoIcons.exclamationmark_triangle,
          title: l10n.remoteFilesFailed,
          actionLabel: l10n.windowStreamRetry,
          onAction: () => unawaited(controller.reload()),
        );
      }
      return Center(
        child: Text(
          controller.query.isEmpty
              ? l10n.remoteFilesEmptyFolder
              : l10n.remoteFilesNoResults(controller.query),
          style: TextStyle(color: colors.tertiaryLabel, fontSize: 15),
        ),
      );
    }
    final here = page;
    final spot = entries.indexWhere((entry) => _spot.contains(entry.name));
    return RefreshIndicator.adaptive(
      onRefresh: controller.reload,
      // A long press below the items is on the folder itself.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: _selecting
            ? null
            : (details) => unawaited(_folderMenu(details.globalPosition)),
        child: _FolderList(
          itemCount: entries.length,
          spotIndex: spot < 0 ? null : spot,
          spotGeneration: _spotGeneration,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final selected = controller.selection.contains(entry.name);
            return _PhoneRow(
              key: ValueKey(
                '${here.deviceId}/${here.root}/${here.path}/${entry.name}',
              ),
              controller: controller,
              entry: entry,
              selecting: _selecting,
              selected: selected,
              spotlit: _spot.contains(entry.name),
              last: index == entries.length - 1,
              onTap: (at) {
                if (_selecting) {
                  controller.select(entry.name, toggle: true);
                } else if (entry.isDir) {
                  _enter(() => controller.openEntry(entry));
                } else {
                  unawaited(_itemMenu(entry, at));
                }
              },
              onLongPress: (at) {
                unawaited(HapticFeedback.mediumImpact());
                if (_selecting) {
                  controller.select(entry.name, toggle: true);
                  return;
                }
                unawaited(_itemMenu(entry, at));
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildSelectBar(
    BuildContext context,
    AppLocalizations l10n,
    FlowSpaceColors colors,
  ) {
    final count = controller.selection.length;
    final any = count > 0;
    return _BottomBar(
      children: [
        _BarAction(
          icon: CupertinoIcons.doc_on_doc,
          label: l10n.remoteFilesCopyToMenu,
          onPressed: any ? () => _startCopy(controller.selectedItems) : null,
        ),
        if (controller.location?.deviceId == FilesDevice.localId &&
            shareLinksSupported())
          _BarAction(
            icon: CupertinoIcons.link,
            label: l10n.shareLinkBarAction,
            onPressed: any
                ? () => unawaited(
                    shareFilesItems(
                      context,
                      controller,
                      controller.selectedItems,
                    ),
                  )
                : null,
          ),
        _BarAction(
          icon: CupertinoIcons.pencil,
          label: l10n.remoteFilesRename,
          onPressed: count == 1
              ? () => unawaited(_rename(_selectedEntries.single))
              : null,
        ),
        _BarAction(
          icon: CupertinoIcons.trash,
          label: controller.hasTrash
              ? l10n.remoteFilesMoveToTrash
              : l10n.remoteFilesDelete,
          destructive: true,
          onPressed: any
              ? () => unawaited(_delete(controller.selectedItems))
              : null,
        ),
      ],
    );
  }

  Widget _buildCopyBar(
    BuildContext context,
    AppLocalizations l10n,
    FlowSpaceColors colors,
  ) {
    final items = _copying!;
    final here = controller.location;
    final ready = !_atRoot && controller.device?.browser != null;
    final problem = ready && here != null
        ? controller.copyProblem(items, here)
        : null;
    final enabled = ready && problem == null;
    final hint = !ready
        ? l10n.remoteFilesChooseDestination
        : switch (problem) {
            FilesCopyProblem.sameDevice => l10n.remoteFilesSameDevice,
            FilesCopyProblem.betweenOthers => l10n.remoteFilesBetweenOthers,
            _ => l10n.remoteFilesCopyStarted(items.length),
          };
    return _BottomBar(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              hint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.secondaryLabel, fontSize: 13),
            ),
          ),
        ),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          onPressed: () => setState(() => _copying = null),
          child: Text(l10n.cancel),
        ),
        CupertinoButton.filled(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          borderRadius: BorderRadius.circular(12),
          onPressed: enabled ? () => unawaited(_copyHere()) : null,
          child: Text(
            l10n.remoteFilesCopyHere,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- pieces

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          color: FlowSpaceColors.of(context).label,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: colors.raised,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 56),
                  child: Divider(
                    height: 0.5,
                    thickness: 0.5,
                    color: colors.hairline,
                  ),
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.dimmed = false,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return _PressableRow(
      onTap: (_) => onTap(),
      child: Opacity(
        opacity: dimmed ? 0.55 : 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
          child: Row(
            children: [
              DeviceGlyph(icon, color: iconColor, size: 24),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.label, fontSize: 17),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.secondaryLabel,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...[trailing!, const SizedBox(width: 8)],
              Icon(
                CupertinoIcons.chevron_forward,
                size: 16,
                color: colors.tertiaryLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row that darkens while pressed, like a grouped table cell.
class _PressableRow extends StatefulWidget {
  const _PressableRow({
    required this.onTap,
    required this.child,
    this.onLongPress,
  });

  /// Where the finger was, so a menu can open next to it.
  final ValueChanged<Offset> onTap;
  final ValueChanged<Offset>? onLongPress;
  final Widget child;

  @override
  State<_PressableRow> createState() => _PressableRowState();
}

class _PressableRowState extends State<_PressableRow> {
  bool _pressed = false;
  Offset _at = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => setState(() {
        _pressed = true;
        _at = details.globalPosition;
      }),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: () => widget.onTap(_at),
      onLongPressStart: widget.onLongPress == null
          ? null
          : (details) {
              setState(() => _pressed = false);
              widget.onLongPress!(details.globalPosition);
            },
      child: AnimatedContainer(
        duration: Duration(milliseconds: _pressed ? 0 : 220),
        color: _pressed
            ? (dark ? const Color(0xFF2C2C2E) : const Color(0xFFD1D1D6))
            : Colors.transparent,
        child: widget.child,
      ),
    );
  }
}

class _PhoneRow extends StatefulWidget {
  const _PhoneRow({
    super.key,
    required this.controller,
    required this.entry,
    required this.selecting,
    required this.selected,
    this.spotlit = false,
    required this.last,
    required this.onTap,
    required this.onLongPress,
  });

  /// Every row is this tall.
  static const double height = 64;

  final FilesController controller;
  final FsEntry entry;
  final bool selecting;
  final bool selected;

  /// Just shown where a copy went.
  final bool spotlit;
  final bool last;
  final ValueChanged<Offset> onTap;
  final ValueChanged<Offset> onLongPress;

  @override
  State<_PhoneRow> createState() => _PhoneRowState();
}

class _PhoneRowState extends State<_PhoneRow> {
  @override
  void initState() {
    super.initState();
    final kind = widget.entry.kind;
    if (kind == FsKind.image || kind == FsKind.video) {
      unawaited(widget.controller.thumbnail(widget.entry));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final accent = FinderColors.of(context).accent;
    final entry = widget.entry;
    final details = [
      fsDateLabel(context, entry.modifiedMs),
      if (!entry.isDir) fsSizeLabel(entry),
    ].join(' · ');
    return _PressableRow(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
        color: widget.spotlit
            ? accent.withValues(alpha: 0.16)
            : widget.selected && widget.selecting
            ? accent.withValues(alpha: 0.08)
            : Colors.transparent,
        child: Row(
          children: [
            AnimatedContainer(
              duration: FlowSpaceTokens.quickDuration,
              curve: Curves.easeOutCubic,
              width: widget.selecting ? 48 : 16,
              alignment: Alignment.centerRight,
              child: AnimatedOpacity(
                duration: FlowSpaceTokens.quickDuration,
                opacity: widget.selecting ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(
                    widget.selected
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.circle,
                    size: 24,
                    color: widget.selected ? accent : colors.tertiaryLabel,
                  ),
                ),
              ),
            ),
            Opacity(
              opacity: entry.hidden ? 0.5 : 1,
              child: FsFileIcon(
                entry: entry,
                size: 44,
                thumbnail: widget.controller.cachedThumbnail(entry),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                height: _PhoneRow.height,
                decoration: BoxDecoration(
                  border: widget.last
                      ? null
                      : Border(
                          bottom: BorderSide(
                            color: colors.hairline,
                            width: 0.5,
                          ),
                        ),
                ),
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.label, fontSize: 16),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            details,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.secondaryLabel,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (entry.isDir && !widget.selecting)
                      Icon(
                        CupertinoIcons.chevron_forward,
                        size: 16,
                        color: colors.tertiaryLabel,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A folder's rows, scrolled to the one a copy was just shown at.
class _FolderList extends StatefulWidget {
  const _FolderList({
    required this.itemCount,
    required this.itemBuilder,
    required this.spotIndex,
    required this.spotGeneration,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final int? spotIndex;
  final int spotGeneration;

  @override
  State<_FolderList> createState() => _FolderListState();
}

class _FolderListState extends State<_FolderList> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToSpot();
  }

  @override
  void didUpdateWidget(_FolderList old) {
    super.didUpdateWidget(old);
    if (old.spotGeneration != widget.spotGeneration) {
      _scrollToSpot();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToSpot() {
    final index = widget.spotIndex;
    if (index == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      final top = index * _PhoneRow.height;
      if (top >= position.pixels &&
          top + _PhoneRow.height <=
              position.pixels + position.viewportDimension) {
        return;
      }
      // A third of the way down, with the rows before it in sight.
      final target = (top - position.viewportDimension / 3).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      unawaited(
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 140),
      itemExtent: _PhoneRow.height,
      itemCount: widget.itemCount,
      itemBuilder: widget.itemBuilder,
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.raised,
        border: Border(top: BorderSide(color: colors.hairline, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final color = onPressed == null
        ? colors.tertiaryLabel
        : destructive
        ? CupertinoColors.systemRed.resolveFrom(context)
        : FinderColors.of(context).accent;
    return Expanded(
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(vertical: 4),
        onPressed: onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

/// iOS 26 style bar button: a frosted pill (or circle) floating over the
/// content, or the tinted "Done" button.
class _GlassPill extends StatefulWidget {
  const _GlassPill({
    required this.child,
    required this.onPressed,
    this.round = false,
    this.prominent = false,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool round;
  final bool prominent;

  final String? semanticLabel;

  @override
  State<_GlassPill> createState() => _GlassPillState();
}

class _GlassPillState extends State<_GlassPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final accent = FinderColors.of(context).accent;
    final enabled = widget.onPressed != null;
    final fg = widget.prominent
        ? Colors.white
        : enabled
        ? colors.label
        : colors.tertiaryLabel;
    Widget content = SizedBox(
      height: 40,
      width: widget.round ? 40 : null,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: widget.round ? 0 : 16),
        child: Center(
          child: IconTheme(
            data: IconThemeData(color: fg),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: fg,
                fontSize: 16,
                fontWeight: widget.prominent
                    ? FontWeight.w600
                    : FontWeight.w500,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
    if (widget.prominent) {
      content = DecoratedBox(
        decoration: ShapeDecoration(
          shape: const StadiumBorder(),
          color: accent,
          shadows: [
            BoxShadow(
              color: accent.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: content,
      );
    } else {
      content = _Glass(child: content);
    }
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onPressed == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                widget.onPressed!();
              },
        child: AnimatedScale(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          scale: _pressed ? 0.92 : 1,
          child: content,
        ),
      ),
    );
  }
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return ClipPath(
      clipper: const ShapeBorderClipper(shape: StadiumBorder()),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: StadiumBorder(
              side: BorderSide(
                color: colors.dark
                    ? Colors.white.withValues(alpha: 0.14)
                    : Colors.white.withValues(alpha: 0.8),
                width: 0.8,
              ),
            ),
            color: colors.dark
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.white.withValues(alpha: 0.72),
            shadows: [
              BoxShadow(
                color: Colors.black.withValues(alpha: colors.dark ? 0.3 : 0.08),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
