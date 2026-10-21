import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../helper/file.dart';
import '../../helper/toast.dart';
import '../../l10n/app_localizations.dart';
import '../../remote_files/fs_host_files.dart';
import '../../remote_files/fs_protocol.dart';
import '../../remote_files/mount/remote_mounts.dart';
import '../window_stream/flow_space_theme.dart';
import 'files_confirm.dart';
import 'files_copy_island.dart';
import 'files_desktop.dart';
import 'files_icons.dart';
import 'files_model.dart';
import 'files_phone.dart';

/// Every connected device's files in one place, like Finder with the other
/// devices under "位置": browse them, drag or copy and paste between this
/// device and another one, create, rename and delete. Copies are ordinary
/// resumable transfers that land in the folder they were dropped on.
class RemoteFilesPage extends StatefulWidget {
  const RemoteFilesPage({super.key, this.peerId, this.deviceName});

  /// The device to show first; null starts on this device.
  final String? peerId;
  final String? deviceName;

  @override
  State<RemoteFilesPage> createState() => _RemoteFilesPageState();
}

class _RemoteFilesPageState extends State<RemoteFilesPage> {
  late final FilesController _controller = FilesController(
    focusPeerId: widget.peerId,
  );
  late final FilesActions _actions = FilesActions(
    controller: _controller,
    context: () => context,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      body: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 700
            ? FinderView(controller: _controller, actions: _actions)
            : SafeArea(
                bottom: false,
                child: FilesPhoneView(
                  controller: _controller,
                  actions: _actions,
                  startAtDevice: widget.peerId != null,
                ),
              ),
      ),
    );
  }
}

/// What both layouts do the same way: copying, editing and saying why
/// something did not work.
class FilesActions {
  FilesActions({required this.controller, required this.context});

  final FilesController controller;
  final BuildContext Function() context;

  AppLocalizations get l10n => AppLocalizations.of(context())!;

  /// Copies [items] into [target], saying why when that is not possible.
  Future<bool> copy(List<FilesItem> items, FilesLocation target) async {
    if (items.isEmpty) {
      return false;
    }
    final problem = controller.copyProblem(items, target);
    if (problem != null) {
      showAppToast(switch (problem) {
        FilesCopyProblem.sameDevice => l10n.remoteFilesSameDevice,
        FilesCopyProblem.betweenOthers => l10n.remoteFilesBetweenOthers,
        FilesCopyProblem.notConnected => l10n.remoteFilesOpenFirst(
          _remoteName(items.first.location.deviceId, target.deviceId),
        ),
        FilesCopyProblem.readOnly => _readOnlyText(target),
      }, tone: AppToastTone.warning);
      return false;
    }
    // Pasted twice: the first is still on its way (or just arrived), so
    // it is the same copy, shown instead of made again.
    if (_alreadyCopying(controller.copySignature(items, target))) {
      return false;
    }
    try {
      final started = await controller.copy(
        items,
        target,
        folderLabel: _folderLabel(target),
      );
      if (started == 0) {
        showAppToast(l10n.remoteFilesFailed, tone: AppToastTone.error);
      }
      return started > 0;
    } catch (error) {
      showError(error);
      return false;
    }
  }

  bool _alreadyCopying(String signature) {
    final same = controller.copyList.sameAs(signature);
    if (same == null) {
      return false;
    }
    showAppToast(
      same.finished
          ? l10n.remoteFilesCopyJustDone
          : l10n.remoteFilesCopyAlready,
    );
    controller.copyList.show(same);
    return true;
  }

  /// Opens [device]'s files in the system's file manager, mounting them
  /// there first; they stay until ejected or the device goes away.
  Future<void> showInFileManager(FilesDevice device) async {
    final l10n = this.l10n;
    final app = systemFileManagerName(l10n);
    final name = filesDeviceName(l10n, device);
    try {
      final mount = await RemoteMounts.shared.mount(device.id, name);
      await openDir(mount.path);
    } on MountFailed catch (failed) {
      showAppToast(
        mountFailureText(l10n, failed.failure, name, app),
        tone: AppToastTone.error,
      );
    }
  }

  /// Takes [device]'s files out of the system's file manager.
  Future<void> eject(FilesDevice device) =>
      RemoteMounts.shared.unmount(device.id);

  /// [at] may not be changed from here: says so.
  bool refusedReadOnly(FilesLocation? at) {
    if (!controller.readOnlyAt(at)) {
      return false;
    }
    showAppToast(_readOnlyText(at!), tone: AppToastTone.warning);
    return true;
  }

  String _readOnlyText(FilesLocation at) {
    final device = controller.deviceById(at.deviceId);
    return l10n.remoteFilesReadOnlyHost(
      device == null ? '' : filesDeviceName(l10n, device),
    );
  }

