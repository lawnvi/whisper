import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/phone/panel_menu.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/picker/device_picker.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/page/remote_files/files_icons.dart';
import 'package:whisper/page/remote_files/files_model.dart';
import 'package:whisper/page/remote_files/files_share_sheet.dart';
import 'package:whisper/page/remote_files/files_transfers.dart';
import 'package:whisper/page/remote_files/remote_files_page.dart';
import 'package:whisper/remote_files/fs_browser.dart';
import 'package:whisper/remote_files/fs_copies.dart';
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/theme/whisper_device_art.dart' as art;
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/island/sources/copy_source.dart'
    show IslandCopyHooks;

/// surfaces.md「文件」at touch size, the prototype's `placeFiles` in `compact`: a
/// row with where this is and what can be done, then rows of 48 without lines.
/// A tap selects a file and raises the capsule, a long press opens a sheet of
/// everything that can be done with it. All that used to be a page of its own
/// here, "浏览", is in the location button.
class PhoneFilesView extends StatefulWidget {
  const PhoneFilesView({
    super.key,
    required this.controller,
    required this.actions,
  });

  final FilesController controller;
  final FilesActions actions;

  @override
  State<PhoneFilesView> createState() => _PhoneFilesViewState();
}

class _PhoneFilesViewState extends State<PhoneFilesView> {
  FilesController get controller => widget.controller;
  FilesActions get actions => widget.actions;

  /// The list of copies is on screen, over wherever it was opened from.
  bool _transfers = false;

  /// Several can be picked: a tap adds or takes away.
  bool _selecting = false;
  bool _filtering = false;
  bool _forward = true;

  /// Picked with "拷贝到…", waiting for a folder to be picked.
  List<FilesItem>? _copying;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  /// Lends the app's island "show all" and "show in Files" while open.
  late final VoidCallback _detachIsland;

  FilesLocation? _awaited;
  bool _slow = false;
  Timer? _slowTimer;

  /// The folder last shown. Opening another, this one stays until it is ready.
  FilesLocation? _shown;

