import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../helper/helper.dart' show isDesktop;
import '../../l10n/app_localizations.dart';
import '../../model/file_transfer.dart';
import '../../remote_files/fs_browser.dart';
import '../../remote_files/fs_host_files.dart';
import '../../share_links/share_link_store.dart';
import '../../widget/island/sources/copy_source.dart' show IslandCopyHooks;
import '../window_stream/flow_space_theme.dart';
import '../window_stream/flow_space_widgets.dart';
import 'files_copy_island.dart';
import 'files_drag.dart';
import 'files_icons.dart';
import 'files_menu.dart';
import 'files_model.dart';
import 'files_share_sheet.dart';
import 'files_shares.dart';
import 'files_transfers.dart';
import 'remote_files_page.dart';

export 'files_drag.dart' show FilesDragData;

/// Finder's surfaces and selection colours, light and dark.
class FinderColors {
  FinderColors.of(BuildContext context)
    : flow = FlowSpaceColors.of(context),
      dark = Theme.of(context).brightness == Brightness.dark;

  final FlowSpaceColors flow;
  final bool dark;

  Color get sidebar => dark ? const Color(0xFF2B2B2E) : const Color(0xFFF2F2F5);
  Color get content => dark ? const Color(0xFF1E1E20) : Colors.white;
  Color get stripe => dark ? const Color(0xFF242427) : const Color(0xFFF6F6F8);

  /// Toolbar groups and the search field.
  Color get capsule => dark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.045);

  /// The chosen segment inside a capsule.
  Color get segment => dark ? const Color(0xFF5A5A5E) : Colors.white;
  Color get accent => dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
  Color get inactiveSelection =>
      dark ? const Color(0xFF3A3A3D) : const Color(0xFFDCDCDF);
  Color get sidebarSelection => dark
      ? Colors.white.withValues(alpha: 0.1)
      : Colors.black.withValues(alpha: 0.08);
  Color get hover => dark
      ? Colors.white.withValues(alpha: 0.06)
      : Colors.black.withValues(alpha: 0.05);
  Color get hairline => flow.hairline;
  Color get label => flow.label;
  Color get secondaryLabel => flow.secondaryLabel;
  Color get tertiaryLabel => flow.tertiaryLabel;
}

bool get _primaryPressed => Platform.isMacOS
    ? HardwareKeyboard.instance.isMetaPressed
    : HardwareKeyboard.instance.isControlPressed;

SingleActivator _primary(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool repeats = true,
}) => SingleActivator(
  key,
  meta: Platform.isMacOS,
  control: !Platform.isMacOS,
  shift: shift,
  includeRepeats: repeats,
);

/// The desktop file manager, laid out like a Finder window: sidebar with
/// favorites and devices, toolbar, list or icon view, path and status bar.
class FinderView extends StatefulWidget {
  const FinderView({
    super.key,
    required this.controller,
    required this.actions,
  });

  final FilesController controller;
  final FilesActions actions;

  @override
  State<FinderView> createState() => _FinderViewState();
}

class _FinderViewState extends State<FinderView> {
  final _listFocus = FocusNode(debugLabel: 'files-listing');
  final _searchFocus = FocusNode(debugLabel: 'files-search');
  final _search = TextEditingController();
  final _scroll = ScrollController();

  /// The icon view's own, so the two can cross over without sharing one.
  final _iconScroll = ScrollController();
  String? _renaming;
  int _columns = 1;

  /// Set by an item a moment before the listing sees the same click.
  bool _itemHit = false;

  FilesController get controller => widget.controller;
  FilesActions get actions => widget.actions;

  static const double _rowHeight = 26;