  String _remoteName(String a, String b) {
    final id = a == FilesDevice.localId ? b : a;
    return controller.deviceById(id)?.name ?? '';
  }

  /// Pastes what was copied here, or files copied in Finder, Explorer or
  /// a file manager when those are newer.
  Future<void> paste() async {
    final target = controller.location;
    if (target == null || target.root.isEmpty || refusedReadOnly(target)) {
      return;
    }
    final external = await controller.externalClipboardPaths();
    if (external != null) {
      if (target.deviceId == FilesDevice.localId) {
        showAppToast(l10n.remoteFilesSameDevice, tone: AppToastTone.warning);
        return;
      }
      await copyPaths(external, target);
      return;
    }
    if (controller.clipboard.isNotEmpty) {
      await copy(controller.clipboard, target);
    }
  }

  Future<void> copyPaths(List<String> paths, FilesLocation target) async {
    if (refusedReadOnly(target) ||
        _alreadyCopying(controller.pathsSignature(paths, target))) {
      return;
    }
    try {
      await controller.copyPaths(
        paths,
        target,
        folderLabel: _folderLabel(target),
      );
    } catch (error) {
      showError(error);
    }
  }

  /// The folder as the sidebar and title name it ("下载", not "Download").
  String? _folderLabel(FilesLocation target) {
    final device = controller.deviceById(target.deviceId);
    if (device == null || target.root.isEmpty) {
      return null;
    }
    return fsFolderLabel(l10n, device, target.root, target.path);
  }

  /// "未命名文件夹", or "未命名文件夹 2" when that is taken.
  String untitledFolder() {
    final base = l10n.remoteFilesUntitledFolder;
    final taken = {
      for (final entry in controller.entries) entry.name.toLowerCase(),
    };
    var name = base;
    for (var n = 2; taken.contains(name.toLowerCase()); n++) {
      name = '$base $n';
    }
    return name;
  }

  /// Creates a folder and returns its name, or null if it failed.
  Future<String?> newFolder([String? name]) async {
    if (refusedReadOnly(controller.location)) {
      return null;
    }
    final folder = name ?? untitledFolder();
    try {
      await controller.newFolder(folder);
      return folder;
    } catch (error) {
      showError(error);
      return null;
    }
  }

  Future<void> rename(FsEntry entry, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed == entry.name ||
        refusedReadOnly(controller.location)) {
      return;
    }
    try {
      await controller.rename(entry, trimmed);
    } catch (error) {
      showError(error);
    }
  }

  /// Moves to the trash, or after a confirmation deletes for good where
  /// there is none (phones).
  Future<void> delete(List<FilesItem> items) async {
    if (items.isEmpty || refusedReadOnly(items.first.location)) {
      return;
    }
    var permanent = false;
    if (!controller.hasTrash) {
      final device = controller.deviceById(items.first.location.deviceId);
      final confirmed = await showFilesConfirm(
        context(),
        title: l10n.remoteFilesDeleteTitle(items.length),
        detail: device == null
            ? l10n.remoteFilesDeleteForever(items.length)
            : l10n.remoteFilesDeleteDetail(filesDeviceName(l10n, device)),
        confirmLabel: l10n.remoteFilesDelete,
        names: [for (final item in items) p.basename(item.path)],
      );
      if (!confirmed) {
        return;
      }
      permanent = true;
    }
    try {
      await controller.remove(items, permanent: permanent);
    } catch (error) {
      showError(error);
      unawaited(controller.reload());
    }
  }

  /// Asks for a name (phones; the desktop renames in place).
  Future<String?> askName(String title, String initial, String confirm) {
    final text = TextEditingController(text: initial);
    final stem = initial.lastIndexOf('.');
    text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: stem > 0 ? stem : initial.length,
    );
    return showCupertinoDialog<String>(
      context: context(),
      builder: (context) => CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: text,
            autofocus: true,
            placeholder: l10n.remoteFilesFolderName,
            onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(text.text.trim()),
            child: Text(confirm),
          ),
        ],
      ),
    );
  }

  void showError(Object error) {
    final reason = FilesController.errorReason(error);
    final offline = controller.device;
    showAppToast(switch (reason) {
      FileBrowseError.exists => l10n.remoteFilesNameExists,
      FileBrowseError.readOnly when offline != null =>
        l10n.remoteFilesReadOnlyHost(filesDeviceName(l10n, offline)),
      'offline' when offline != null => l10n.remoteFilesOffline(
        filesDeviceName(l10n, offline),
      ),
      _ => l10n.remoteFilesFailed,
    }, tone: AppToastTone.error);
  }
}

/// Whether file browsing makes sense with this device's platform at all:
/// everywhere now (an iPhone or iPad offers its Whisper folder, the one
/// the Files app shows).
bool canOfferRemoteFiles() => true;
