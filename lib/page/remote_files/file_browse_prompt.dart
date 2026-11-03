import 'package:whisper/new_ui/phone/phone_parts.dart' show PhoneSheetFrame;
import 'package:whisper/new_ui/shell/shell_parts.dart'
    show ShellButton, ShellButtonKind, ShellGroup, ShellRow, ShellSwitch;
import 'package:whisper/new_ui/shell/shell_requests.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../helper/helper.dart';
import '../../helper/island_asks.dart';
import '../../helper/notification.dart';
import '../../helper/notification_l10n.dart';
import '../../l10n/app_localizations.dart';
import '../../remote_files/fs_host.dart';
import '../../socket/svrmanager.dart';
import '../../remote_files/mount/remote_mounts.dart';
import 'files_icons.dart';

/// Asks "‹device› wants to browse your files" over the whole app whenever
/// [FileBrowseHost] has a request. Allow once, always allow (remembered for
/// that device) or don't allow; silence for a minute is a no. A switch says
/// whether it may also change them, remembered for that device too.
class FileBrowsePromptHost extends StatefulWidget {
  const FileBrowsePromptHost({
    super.key,
    required this.child,
    FileBrowseGate? gate,
  }) : _gate = gate;

  final Widget child;
  final FileBrowseGate? _gate;

  @override
  State<FileBrowsePromptHost> createState() => _FileBrowsePromptHostState();
}

class _FileBrowsePromptHostState extends State<FileBrowsePromptHost> {
  FileBrowseGate get _gate => widget._gate ?? FileBrowseHost.shared.gate;
  FileBrowseRequest? _announced;

  @override
  void initState() {
    super.initState();
    _gate.addListener(_onGate);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A device mounted in the file manager names its roots in the app's
    // own language, also when mounted on connect with no window open.
    final l10n = AppLocalizations.of(context);
    if (l10n != null) {
      RemoteMounts.shared.rootNamer = (root) => fsRootLabel(l10n, root);
    }
  }

  @override
  void dispose() {
    _gate.removeListener(_onGate);
    super.dispose();
  }

