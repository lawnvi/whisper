import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_wake.dart';
import 'package:whisper/page/remote_files/files_copy_island.dart';
import 'package:whisper/page/remote_files/files_icons.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/mount/remote_mounts.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/app_dialogs.dart';

/// One of the phone's three entries on its device page.
class ShellDeviceEntry {
  const ShellDeviceEntry({
    required this.glyph,
    required this.title,
    required this.onTap,
  });

  final WhisperGlyph glyph;
  final String title;

  /// Null while disconnected: dimmed but in place, so the layout does not jump.
  final VoidCallback? onTap;
}

/// docs/design/surfaces.md「设备卡片」, the prototype's `inspHtml`: everything
/// about one device. It replaces ClientSettingsScreen, one to one.
class ShellDeviceCard extends StatefulWidget {
  const ShellDeviceCard({
    super.key,
    required this.device,
    required this.connected,
    required this.statusLine,
    required this.paired,
    required this.onDiagnostics,
    required this.onRemove,
    this.onSound,
    this.onInput,
    this.soundOn = false,
    this.soundStatus,
    this.inputOn = false,
    this.inputStatus,
    this.soundEnabled = true,
    this.touch = false,
    this.topInset = 22,
    this.deviceLoader,
    this.entries = const [],
    this.onSearchHistory,
    this.onClose,
  });

  /// The × at the top right. Null on a page of its own, which has a back arrow.
  final VoidCallback? onClose;

  final DeviceData device;
  final bool connected, paired;
  final String statusLine;

  /// Null when it has none: a phone has no keyboard to take over.
  final VoidCallback? onSound, onInput;
  final VoidCallback onDiagnostics;
  final Future<void> Function(String uid) onRemove;
  final bool soundOn, inputOn, soundEnabled;
  final String? soundStatus, inputStatus;
  final bool touch;

  /// Room for window buttons that sit over the card.
  final double topInset;
  final Future<DeviceData?> Function(String uid)? deviceLoader;

  /// The phone's control, files and apps.
  final List<ShellDeviceEntry> entries;
  final VoidCallback? onSearchHistory;

  @override
  State<ShellDeviceCard> createState() => _ShellDeviceCardState();
}

class _ShellDeviceCardState extends State<ShellDeviceCard> {
  late DeviceData _device = widget.device;

