import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/phone/panel_menu.dart';
import 'package:whisper/page/remote_files/files_copy_island.dart';
import 'package:whisper/page/remote_files/files_icons.dart';
import 'package:whisper/remote_files/fs_browser.dart';
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/remote_files/fs_shared_folders.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

import 'settings_rows.dart';
import 'settings_panel.dart';

/// 「共享的目录」 in 共享与权限: how many disks are shared, and the way to
/// them.
class SharedFoldersRow extends StatelessWidget {
  const SharedFoldersRow({
    super.key,
    required this.folders,
    required this.onTap,
  });

  final FsSharedFolders folders;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: folders,
      builder: (context, _) => SettingsRow(
        title: l10n.sharedFolders,
        onTap: onTap,
        trailing: SettingsDisclosure(
          value: l10n.sharedFoldersCount(
            (folders.systemDiskShared ? 1 : 0) + folders.sharedDisks.length,
          ),
        ),
      ),
    );
  }
}

/// The page under 共享与权限 (docs/design/surfaces.md「设置」): every disk
/// and partition with the switch that shares it, the system disk (its home
/// folder) first; then the folders left out, whose menu shows one in the file
/// manager or shares it again, and a row that leaves one more out.
class SharedFoldersPage extends StatefulWidget {
  const SharedFoldersPage({
    super.key,
    required this.folders,
    required this.back,
    required this.backLabel,
    this.pickFolder,
    this.showMessage,
  });

  final FsSharedFolders folders;
  final VoidCallback back;
  final String backLabel;

  /// The system's folder picker unless given (previews).
  final Future<String?> Function()? pickFolder;
  final void Function(String message)? showMessage;

  @override
  State<SharedFoldersPage> createState() => _SharedFoldersPageState();
}

class _SharedFoldersPageState extends State<SharedFoldersPage> {
  FsRoot? _system;
  List<FsRoot> _disks = const [];

  /// Folders left out that are not there now, such as on a USB stick taken
  /// out.
  Set<String> _missing = const {};

  @override
  void initState() {
    super.initState();
    widget.folders.addListener(_check);
    unawaited(widget.folders.refresh());
    unawaited(_readDisks());
    _check();
  }

  @override
  void dispose() {
    widget.folders.removeListener(_check);
    super.dispose();
  }

  /// The disks here: read once the page opens.
  Future<void> _readDisks() async {
    final system = await widget.folders.systemDisk();
    final disks = await widget.folders.otherDisks();
    if (mounted) {
      setState(() {
        _system = system;
        _disks = disks;
      });
    }
  }

  Future<void> _check() async {
    final missing = <String>{
      for (final folder in widget.folders.excluded)
        if (!await FsSharedFolders.exists(folder)) folder,
    };
    if (mounted) setState(() => _missing = missing);
  }

  void _say(String message) {
    final show = widget.showMessage;
    show != null
        ? show(message)
        : showAppToast(message, tone: AppToastTone.warning);
  }

  Future<void> _exclude(AppLocalizations l10n) async {
    final folder = await (widget.pickFolder ?? WhisperFilePicker.pickFolder)();
    if (folder == null) return;
    if (await widget.folders.exclude(folder) == FsExcluded.already) {
      _say(l10n.sharedFoldersAlready);
    }
  }

  void _menu(AppLocalizations l10n, String folder, Rect anchor) {
    unawaited(
      showPanelMenu(
        context,
        anchor: anchor,
        items: [
          PanelMenuEntry(
            label: l10n.sharedFoldersReveal(systemFileManagerName(l10n)),
            enabled: !_missing.contains(folder),
            onSelected: () => unawaited(openDir(folder)),
          ),
          PanelMenuEntry(
            label: l10n.sharedFoldersInclude,
            onSelected: () => unawaited(widget.folders.include(folder)),
          ),
        ],
      ),
    );
  }