  void _onGate() {
    final pending = _gate.pending;
    final asked = _announced;
    if (asked != null && !identical(pending, asked)) {
      // Answered in the app, or given up on: off the island too.
      unawaited(IslandAsks.shared.settle(_askId(asked)));
      RequestIslandSource.shared.settle(fileBrowseAskId(asked.peerId));
    }
    if (pending != null && !identical(pending, _announced)) {
      _announced = pending;
      HapticFeedback.mediumImpact();
      _announce(pending);
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// The question must be seen: raise the window on desktops; on a phone in
  /// the background, put it on the island with its answers (Android), or
  /// notify.
  void _announce(FileBrowseRequest request) {
    if (isDesktop()) {
      final l10n = AppLocalizations.of(context);
      if (l10n != null) {
        askFileBrowse(
          l10n,
          request,
          _gate.decide,
          device: WsSvrManager().remoteProfileFor(request.peerId)?.device,
        );
      }
      return;
    }
    if (isDesktop()) {
      windowManager.show();
      windowManager.focus();
      return;
    }
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    final l10n = resolveNotificationL10n();
    if (!Platform.isAndroid) {
      NotificationHelper().showNotification(
        title: l10n.remoteFilesPromptTitle(request.deviceName),
        body: l10n.remoteFilesPromptBodyPhone,
      );
      return;
    }
    unawaited(_ask(request, l10n));
  }

  static String _askId(FileBrowseRequest request) => 'browse:${request.peerId}';

  Future<void> _ask(FileBrowseRequest request, AppLocalizations l10n) async {
    final readOnly = await FileBrowseHost.shared.permissions.isReadOnly(
      request.peerId,
    );
    if (!identical(_gate.pending, request)) {
      return;
    }
    await IslandAsks.shared.ask(
      id: _askId(request),
      glyph: 'folder',
      title: l10n.remoteFilesPromptTitle(request.deviceName),
      figure: request.deviceName,
      platform: WsSvrManager()
          .remoteProfileFor(request.peerId)
          ?.device
          .platform,
      text: readOnly
          ? l10n.remoteFilesPromptBodyReadOnlyPhone
          : l10n.remoteFilesPromptBodyPhone,
      buttons: [
        IslandAskButton('deny', l10n.remoteFilesDeny, role: 'decline'),
        IslandAskButton('once', l10n.remoteFilesAllowOnce, role: 'accept'),
      ],
      channelName: l10n.notificationChannelRequests,
      // Answered as it is set for this device ("允许修改文件" stays).
      onAnswer: (button) {
        if (!identical(_gate.pending, request)) {
          return;
        }
        switch (button) {
          case 'deny':
            _gate.decide(FileBrowseDecision.deny);
          case 'once':
            _gate.decide(FileBrowseDecision.once);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final request = _gate.pending;
    if (isDesktop()) return widget.child;
    // A 弹层 that stays open through a fold: a bottom sheet in the compact size
    // class, in the middle beside a sidebar.
    return Stack(
      children: [
        widget.child,
        if (request != null)
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: ColoredBox(
                color: context.wc.scrim,
                child: PhoneSheetFrame(
                  child: _PromptCard(
                    key: ValueKey(request),
                    request: request,
                    onDecide: _gate.decide,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PromptCard extends StatefulWidget {
  const _PromptCard({super.key, required this.request, required this.onDecide});

  final FileBrowseRequest request;
  final ValueChanged<FileBrowseDecision> onDecide;

  @override
  State<_PromptCard> createState() => _PromptCardState();
}

class _PromptCardState extends State<_PromptCard> {
  /// "允许修改文件", as last set for this device.
  bool _allowChanges = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final readOnly = await FileBrowseHost.shared.permissions.isReadOnly(
      widget.request.peerId,
    );
    if (mounted) {
      setState(() => _allowChanges = !readOnly);
    }
  }

  Future<void> _decide(FileBrowseDecision decision) async {
    if (decision == FileBrowseDecision.once ||
        decision == FileBrowseDecision.always) {
      await FileBrowseHost.shared.setReadOnly(
        widget.request.peerId,
        !_allowChanges,
      );
    }
    widget.onDecide(decision);
  }

  /// `.sheet`: a title, one line, the switch, the three answers.
  Widget _buildNew(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    const type = WhisperType(touch: true);
    final request = widget.request;
    Widget answer(
      String label,
      FileBrowseDecision decision, {
      ShellButtonKind kind = ShellButtonKind.normal,
    }) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ShellButton(
        label: label,
        kind: kind,
        large: true,
        touch: true,
        onTap: () => unawaited(_decide(decision)),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        Text(
          l10n.remoteFilesPromptTitle(request.deviceName),
          style: TextStyle(
            fontSize: type.head,
            height: 1.3,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _allowChanges
              ? l10n.remoteFilesPromptBodyPhone
              : l10n.remoteFilesPromptBodyReadOnlyPhone,
          style: TextStyle(fontSize: type.note, height: 1.45, color: c.ink2),
        ),
        const SizedBox(height: 14),
        ShellGroup(
          children: [
            ShellRow(
              touch: true,
              label: l10n.remoteFilesPromptAllowChanges,
              trailing: ShellSwitch(
                touch: true,
                label: l10n.remoteFilesPromptAllowChanges,
                value: _allowChanges,
                onChanged: (value) => setState(() => _allowChanges = value),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        answer(
          l10n.remoteFilesAllowOnce,
          FileBrowseDecision.once,
          kind: ShellButtonKind.primary,
        ),
        answer(l10n.remoteFilesAllowAlways, FileBrowseDecision.always),
        answer(
          l10n.remoteFilesDeny,
          FileBrowseDecision.deny,
          kind: ShellButtonKind.quiet,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildNew(context);
  }
}