  /// On phones and tablets the app's island shows copies; this lends it
  /// "show all" and "show in Files" while open.
  VoidCallback? _detachIsland;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    controller.revealed.addListener(_onRevealed);
    _listFocus.addListener(() => setState(() {}));
    if (!isDesktop()) {
      _detachIsland = IslandCopyHooks.attach(
        showAll: controller.openTransfers,
        reveal: (batch) => unawaited(controller.reveal(batch)),
      );
    }
  }

  @override
  void dispose() {
    _detachIsland?.call();
    controller.removeListener(_onChanged);
    controller.revealed.removeListener(_onRevealed);
    _listFocus.dispose();
    _searchFocus.dispose();
    _search.dispose();
    _scroll.dispose();
    _iconScroll.dispose();
    super.dispose();
  }

  FilesLocation? _shownLocation;

  void _onChanged() {
    // Only once the next folder is on screen: the one before stays as it
    // was (scrolled, searched) while it loads.
    if (controller.shownLocation != _shownLocation) {
      _shownLocation = controller.shownLocation;
      _renaming = null;
      if (_search.text != controller.query) {
        _search.text = controller.query;
      }
      for (final scroll in [_scroll, _iconScroll]) {
        if (scroll.hasClients) {
          scroll.jumpTo(0);
        }
      }
    }
    setState(() {});
  }

  // ------------------------------------------------------------- commands

  void _openSelected() {
    final selected = _selectedEntries;
    if (selected.length == 1 && selected.single.isDir) {
      unawaited(controller.openEntry(selected.single));
    }
  }

  List<FsEntry> get _selectedEntries => [
    for (final entry in controller.entries)
      if (controller.selection.contains(entry.name)) entry,
  ];

  void _startRename() {
    final selected = _selectedEntries;
    if (selected.length == 1) {
      setState(() => _renaming = selected.single.name);
    }
  }

  Future<void> _newFolder() async {
    final name = await actions.newFolder();
    if (name != null && mounted) {
      setState(() => _renaming = name);
    }
  }

  void _delete() => unawaited(actions.delete(controller.selectedItems));

  void _moveSelection(int delta, {bool extend = false}) {
    final entries = controller.entries;
    if (entries.isEmpty) {
      return;
    }
    var index = -1;
    for (var i = 0; i < entries.length; i++) {
      if (controller.selection.contains(entries[i].name)) {
        index = delta > 0 ? i : (index < 0 ? i : index);
        if (delta < 0) {
          break;
        }
      }
    }
    final next = index < 0
        ? (delta > 0 ? 0 : entries.length - 1)
        : (index + delta).clamp(0, entries.length - 1);
    controller.select(entries[next].name, extend: extend);
    _reveal(next);
  }

  void _reveal(int index, {bool animate = false}) {
    final icons = controller.view == FilesView.icons;
    final scroll = icons ? _iconScroll : _scroll;
    if (!scroll.hasClients || scroll.positions.length != 1) {
      return;
    }
    final extent = icons ? _iconHeight : _rowHeight;
    final top = icons
        ? _iconTop + (index ~/ math.max(1, _columns)) * _iconHeight
        : index * _rowHeight;
    final position = scroll.position;
    double? target;
    if (top < position.pixels) {
      target = top;
    } else if (top + extent > position.pixels + position.viewportDimension) {
      target = top + extent - position.viewportDimension;
    }
    if (target == null) {
      return;
    }
    target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
    if (animate) {
      unawaited(
        scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      scroll.jumpTo(target);
    }
  }

  static const double _iconHeight = 116;
  static const double _iconTop = 14;

  /// Shows the listing another way, the selection kept and still in view.
  void _setView(FilesView view) {
    if (controller.view == view) {
      return;
    }
    controller.setView(view);
    _revealSelection();
  }

  /// Once laid out: scrolls to the first selected item.
  void _revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final entries = controller.entries;
      final first = entries.indexWhere(
        (entry) => controller.selection.contains(entry.name),
      );
      if (first >= 0) {
        _reveal(first, animate: true);
      }
    });
  }

  /// A copy shown where it went: its items are selected; keys go on from
  /// there.
  void _onRevealed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _listFocus.requestFocus();
      }
    });
    _revealSelection();
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    _primary(LogicalKeyboardKey.keyC): controller.copySelection,
    // Held down, ⌘V pastes once.
    _primary(LogicalKeyboardKey.keyV, repeats: false): () =>
        unawaited(actions.paste()),
    _primary(LogicalKeyboardKey.keyA): controller.selectAll,
    _primary(LogicalKeyboardKey.backspace): _delete,
    const SingleActivator(LogicalKeyboardKey.delete): _delete,
    _primary(LogicalKeyboardKey.keyN, shift: true): () =>
        unawaited(_newFolder()),
    _primary(LogicalKeyboardKey.keyF): _searchFocus.requestFocus,
    // As in Finder: ⌘1 icons, ⌘2 list.
    _primary(LogicalKeyboardKey.digit1): () => _setView(FilesView.icons),
    _primary(LogicalKeyboardKey.digit2): () => _setView(FilesView.list),
    _primary(LogicalKeyboardKey.keyR): () => unawaited(controller.reload()),
    _primary(LogicalKeyboardKey.arrowUp): () => unawaited(controller.up()),
    _primary(LogicalKeyboardKey.arrowDown): _openSelected,
    _primary(LogicalKeyboardKey.keyO): _openSelected,
    _primary(LogicalKeyboardKey.bracketLeft): () =>
        unawaited(controller.back()),
    _primary(LogicalKeyboardKey.bracketRight): () =>
        unawaited(controller.forward()),
    const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
        unawaited(controller.back()),
    const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () =>
        unawaited(controller.forward()),
    const SingleActivator(LogicalKeyboardKey.f2): _startRename,
    _primary(LogicalKeyboardKey.period, shift: true): controller.toggleHidden,
    const SingleActivator(LogicalKeyboardKey.enter): Platform.isMacOS
        ? _startRename
        : _openSelected,
    const SingleActivator(LogicalKeyboardKey.escape): controller.clearSelection,
    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
        _moveSelection(controller.view == FilesView.icons ? _columns : 1),
    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
        _moveSelection(controller.view == FilesView.icons ? -_columns : -1),
    const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): () =>
        _moveSelection(1, extend: true),
    const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () =>
        _moveSelection(-1, extend: true),
    if (controller.view == FilesView.icons) ...{
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          _moveSelection(1),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          _moveSelection(-1),
    },
  };

  // ------------------------------------------------------------- menus

  /// Places another device offers for "拷贝到": its own places when the
  /// items are here, this device's favorites when they are over there.
  List<FilesMenuItem> _copyTargets(
    AppLocalizations l10n,
    List<FilesItem> items,
  ) {
    if (items.isEmpty) {
      return const [];
    }
    final fromHere = items.first.location.deviceId == FilesDevice.localId;
    final targets = <FilesMenuItem>[];
    for (final device in controller.devices) {
      if (device.isLocal == fromHere || device.browser == null) {
        continue;
      }
      for (final place in device.browser!.places.take(fromHere ? 4 : 7)) {
        final where = FilesLocation(device.id, place.root, place.path);
        targets.add(
          FilesMenuItem(
            label: fromHere
                ? '${filesDeviceName(l10n, device)} · ${fsPlaceLabel(l10n, place)}'
                : fsPlaceLabel(l10n, place),
            icon: fsPlaceGlyph(place),
            onSelected: () => unawaited(actions.copy(items, where)),
          ),
        );
      }
    }
    return targets;
  }

  Future<void> _entryMenu(FsEntry entry, Offset position) async {
    if (!controller.selection.contains(entry.name)) {
      controller.select(entry.name);
    }
    _listFocus.requestFocus();
    final l10n = AppLocalizations.of(context)!;
    final count = controller.selection.length;
    final items = controller.selectedItems;
    final targets = _copyTargets(l10n, items);
    final here = controller.location!;
    _menuOpen = true;
    await showFilesMenu(
      context,
      position: position,
      items: [
        if (count == 1 && entry.isDir) ...[
          FilesMenuItem(
            label: l10n.remoteFilesOpen,
            icon: CupertinoIcons.folder,
            shortcut: filesShortcut('↓'),
            onSelected: () => unawaited(controller.openEntry(entry)),
          ),
          const FilesMenuItem.separator(),
        ],
        FilesMenuItem(
          label: l10n.remoteFilesCopy,
          icon: CupertinoIcons.doc_on_doc,
          shortcut: filesShortcut('C'),
          onSelected: controller.copySelection,
        ),
        if (targets.isNotEmpty)
          FilesMenuItem(
            label: l10n.remoteFilesCopyToSubmenu,
            icon: CupertinoIcons.arrow_up_right_square,
            children: targets,
          ),
        if (here.deviceId == FilesDevice.localId && shareLinksSupported())
          FilesMenuItem(
            label: l10n.shareLinkMenuCreate,
            icon: CupertinoIcons.link,
            onSelected: () =>
                unawaited(shareFilesItems(context, controller, items)),
          ),
        if (count == 1 && entry.isDir && controller.clipboard.isNotEmpty)
          FilesMenuItem(
            label: l10n.remoteFilesPasteInto(entry.name),
            icon: CupertinoIcons.doc_on_clipboard,
            onSelected: () => unawaited(
              actions.copy(
                controller.clipboard,
                FilesLocation(here.deviceId, here.root, here.child(entry.name)),
              ),
            ),
          ),
        const FilesMenuItem.separator(),
        FilesMenuItem(
          label: l10n.remoteFilesRename,
          icon: CupertinoIcons.pencil,
          shortcut: Platform.isMacOS ? '↩' : 'F2',
          enabled: count == 1,
          onSelected: () => setState(() => _renaming = entry.name),
        ),
        FilesMenuItem(
          label: controller.hasTrash
              ? l10n.remoteFilesMoveToTrash
              : l10n.remoteFilesDelete,
          icon: CupertinoIcons.trash,
          shortcut: filesShortcut('⌫'),
          destructive: true,
          onSelected: _delete,
        ),
        const FilesMenuItem.separator(),
        FilesMenuItem(
          label: l10n.remoteFilesNewFolder,
          icon: CupertinoIcons.folder_badge_plus,
          shortcut: filesShortcut('N', shift: true),
          onSelected: () => unawaited(_newFolder()),
        ),
      ],
    );
    _menuClosed();
  }

  /// A menu is up: the listing keeps its selection colours, as Finder's
  /// does, instead of greying out while the menu has the keyboard.
  bool _menuOpen = false;

  void _menuClosed() {
    if (mounted) {
      setState(() => _menuOpen = false);
    }
  }

  bool get _listActive => _listFocus.hasFocus || _menuOpen;

  Future<void> _backgroundMenu(Offset position) async {
    controller.clearSelection();
    _listFocus.requestFocus();
    final l10n = AppLocalizations.of(context)!;
    await showFilesMenu(
      context,
      position: position,
      items: _folderMenuItems(l10n),
    );
  }

  List<FilesMenuItem> _folderMenuItems(AppLocalizations l10n) => [
    FilesMenuItem(
      label: l10n.remoteFilesNewFolder,
      icon: CupertinoIcons.folder_badge_plus,
      shortcut: filesShortcut('N', shift: true),
      onSelected: () => unawaited(_newFolder()),
    ),
    FilesMenuItem(
      label: controller.clipboard.isEmpty
          ? l10n.remoteFilesPastePlain
          : l10n.remoteFilesPaste(controller.clipboard.length),
      icon: CupertinoIcons.doc_on_clipboard,
      shortcut: filesShortcut('V'),
      onSelected: () => unawaited(actions.paste()),
    ),
    const FilesMenuItem.separator(),
    FilesMenuItem(
      label: l10n.remoteFilesViewList,
      icon: CupertinoIcons.list_bullet,
      checked: controller.view == FilesView.list,
      shortcut: filesShortcut('2'),
      onSelected: () => _setView(FilesView.list),
    ),
    FilesMenuItem(
      label: l10n.remoteFilesViewIcons,
      icon: CupertinoIcons.square_grid_2x2,
      checked: controller.view == FilesView.icons,
      shortcut: filesShortcut('1'),
      onSelected: () => _setView(FilesView.icons),
    ),
    FilesMenuItem(
      label: l10n.remoteFilesSortBy,
      icon: CupertinoIcons.arrow_up_arrow_down,
      children: [
        for (final (sort, label) in [
          (FilesSort.name, l10n.remoteFilesColumnName),
          (FilesSort.modified, l10n.remoteFilesColumnModified),
          (FilesSort.size, l10n.remoteFilesColumnSize),
          (FilesSort.kind, l10n.remoteFilesColumnKind),
        ])
          FilesMenuItem(
            label: label,
            checked: controller.sort == sort,
            onSelected: () => controller.setSort(sort),
          ),
      ],
    ),
    const FilesMenuItem.separator(),
    FilesMenuItem(
      label: l10n.remoteFilesShowHidden,
      icon: CupertinoIcons.eye,
      checked: controller.showHidden,
      shortcut: filesShortcut('.', shift: true),
      onSelected: controller.toggleHidden,
    ),
    FilesMenuItem(
      label: l10n.remoteFilesRefresh,
      icon: CupertinoIcons.arrow_clockwise,
      shortcut: filesShortcut('R'),
      onSelected: () => unawaited(controller.reload()),
    ),
  ];

  // ------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    return ColoredBox(
      color: colors.content,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The sidebar floats in the window, as in current macOS.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
            child: SizedBox(
              width: 214,
              child: _Sidebar(controller: controller, actions: actions),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildToolbar(context, colors),
                    Expanded(child: _buildContent(context, colors)),
                    _BottomBar(controller: controller),
                  ],
                ),
                // Copies under way, at the top of the window like an island
                // (desktops; phones and tablets have the app's island).
                if (isDesktop())
                  Positioned.fill(
                    child: FilesCopyIsland(
                      copies: controller.copyList,
                      top: 10,
                      maxWidth: 380,
                      onShowAll: controller.openTransfers,
                      onReveal: (batch) => unawaited(controller.reveal(batch)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, FinderColors colors) {
    final l10n = AppLocalizations.of(context)!;
    final device = controller.device;
    final ready = device?.browser != null && !controller.panelOpen;
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
        child: Row(
          children: [
            _Capsule(
              children: [
                _ToolButton(
                  icon: CupertinoIcons.chevron_left,
                  tooltip: l10n.back,
                  onPressed: controller.canGoBack
                      ? () => unawaited(controller.back())
                      : null,
                ),
                _ToolButton(
                  icon: CupertinoIcons.chevron_right,
                  tooltip: l10n.remoteFilesForward,
                  onPressed: controller.canGoForward
                      ? () => unawaited(controller.forward())
                      : null,
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _title(l10n),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.label,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            _ViewSwitch(
              view: controller.view,
              onChanged: ready ? _setView : null,
            ),
            const SizedBox(width: 8),
            if (controller.location?.deviceId == FilesDevice.localId &&
                shareLinksSupported()) ...[
              _Capsule(
                children: [
                  _ToolButton(
                    icon: CupertinoIcons.share,
                    tooltip: l10n.shareLinkMenuCreate,
                    onPressed: ready && controller.selection.isNotEmpty
                        ? () => unawaited(
                            shareFilesItems(
                              context,
                              controller,
                              controller.selectedItems,
                            ),
                          )
                        : null,
                  ),
                ],
              ),
              const SizedBox(width: 8),
            ],
            _Capsule(
              children: [
                _ToolButton(
                  icon: CupertinoIcons.folder_badge_plus,
                  tooltip: l10n.remoteFilesNewFolder,
                  onPressed: ready ? () => unawaited(_newFolder()) : null,
                ),
                Builder(
                  builder: (context) => _ToolButton(
                    icon: CupertinoIcons.ellipsis,
                    tooltip: l10n.remoteFilesMore,
                    onPressed: ready
                        ? () {
                            final box =
                                context.findRenderObject()! as RenderBox;
                            unawaited(
                              showFilesMenu(
                                context,
                                position: box.localToGlobal(
                                  Offset(box.size.width, box.size.height + 8),
                                ),
                                alignRight: true,
                                items: _folderMenuItems(l10n),
                              ),
                            );
                          }
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 200,
              height: 32,
              child: CupertinoSearchTextField(
                controller: _search,
                focusNode: _searchFocus,
                enabled: ready,
                placeholder: l10n.remoteFilesSearch,
                style: TextStyle(color: colors.label, fontSize: 13),
                itemSize: 15,
                backgroundColor: colors.capsule,
                borderRadius: BorderRadius.circular(16),
                padding: const EdgeInsets.fromLTRB(4, 7, 8, 7),
                prefixInsets: const EdgeInsetsDirectional.fromSTEB(10, 0, 0, 2),
                onChanged: controller.setQuery,
                onSuffixTap: () {
                  _search.clear();
                  controller.setQuery('');
                  _listFocus.requestFocus();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _title(AppLocalizations l10n) {
    if (controller.transfersOpen) {
      return l10n.remoteFilesTransfers;
    }
    if (controller.sharesOpen) {
      return l10n.shareLinksTitle;
    }
    final device = controller.device;
    final here = controller.location;
    if (device == null || here == null) {
      return l10n.remoteFilesTitle;
    }
    if (here.root.isEmpty) {
      return filesDeviceName(l10n, device);
    }
    return fsFolderLabel(l10n, device, here.root, here.path);
  }

  Widget _buildContent(BuildContext context, FinderColors colors) {
    final l10n = AppLocalizations.of(context)!;
    if (controller.sharesOpen) {
      return const FilesSharesList();
    }
    if (controller.transfersOpen) {
      return FilesTransfersList(
        copies: controller.copyList,
        onReveal: (batch) => unawaited(controller.reveal(batch)),
      );
    }
    final device = controller.device;
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
        onAction: () => unawaited(controller.cancelOpen()),
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
    final entries = controller.entries;
    // Opening a folder, the one before stays until the new one is ready,
    // then it changes over once: nothing blank or stale shows in between.
    final previous = controller.showingPrevious;
    Widget body;
    if (entries.isEmpty) {
      body = controller.loading && !previous
          ? const Center(child: CupertinoActivityIndicator())
          : controller.error != null
          ? FlowEmptyState(
              icon: CupertinoIcons.exclamationmark_triangle,
              title: l10n.remoteFilesFailed,
              actionLabel: l10n.windowStreamRetry,
              onAction: () => unawaited(controller.reload()),
            )
          : Center(
              child: Text(
                controller.query.isEmpty
                    ? l10n.remoteFilesEmptyFolder
                    : l10n.remoteFilesNoResults(controller.query),
                style: TextStyle(color: colors.tertiaryLabel, fontSize: 13),
              ),
            );
    } else {
      // List or icons: one fades into the other, the new one settling up
      // from a touch smaller.
      final list = controller.view == FilesView.list;
      body = AnimatedSwitcher(
        duration: flowReduceMotion(context)
            ? Duration.zero
            : const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween(begin: 0.98, end: 1.0).animate(animation),
            child: child,
          ),
        ),
        child: KeyedSubtree(
          key: ValueKey(controller.view),
          child: list
              ? _buildList(context, colors, entries)
              : _buildIcons(context, colors, entries),
        ),
      );
    }
    // Not to be clicked into any more while the next loads; a slow folder
    // says it is coming. Always the same frame around the listing, so
    // nothing in it is rebuilt when loading starts or ends.
    body = Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(ignoring: previous, child: body),
        if (previous) const _SlowLoad(),
      ],
    );
    return _wrapListing(context, colors, body);
  }

  /// Focus, shortcuts, background clicks and both kinds of drop around
  /// the listing.
  Widget _wrapListing(BuildContext context, FinderColors colors, Widget body) {
    // Drops go where the user sees them going: the folder on screen.
    final here = controller.shownLocation ?? controller.location!;
    final device = controller.device!;
    // Files dragged in from Finder or Explorer copy straight over.
    Widget listing = FilesDropTarget(
      controller: controller,
      target: here,
      onItems: (items, target) => unawaited(actions.copy(items, target)),
      onPaths: device.isLocal
          ? null
          : (paths, target) => unawaited(actions.copyPaths(paths, target)),
      hitTestBehavior: HitTestBehavior.translucent,
      builder: (context, dropping) => Stack(
        fit: StackFit.expand,
        children: [
          // A folder changes over at once, like Finder, when it is ready.
          KeyedSubtree(
            key: ValueKey(controller.shownLocation ?? here),
            child: body,
          ),
          IgnorePointer(
            child: AnimatedOpacity(
              duration: FlowSpaceTokens.quickDuration,
              opacity: dropping ? 1 : 0,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.accent, width: 3),
                  color: colors.accent.withValues(alpha: 0.05),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    // Clicks that reach here without landing on an item clear the
    // selection or open the folder's menu.
    listing = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        final onItem = _itemHit;
        _itemHit = false;
        if (onItem) {
          return;
        }
        _listFocus.requestFocus();
        if (event.buttons == kSecondaryMouseButton) {
          unawaited(_backgroundMenu(event.position));
        } else if (event.buttons == kPrimaryButton) {
          controller.clearSelection();
        }
      },
      child: listing,
    );
    return CallbackShortcuts(
      bindings: _renaming == null ? _shortcuts : const {},
      child: Focus(focusNode: _listFocus, autofocus: true, child: listing),
    );
  }

  // ------------------------------------------------------------- list view

  Widget _buildList(
    BuildContext context,
    FinderColors colors,
    List<FsEntry> entries,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _ListColumns.forWidth(constraints.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ListHeader(controller: controller, columns: columns),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                itemExtent: _rowHeight,
                // Always some room below the last row, for a right click on
                // the folder itself (New Folder, Paste…).
                padding: const EdgeInsets.only(bottom: 56),
                itemCount: entries.length,
                itemBuilder: (context, index) => _item(
                  entries[index],
                  (dropping) => _ListRow(
                    entry: entries[index],
                    index: index,
                    columns: columns,
                    selected: controller.selection.contains(
                      entries[index].name,
                    ),
                    focused: _listActive,
                    renaming: _renaming == entries[index].name,
                    onRenamed: _finishRename,
                    dropping: dropping,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _finishRename(FsEntry entry, String? name) {
    setState(() => _renaming = null);
    _listFocus.requestFocus();
    if (name != null) {
      unawaited(actions.rename(entry, name));
    }
  }

  /// Clicks, double clicks, the context menu, dragging out and dropping
  /// into folders, the same for rows and icons.
  Widget _item(FsEntry entry, Widget Function(bool dropping) build) {
    final selected = controller.selection.contains(entry.name);
    final here = controller.shownLocation ?? controller.location!;
    Widget item = build(false);
    if (entry.isDir) {
      final target = FilesLocation(
        here.deviceId,
        here.root,
        here.child(entry.name),
      );
      item = FilesDropTarget(
        controller: controller,
        target: target,
        onItems: (items, target) => unawaited(actions.copy(items, target)),
        onPaths: controller.device!.isLocal
            ? null
            : (paths, target) => unawaited(actions.copyPaths(paths, target)),
        builder: (context, dropping) => build(dropping),
      );
    }
    item = _ClickRegion(
      onDown: () {
        _itemHit = true;
        _listFocus.requestFocus();
        if (_primaryPressed) {
          controller.select(entry.name, toggle: true);
        } else if (HardwareKeyboard.instance.isShiftPressed) {
          controller.select(entry.name, extend: true);
        } else if (!selected) {
          controller.select(entry.name);
        }
      },
      onUp: () {
        // A plain click on one of several selected items keeps them all
        // until it is clear that it was not the start of a drag.
        if (selected &&
            !_primaryPressed &&
            !HardwareKeyboard.instance.isShiftPressed &&
            controller.selection.length > 1) {
          controller.select(entry.name);
        }
      },
      onDoubleClick: () {
        if (entry.isDir) {
          unawaited(controller.openEntry(entry));
        }
      },
      onSecondary: (position) {
        _itemHit = true;
        unawaited(_entryMenu(entry, position));
      },
      child: item,
    );
    if (_renaming == entry.name) {
      return item;
    }
    final count = selected ? controller.selection.length : 1;
    if (filesSystemDrag) {
      // Out of the window too: into Finder or Explorer.
      return FilesSystemDragSource(
        controller: controller,
        items: () => controller.selection.contains(entry.name)
            ? controller.selectedItems
            : [FilesItem(here, entry.name, isDir: entry.isDir)],
        feedback: _DragFeedback(
          entry: entry,
          count: count,
          thumbnail: controller.cachedThumbnail(entry),
          offset: Offset.zero,
        ),
        child: item,
      );
    }
    return _FilesDraggable<FilesDragData>(
      data: FilesDragData(
        selected
            ? controller.selectedItems
            : [FilesItem(here, entry.name, isDir: entry.isDir)],
      ),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragFeedback(
        entry: entry,
        count: count,
        thumbnail: controller.cachedThumbnail(entry),
      ),
      child: item,
    );
  }

  // ------------------------------------------------------------- icon view

  Widget _buildIcons(
    BuildContext context,
    FinderColors colors,
    List<FsEntry> entries,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const tile = 108.0;
        _columns = math.max(1, (constraints.maxWidth - 24) ~/ tile);
        return GridView.builder(
          controller: _iconScroll,
          padding: const EdgeInsets.fromLTRB(12, _iconTop, 12, 56),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _columns,
            mainAxisExtent: _iconHeight,
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) => _item(
            entries[index],
            (dropping) => _IconTile(
              controller: controller,
              entry: entries[index],
              selected: controller.selection.contains(entries[index].name),
              focused: _listActive,
              dropGlow: dropping,
              renaming: _renaming == entries[index].name,
              onRenamed: _finishRename,
            ),
          ),
        );
      },
    );
  }
}

// ----------------------------------------------------------------- sidebar

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.controller, required this.actions});

  final FilesController controller;
  final FilesActions actions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = FinderColors.of(context);
    final local = controller.deviceById(FilesDevice.localId)!;
    final here = controller.location;
    // One row is highlighted: the first whose folder is the one shown.
    String? selectedKey;
    final rows = <Widget>[];

    void add(String key, Widget Function(bool selected) row) {
      rows.add(Builder(builder: (_) => row(selectedKey == key)));
    }

    bool matches(FilesLocation where) =>
        here != null &&
        selectedKey == null &&
        !controller.panelOpen &&
        here == where;

    rows.add(_SectionLabel(l10n.remoteFilesFavorites));
    for (final place in local.browser!.places) {
      final where = FilesLocation(local.id, place.root, place.path);
      final key = 'fav:${place.root}/${place.path}';
      if (matches(where)) {
        selectedKey = key;
      }
      add(
        key,
        (selected) => _SidebarItem(
          icon: fsPlaceGlyph(place),
          label: fsPlaceLabel(l10n, place),
          selected: selected,
          dropTarget: where,
          controller: controller,
          actions: actions,
          onTap: () => unawaited(controller.go(where)),
        ),
      );
    }
    rows.add(_SectionLabel(l10n.remoteFilesLocations));
    for (final device in controller.devices) {
      final places = device.browser?.places ?? const <FsPlace>[];
      final home = places.isEmpty
          ? null
          : FilesLocation(device.id, places.first.root, places.first.path);
      final key = 'dev:${device.id}';
      if ((home != null && matches(home)) ||
          (here?.deviceId == device.id &&
              here!.root.isEmpty &&
              selectedKey == null &&
              !controller.panelOpen)) {
        selectedKey = key;
      }
      // Another device's own places, listed under it when it is unfolded
      // (with its arrow, or by clicking it again once it is shown).
      final children = device.isLocal ? const <FsPlace>[] : places.skip(1);
      final unfoldable = children.isNotEmpty;
      final expanded =
          unfoldable && controller.sidebarExpanded.contains(device.id);
      add(
        key,
        (selected) => _SidebarItem(
          icon: fsDeviceIcon(device.platform),
          label: filesDeviceName(l10n, device),
          selected: selected,
          dimmed:
              device.state == FilesDeviceState.offline ||
              device.state == FilesDeviceState.unsupported,
          trailing: device.isLocal ? null : _DeviceBadge(state: device.state),
          expanded: unfoldable ? expanded : null,
          onExpand: () => controller.toggleSidebarDevice(device.id),
          dropTarget: home,
          controller: controller,
          actions: actions,
          onTap: () {
            if (selected && unfoldable) {
              controller.toggleSidebarDevice(device.id);
              return;
            }
            unawaited(
              home == null ? controller.open(device) : controller.go(home),
            );
          },
        ),
      );
      if (!unfoldable) {
        continue;
      }
      final childRows = <Widget>[];
      for (final place in children) {
        final where = FilesLocation(device.id, place.root, place.path);
        final childKey = 'dev:${device.id}:${place.root}/${place.path}';
        if (matches(where)) {
          // Folded away, the device stands for where one is.
          selectedKey = expanded ? childKey : key;
        }
        childRows.add(
          Builder(
            builder: (_) => _SidebarItem(
              icon: fsPlaceGlyph(place),
              label: fsPlaceLabel(l10n, place),
              indent: true,
              selected: selectedKey == childKey,
              dropTarget: where,
              controller: controller,
              actions: actions,
              onTap: () => unawaited(controller.go(where)),
            ),
          ),
        );
      }
      rows.add(_SidebarGroup(expanded: expanded, children: childRows));
    }
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: colors.hairline, width: 0.5),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        color: colors.sidebar,
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: colors.dark ? 0.35 : 0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.remoteFilesTitle,
                      style: TextStyle(
                        color: colors.label,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _ToolButton(
                    icon: CupertinoIcons.xmark,
                    tooltip: l10n.remoteFilesClose,
                    round: true,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              children: rows,
            ),
          ),
          // Copies and share links, kept at the bottom where they are easy
          // to find.
          Container(height: 0.5, color: colors.hairline),
          if (shareLinksSupported())
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: ListenableBuilder(
                listenable: ShareLinkStore.shared,
                builder: (context, _) {
                  final on = ShareLinkStore.shared.enabledCount;
                  return _SidebarItem(
                    icon: CupertinoIcons.link,
                    label: l10n.shareLinksTitle,
                    selected: controller.sharesOpen,
                    trailing: on == 0 || !ShareLinkStore.shared.serviceOn
                        ? null
                        : Text(
                            '$on',
                            style: TextStyle(
                              color: colors.secondaryLabel,
                              fontSize: 12,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                    controller: controller,
                    actions: actions,
                    onTap: controller.openShares,
                  );
                },
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              8,
              shareLinksSupported() ? 0 : 6,
              8,
              8,
            ),
            child: ListenableBuilder(
              listenable: controller.copyList,
              builder: (context, _) {
                final busy = controller.copyList.active.firstOrNull;
                return _SidebarItem(
                  icon: CupertinoIcons.arrow_up_arrow_down,
                  label: l10n.remoteFilesTransfers,
                  selected: controller.transfersOpen,
                  trailing: busy == null
                      ? null
                      : CopyRing(batch: busy, size: 16, track: colors.hairline),
                  controller: controller,
                  actions: actions,
                  onTap: controller.openTransfers,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 8, 5),
      child: Text(
        text,
        style: TextStyle(
          color: FinderColors.of(context).tertiaryLabel,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A device's places under it, unfolding and folding away smoothly.
class _SidebarGroup extends StatelessWidget {
  const _SidebarGroup({required this.expanded, required this.children});

  final bool expanded;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: expanded
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              )
            : const SizedBox(width: double.infinity),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.controller,
    required this.actions,
    this.dropTarget,
    this.trailing,
    this.indent = false,
    this.dimmed = false,
    this.expanded,
    this.onExpand,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final FilesController controller;
  final FilesActions actions;
  final FilesLocation? dropTarget;
  final Widget? trailing;
  final bool indent;
  final bool dimmed;

  /// Whether the places under it show; null when it has none.
  final bool? expanded;
  final VoidCallback? onExpand;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    final target = widget.dropTarget;
    return FilesDropTarget(
      controller: widget.controller,
      target: target,
      onItems: (items, target) => unawaited(widget.actions.copy(items, target)),
      onPaths: target == null || target.deviceId == FilesDevice.localId
          ? null
          : (paths, target) =>
                unawaited(widget.actions.copyPaths(paths, target)),
      builder: (context, dropping) {
        final fg = dropping ? Colors.white : colors.label;
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 30,
              margin: const EdgeInsets.symmetric(vertical: 0.5),
              padding: EdgeInsets.only(left: widget.indent ? 26 : 8, right: 8),
              decoration: BoxDecoration(
                color: dropping
                    ? colors.accent
                    : widget.selected
                    ? colors.sidebarSelection
                    : _hover
                    ? colors.hover
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Opacity(
                opacity: widget.dimmed ? 0.5 : 1,
                child: Row(
                  children: [
                    Icon(
                      widget.icon,
                      size: 16,
                      color: dropping ? Colors.white : colors.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg, fontSize: 13),
                      ),
                    ),
                    ?widget.trailing,
                    if (widget.expanded case final expanded?)
                      GestureDetector(
                        key: const ValueKey('files-sidebar-expand'),
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onExpand,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: SizedBox(
                            width: 16,
                            height: 30,
                            child: AnimatedRotation(
                              turns: expanded ? 0.25 : 0,
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOutCubic,
                              child: Icon(
                                CupertinoIcons.chevron_right,
                                size: 11,
                                color: dropping
                                    ? Colors.white
                                    : colors.tertiaryLabel,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DeviceBadge extends StatelessWidget {
  const _DeviceBadge({required this.state});

  final FilesDeviceState state;

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    return switch (state) {
      FilesDeviceState.waiting => const CupertinoActivityIndicator(radius: 6),
      FilesDeviceState.denied => Icon(
        CupertinoIcons.lock_fill,
        size: 11,
        color: colors.tertiaryLabel,
      ),
      FilesDeviceState.noAnswer => Icon(
        CupertinoIcons.clock,
        size: 11,
        color: colors.tertiaryLabel,
      ),
      FilesDeviceState.ready => Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: FlowSpaceTokens.live,
          shape: BoxShape.circle,
        ),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

// ----------------------------------------------------------------- toolbar

class _ToolButton extends StatefulWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.round = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// A small round button on its own (the sidebar's close button).
  final bool round;

  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    final enabled = widget.onPressed != null;
    final size = widget.round ? 26.0 : 32.0;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: widget.round ? size : 34,
            height: size,
            decoration: BoxDecoration(
              color: !enabled
                  ? Colors.transparent
                  : _pressed
                  ? colors.capsule.withValues(alpha: colors.dark ? 0.2 : 0.12)
                  : _hover || widget.round
                  ? colors.capsule
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(size / 2),
            ),
            child: Icon(
              widget.icon,
              size: widget.round ? 12 : 16,
              color: enabled ? colors.secondaryLabel : colors.tertiaryLabel,
            ),
          ),
        ),
      ),
    );
  }
}

/// A rounded group of toolbar buttons, the way macOS draws them now.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: colors.capsule,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// List / icons, a segmented capsule whose chosen half slides.
class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({required this.view, required this.onChanged});

  final FilesView view;
  final ValueChanged<FilesView>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = FinderColors.of(context);
    Widget segment(FilesView value, IconData icon, String tooltip) {
      final chosen = view == value;
      return Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onChanged == null ? null : () => onChanged!(value),
          child: SizedBox(
            width: 38,
            height: 28,
            child: Icon(
              icon,
              size: 15,
              color: onChanged == null
                  ? colors.tertiaryLabel
                  : chosen
                  ? colors.label
                  : colors.secondaryLabel,
            ),
          ),
        ),
      );
    }

    return Container(
      height: 32,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.capsule,
        borderRadius: BorderRadius.circular(16),
      ),
      child: SizedBox(
        width: 76,
        height: 28,
        child: Stack(
          children: [
            // The light slips across to the chosen one.
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: const SpringCurve(FlowSpaceTokens.snappySpring, 0.26),
              left: view == FilesView.list ? 0 : 38,
              top: 0,
              child: Container(
                width: 38,
                height: 28,
                decoration: BoxDecoration(
                  color: colors.segment,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: colors.dark ? 0.3 : 0.1,
                      ),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                segment(
                  FilesView.list,
                  CupertinoIcons.list_bullet,
                  l10n.remoteFilesViewList,
                ),
                segment(
                  FilesView.icons,
                  CupertinoIcons.square_grid_2x2,
                  l10n.remoteFilesViewIcons,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- listing

/// Which columns fit, and how wide the fixed ones are.
class _ListColumns {
  const _ListColumns({
    required this.modified,
    required this.size,
    required this.kind,
  });

  factory _ListColumns.forWidth(double width) => _ListColumns(
    modified: width >= 460 ? 168 : 0,
    size: width >= 560 ? 86 : 0,
    kind: width >= 680 ? 140 : 0,
  );

  final double modified;
  final double size;
  final double kind;
}

class _ListHeader extends StatelessWidget {
  const _ListHeader({required this.controller, required this.columns});

  final FilesController controller;
  final _ListColumns columns;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = FinderColors.of(context);
    Widget cell(String label, FilesSort sort, {bool end = false}) {
      final active = controller.sort == sort;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => controller.setSort(sort),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: end
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? colors.label : colors.secondaryLabel,
                    fontSize: 11.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (active)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    controller.ascending
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    size: 9,
                    color: colors.secondaryLabel,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    Widget divider() => Container(width: 1, height: 14, color: colors.hairline);
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.hairline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 22),
              child: cell(l10n.remoteFilesColumnName, FilesSort.name),
            ),
          ),
          if (columns.modified > 0) ...[
            divider(),
            SizedBox(
              width: columns.modified - 1,
              child: cell(l10n.remoteFilesColumnModified, FilesSort.modified),
            ),
          ],
          if (columns.size > 0) ...[
            divider(),
            SizedBox(
              width: columns.size - 1,
              child: cell(
                l10n.remoteFilesColumnSize,
                FilesSort.size,
                end: true,
              ),
            ),
          ],
          if (columns.kind > 0) ...[
            divider(),
            SizedBox(
              width: columns.kind - 1,
              child: cell(l10n.remoteFilesColumnKind, FilesSort.kind),
            ),
          ],
        ],
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.entry,
    required this.index,
    required this.columns,
    required this.selected,
    required this.focused,
    required this.renaming,
    required this.onRenamed,
    required this.dropping,
  });

  final FsEntry entry;
  final int index;
  final _ListColumns columns;
  final bool selected;
  final bool focused;
  final bool renaming;
  final void Function(FsEntry entry, String? name) onRenamed;

  /// Something is being dragged over this folder.
  final bool dropping;

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    final active = selected && focused;
    final Color background;
    if (dropping) {
      background = colors.accent.withValues(alpha: 0.85);
    } else if (selected) {
      background = active ? colors.accent : colors.inactiveSelection;
    } else {
      background = index.isOdd ? colors.stripe : Colors.transparent;
    }
    final strong = active || dropping;
    final primary = strong ? Colors.white : colors.label;
    final secondary = strong
        ? Colors.white.withValues(alpha: 0.85)
        : colors.secondaryLabel;
    final l10n = AppLocalizations.of(context)!;
    TextStyle style(Color color) =>
        TextStyle(color: color, fontSize: 13, height: 1.2);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Opacity(
              opacity: entry.hidden ? 0.5 : 1,
              child: FsFileIcon(entry: entry, size: 18, onAccent: strong),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: renaming
                  ? _RenameField(
                      entry: entry,
                      fontSize: 13,
                      onDone: (name) => onRenamed(entry, name),
                    )
                  : Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style(
                        entry.hidden ? primary.withValues(alpha: 0.6) : primary,
                      ),
                    ),
            ),
            if (columns.modified > 0)
              SizedBox(
                width: columns.modified,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    fsDateLabel(context, entry.modifiedMs),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style(secondary),
                  ),
                ),
              ),
            if (columns.size > 0)
              SizedBox(
                width: columns.size,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    fsSizeLabel(entry),
                    maxLines: 1,
                    textAlign: TextAlign.end,
                    style: style(secondary),
                  ),
                ),
              ),
            if (columns.kind > 0)
              SizedBox(
                width: columns.kind,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    fsKindLabel(l10n, entry),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style(secondary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _IconTile extends StatefulWidget {
  const _IconTile({
    required this.controller,
    required this.entry,
    required this.selected,
    required this.focused,
    required this.dropGlow,
    required this.renaming,
    required this.onRenamed,
  });

  final FilesController controller;
  final FsEntry entry;
  final bool selected;
  final bool focused;
  final bool dropGlow;
  final bool renaming;
  final void Function(FsEntry entry, String? name) onRenamed;

  @override
  State<_IconTile> createState() => _IconTileState();
}

class _IconTileState extends State<_IconTile> {
  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(_IconTile old) {
    super.didUpdateWidget(old);
    if (old.entry.name != widget.entry.name) {
      _loadThumbnail();
    }
  }

  void _loadThumbnail() {
    final kind = widget.entry.kind;
    if (kind == FsKind.image || kind == FsKind.video) {
      unawaited(widget.controller.thumbnail(widget.entry));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    final entry = widget.entry;
    final active = widget.selected && widget.focused;
    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 80,
          height: 72,
          decoration: BoxDecoration(
            color: widget.dropGlow
                ? colors.accent.withValues(alpha: 0.2)
                : widget.selected
                ? colors.sidebarSelection
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: widget.dropGlow
                ? Border.all(color: colors.accent, width: 2)
                : null,
          ),
          alignment: Alignment.center,
          child: Opacity(
            opacity: entry.hidden ? 0.5 : 1,
            child: FsFileIcon(
              entry: entry,
              size: 60,
              thumbnail: widget.controller.cachedThumbnail(entry),
            ),
          ),
        ),
        const SizedBox(height: 4),
        if (widget.renaming)
          SizedBox(
            width: 100,
            child: _RenameField(
              entry: entry,
              fontSize: 12,
              center: true,
              onDone: (name) => widget.onRenamed(entry, name),
            ),
          )
        else
          Container(
            constraints: const BoxConstraints(maxWidth: 100),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: widget.selected
                  ? (active ? colors.accent : colors.inactiveSelection)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entry.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: active ? Colors.white : colors.label,
                fontSize: 12,
                height: 1.25,
              ),
            ),
          ),
      ],
    );
  }
}

/// Finder's in-place rename: the name without its extension is selected.
class _RenameField extends StatefulWidget {
  const _RenameField({
    required this.entry,
    required this.fontSize,
    required this.onDone,
    this.center = false,
  });

  final FsEntry entry;
  final double fontSize;
  final bool center;

  /// The new name, or null when cancelled.
  final ValueChanged<String?> onDone;

  @override
  State<_RenameField> createState() => _RenameFieldState();
}

class _RenameFieldState extends State<_RenameField> {
  late final _text = TextEditingController(text: widget.entry.name);
  final _focus = FocusNode();
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final name = widget.entry.name;
    final dot = widget.entry.isDir ? -1 : name.lastIndexOf('.');
    _text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: dot > 0 ? dot : name.length,
    );
    _focus.addListener(() {
      if (!_focus.hasFocus) {
        _finish(_text.text);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _finish(String? name) {
    if (_done) {
      return;
    }
    _done = true;
    widget.onDone(name);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _finish(null);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      // Finder's: a white field with a soft accent ring, the same before
      // and after it takes focus. The field draws nothing of its own (the
      // app theme would add a filled, rounded outline inside the ring).
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.content,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(
              color: colors.accent.withValues(alpha: 0.8),
              width: 1.5,
              strokeAlign: BorderSide.strokeAlignOutside,
            ),
          ),
          shadows: [
            BoxShadow(
              color: colors.accent.withValues(alpha: 0.25),
              blurRadius: 3,
              spreadRadius: 1.5,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TextField(
            controller: _text,
            focusNode: _focus,
            maxLines: 1,
            textAlign: widget.center ? TextAlign.center : TextAlign.start,
            style: TextStyle(color: colors.label, fontSize: widget.fontSize),
            cursorHeight: widget.fontSize + 2,
            cursorColor: colors.accent,
            decoration: const InputDecoration(
              isCollapsed: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              hoverColor: Colors.transparent,
              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            ),
            onSubmitted: _finish,
          ),
        ),
      ),
    );
  }
}

/// Detects clicks without waiting for a possible double click, so the
/// selection follows the pointer at once.
class _ClickRegion extends StatefulWidget {
  const _ClickRegion({
    required this.onDown,
    required this.onUp,
    required this.onDoubleClick,
    required this.onSecondary,
    required this.child,
  });

  final VoidCallback onDown;
  final VoidCallback onUp;
  final VoidCallback onDoubleClick;
  final ValueChanged<Offset> onSecondary;
  final Widget child;

  @override
  State<_ClickRegion> createState() => _ClickRegionState();
}

class _ClickRegionState extends State<_ClickRegion> {
  Duration? _lastDown;
  Offset _downAt = Offset.zero;
  bool _moved = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (event.buttons == kSecondaryMouseButton) {
          widget.onSecondary(event.position);
          return;
        }
        if (event.buttons != kPrimaryButton) {
          return;
        }
        _moved = false;
        final last = _lastDown;
        final isDouble =
            last != null &&
            event.timeStamp - last < kDoubleTapTimeout &&
            (event.position - _downAt).distance < kDoubleTapSlop;
        _lastDown = isDouble ? null : event.timeStamp;
        _downAt = event.position;
        widget.onDown();
        if (isDouble) {
          widget.onDoubleClick();
        }
      },
      onPointerMove: (event) {
        // As soon as it is a drag: a system drag takes the pointer and the
        // window may not see it move any further.
        if ((event.position - _downAt).distance >
            FilesSlopDragRecognizer.slop) {
          _moved = true;
        }
      },
      onPointerUp: (_) {
        if (!_moved) {
          widget.onUp();
        }
      },
      child: widget.child,
    );
  }
}

/// A drag that starts only after the pointer really moved. A mouse counts
/// as dragging after a single pixel otherwise, so an ordinary click flashed
/// the drag picture.
class _FilesDraggable<T extends Object> extends Draggable<T> {
  const _FilesDraggable({
    required super.child,
    required super.feedback,
    super.data,
    super.dragAnchorStrategy,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => FilesSlopDragRecognizer()..onStart = onStart;
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({
    required this.entry,
    required this.count,
    this.thumbnail,
    this.offset = const Offset(-24, -24),
  });

  final FsEntry entry;
  final int count;
  final Uint8List? thumbnail;

  /// From the pointer (the system drag places its picture itself).
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    return Transform.translate(
      offset: offset,
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: 84,
          height: 84,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Opacity(
                  opacity: 0.85,
                  child: FsFileIcon(
                    entry: entry,
                    size: 56,
                    thumbnail: thumbnail,
                  ),
                ),
              ),
              if (count > 1)
                Positioned(
                  right: 4,
                  top: 2,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 22),
                    height: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF3B30),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: colors.content, width: 1.5),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
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

// ----------------------------------------------------------------- bottom

/// The path (clickable, like Finder's path bar) and what is selected,
/// plus copies in flight, in one quiet line.
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.controller});

  final FilesController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = FinderColors.of(context);
    final device = controller.device;
    final here = controller.location;
    final crumbs = <(IconData, String, FilesLocation?)>[];
    if (device != null && here != null && !controller.panelOpen) {
      crumbs.add((
        fsDeviceIcon(device.platform),
        filesDeviceName(l10n, device),
        null,
      ));
      if (here.root.isNotEmpty) {
        final parts = here.crumbs;
        for (var i = 0; i <= parts.length; i++) {
          final path = parts.sublist(0, i).join('/');
          crumbs.add((
            CupertinoIcons.folder_fill,
            fsFolderLabel(l10n, device, here.root, path),
            FilesLocation(here.deviceId, here.root, path),
          ));
        }
      }
    }
    final ready = device?.browser != null && !controller.panelOpen;
    final count = controller.entries.length;
    final selected = controller.selection.length;
    final status = !ready
        ? ''
        : selected == 0
        ? l10n.remoteFilesItemCount(count)
        : l10n.remoteFilesStatusSelected(selected, count);
    final Widget? activity = controller.clipboardPreparing
        ? _Activity(
            key: const ValueKey('preparing'),
            busy: true,
            text: l10n.remoteFilesClipboardPreparing(controller.stagedCount),
          )
        : controller.clipboardReady
        ? _Activity(
            key: const ValueKey('ready'),
            icon: CupertinoIcons.doc_on_clipboard_fill,
            text: l10n.remoteFilesClipboardReady,
          )
        : null;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.hairline, width: 0.5)),
      ),
      child: Row(
        children: [
          // Starts at the left like Finder's; a long path scrolls to its end.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: Row(
                    children: [
                      for (var i = 0; i < crumbs.length; i++) ...[
                        if (i > 0)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: Icon(
                              CupertinoIcons.chevron_right,
                              size: 8,
                              color: colors.tertiaryLabel,
                            ),
                          ),
                        _Crumb(
                          icon: crumbs[i].$1,
                          label: crumbs[i].$2,
                          last: i == crumbs.length - 1,
                          onTap: crumbs[i].$3 == null
                              ? null
                              : () => unawaited(controller.go(crumbs[i].$3!)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          if (status.isNotEmpty)
            Text(
              status,
              style: TextStyle(color: colors.secondaryLabel, fontSize: 11.5),
            ),
          AnimatedSize(
            duration: FlowSpaceTokens.quickDuration,
            curve: Curves.easeOutCubic,
            child: AnimatedSwitcher(
              duration: FlowSpaceTokens.quickDuration,
              child: activity == null
                  ? const SizedBox.shrink()
                  : Padding(
                      key: activity.key,
                      padding: const EdgeInsets.only(left: 14),
                      child: activity,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Crumb extends StatefulWidget {
  const _Crumb({
    required this.icon,
    required this.label,
    required this.last,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool last;
  final VoidCallback? onTap;

  @override
  State<_Crumb> createState() => _CrumbState();
}

class _CrumbState extends State<_Crumb> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    final folder = widget.icon == CupertinoIcons.folder_fill;
    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: _hover && widget.onTap != null
                ? colors.capsule
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 12,
                color: folder ? const Color(0xFF3A97EA) : colors.secondaryLabel,
              ),
              const SizedBox(width: 4),
              Text(
                widget.label,
                style: TextStyle(
                  color: widget.last ? colors.label : colors.secondaryLabel,
                  fontSize: 11.5,
                  fontWeight: widget.last ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A spinner that only shows once loading has taken a moment.
class _SlowLoad extends StatefulWidget {
  const _SlowLoad();

  @override
  State<_SlowLoad> createState() => _SlowLoadState();
}

class _SlowLoadState extends State<_SlowLoad> {
  bool _shown = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() => _shown = true);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedOpacity(
      duration: FlowSpaceTokens.quickDuration,
      opacity: _shown ? 1 : 0,
      child: const Center(child: CupertinoActivityIndicator(radius: 12)),
    ),
  );
}

class _Activity extends StatelessWidget {
  const _Activity({
    super.key,
    required this.text,
    this.icon,
    this.busy = false,
  });

  final String text;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = FinderColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          const CupertinoActivityIndicator(radius: 6)
        else if (icon != null)
          Icon(icon, size: 12, color: colors.accent),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(color: colors.secondaryLabel, fontSize: 11.5),
        ),
      ],
    );
  }
}