  Widget _diskRow(AppLocalizations l10n, FsRoot disk, {required bool system}) {
    final folders = widget.folders;
    final name = disk.label.isEmpty && disk.drive.isEmpty
        ? l10n.sharedFoldersSystemDisk
        : diskName(l10n, disk);
    return SettingsSwitchRow(
      key: ValueKey(disk.directory),
      leading: Icon(
        disk.removable ? Icons.usb_rounded : Icons.storage_rounded,
        size: 22,
        color: context.wc.ink2,
      ),
      title: name,
      // Sharing it shares the home folder on it, not the system's.
      subtitle: system ? l10n.sharedFoldersSystemDiskNote : disk.directory,
      pathSubtitle: !system,
      minHeight: _placeHeight(context),
      value: folders.isDiskShared(disk, system: system),
      onChanged: (on) => unawaited(folders.shareDisk(disk, on, system: system)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = context.wc;
    final type = WhisperType(touch: SettingsScope.of(context).touch);
    final folders = widget.folders;
    final system = _system;
    return ListenableBuilder(
      listenable: folders,
      builder: (context, _) => SettingsPanelPage(
        title: l10n.sharedFolders,
        back: widget.back,
        backLabel: widget.backLabel,
        children: [
          SettingsGroupLabel(l10n.sharedFoldersDisks),
          SettingsGroup(
            children: [
              if (system != null) _diskRow(l10n, system, system: true),
              for (final disk in _disks) _diskRow(l10n, disk, system: false),
            ],
          ),
          const SizedBox(height: 16),
          SettingsGroupLabel(l10n.sharedFoldersExcluded),
          SettingsGroup(
            children: [
              for (final folder in folders.excluded)
                _FolderRow(
                  key: ValueKey(folder),
                  name: p.basename(folder).isEmpty
                      ? folder
                      : p.basename(folder),
                  path: _shown(folder, folders.home),
                  missing: _missing.contains(folder)
                      ? l10n.sharedFoldersMissing
                      : null,
                  onMenu: (anchor) => _menu(l10n, folder, anchor),
                ),
              SettingsRow(
                leading: WhisperIcon(
                  WhisperGlyph.plus,
                  size: 16,
                  weight: 2,
                  color: c.accentText,
                ),
                title: l10n.sharedFoldersExclude,
                titleColor: c.accentText,
                semanticLabel: l10n.sharedFoldersExclude,
                onTap: () => unawaited(_exclude(l10n)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Text(
              l10n.sharedFoldersFooter,
              style: TextStyle(fontSize: type.note, height: 1.4, color: c.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

/// A disk as Explorer names it (「Data (D:)」「本地磁盘 (D:)」), else by its
/// volume's or folder's name.
String diskName(AppLocalizations l10n, FsRoot disk) => disk.drive.isEmpty
    ? disk.label
    : fsPlaceLabel(
        l10n,
        FsPlace(
          root: '',
          path: '',
          kind: 'root',
          rootKind: 'drive',
          label: disk.label,
          drive: disk.drive,
          removable: disk.removable,
        ),
      );

/// ~ for the [home] folder: it is the part nobody needs to read.
String _shown(String folder, FsRoot? home) {
  if (home != null && p.isWithin(home.directory, folder)) {
    return '~${p.separator}${p.relative(folder, from: home.directory)}';
  }
  return folder;
}

/// A disk's or folder's row: a name with where it is under it.
double _placeHeight(BuildContext context) =>
    SettingsScope.of(context).touch ? 60 : 52;

/// A folder left out: its icon, name and where it is. Pressed, or clicked
/// with the other button, it opens its menu where the pointer is.
class _FolderRow extends StatefulWidget {
  const _FolderRow({
    super.key,
    required this.name,
    required this.path,
    required this.missing,
    required this.onMenu,
  });

  final String name, path;

  /// Said on the right when the folder is not there now.
  final String? missing;
  final ValueChanged<Rect> onMenu;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  Offset? _pointer;

  /// Where the menu grows from: the pointer, or the row from a key.
  Rect _anchor() {
    final row = panelMenuAnchor(context);
    final pointer = _pointer;
    _pointer = null;
    if (pointer == null) return row;
    final overlay =
        Navigator.of(context, rootNavigator: true).context.findRenderObject()!
            as RenderBox;
    return Rect.fromCenter(
      center: overlay.globalToLocal(pointer),
      width: 1,
      height: 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final missing = widget.missing;
    return Listener(
      onPointerDown: (event) => _pointer = event.position,
      child: GestureDetector(
        onSecondaryTapUp: (details) {
          _pointer = details.globalPosition;
          widget.onMenu(_anchor());
        },
        child: SettingsRow(
          leading: Opacity(
            opacity: missing == null ? 1 : .45,
            child: const FsFileIcon(
              entry: FsEntry(name: '', isDir: true, size: 0, modifiedMs: 0),
              size: 28,
            ),
          ),
          title: widget.name,
          titleColor: missing == null ? null : context.wc.ink2,
          subtitle: widget.path,
          pathSubtitle: true,
          minHeight: _placeHeight(context),
          trailing: missing == null ? null : SettingsValue(missing),
          semanticLabel: widget.name,
          onTap: () => widget.onMenu(_anchor()),
        ),
      ),
    );
  }
}