  /// Null until read.
  bool? _browseAllowed, _changesAllowed;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    unawaited(_loadFilePermissions());
  }

  @override
  void didUpdateWidget(ShellDeviceCard old) {
    super.didUpdateWidget(old);
    if (old.device.uid != widget.device.uid) {
      _device = widget.device;
      _browseAllowed = null;
      _changesAllowed = null;
      unawaited(_loadFilePermissions());
    }
  }

  Future<void> _reload() async {
    final loader = widget.deviceLoader;
    final fresh = loader == null
        ? await LocalDatabase().fetchDevice(_device.uid)
        : await loader(_device.uid);
    if (fresh != null && mounted) setState(() => _device = fresh);
  }

  Future<void> _loadFilePermissions() async {
    final permissions = FileBrowseHost.shared.permissions;
    final uid = _device.uid;
    final always = await permissions.isAlways(uid);
    final readOnly = await permissions.isReadOnly(uid);
    if (mounted && uid == _device.uid) {
      setState(() {
        _browseAllowed = always;
        _changesAllowed = !readOnly;
      });
    }
  }

  Future<void> _setBrowse(bool allowed) async {
    final host = FileBrowseHost.shared;
    if (allowed) {
      await host.permissions.setAlways(_device.uid, true);
    } else {
      await host.revokeAlways(_device.uid);
      // Changing depends on browsing.
      await host.setReadOnly(_device.uid, true);
    }
    if (mounted) {
      setState(() {
        _browseAllowed = allowed;
        if (!allowed) _changesAllowed = false;
      });
    }
  }

  Future<void> _setChanges(bool allowed) async {
    setState(() => _changesAllowed = allowed);
    await FileBrowseHost.shared.setReadOnly(_device.uid, !allowed);
  }

  Future<void> _setTrust(bool value) async {
    await WsSvrManager().setPeerTrust(_device.uid, value);
    await ConnectionCoordinator().refreshTrustState();
    await _reload();
  }

  Future<void> _toggleClipboard() async {
    await LocalDatabase().clipboardDevice(_device.uid, !_device.clipboard);
    await _reload();
  }

  Future<void> _toggleMount(AppLocalizations l10n) async {
    final wanted = !RemoteMounts.shared.wants(_device.uid);
    final app = systemFileManagerName(l10n);
    try {
      final mount = await RemoteMounts.shared.setWanted(
        _device.uid,
        _device.name,
        wanted,
      );
      if (mount != null) await openDir(mount.path);
    } on MountFailed catch (failed) {
      if (failed.failure != MountFailure.offline) {
        showAppToast(
          mountFailureText(l10n, failed.failure, _device.name, app),
          tone: AppToastTone.error,
        );
      }
    }
  }

  Future<void> _confirmRemove(AppLocalizations l10n) async {
    final confirmed = await confirmAction(
      context,
      title: l10n.deleteDeviceTitle(_device.name),
      description: l10n.deleteDeviceDesc,
      confirmButtonText: l10n.confirm,
      cancelButtonText: l10n.cancel,
      isDestructive: true,
    );
    if (confirmed) await widget.onRemove(_device.uid);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    final touch = widget.touch;
    final type = WhisperType(touch: touch);
    final device = _device;
    final on = widget.connected;
    return Stack(
      children: [
        ColoredBox(
          color: c.canvas,
          // As tall as what is in it, and it scrolls only when that does not fit.
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, widget.topInset, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: deviceArtFor(device, size: 104, paired: widget.paired),
                ),
                const SizedBox(height: 10),
                Text(
                  device.name,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: type.title,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    widget.statusLine,
                    ?deviceSystemName(device.platform),
                  ].join(' · '),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: type.note, color: c.ink2),
                ),
                const SizedBox(height: 20),
                if (touch) ...[
                  if (widget.entries.isNotEmpty)
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 300),
                        child: Row(
                          children: [
                            for (final entry in widget.entries)
                              Expanded(
                                child: _Circle(
                                  glyph: entry.glyph,
                                  title: entry.title,
                                  act: true,
                                  touch: touch,
                                  onTap: entry.onTap,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (widget.entries.isNotEmpty) const SizedBox(height: 20),
                  ShellGroup(
                    children: [
                      ShellRow(
                        touch: true,
                        dim: !on,
                        label: l10n.shellPhoneSyncClipboard(device.name),
                        trailing: ShellSwitch(
                          touch: true,
                          label: l10n.shellPhoneSyncClipboard(device.name),
                          value: device.clipboard,
                          onChanged: on
                              ? (_) => unawaited(_toggleClipboard())
                              : null,
                        ),
                      ),
                    ],
                  ),
                ] else
                  ListenableBuilder(
                    listenable: RemoteMounts.shared,
                    builder: (context, _) => Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.onSound != null)
                          Expanded(
                            child: _Circle(
                              glyph: WhisperGlyph.speaker,
                              title: l10n.shellCardSound,
                              sub: widget.soundStatus,
                              on: widget.soundOn,
                              touch: touch,
                              onTap: on && widget.soundEnabled
                                  ? widget.onSound
                                  : null,
                            ),
                          ),
                        if (widget.onInput != null)
                          Expanded(
                            child: _Circle(
                              glyph: WhisperGlyph.keyboard,
                              title: l10n.shellCardInput,
                              sub: widget.inputStatus,
                              on: widget.inputOn,
                              touch: touch,
                              onTap: on ? widget.onInput : null,
                            ),
                          ),
                        Expanded(
                          child: _Circle(
                            glyph: WhisperGlyph.clip,
                            title: l10n.shellCardClipboard,
                            on: device.clipboard,
                            touch: touch,
                            onTap: on
                                ? () => unawaited(_toggleClipboard())
                                : null,
                          ),
                        ),
                        if (RemoteMounts.supported)
                          Expanded(
                            child: _Circle(
                              glyph: WhisperGlyph.drive,
                              title: l10n.shellCardMount,
                              on: RemoteMounts.shared.wants(device.uid),
                              busy: RemoteMounts.shared.isMounting(device.uid),
                              touch: touch,
                              onTap: on
                                  ? () => unawaited(_toggleMount(l10n))
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 20),
                ShellGroupLabel(l10n.shellCardCan(device.name), touch: touch),
                ShellGroup(
                  children: [
                    _permission(
                      l10n.shellCardTrust,
                      device.auth,
                      (v) => unawaited(_setTrust(v)),
                    ),
                    if (_browseAllowed case final browse?)
                      _permission(
                        l10n.shellCardBrowse,
                        browse,
                        (v) => unawaited(_setBrowse(v)),
                      ),
                    if (_changesAllowed case final changes?)
                      _permission(
                        l10n.shellCardChange,
                        // Depends on browsing: off and disabled without it.
                        changes && _browseAllowed == true,
                        _browseAllowed == true
                            ? (v) => unawaited(_setChanges(v))
                            : null,
                      ),
                  ],
                ),
                if (widget.onSearchHistory != null) ...[
                  const SizedBox(height: 20),
                  ShellGroup(
                    children: [
                      ShellRow(
                        touch: touch,
                        label: l10n.shellPhoneSearchHistory,
                        chevron: true,
                        onTap: widget.onSearchHistory,
                      ),
                    ],
                  ),
                ],
                if (!on) ...[
                  const SizedBox(height: 20),
                  ShellGroup(
                    children: [
                      if (canWake(device))
                        ShellRow(
                          touch: touch,
                          label: l10n.shellCardWake,
                          color: c.accent,
                          onTap: () => unawaited(wakeDevices([device])),
                        ),
                      ShellRow(
                        touch: touch,
                        label: l10n.shellCardDiagnostics,
                        chevron: true,
                        onTap: widget.onDiagnostics,
                      ),
                    ],
                  ),
                ],
                if (!on && !_nearby(device)) ...[
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Pressable(
                      onTap: () => unawaited(_confirmRemove(l10n)),
                      radius: WhisperRadius.xs,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: touch ? 14 : 2,
                        ),
                        child: Text(
                          l10n.shellCardRemove,
                          style: TextStyle(fontSize: type.note, color: c.bad),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (widget.onClose case final close?)
          Positioned(
            top: touch ? 2 : 8,
            right: touch ? 2 : 8,
            child: ShellIconButton(
              glyph: WhisperGlyph.x,
              iconSize: 14,
              weight: 2,
              touch: touch,
              label: l10n.close,
              onTap: close,
            ),
          ),
      ],
    );
  }

  bool _nearby(DeviceData device) => device.around == true;

  Widget _permission(String label, bool value, ValueChanged<bool>? onChanged) =>
      ShellRow(
        touch: widget.touch,
        label: label,
        dim: onChanged == null,
        trailing: ShellSwitch(
          touch: widget.touch,
          label: label,
          value: value,
          onChanged: onChanged,
        ),
      );
}

/// `.circ`: 46 across, the name under it, and a state line kept even when empty
/// so the row of circles does not change height.
class _Circle extends StatelessWidget {
  const _Circle({
    required this.glyph,
    required this.title,
    required this.touch,
    required this.onTap,
    this.sub,
    this.on = false,
    this.busy = false,
    this.act = false,
  });

  final WhisperGlyph glyph;
  final String title;
  final String? sub;
  final bool on, busy, act, touch;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: touch);
    final background = on ? c.accent : (act ? c.group : c.fill);
    final foreground = on ? c.onAccent : (act ? c.accentText : c.ink);
    return Opacity(
      opacity: onTap == null && !busy ? .45 : 1,
      child: Pressable(
        onTap: busy ? null : onTap,
        radius: WhisperRadius.s,
        scale: .92,
        label: title,
        selected: on,
        child: Column(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: background,
                shape: BoxShape.circle,
                boxShadow: act
                    ? WhisperShadow.e1(Theme.of(context).brightness)
                    : null,
              ),
              child: Center(
                child: busy
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: foreground,
                        ),
                      )
                    : WhisperIcon(glyph, size: 20, color: foreground),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: type.tiny, height: 1.25, color: c.ink),
            ),
            if (!act)
              Text(
                sub ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: type.tiny,
                  height: 1.25,
                  color: c.ink2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
