import 'package:whisper/new_ui/picker/device_picker.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_device_art.dart' as art;
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../helper/helper.dart' show isDesktop;
import '../../l10n/app_localizations.dart';
import '../../remote_files/fs_browser.dart';
import '../../remote_files/fs_host_files.dart';
import '../../share_links/share_link_store.dart';
import '../../widget/island/sources/copy_source.dart' show IslandCopyHooks;
import '../window_stream/flow_space_theme.dart';
import '../window_stream/flow_space_widgets.dart';
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
      _c = context.wc,
      dark = Theme.of(context).brightness == Brightness.dark;

  final FlowSpaceColors flow;
  final WhisperColors _c;
  final bool dark;

  Color get sidebar => _c.sidebarSolid;
  Color get content => _c.content;
  Color get stripe => _c.canvas;

  /// Toolbar groups and the search field.
  Color get capsule => _c.fill;

  /// The chosen segment inside a capsule.
  Color get segment => _c.raised;
  Color get accent => _c.accent;
  Color get inactiveSelection => _c.selected;
  Color get sidebarSelection => _c.selected;
  Color get hover => _c.fill;
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

  /// The filter field is showing in the path row.
  bool _filtering = false;

  /// Set by an item a moment before the listing sees the same click.
  bool _itemHit = false;

  /// Where a finger went down on the list (see the list's [Listener]).
  Offset? _backgroundTouch;

  /// The finger went down on an item, not the blank around them.
  bool _touchOnItem = false;
  Timer? _backgroundHold;

  /// A touch screen's "选择": taps add and remove items, as a click with
  /// Command or Ctrl held does.
  bool _selecting = false;

  /// This layout on a tablet: fingers, no right button, no Command key.
  static bool get _touchDevice =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  FilesController get controller => widget.controller;
  FilesActions get actions => widget.actions;

  // 48 to touch: a tablet has this list and a finger.
  static double get _rowHeight => WhisperLayout.touchPlatform ? 48 : (30);

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
    if (selected.length == 1 && !actions.refusedReadOnly(controller.location)) {
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

  Future<void> _entryMenu(
    FsEntry entry,
    Offset position, {
    bool touch = false,
  }) async {
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
      touch: touch,
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
        if (count == 1 &&
            entry.isDir &&
            controller.clipboard.isNotEmpty &&
            controller.canChange)
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
        // Its user lets this device read only: nothing to change there.
        if (controller.canChange) ...[
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

  Future<void> _backgroundMenu(Offset position, {bool touch = false}) async {
    controller.clearSelection();
    _listFocus.requestFocus();
    final l10n = AppLocalizations.of(context)!;
    await showFilesMenu(
      context,
      position: position,
      touch: touch,
      items: _folderMenuItems(l10n),
    );
  }

  List<FilesMenuItem> _folderMenuItems(AppLocalizations l10n) => [
    // No Command-A on a tablet: picking everything is here, and stays on
    // to add or take away items.
    if (_touchDevice) ...[
      FilesMenuItem(
        label: _selecting ? l10n.remoteFilesDone : l10n.remoteFilesSelect,
        icon: _selecting
            ? CupertinoIcons.checkmark_alt
            : CupertinoIcons.checkmark_circle,
        onSelected: () {
          setState(() => _selecting = !_selecting);
          if (!_selecting) controller.clearSelection();
        },
      ),
      FilesMenuItem(
        label: l10n.remoteFilesSelectAll,
        icon: CupertinoIcons.checkmark_circle,
        onSelected: () {
          setState(() => _selecting = true);
          controller.selectAll();
        },
      ),
      const FilesMenuItem.separator(),
    ],
    if (controller.canChange) ...[
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
    ],
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

  /// surfaces.md「文件」, the prototype's `placeFiles`: no sidebar of its own, its
  /// places are in the location menu; no lines; one toolbar row.
  Widget _buildNew(BuildContext context) {
    final colors = FinderColors.of(context);
    final ready = controller.device?.browser != null && !controller.panelOpen;
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildPathRow(context),
            Expanded(child: _buildContent(context, colors)),
          ],
        ),
        if (ready && controller.selection.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 18,
            child: Center(child: _buildFloatBar(context)),
          ),
      ],
    );
  }

  /// `.fhead`: back, location, the path; how many, filter, more.
  Widget _buildPathRow(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = context.wc;
    final type = WhisperType(touch: WhisperLayout.touchPlatform);
    final device = controller.device;
    final here = controller.location;
    final panel = controller.panelOpen;
    final canBack = panel || controller.canGoBack;
    final crumbs = <(String, FilesLocation)>[];
    if (device != null && here != null && !panel && here.root.isNotEmpty) {
      final parts = here.crumbs;
      for (var i = 0; i <= parts.length; i++) {
        final path = parts.sublist(0, i).join('/');
        crumbs.add((
          fsFolderLabel(l10n, device, here.root, path),
          FilesLocation(here.deviceId, here.root, path),
        ));
      }
    }
    final ready = device?.browser != null && !panel;
    final count = controller.entries.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 28),
        child: Row(
          children: [
            Opacity(
              opacity: canBack ? 1 : .35,
              child: ShellIconButton(
                touch: WhisperLayout.touchPlatform,
                glyph: WhisperGlyph.back,
                iconSize: 13,
                weight: 2,
                label: l10n.back,
                onTap: !canBack
                    ? null
                    : () {
                        if (panel) {
                          final where = controller.location;
                          if (where != null) {
                            unawaited(controller.go(where, record: false));
                          }
                        } else {
                          unawaited(controller.back());
                        }
                      },
              ),
            ),
            const SizedBox(width: 2),
            Builder(
              builder: (buttonContext) => Pressable(
                onTap: () => _openLocationMenu(buttonContext),
                radius: WhisperRadius.s,
                scale: 1,
                child: Container(
                  height: 28,
                  padding: const EdgeInsets.fromLTRB(11, 0, 8, 0),
                  decoration: BoxDecoration(
                    color: c.fill,
                    borderRadius: BorderRadius.circular(WhisperRadius.s),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Text(
                          panel
                              ? _title(l10n)
                              : device == null
                              ? ''
                              : filesDeviceName(l10n, device),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: type.note,
                            fontWeight: FontWeight.w500,
                            color: c.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      WhisperIcon(
                        WhisperGlyph.updown,
                        size: 12,
                        weight: 2,
                        color: c.ink2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  // A deep path keeps its end in view.
                  reverse: true,
                  child: Row(
                    children: [
                      for (final (label, where) in crumbs) ...[
                        const SizedBox(width: 2),
                        WhisperIcon(
                          WhisperGlyph.right,
                          size: 10,
                          weight: 2,
                          color: c.ink2,
                        ),
                        Pressable(
                          onTap: () => unawaited(controller.go(where)),
                          radius: WhisperRadius.xs,
                          scale: 1,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: type.note,
                                fontWeight: FontWeight.w500,
                                color: c.ink,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (_filtering)
              SizedBox(
                width: 160,
                height: 28,
                child: CupertinoSearchTextField(
                  controller: _search,
                  focusNode: _searchFocus,
                  autofocus: true,
                  placeholder: l10n.remoteFilesSearch,
                  style: TextStyle(color: c.ink, fontSize: type.note),
                  itemSize: 13,
                  backgroundColor: c.fill,
                  borderRadius: BorderRadius.circular(WhisperRadius.s),
                  padding: const EdgeInsets.fromLTRB(4, 5, 6, 5),
                  prefixInsets: const EdgeInsetsDirectional.fromSTEB(
                    8,
                    0,
                    0,
                    1,
                  ),
                  onChanged: controller.setQuery,
                  onSuffixTap: () {
                    _search.clear();
                    controller.setQuery('');
                    setState(() => _filtering = false);
                    _listFocus.requestFocus();
                  },
                ),
              )
            else if (ready)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  l10n.shellFilesCount(count),
                  style: TextStyle(fontSize: type.note, color: c.ink2),
                ),
              ),
            const SizedBox(width: 2),
            ShellIconButton(
              touch: WhisperLayout.touchPlatform,
              glyph: WhisperGlyph.search,
              iconSize: 14,
              label: l10n.remoteFilesSearch,
              onTap: ready
                  ? () => setState(() {
                      _filtering = !_filtering;
                      if (!_filtering) {
                        _search.clear();
                        controller.setQuery('');
                      }
                    })
                  : null,
            ),
            Builder(
              builder: (buttonContext) => ShellIconButton(
                touch: WhisperLayout.touchPlatform,
                glyph: WhisperGlyph.more,
                iconSize: 15,
                weight: 2.4,
                label: l10n.remoteFilesMore,
                onTap: ready
                    ? () {
                        final box =
                            buttonContext.findRenderObject()! as RenderBox;
                        unawaited(
                          showFilesMenu(
                            buttonContext,
                            position: box.localToGlobal(
                              Offset(box.size.width, box.size.height + 6),
                            ),
                            alignRight: true,
                            items: [
                              if (controller.canChange) ...[
                                FilesMenuItem(
                                  label: l10n.remoteFilesNewFolder,
                                  shortcut: filesShortcut('N', shift: true),
                                  onSelected: () => unawaited(_newFolder()),
                                ),
                                const FilesMenuItem.separator(),
                              ],
                              ..._folderMenuItems(l10n),
                              const FilesMenuItem.separator(),
                              FilesMenuItem(
                                label: l10n.remoteFilesTransfers,
                                onSelected: controller.openTransfers,
                              ),
                            ],
                          ),
                        );
                      }
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// This device first, then the others that can be browsed, each followed by
  /// its favourites: what used to be a sidebar in the shell's sidebar's way.
  void _openLocationMenu(BuildContext buttonContext) {
    final l10n = AppLocalizations.of(context)!;
    final box = buttonContext.findRenderObject()! as RenderBox;
    final current = controller.location?.deviceId;
    final items = <FilesMenuItem>[];
    for (final device in controller.devices) {
      if (device.state == FilesDeviceState.offline ||
          device.state == FilesDeviceState.unsupported) {
        continue;
      }
      final places = device.browser?.places ?? const <FsPlace>[];
      items.add(
        FilesMenuItem(
          label: filesDeviceName(l10n, device),
          leading: _DeviceMenuGlyph(device: device),
          checked: device.id == current,
          onSelected: () {
            if (device.id == current) return;
            if (places.isEmpty) {
              unawaited(controller.open(device));
            } else {
              unawaited(
                controller.go(
                  FilesLocation(
                    device.id,
                    places.first.root,
                    places.first.path,
                  ),
                ),
              );
            }
          },
        ),
      );
      if (device.id == current) {
        for (final place in places) {
          final where = FilesLocation(device.id, place.root, place.path);
          items.add(
            FilesMenuItem(
              label: fsPlaceLabel(l10n, place),
              leading: const SizedBox(width: 18),
              onSelected: () => unawaited(controller.go(where)),
            ),
          );
        }
      }
    }
    unawaited(
      showFilesMenu(
        buttonContext,
        position: box.localToGlobal(Offset(0, box.size.height + 6)),
        items: items,
      ),
    );
  }

  /// `.float-bar`: what can be done with the selection.
  Widget _buildFloatBar(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = controller.selectedItems;
    final local = controller.location?.deviceId == FilesDevice.localId;
    const shape = StadiumBorder();
    Widget sendTo({required bool primary}) => Builder(
      builder: (buttonContext) => ShellButton(
        label: l10n.shellFilesSendTo,
        kind: primary ? ShellButtonKind.primary : ShellButtonKind.quiet,
        onTap: () async {
          final targets = _copyTargets(l10n, items);
          final picked = await showDevicePicker(
            buttonContext,
            title: items.length == 1
                ? l10n.pickerSendFile(items.single.name)
                : l10n.pickerSendItems(items.length),
            touch: false,
            anchor: buttonContext,
            devices: [
              for (final (i, target) in targets.indexed)
                DevicePickerEntry(
                  id: '$i',
                  name: target.label,
                  glyph: WhisperGlyph.folder,
                ),
            ],
          );
          if (picked != null) targets[int.parse(picked)].onSelected?.call();
        },
      ),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: WhisperShadow.e2(Theme.of(context).brightness),
      ),
      child: WhisperGlass(
        kind: GlassKind.control,
        shape: shape,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (local) ...[
                sendTo(primary: true),
                const SizedBox(width: 2),
                if (shareLinksSupported())
                  ShellButton(
                    label: l10n.shareLinksTitle,
                    kind: ShellButtonKind.quiet,
                    onTap: () =>
                        unawaited(shareFilesItems(context, controller, items)),
                  ),
              ] else ...[
                ShellButton(
                  label: l10n.shellFilesCopyHere,
                  kind: ShellButtonKind.primary,
                  onTap: () => unawaited(_copyToThisDevice(items)),
                ),
                const SizedBox(width: 2),
                sendTo(primary: false),
              ],
              const SizedBox(width: 2),
              ShellIconButton(
                touch: WhisperLayout.touchPlatform,
                glyph: WhisperGlyph.x,
                iconSize: 13,
                color: context.wc.accentText,
                label: l10n.cancel,
                onTap: controller.clearSelection,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Into this device's first favourite: its downloads.
  Future<void> _copyToThisDevice(List<FilesItem> items) async {
    final local = controller.deviceById(FilesDevice.localId);
    final places = local?.browser?.places ?? const <FsPlace>[];
    if (local == null || places.isEmpty) return;
    FsPlace target = places.first;
    for (final place in places) {
      if (place.kind == 'downloads') {
        target = place;
        break;
      }
    }
    await actions.copy(
      items,
      FilesLocation(local.id, target.root, target.path),
    );
  }

  /// What a device that cannot show files yet says, with its picture.
  Widget? _newMessage(FilesDevice device, String name, AppLocalizations l10n) {
    Widget state(String title, {String body = '', Widget? action}) =>
        ShellDeviceState(
          art: art.DeviceArt(
            kind: art.deviceKindFor(device.platform),
            wallpaper: device.isLocal
                ? art.DeviceWallpaper.self
                : art.DeviceWallpaper.forPairingOrder(device.id.hashCode.abs()),
            size: 84,
          ),
          title: title,
          body: body,
          action: action,
        );
    ShellButton retry(String label, VoidCallback onTap) => ShellButton(
      label: label,
      kind: ShellButtonKind.primary,
      large: true,
      onTap: onTap,
    );
    return switch (device.state) {
      FilesDeviceState.waiting => state(
        l10n.shellFilesAskOnDevice(name),
        action: ShellButton(
          label: l10n.cancel,
          large: true,
          onTap: () => unawaited(controller.cancelOpen()),
        ),
      ),
      FilesDeviceState.idle => state(
        l10n.remoteFilesNotAsked(name),
        action: retry(
          l10n.remoteFilesAskAgain,
          () => unawaited(controller.retry()),
        ),
      ),
      FilesDeviceState.noAnswer => state(
        l10n.remoteFilesNoAnswer(name),
        body: l10n.remoteFilesNoAnswerDetail,
        action: retry(
          l10n.windowStreamRetry,
          () => unawaited(controller.retry()),
        ),
      ),
      FilesDeviceState.denied => state(
        l10n.shellFilesDenied(name),
        action: retry(
          l10n.windowStreamRetry,
          () => unawaited(controller.retry()),
        ),
      ),
      FilesDeviceState.offline => state(
        l10n.shellNotConnected(name),
        action: retry(
          l10n.windowStreamRetry,
          () => unawaited(controller.retry()),
        ),
      ),
      FilesDeviceState.unsupported => state(l10n.remoteFilesUnsupported(name)),
      FilesDeviceState.ready => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    return _buildNew(context);
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
    final Widget? message = _newMessage(device, name, l10n);
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
        if (filesTouchPointer(event.kind)) {
          // A finger may be starting a scroll: decided when it lifts.
          // Held still on the blank, it opens the folder's menu.
          _backgroundTouch = event.position;
          final onItem = _touchOnItem;
          _touchOnItem = false;
          _backgroundHold?.cancel();
          _backgroundHold = onItem
              ? null
              : Timer(kLongPressTimeout, () {
                  _backgroundHold = null;
                  _backgroundTouch = null;
                  unawaited(HapticFeedback.selectionClick());
                  unawaited(_backgroundMenu(event.position, touch: true));
                });
          return;
        }
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
      onPointerMove: (event) {
        final down = _backgroundTouch;
        if (down != null && (event.position - down).distance > kTouchSlop) {
          _backgroundHold?.cancel();
          _backgroundHold = null;
        }
      },
      onPointerUp: (event) {
        _backgroundHold?.cancel();
        _backgroundHold = null;
        final down = _backgroundTouch;
        _backgroundTouch = null;
        final onItem = _itemHit;
        _itemHit = false;
        if (down == null ||
            onItem ||
            (event.position - down).distance > kTouchSlop) {
          return;
        }
        _listFocus.requestFocus();
        controller.clearSelection();
      },
      onPointerCancel: (_) {
        _backgroundHold?.cancel();
        _backgroundHold = null;
        _backgroundTouch = null;
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
        final newColumns = _NewColumns.forWidth(constraints.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _NewListHeader(controller: controller, columns: newColumns),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                itemExtent: _rowHeight,
                // Always some room below the last row, for a right click on
                // the folder itself (New Folder, Paste…).
                padding: EdgeInsets.only(bottom: 72),
                itemCount: entries.length,
                itemBuilder: (context, index) => _item(
                  entries[index],
                  (dropping) => _NewListRow(
                    entry: entries[index],
                    columns: newColumns,
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
      onTouchStart: () => _touchOnItem = true,
      onDown: () {
        _itemHit = true;
        _listFocus.requestFocus();
        if (_primaryPressed || _selecting) {
          controller.select(entry.name, toggle: true);
        } else if (HardwareKeyboard.instance.isShiftPressed) {
          controller.select(entry.name, extend: true);
        } else if (!selected) {
          controller.select(entry.name);
        }
      },
      onUp: () {
        // A plain click on one of several selected items keeps them all
        // until it is clear that it was not the start of a drag. Picking
        // with taps, the tap has already added or taken it away.
        if (!_selecting &&
            selected &&
            !_primaryPressed &&
            !HardwareKeyboard.instance.isShiftPressed &&
            controller.selection.length > 1) {
          controller.select(entry.name);
        }
      },
      onDoubleClick: () {
        if (entry.isDir && !_selecting) {
          unawaited(controller.openEntry(entry));
        }
      },
      onTouchOpen: WhisperLayout.touchPlatform && entry.isDir && !_selecting
          ? () => unawaited(controller.openEntry(entry))
          : null,
      onSecondary: (position) {
        _itemHit = true;
        unawaited(_entryMenu(entry, position));
      },
      onLongPress: (position) {
        _itemHit = true;
        unawaited(_entryMenu(entry, position, touch: true));
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
      // A held finger moving on drags; letting go opens the menu.
      liftOnHold: false,
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
          padding: const EdgeInsets.fromLTRB(12, _iconTop, 12, 72),
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

// ----------------------------------------------------------------- toolbar

// ----------------------------------------------------------------- listing

/// surfaces.md「文件」: icon 20, name flexing, size 84, date 76, kind 90 past 800.
/// As the content narrows they go in that order: kind, size, date.
class _NewColumns {
  const _NewColumns({
    required this.date,
    required this.size,
    required this.kind,
  });

  factory _NewColumns.forWidth(double width) =>
      _NewColumns(date: width >= 360, size: width >= 460, kind: width > 800);

  final bool date, size, kind;

  static const double gap = 10, sizeWidth = 84, dateWidth = 76, kindWidth = 90;
}

/// `.fcols`.
class _NewListHeader extends StatelessWidget {
  const _NewListHeader({required this.controller, required this.columns});

  final FilesController controller;
  final _NewColumns columns;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = context.wc;
    final type = WhisperType(touch: WhisperLayout.touchPlatform);
    Widget cell(String label, FilesSort sort) {
      final active = controller.sort == sort;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => controller.setSort(sort),
        child: Row(
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: type.tiny, color: c.ink2),
              ),
            ),
            if (active) ...[
              const SizedBox(width: 3),
              RotatedBox(
                quarterTurns: controller.ascending ? 3 : 1,
                child: WhisperIcon(
                  WhisperGlyph.right,
                  size: 8,
                  weight: 2,
                  color: c.ink2,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 0, 26, 3),
      child: Row(
        children: [
          const SizedBox(width: 20 + _NewColumns.gap),
          Expanded(child: cell(l10n.remoteFilesColumnName, FilesSort.name)),
          if (columns.kind) ...[
            const SizedBox(width: _NewColumns.gap),
            SizedBox(
              width: _NewColumns.kindWidth,
              child: cell(l10n.remoteFilesColumnKind, FilesSort.kind),
            ),
          ],
          if (columns.size) ...[
            const SizedBox(width: _NewColumns.gap),
            SizedBox(
              width: _NewColumns.sizeWidth,
              child: cell(l10n.remoteFilesColumnSize, FilesSort.size),
            ),
          ],
          if (columns.date) ...[
            const SizedBox(width: _NewColumns.gap),
            SizedBox(
              width: _NewColumns.dateWidth,
              child: cell(l10n.remoteFilesColumnModified, FilesSort.modified),
            ),
          ],
        ],
      ),
    );
  }
}

/// `.frow`: no lines, no stripes. Selected is solid accent with white text.
class _NewListRow extends StatefulWidget {
  const _NewListRow({
    required this.entry,
    required this.columns,
    required this.selected,
    required this.focused,
    required this.renaming,
    required this.onRenamed,
    required this.dropping,
  });

  final FsEntry entry;
  final _NewColumns columns;
  final bool selected, focused, renaming, dropping;
  final void Function(FsEntry entry, String? name) onRenamed;

  @override
  State<_NewListRow> createState() => _NewListRowState();
}

class _NewListRowState extends State<_NewListRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: WhisperLayout.touchPlatform);
    final l10n = AppLocalizations.of(context)!;
    final entry = widget.entry;
    final strong = (widget.selected && widget.focused) || widget.dropping;
    final background = strong
        ? c.accent
        : widget.selected
        ? c.selected
        : _hover
        ? c.fill
        : Colors.transparent;
    final primary = strong ? c.onAccent : c.ink;
    final second = strong ? c.onAccent : c.ink2;
    final numbers = TextStyle(
      fontSize: type.note,
      color: second,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(WhisperRadius.xs),
        ),
        child: Row(
          children: [
            Opacity(
              opacity: entry.hidden ? .5 : 1,
              child: SizedBox(
                width: 20,
                child: Center(
                  child: entry.isDir
                      ? const WhisperFolderArt(size: 18)
                      : const WhisperDocArt(size: 18),
                ),
              ),
            ),
            const SizedBox(width: _NewColumns.gap),
            Expanded(
              child: widget.renaming
                  ? _RenameField(
                      entry: entry,
                      fontSize: type.body,
                      onDone: (name) => widget.onRenamed(entry, name),
                    )
                  : Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.body,
                        color: entry.hidden
                            ? primary.withValues(alpha: .6)
                            : primary,
                      ),
                    ),
            ),
            if (widget.columns.kind) ...[
              const SizedBox(width: _NewColumns.gap),
              SizedBox(
                width: _NewColumns.kindWidth,
                child: Text(
                  fsKindLabel(l10n, entry),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: numbers,
                ),
              ),
            ],
            if (widget.columns.size) ...[
              const SizedBox(width: _NewColumns.gap),
              SizedBox(
                width: _NewColumns.sizeWidth,
                child: Text(fsSizeLabel(entry), maxLines: 1, style: numbers),
              ),
            ],
            if (widget.columns.date) ...[
              const SizedBox(width: _NewColumns.gap),
              SizedBox(
                width: _NewColumns.dateWidth,
                child: Text(
                  shellShortDate(context, entry.modifiedMs),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: numbers,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DeviceMenuGlyph extends StatelessWidget {
  const _DeviceMenuGlyph({required this.device});

  final FilesDevice device;

  @override
  Widget build(BuildContext context) => art.DeviceGlyph(
    kind: art.deviceKindFor(device.platform),
    color: IconTheme.of(context).color ?? context.wc.accent,
    size: 18,
  );
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
    this.onTouchStart,
    this.onLongPress,
    this.onTouchOpen,
  });

  /// A finger went down here (the list tells it from one on its blank).
  final VoidCallback? onTouchStart;

  /// One tap opens this: a folder under a finger.
  final VoidCallback? onTouchOpen;

  /// A finger held still and let go: the menu a right click opens.
  final ValueChanged<Offset>? onLongPress;
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

  /// A finger's press waits for its release: it may be the start of a
  /// scroll, which must not select (or clear) anything.
  bool _touch = false;
  bool _touchDouble = false;

  /// The finger has been down a long press (its menu when let go).
  bool _held = false;
  Timer? _holdTimer;

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

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
        _touch = filesTouchPointer(event.kind);
        if (_touch) {
          _touchDouble = isDouble;
          _held = false;
          _holdTimer?.cancel();
          _holdTimer = Timer(kLongPressTimeout, () => _held = true);
          widget.onTouchStart?.call();
          return;
        }
        widget.onDown();
        if (isDouble) {
          widget.onDoubleClick();
        }
      },
      onPointerMove: (event) {
        // As soon as it is a drag: a system drag takes the pointer and the
        // window may not see it move any further. A finger scrolls.
        if ((event.position - _downAt).distance >
            (_touch ? kTouchSlop : FilesSlopDragRecognizer.slop)) {
          _moved = true;
        }
      },
      onPointerUp: (event) {
        _holdTimer?.cancel();
        if (_moved) {
          return;
        }
        final longPress = widget.onLongPress;
        if (_touch && _held && longPress != null) {
          longPress(event.position);
          return;
        }
        if (_touch) {
          // A finger has no double click to spare: one tap goes into a folder.
          if (widget.onTouchOpen case final open?) {
            open();
            return;
          }
          widget.onDown();
          if (_touchDouble) {
            widget.onDoubleClick();
          }
        }
        widget.onUp();
      },
      onPointerCancel: (_) => _moved = true,
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
    this.liftOnHold = true,
  });

  /// See [FilesSlopDragRecognizer.liftOnHold].
  final bool liftOnHold;

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => FilesSlopDragRecognizer(liftOnHold: liftOnHold)..onStart = onStart;
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
                      color: Radix.red9,
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