  /// Items just shown where a copy went: lit for a moment.
  Set<String> _spot = const {};
  int _spotGeneration = 0;
  Timer? _spotTimer;

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
    _searchFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_search.text != controller.query) _search.text = controller.query;
    final waiting = !_transfers && controller.showingPrevious;
    if (waiting && controller.location != _awaited) {
      _awaited = controller.location;
      _slow = false;
      _slowTimer?.cancel();
      _slowTimer = Timer(WhisperLoops.slowLoad, () {
        if (mounted) setState(() => _slow = true);
      });
    } else if (!waiting && _awaited != null) {
      _awaited = null;
      _slow = false;
      _slowTimer?.cancel();
    }
    if (mounted) setState(() {});
  }

  void _onRevealed() {
    final names = {...controller.selection};
    controller.clearSelection();
    _spotTimer?.cancel();
    setState(() {
      _spot = names;
      _spotGeneration++;
    });
    _spotTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _spot = const {});
    });
  }

  /// The folder to show now: the one before stays until the next is ready, and
  /// only a slow one comes up first, to say it is on its way.
  FilesLocation? get _page {
    final shown = _shown;
    if (controller.showingPrevious && !_slow && shown != null) return shown;
    return controller.location;
  }

  // ------------------------------------------------------------ navigation

  void _enter(Future<void> Function() go) {
    setState(() {
      _forward = true;
      _transfers = false;
      _selecting = false;
    });
    controller.clearSelection();
    unawaited(go());
  }

  void _showTransfers() {
    if (_transfers) return;
    setState(() {
      _forward = true;
      _transfers = true;
      _selecting = false;
    });
  }

  void _reveal(FileCopyBatch batch) => _enter(() => controller.reveal(batch));

  bool get _inFolder => controller.location?.path.isNotEmpty ?? false;

  void _up() {
    final here = controller.location;
    if (here == null || here.path.isEmpty) return;
    setState(() => _forward = false);
    controller.clearSelection();
    unawaited(controller.go(here.parent));
  }

  void _endFilter() {
    _search.clear();
    controller.setQuery('');
    setState(() => _filtering = false);
  }

  void _endSelection() {
    setState(() => _selecting = false);
    controller.clearSelection();
  }

  /// What the back gesture takes away first.
  void _goBack() {
    if (_filtering) return _endFilter();
    if (_selecting || controller.selection.isNotEmpty) return _endSelection();
    if (_transfers) return setState(() => _transfers = false);
    if (_inFolder) return _up();
    if (_copying != null) return setState(() => _copying = null);
    Navigator.of(context).pop();
  }

  /// The arrow in the bar leaves the page; the one in the path row goes up.
  void _leave() {
    if (_transfers) return setState(() => _transfers = false);
    if (_selecting || controller.selection.isNotEmpty) return _endSelection();
    unawaited(shellMaybePop(context));
  }

  bool get _canPop =>
      !_filtering &&
      !_selecting &&
      controller.selection.isEmpty &&
      !_transfers &&
      !_inFolder &&
      _copying == null;

  Future<void> _openDevice(FilesDevice device) {
    final places = device.browser?.places;
    if (places == null || places.isEmpty) return controller.open(device);
    return controller.go(
      FilesLocation(device.id, places.first.root, places.first.path),
    );
  }

  // --------------------------------------------------------------- actions

  List<FilesItem> _itemsFor(FsEntry entry) {
    if (controller.selection.contains(entry.name)) {
      return controller.selectedItems;
    }
    return [FilesItem(controller.location!, entry.name, isDir: entry.isDir)];
  }

  /// Into a device's downloads, or the first place it has.
  FilesLocation? _defaultPlace(FilesDevice device) {
    final places = device.browser?.places ?? const <FsPlace>[];
    if (places.isEmpty) return null;
    var target = places.first;
    for (final place in places) {
      if (place.kind == 'downloads') {
        target = place;
        break;
      }
    }
    return FilesLocation(device.id, target.root, target.path);
  }

  Future<void> _copyToThisDevice(List<FilesItem> items) async {
    final local = controller.deviceById(FilesDevice.localId);
    final where = local == null ? null : _defaultPlace(local);
    if (where == null) return;
    if (await actions.copy(items, where) && mounted) {
      unawaited(HapticFeedback.lightImpact());
      _endSelection();
    }
  }

  String _sendTitle(AppLocalizations l10n, List<FilesItem> items) =>
      items.length == 1
      ? l10n.pickerSendFile(items.first.name)
      : l10n.pickerSendItems(items.length);

  /// 发到…: this device's files go to another device, another device's files
  /// to a place here. Copies only go between this device and another one.
  Future<void> _sendTo(List<FilesItem> items) async {
    if (items.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final fromHere = items.first.location.deviceId == FilesDevice.localId;
    if (!fromHere) {
      final local = controller.deviceById(FilesDevice.localId)!;
      final places = local.browser?.places ?? const <FsPlace>[];
      final picked = await showDevicePicker(
        context,
        title: _sendTitle(l10n, items),
        touch: true,
        devices: [
          for (final (i, place) in places.indexed)
            DevicePickerEntry(
              id: '$i',
              name: fsPlaceLabel(l10n, place),
              glyph: WhisperGlyph.folder,
            ),
        ],
      );
      if (picked == null || !mounted) return;
      final place = places[int.parse(picked)];
      final where = FilesLocation(local.id, place.root, place.path);
      if (await actions.copy(items, where) && mounted) {
        unawaited(HapticFeedback.lightImpact());
        _endSelection();
      }
      return;
    }
    final picked = await showDevicePicker(
      context,
      title: _sendTitle(l10n, items),
      touch: true,
      devices: [
        for (final device in controller.devices)
          if (!device.isLocal &&
              device.state != FilesDeviceState.offline &&
              device.state != FilesDeviceState.unsupported)
            DevicePickerEntry(
              id: device.id,
              name: device.name,
              kind: art.deviceKindFor(device.platform, name: device.name),
            ),
      ],
    );
    if (picked == null || !mounted) return;
    final device = controller.deviceById(picked);
    if (device == null) return;
    final where = _defaultPlace(device);
    if (where == null) {
      // Not allowed to look there yet: ask, then pick the folder over there.
      _startCopy(items);
      unawaited(controller.open(device));
      return;
    }
    if (await actions.copy(items, where) && mounted) {
      unawaited(HapticFeedback.lightImpact());
      _endSelection();
    }
  }

  void _startCopy(List<FilesItem> items) {
    if (items.isEmpty) return;
    controller.clearSelection();
    setState(() {
      _copying = items;
      _selecting = false;
    });
  }

  Future<void> _copyHere() async {
    final items = _copying;
    final here = controller.location;
    if (items == null || here == null) return;
    if (await actions.copy(items, here) && mounted) {
      unawaited(HapticFeedback.lightImpact());
      setState(() => _copying = null);
    }
  }

  void _copyToClipboard(FsEntry? entry) {
    final l10n = AppLocalizations.of(context)!;
    if (entry != null && !controller.selection.contains(entry.name)) {
      controller.select(entry.name);
    }
    controller.copySelection();
    final count = controller.clipboard.length;
    _endSelection();
    showAppToast(l10n.phoneFilesCopied(count));
  }

  Future<void> _rename(FsEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await _askName(
      l10n.remoteFilesRename,
      entry.name,
      l10n.remoteFilesDone,
    );
    if (name != null) await actions.rename(entry, name);
    if (mounted) _endSelection();
  }

  Future<void> _newFolder() async {
    final l10n = AppLocalizations.of(context)!;
    final name = await _askName(
      l10n.remoteFilesNewFolder,
      actions.untitledFolder(),
      l10n.remoteFilesCreate,
    );
    if (name != null && name.isNotEmpty) await actions.newFolder(name);
  }

  Future<String?> _askName(String title, String initial, String confirm) =>
      showPhoneSheet<String>(
        context,
        builder: (context) =>
            _NameSheet(title: title, initial: initial, confirm: confirm),
      );

  Future<void> _delete(List<FilesItem> items) async {
    await actions.delete(items, confirm: _confirmDelete);
    if (mounted) _endSelection();
  }

  Future<bool> _confirmDelete({
    required String title,
    required String detail,
    required String confirmLabel,
    required List<String> names,
  }) async {
    unawaited(HapticFeedback.mediumImpact());
    final confirmed = await showPhoneSheet<bool>(
      context,
      builder: (context) => _ConfirmSheet(
        title: title,
        detail: detail,
        confirmLabel: confirmLabel,
        names: names,
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _share(List<FilesItem> items) async {
    await shareFilesItems(context, controller, items);
    if (mounted) _endSelection();
  }

  /// Run after the sheet has gone.
  VoidCallback _thenClose(BuildContext sheet, VoidCallback action) => () {
    Navigator.of(sheet).pop();
    action();
  };

  /// `右键（手机长按）`: everything that can be done with what was pressed.
  Future<void> _itemSheet(FsEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final items = _itemsFor(entry);
    final here = controller.location!;
    final single = items.length == 1;
    final local = here.deviceId == FilesDevice.localId;
    unawaited(HapticFeedback.mediumImpact());
    await showPhoneSheet<void>(
      context,
      builder: (sheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PhoneSheetTitle(
            single ? entry.name : l10n.remoteFilesSelected(items.length),
          ),
          const SizedBox(height: 14),
          ShellGroup(
            children: [
              if (single && entry.isDir)
                ShellRow(
                  touch: true,
                  label: l10n.remoteFilesOpen,
                  onTap: _thenClose(
                    sheet,
                    () => _enter(() => controller.openEntry(entry)),
                  ),
                ),
              ShellRow(
                touch: true,
                label: l10n.remoteFilesCopy,
                onTap: _thenClose(sheet, () => _copyToClipboard(entry)),
              ),
              if (!local)
                ShellRow(
                  touch: true,
                  label: l10n.shellFilesCopyHere,
                  onTap: _thenClose(
                    sheet,
                    () => unawaited(_copyToThisDevice(items)),
                  ),
                ),
              ShellRow(
                touch: true,
                label: l10n.shellFilesSendTo,
                onTap: _thenClose(sheet, () => unawaited(_sendTo(items))),
              ),
              ShellRow(
                touch: true,
                label: l10n.remoteFilesCopyToMenu,
                onTap: _thenClose(sheet, () => _startCopy(items)),
              ),
              if (local && shareLinksSupported())
                ShellRow(
                  touch: true,
                  label: l10n.shareLinksTitle,
                  onTap: _thenClose(sheet, () => unawaited(_share(items))),
                ),
              if (single &&
                  entry.isDir &&
                  controller.clipboard.isNotEmpty &&
                  controller.canChange)
                ShellRow(
                  touch: true,
                  label: l10n.remoteFilesPasteInto(entry.name),
                  onTap: _thenClose(
                    sheet,
                    () => unawaited(
                      actions.copy(
                        controller.clipboard,
                        FilesLocation(
                          here.deviceId,
                          here.root,
                          here.child(entry.name),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (controller.canChange) ...[
            const SizedBox(height: 14),
            ShellGroup(
              children: [
                if (single)
                  ShellRow(
                    touch: true,
                    label: l10n.remoteFilesRename,
                    onTap: _thenClose(sheet, () => unawaited(_rename(entry))),
                  ),
                ShellRow(
                  touch: true,
                  label: controller.hasTrash
                      ? l10n.remoteFilesMoveToTrash
                      : l10n.remoteFilesDelete,
                  color: context.wc.bad,
                  onTap: _thenClose(sheet, () => unawaited(_delete(items))),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// A long press below the items: the folder itself.
  Future<void> _folderSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final here = controller.location;
    unawaited(HapticFeedback.mediumImpact());
    await showPhoneSheet<void>(
      context,
      builder: (sheet) => ShellGroup(
        children: [
          if (controller.canChange)
            ShellRow(
              touch: true,
              label: l10n.remoteFilesNewFolder,
              onTap: _thenClose(sheet, () => unawaited(_newFolder())),
            ),
          if (here != null &&
              controller.clipboard.isNotEmpty &&
              controller.canChange)
            ShellRow(
              touch: true,
              label: l10n.remoteFilesPaste(controller.clipboard.length),
              onTap: _thenClose(
                sheet,
                () => unawaited(actions.copy(controller.clipboard, here)),
              ),
            ),
          ShellRow(
            touch: true,
            label: l10n.remoteFilesSelect,
            dim: controller.entries.isEmpty,
            onTap: controller.entries.isEmpty
                ? null
                : _thenClose(sheet, () => setState(() => _selecting = true)),
          ),
        ],
      ),
    );
  }

  /// The selection's sheet, from the capsule: what does not fit in it.
  Future<void> _selectionSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final items = controller.selectedItems;
    final entries = [
      for (final entry in controller.entries)
        if (controller.selection.contains(entry.name)) entry,
    ];
    if (items.isEmpty) return;
    await showPhoneSheet<void>(
      context,
      builder: (sheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PhoneSheetTitle(l10n.remoteFilesSelected(items.length)),
          const SizedBox(height: 14),
          ShellGroup(
            children: [
              ShellRow(
                touch: true,
                label: l10n.remoteFilesCopy,
                onTap: _thenClose(sheet, () => _copyToClipboard(null)),
              ),
              ShellRow(
                touch: true,
                label: l10n.remoteFilesCopyToMenu,
                onTap: _thenClose(sheet, () => _startCopy(items)),
              ),
            ],
          ),
          if (controller.canChange) ...[
            const SizedBox(height: 14),
            ShellGroup(
              children: [
                if (entries.length == 1)
                  ShellRow(
                    touch: true,
                    label: l10n.remoteFilesRename,
                    onTap: _thenClose(
                      sheet,
                      () => unawaited(_rename(entries.single)),
                    ),
                  ),
                ShellRow(
                  touch: true,
                  label: controller.hasTrash
                      ? l10n.remoteFilesMoveToTrash
                      : l10n.remoteFilesDelete,
                  color: context.wc.bad,
                  onTap: _thenClose(sheet, () => unawaited(_delete(items))),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// `.menu` under the location button: this device first, then the others that
  /// can be browsed, each with its favourites under it.
  void _openLocationMenu(BuildContext button) {
    final l10n = AppLocalizations.of(context)!;
    final here = controller.location;
    final items = <PanelMenuEntry>[];
    for (final device in controller.devices) {
      if (device.state == FilesDeviceState.offline ||
          device.state == FilesDeviceState.unsupported) {
        continue;
      }
      final current = device.id == here?.deviceId;
      items.add(
        PanelMenuEntry(
          key: ValueKey('files-location-${device.id}'),
          label: filesDeviceName(l10n, device),
          leading: (color) => art.DeviceGlyph(
            kind: art.deviceKindFor(device.platform, name: device.name),
            color: color,
            size: 20,
          ),
          checked: current,
          onSelected: () {
            if (current) return;
            _enter(() => _openDevice(device));
          },
        ),
      );
      for (final place in device.browser?.places ?? const <FsPlace>[]) {
        final where = FilesLocation(device.id, place.root, place.path);
        items.add(
          PanelMenuEntry(
            label: fsPlaceLabel(l10n, place),
            indent: true,
            checked: where == here,
            onSelected: () => _enter(() => controller.go(where)),
          ),
        );
      }
    }
    unawaited(
      showPanelMenu(
        button,
        // From the pill, not from what is added around it for a finger.
        anchor: panelMenuAnchor(button).deflate(7),
        items: items,
        touch: true,
      ),
    );
  }

  /// `.menu` under 更多: what goes for the whole folder.
  void _openMoreMenu(BuildContext button) {
    final l10n = AppLocalizations.of(context)!;
    final canChange = controller.canChange;
    unawaited(
      showPanelMenu(
        button,
        anchor: panelMenuAnchor(button),
        touch: true,
        items: [
          PanelMenuEntry(
            label: l10n.remoteFilesSelect,
            enabled: controller.entries.isNotEmpty,
            onSelected: () => setState(() => _selecting = true),
          ),
          if (canChange)
            PanelMenuEntry(
              label: l10n.remoteFilesNewFolder,
              onSelected: () => unawaited(_newFolder()),
            ),
          if (canChange && controller.clipboard.isNotEmpty)
            PanelMenuEntry(
              label: l10n.remoteFilesPaste(controller.clipboard.length),
              onSelected: () => unawaited(
                actions.copy(controller.clipboard, controller.location!),
              ),
            ),
          const PanelMenuEntry.separator(),
          for (final (sort, label) in [
            (FilesSort.name, l10n.remoteFilesColumnName),
            (FilesSort.modified, l10n.remoteFilesColumnModified),
            (FilesSort.size, l10n.remoteFilesColumnSize),
            (FilesSort.kind, l10n.remoteFilesColumnKind),
          ])
            PanelMenuEntry(
              label: label,
              checked: controller.sort == sort,
              // Picked again, it turns around.
              trailing: controller.sort == sort
                  ? (color) => RotatedBox(
                      quarterTurns: controller.ascending ? 0 : 2,
                      child: WhisperIcon(
                        WhisperGlyph.up,
                        size: 13,
                        weight: 2,
                        color: color,
                      ),
                    )
                  : null,
              onSelected: () => controller.setSort(sort),
            ),
          const PanelMenuEntry.separator(),
          PanelMenuEntry(
            label: l10n.remoteFilesShowHidden,
            checked: controller.showHidden,
            onSelected: controller.toggleHidden,
          ),
          PanelMenuEntry(
            label: l10n.remoteFilesRefresh,
            onSelected: () => unawaited(controller.reload()),
          ),
          PanelMenuEntry(
            label: l10n.remoteFilesTransfers,
            onSelected: _showTransfers,
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = context.wc;
    final page = _page;
    _shown = page;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final bar = _transfers
        ? null
        : _copying != null
        ? _copyBar(l10n)
        : controller.selection.isNotEmpty
        ? _selectionBar(l10n)
        : null;
    return PopScope(
      // A tab kept behind another must not hold back the one on screen.
      canPop: _canPop || !TickerMode.of(context),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: PhonePage(
        title: _transfers ? l10n.remoteFilesTransfers : l10n.shellTabFiles,
        background: _transfers ? c.canvas : c.content,
        onBack: _leave,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_transfers) _pathRow(l10n),
                Expanded(
                  child: _transfers
                      ? FilesTransfersList(
                          copies: controller.copyList,
                          grouped: true,
                          onReveal: _reveal,
                        )
                      : _SlideIn(
                          key: ValueKey(page),
                          side: _forward ? 1 : -1,
                          child: page == null
                              ? const SizedBox.shrink()
                              : _folder(l10n, page),
                        ),
                ),
              ],
            ),
            if (bar != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 24 + bottom,
                child: Center(child: bar),
              ),
          ],
        ),
      ),
    );
  }

  /// `.fhead`: back, location, the path; how many, filter, more. The same height
  /// whatever it is doing, so that nothing under it moves.
  Widget _pathRow(AppLocalizations l10n) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final device = controller.device;
    final here = controller.location;
    final ready = device?.browser != null;
    final selectionRow = _selecting;
    return Padding(
      // The back chevron and the three dots line up with what is under them:
      // the file icons and the sizes. Their targets stick out past that.
      padding: selectionRow
          ? const EdgeInsets.fromLTRB(20, 0, 20, 8)
          : const EdgeInsets.fromLTRB(5, 0, 4, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: selectionRow
            ? _selectingRow(l10n)
            : LayoutBuilder(
                builder: (context, box) {
                  final crumbs = _crumbs(l10n, device, here);
                  return Row(
                    children: [
                      Opacity(
                        opacity: _inFolder ? 1 : .35,
                        child: ShellIconButton(
                          glyph: WhisperGlyph.back,
                          iconSize: 13,
                          weight: 2,
                          touch: true,
                          label: l10n.back,
                          onTap: _inFolder ? _up : null,
                        ),
                      ),
                      const SizedBox(width: 2),
                      if (_filtering)
                        Expanded(child: _filterField(l10n))
                      else ...[
                        Builder(
                          builder: (button) => PhonePopButton(
                            key: const ValueKey('files-location'),
                            label: device == null
                                ? ''
                                : filesDeviceName(l10n, device),
                            // Half the room there is once the path has to fit.
                            maxLabelWidth: crumbs.isEmpty
                                ? (box.maxWidth - 224).clamp(44.0, 150.0)
                                : ((box.maxWidth - 150) / 2 - 37).clamp(
                                    44.0,
                                    150.0,
                                  ),
                            onTap: () => _openLocationMenu(button),
                          ),
                        ),
                        Expanded(
                          child: crumbs.isEmpty
                              ? _count(l10n, ready, expand: true)
                              : _ScrollsToEnd(
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
                                          onTap: () =>
                                              unawaited(controller.go(where)),
                                          radius: WhisperRadius.xs,
                                          scale: 1,
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              minHeight: 48,
                                            ),
                                            child: Center(
                                              widthFactor: 1,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 5,
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
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                        ),
                      ],
                      ShellIconButton(
                        key: const ValueKey('files-filter'),
                        glyph: _filtering
                            ? WhisperGlyph.x
                            : WhisperGlyph.search,
                        iconSize: 14,
                        touch: true,
                        label: l10n.remoteFilesSearch,
                        onTap: !ready
                            ? null
                            : () {
                                if (_filtering) {
                                  _endFilter();
                                } else {
                                  setState(() => _filtering = true);
                                }
                              },
                      ),
                      if (!_filtering) const SizedBox(width: 2),
                      if (!_filtering)
                        Builder(
                          builder: (button) => ShellIconButton(
                            key: const ValueKey('files-more'),
                            glyph: WhisperGlyph.more,
                            iconSize: 15,
                            weight: 2.4,
                            touch: true,
                            label: l10n.remoteFilesMore,
                            onTap: ready ? () => _openMoreMenu(button) : null,
                          ),
                        ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  /// `.cnt`: at the right of the room there is, and gone first when there is none.
  Widget _count(AppLocalizations l10n, bool ready, {bool expand = false}) {
    if (!ready) return const SizedBox.shrink();
    const type = WhisperType(touch: true);
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Text(
        l10n.shellFilesCount(controller.entries.length),
        maxLines: 1,
        softWrap: false,
        overflow: expand ? TextOverflow.fade : TextOverflow.clip,
        textAlign: TextAlign.end,
        style: TextStyle(fontSize: type.note, color: context.wc.ink2),
      ),
    );
  }

  /// While several are being picked: all of them, how many, done.
  Widget _selectingRow(AppLocalizations l10n) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    return Row(
      children: [
        PhoneButton(
          key: const ValueKey('files-select-all'),
          kind: PhoneButtonKind.quiet,
          label: l10n.remoteFilesSelectAll,
          onTap: controller.selectAll,
        ),
        Expanded(
          child: Text(
            l10n.remoteFilesSelected(controller.selection.length),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: type.note, color: c.ink2),
          ),
        ),
        PhoneButton(
          key: const ValueKey('files-select-done'),
          kind: PhoneButtonKind.quiet,
          label: l10n.remoteFilesDone,
          onTap: _endSelection,
        ),
      ],
    );
  }

  /// The path below what the location button says. A device's first place is
  /// the device itself: nothing to add.
  List<(String, FilesLocation)> _crumbs(
    AppLocalizations l10n,
    FilesDevice? device,
    FilesLocation? here,
  ) {
    if (device == null || here == null || here.root.isEmpty) return const [];
    final first = device.browser?.places.firstOrNull;
    final parts = here.crumbs;
    return [
      for (var i = 0; i <= parts.length; i++)
        if (i > 0 ||
            first == null ||
            first.root != here.root ||
            first.path != '')
          (
            fsFolderLabel(
              l10n,
              device,
              here.root,
              parts.sublist(0, i).join('/'),
            ),
            FilesLocation(
              here.deviceId,
              here.root,
              parts.sublist(0, i).join('/'),
            ),
          ),
    ];
  }

  Widget _filterField(AppLocalizations l10n) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    // 34 to look at, the height of the row to hit.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _searchFocus.requestFocus,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(WhisperRadius.s),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: TextField(
              key: const ValueKey('files-filter-field'),
              controller: _search,
              focusNode: _searchFocus,
              autofocus: true,
              onChanged: controller.setQuery,
              cursorColor: c.accent,
              style: TextStyle(fontSize: type.note, height: 1.4, color: c.ink),
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: l10n.remoteFilesSearch,
                hintStyle: TextStyle(fontSize: type.note, color: c.ink3),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// What a device that cannot show files yet says, with its picture.
  Widget? _message(FilesDevice device, AppLocalizations l10n) {
    final name = filesDeviceName(l10n, device);
    Widget state(String title, {String body = '', Widget? action}) =>
        ShellDeviceState(
          touch: true,
          art: art.DeviceArt(
            kind: art.deviceKindFor(device.platform, name: device.name),
            wallpaper: device.isLocal
                ? art.DeviceWallpaper.self
                : art.DeviceWallpaper.forPairingOrder(device.id.hashCode.abs()),
            size: 84,
          ),
          title: title,
          body: body,
          action: action,
        );
    PhoneButton retry(String label, VoidCallback onTap) => PhoneButton(
      label: label,
      kind: PhoneButtonKind.primary,
      large: true,
      onTap: onTap,
    );
    return switch (device.state) {
      FilesDeviceState.waiting => state(
        l10n.shellFilesAskOnDevice(name),
        body: l10n.remoteFilesWaitingDetail,
        action: PhoneButton(
          label: l10n.cancel,
          large: true,
          onTap: () => unawaited(controller.cancelOpen(device)),
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
          l10n.remoteFilesAskAgain,
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

  Widget _folder(AppLocalizations l10n, FilesLocation page) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final device = controller.deviceById(page.deviceId);
    if (device == null) return const SizedBox.shrink();
    final message = _message(device, l10n);
    if (message != null) return message;
    if (controller.shownLocation != page) {
      return const Center(child: CupertinoActivityIndicator());
    }
    final entries = controller.entries;
    if (entries.isEmpty) {
      if (controller.loading) {
        return const Center(child: CupertinoActivityIndicator());
      }
      if (controller.error != null) {
        return ShellDeviceState(
          touch: true,
          art: const SizedBox.shrink(),
          title: l10n.remoteFilesFailed,
          body: '',
          action: PhoneButton(
            label: l10n.windowStreamRetry,
            kind: PhoneButtonKind.primary,
            large: true,
            onTap: () => unawaited(controller.reload()),
          ),
        );
      }
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => unawaited(_folderSheet()),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              controller.query.isEmpty
                  ? l10n.remoteFilesEmptyFolder
                  : l10n.remoteFilesNoResults(controller.query),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: type.body, color: c.ink2),
            ),
          ),
        ),
      );
    }
    final spot = entries.indexWhere((entry) => _spot.contains(entry.name));
    return RefreshIndicator.adaptive(
      onRefresh: controller.reload,
      color: c.accent,
      // A long press below the items is on the folder itself.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: _selecting ? null : () => unawaited(_folderSheet()),
        child: _Rows(
          itemCount: entries.length,
          spotIndex: spot < 0 ? null : spot,
          spotGeneration: _spotGeneration,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return PhoneFileRow(
              key: ValueKey(
                '${page.deviceId}/${page.root}/${page.path}/${entry.name}',
              ),
              controller: controller,
              entry: entry,
              selected: controller.selection.contains(entry.name),
              spotlit: _spot.contains(entry.name),
              onTap: () {
                if (_selecting) {
                  controller.select(entry.name, toggle: true);
                } else if (entry.isDir) {
                  _enter(() => controller.openEntry(entry));
                } else if (_copying == null) {
                  // One at a time, as in the prototype: a tap on it again lets go.
                  if (controller.selection.length == 1 &&
                      controller.selection.contains(entry.name)) {
                    controller.clearSelection();
                  } else {
                    controller.select(entry.name);
                  }
                }
              },
              onLongPress: () {
                if (_selecting) {
                  unawaited(HapticFeedback.mediumImpact());
                  controller.select(entry.name, toggle: true);
                  return;
                }
                unawaited(_itemSheet(entry));
              },
            );
          },
        ),
      ),
    );
  }

  /// `.float-bar`: other device's files come here first, this device's go out.
  Widget _selectionBar(AppLocalizations l10n) {
    final items = controller.selectedItems;
    final local = controller.location?.deviceId == FilesDevice.localId;
    final c = context.wc;
    return PhoneFloatBar(
      key: const ValueKey('files-capsule'),
      children: [
        if (local) ...[
          PhoneButton(
            key: const ValueKey('files-send-to'),
            label: l10n.shellFilesSendTo,
            kind: PhoneButtonKind.primary,
            onTap: () => unawaited(_sendTo(items)),
          ),
          if (shareLinksSupported())
            PhoneButton(
              key: const ValueKey('files-share-link'),
              label: l10n.shareLinksTitle,
              kind: PhoneButtonKind.quiet,
              onTap: () => unawaited(_share(items)),
            ),
        ] else ...[
          PhoneButton(
            key: const ValueKey('files-copy-here'),
            label: l10n.shellFilesCopyHere,
            kind: PhoneButtonKind.primary,
            onTap: () => unawaited(_copyToThisDevice(items)),
          ),
          PhoneButton(
            key: const ValueKey('files-send-to'),
            label: l10n.shellFilesSendTo,
            kind: PhoneButtonKind.quiet,
            onTap: () => unawaited(_sendTo(items)),
          ),
        ],
        if (_selecting)
          _CapsuleIcon(
            key: const ValueKey('files-selection-more'),
            glyph: WhisperGlyph.more,
            weight: 2.4,
            color: c.accentText,
            label: l10n.remoteFilesMore,
            onTap: () => unawaited(_selectionSheet()),
          ),
        _CapsuleIcon(
          key: const ValueKey('files-unselect'),
          glyph: WhisperGlyph.x,
          color: c.accentText,
          label: l10n.cancel,
          onTap: _endSelection,
        ),
      ],
    );
  }

  /// Picking the folder "拷贝到…" goes into.
  Widget _copyBar(AppLocalizations l10n) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final items = _copying!;
    final here = controller.location;
    final ready = controller.device?.browser != null;
    final problem = ready && here != null
        ? controller.copyProblem(items, here)
        : null;
    final hint = !ready
        ? l10n.remoteFilesChooseDestination
        : switch (problem) {
            FilesCopyProblem.sameDevice => l10n.remoteFilesSameDevice,
            FilesCopyProblem.betweenOthers => l10n.remoteFilesBetweenOthers,
            FilesCopyProblem.readOnly => l10n.remoteFilesReadOnlyHost(
              filesDeviceName(l10n, controller.device!),
            ),
            _ => l10n.remoteFilesChooseDestination,
          };
    return PhoneFloatBar(
      key: const ValueKey('files-copy-bar'),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 124),
          child: Padding(
            padding: const EdgeInsets.only(left: 10, right: 2),
            child: Text(
              hint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: type.tiny,
                height: 1.25,
                color: c.ink2Glass,
              ),
            ),
          ),
        ),
        PhoneButton(
          key: const ValueKey('files-copy-cancel'),
          label: l10n.cancel,
          kind: PhoneButtonKind.quiet,
          onTap: () => setState(() => _copying = null),
        ),
        PhoneButton(
          key: const ValueKey('files-copy-go'),
          label: l10n.remoteFilesCopyHere,
          kind: PhoneButtonKind.primary,
          onTap: ready && problem == null ? () => unawaited(_copyHere()) : null,
        ),
      ],
    );
  }
}

/// `.frow` at touch size: icon column 24, name, size; 48 high, 10 / 12 inside, 8
/// from the window's edge. No lines. Selected is solid `accent` with white text.
class PhoneFileRow extends StatefulWidget {
  const PhoneFileRow({
    super.key,
    required this.controller,
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    this.spotlit = false,
  });

  final FilesController controller;
  final FsEntry entry;
  final bool selected;

  /// Just shown where a copy went.
  final bool spotlit;
  final VoidCallback onTap, onLongPress;

  /// With a person's text size the rows are taller; all the same height.
  static double extent(BuildContext context) {
    const type = WhisperType(touch: true);
    final text = MediaQuery.textScalerOf(context).scale(type.body) * 1.4;
    return text + 20 > 48 ? text + 20 : 48;
  }

  @override
  State<PhoneFileRow> createState() => _PhoneFileRowState();
}

class _PhoneFileRowState extends State<PhoneFileRow> {
  bool _down = false;

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
    final c = context.wc;
    const type = WhisperType(touch: true);
    final entry = widget.entry;
    final selected = widget.selected;
    final primary = selected ? c.onAccent : c.ink;
    final second = selected ? c.onAccent : c.ink2;
    final thumbnail = entry.isDir
        ? null
        : widget.controller.cachedThumbnail(entry);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        onLongPress: () {
          setState(() => _down = false);
          widget.onLongPress();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SpringBuilder(
            value: widget.spotlit ? 1 : 0,
            animateWhenReduced: true,
            builder: (context, spot, child) => DecoratedBox(
              decoration: BoxDecoration(
                color: selected
                    ? c.accent
                    : _down
                    ? c.fill
                    : Color.lerp(
                        c.accent.withValues(alpha: 0),
                        c.accent.withValues(alpha: .16),
                        spot.clamp(0.0, 1.0),
                      ),
                borderRadius: BorderRadius.circular(WhisperRadius.s),
              ),
              child: child,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Opacity(
                    opacity: entry.hidden ? .5 : 1,
                    child: SizedBox(
                      width: 24,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: entry.isDir
                            ? const WhisperFolderArt(size: 18)
                            : thumbnail != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  WhisperRadius.xs,
                                ),
                                child: Image.memory(
                                  thumbnail,
                                  width: 24,
                                  height: 24,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                ),
                              )
                            : const WhisperDocArt(size: 18),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.body,
                        height: 1.4,
                        color: entry.hidden
                            ? primary.withValues(alpha: .6)
                            : primary,
                      ),
                    ),
                  ),
                  if (!entry.isDir) ...[
                    const SizedBox(width: 10),
                    Text(
                      fsSizeLabel(entry),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: type.note,
                        height: 1.4,
                        color: second,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The path: from the left when it fits, showing its end when it does not.
class _ScrollsToEnd extends StatelessWidget {
  const _ScrollsToEnd({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: box.maxWidth),
        child: child,
      ),
    ),
  );
}

/// A round icon in the capsule, 48 to hit like the buttons next to it.
class _CapsuleIcon extends StatelessWidget {
  const _CapsuleIcon({
    super.key,
    required this.glyph,
    required this.label,
    required this.onTap,
    required this.color,
    this.weight = 1.6,
  });

  final WhisperGlyph glyph;
  final String label;
  final VoidCallback onTap;
  final Color color;
  final double weight;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    radius: WhisperRadius.capsule,
    scale: .92,
    label: label,
    child: SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: WhisperIcon(glyph, size: 13, weight: weight, color: color),
      ),
    ),
  );
}

/// Comes in from the side it was asked from, a little smaller, as `tInR` does.
class _SlideIn extends StatelessWidget {
  const _SlideIn({super.key, required this.side, required this.child});

  final double side;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return SpringBuilder(
      from: 0,
      value: 1,
      spring: WhisperSprings.smooth,
      animateWhenReduced: true,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: FractionalTranslation(
          translation: Offset(reduced ? 0 : side * .09 * (1 - t), 0),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// A folder's rows, brought to the one a copy was just shown at.
class _Rows extends StatefulWidget {
  const _Rows({
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
  State<_Rows> createState() => _RowsState();
}

class _RowsState extends State<_Rows> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToSpot();
  }

  @override
  void didUpdateWidget(_Rows old) {
    super.didUpdateWidget(old);
    if (old.spotGeneration != widget.spotGeneration) _scrollToSpot();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToSpot() {
    final index = widget.spotIndex;
    if (index == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final extent = PhoneFileRow.extent(context);
      final top = index * extent;
      if (top >= position.pixels &&
          top + extent <= position.pixels + position.viewportDimension) {
        return;
      }
      // A third of the way down, with the rows before it in sight.
      position.jumpTo(
        (top - position.viewportDimension / 3).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: _scroll,
    physics: const AlwaysScrollableScrollPhysics(),
    padding: EdgeInsets.only(bottom: 72 + MediaQuery.paddingOf(context).bottom),
    itemExtent: PhoneFileRow.extent(context),
    itemCount: widget.itemCount,
    itemBuilder: widget.itemBuilder,
  );
}

/// Asks for a name.
class _NameSheet extends StatefulWidget {
  const _NameSheet({
    required this.title,
    required this.initial,
    required this.confirm,
  });

  final String title, initial, confirm;

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    final stem = widget.initial.lastIndexOf('.');
    _text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: stem > 0 ? stem : widget.initial.length,
    );
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() => Navigator.of(context).pop(_text.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.shellL10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PhoneSheetTitle(widget.title),
        const SizedBox(height: 14),
        ShellField(
          label: l10n.remoteFilesFolderName,
          fieldKey: const ValueKey('files-name-field'),
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _done(),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: PhoneButton(
                label: l10n.cancel,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: PhoneButton(
                key: const ValueKey('files-name-confirm'),
                kind: PhoneButtonKind.primary,
                label: widget.confirm,
                onTap: _done,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Before something that cannot be undone: what it is, and a red button.
class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.title,
    required this.detail,
    required this.confirmLabel,
    required this.names,
  });

  final String title, detail, confirmLabel;
  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: true);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PhoneSheetTitle(title),
        const SizedBox(height: 14),
        Text(
          detail,
          style: TextStyle(fontSize: type.note, height: 1.5, color: c.ink2),
        ),
        if (names.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            names.take(3).join('\n'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: type.body, height: 1.4, color: c.ink),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: PhoneButton(
                label: l10n.cancel,
                onTap: () => Navigator.of(context).pop(false),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: PhoneButton(
                key: const ValueKey('files-delete-confirm'),
                kind: PhoneButtonKind.danger,
                label: confirmLabel,
                onTap: () => Navigator.of(context).pop(true),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
