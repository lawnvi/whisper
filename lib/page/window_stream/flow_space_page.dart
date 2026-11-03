import 'package:whisper/helper/helper.dart';
import 'package:whisper/new_ui/apps/apps_parts.dart';
import 'package:whisper/new_ui/apps/phone_apps.dart';
import 'package:whisper/new_ui/phone/panel_menu.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../helper/toast.dart';
import '../../l10n/app_localizations.dart';
import '../../window_stream/android/window_activity.dart';
import '../../window_stream/core/window_source.dart';
import '../../window_stream/remote/remote_peer_source.dart';
import '../../window_stream/core/window_stream_models.dart';
import '../../window_stream/remote/window_stream_control.dart';
import '../../window_stream/remote/window_stream_host.dart';
import '../../socket/svrmanager.dart';
import '../../window_stream/window_stream_coordinator.dart';
import '../../window_stream/window_stream_support.dart';
import '../remote_files/files_menu.dart';
import 'flow_app_icon.dart';
import 'flow_space_controller.dart';
import 'flow_space_theme.dart';
import 'flow_open.dart';
import 'flow_send_panel.dart';

/// The Flow Space: every device's apps, recent tasks and open windows, in
/// one place and one design language on desktops, tablets and phones.
class FlowSpacePage extends StatefulWidget {
  const FlowSpacePage({
    super.key,
    WindowStreamCoordinator? coordinator,
    this.focusPeerId,
  }) : _coordinator = coordinator;

  final WindowStreamCoordinator? _coordinator;

  /// Opened from a device's page: start on that device.
  final String? focusPeerId;

  @override
  State<FlowSpacePage> createState() => _FlowSpacePageState();
}

class _FlowSpacePageState extends State<FlowSpacePage> {
  late final WindowStreamCoordinator _coordinator =
      widget._coordinator ?? WindowStreamCoordinator.shared;
  late final FlowSpaceController _controller = FlowSpaceController(
    coordinator: _coordinator,
    focusPeerId: widget.focusPeerId,
  );
  final _opening = <String>{};
  String _query = '';
  // Kept here: the field moves between the title row and its own row.
  final _searchController = TextEditingController();
  bool _showSystem = false;
  Object? _startError;

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_rebuild);
    NativeWindowActivity.lastFrames.addListener(_rebuild);
    WindowStreamHost.shared.hostedChanged.addListener(_rebuild);
    _coordinator.start().catchError((Object error) {
      if (mounted) {
        setState(() => _startError = error);
      }
    });
    unawaited(_coordinator.loadQuality());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _coordinator.updateStrings(l10n);
  }

  @override
  void dispose() {
    NativeWindowActivity.lastFrames.removeListener(_rebuild);
    WindowStreamHost.shared.hostedChanged.removeListener(_rebuild);
    _controller.removeListener(_rebuild);
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) {
      setState(() {});
    }
  }

  // ------------------------------------------------------------------ actions

  Future<void> _open(WindowSource source, OpenTarget target) async {
    final key =
        '${source.info.id}/${target.appId}/${target is OpenTask ? target.task.id : ''}';
    if (!_opening.add(key)) {
      return;
    }
    setState(() {});
    try {
      await openFlowWindow(
        Navigator.of(context),
        source,
        target,
        coordinator: _coordinator,
      );
    } on WindowStreamFailure catch (failure) {
      showAppToast(_failureText(failure.reason), tone: AppToastTone.error);
    } catch (_) {
      showAppToast(l10n.windowStreamOpenFailed, tone: AppToastTone.error);
    } finally {
      _opening.remove(key);
      if (mounted) {
        setState(() {});
      }
    }
  }

  /// One wording for every failure, naming the device that has the
  /// window and what to do over there.
  String _failureText(
    WindowStreamFailureReason reason, [
    WindowSource? source,
  ]) => flowFailureText(l10n, reason, source: source);

  Color _hue(WindowSource source) =>
      FlowSpaceTokens.deviceHue(source.info.id, Theme.of(context).brightness);

  bool _isLandscapeSource(WindowSource source) =>
      source.info.platform != WindowStreamPlatform.android &&
      source.info.platform != WindowStreamPlatform.ios;

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    if (isDesktop()) {
      return Material(
        type: MaterialType.transparency,
        child: _buildNew(context),
      );
    }
    return _buildNewPhone(context);
  }

  /// surfaces.md「应用」, the prototype's `placeApps`: what is moving, this device's
  /// apps, what can be sent there. No shelf of devices: that is the sidebar.
  Widget _buildNew(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    final view = _controller.selectedView;
    final source = view?.source;
    final peerId = source == null ? widget.focusPeerId : _sendPeerOf(source);
    if (view == null || source == null) {
      return const Center(child: CupertinoActivityIndicator());
    }
    final name = source.info.name;
    final apps = view.apps;
    final brightness = Theme.of(context).brightness;
    Widget heading(String text, {Widget? end}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: type.note,
                fontWeight: FontWeight.w600,
                color: c.ink2,
              ),
            ),
          ),
          ?end,
        ],
      ),
    );
    final sessions = _coordinator
        .sessionsFor(source)
        .where((session) => !session.state.isTerminal)
        .toList();
    final query = _query.trim().toLowerCase();
    final visibleApps = (apps ?? const <AppEntry>[])
        .where((app) => _showSystem || !app.system)
        .where(
          (app) =>
              query.isEmpty ||
              app.label.toLowerCase().contains(query) ||
              app.id.toLowerCase().contains(query),
        )
        .toList();
    final phoneSource = !_isLandscapeSource(source);
    final hosted = peerId == null
        ? const <({String sessionId, String title})>[]
        : WindowStreamHost.shared.hostedFor(peerId);
    Widget flowRow(
      String title,
      String detail,
      String action,
      VoidCallback onTap,
    ) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: type.body,
                      height: 1.3,
                      color: c.ink,
                    ),
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: type.note, color: c.ink2),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            ShellButton(label: action, onTap: onTap),
          ],
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 30),
      children: [
        if (sessions.isNotEmpty || hosted.isNotEmpty) ...[
          heading(l10n.shellAppsMoving),
          DecoratedBox(
            decoration: BoxDecoration(
              color: c.fill,
              borderRadius: BorderRadius.circular(WhisperRadius.m),
            ),
            child: Column(
              children: [
                for (final session in sessions)
                  flowRow(
                    session.handle.title,
                    l10n.shellAppsRunsOn(name),
                    l10n.shellAppsEnd,
                    () => unawaited(_coordinator.close(session)),
                  ),
                for (final window in hosted)
                  flowRow(
                    window.title,
                    l10n.shellAppsShownOn(name),
                    l10n.shellAppsBringBack,
                    () => unawaited(
                      WindowStreamHost.shared.bringBack(window.sessionId),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
        heading(
          l10n.shellAppsOn(name),
          end: Builder(
            builder: (buttonContext) => ShellIconButton(
              glyph: WhisperGlyph.more,
              iconSize: 15,
              weight: 2.4,
              label: l10n.windowStreamQuality,
              onTap: () => _openNewAppsMenu(buttonContext),
            ),
          ),
        ),
        if (phoneSource && apps != null) ...[
          SizedBox(height: 34, child: _buildSearchField(context)),
          const SizedBox(height: 12),
        ],
        if (source.state.value.failure case final notice?) ...[
          Text(
            _failureText(notice.reason, source),
            style: TextStyle(fontSize: type.note, color: c.warn),
          ),
          const SizedBox(height: 12),
        ],
        if (view.tasks.isNotEmpty) ...[
          ShellAutoGrid(
            minWidth: 160,
            runSpacing: 12,
            spacing: 12,
            children: [
              for (final task in view.tasks)
                ShellWindowThumb(
                  title: task.label,
                  picture:
                      NativeWindowActivity
                          .lastFrames
                          .value[NativeWindowActivity.frameKey(
                        source.info.id,
                        task.id,
                      )] ??
                      view.snapshots[task.id],
                  badge: _sessionOf(source, task) != null
                      ? l10n.windowStreamStreaming
                      : task.shownOn != null
                      ? l10n.flowTaskOpenOn(
                          task.shownOn!.isEmpty
                              ? l10n.windowStreamThatDevice
                              : task.shownOn!,
                        )
                      : null,
                  onTap: (_) {
                    if (_closingTasks.contains(_taskKey(source, task))) {
                      return;
                    }
                    final session = _sessionOf(source, task);
                    if (session != null) {
                      _focus(session);
                    } else {
                      unawaited(_open(source, OpenTask(task)));
                    }
                  },
                  closeLabel: l10n.windowStreamCloseWindow,
                  onClose: () => unawaited(_closeTask(source, task)),
                ),
            ],
          ),
          const SizedBox(height: 14),
        ],
        if (apps == null)
          view.failure != null
              ? ShellDeviceState(
                  art: const SizedBox.shrink(),
                  title: l10n.windowStreamLoadFailed,
                  body: _failureText(view.failure!.reason, source),
                  action: ShellButton(
                    label: l10n.windowStreamRetry,
                    kind: ShellButtonKind.primary,
                    large: true,
                    onTap: () => unawaited(_controller.reload()),
                  ),
                )
              : const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CupertinoActivityIndicator()),
                )
        else if (visibleApps.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              l10n.windowStreamNoApps,
              style: TextStyle(fontSize: type.note, color: c.ink2),
            ),
          )
        else
          ShellAutoGrid(
            minWidth: 76,
            spacing: 6,
            runSpacing: 12,
            children: [
              for (final app in visibleApps)
                ShellAppIcon(
                  label: app.label,
                  hue: flowAppHue(app.id, brightness),
                  icon: view.icons[app.id],
                  busy: _opening.any(
                    (key) => key.startsWith('${source.info.id}/${app.id}/'),
                  ),
                  onTap: () => unawaited(
                    _open(source, OpenApp(app.id, label: app.label)),
                  ),
                ),
            ],
          ),
        if (peerId != null) ...[
          const SizedBox(height: 24),
          heading(l10n.windowStreamSendTo(name)),
          ShellSendWindows(
            deviceName: name,
            available: WsSvrManager().canOfferWindowsTo(peerId),
            onSend: (window, from, picture) => unawaited(
              _send(
                cardId: source.info.id,
                name: name,
                hue: _hue(source),
                peerId: peerId,
                window: window,
                from: from,
                picture: picture,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// surfaces.md「应用」at touch size: one list as on a desktop, with the page's
  /// back arrow, its 更多 at the right and everything at a finger's size.
  Widget _buildNewPhone(BuildContext context) {
    final c = context.wc;
    final brightness = Theme.of(context).brightness;
    final view = _controller.selectedView;
    final source = view?.source;
    final target = _controller.selectedTarget;
    final blocking = _newPhoneBlocking();
    Widget body;
    if (blocking != null) {
      body = blocking;
    } else if (view == null || source == null) {
      body = target == null
          ? const Center(child: CupertinoActivityIndicator())
          : PhoneAppsView(
              movingTitle: l10n.shellAppsMoving,
              flows: const [],
              sendTitle: l10n.windowStreamSendTo(target.name),
              send: _newPhoneSend(
                cardId: _targetCardId(target),
                name: target.name,
                hue: _targetHue(target),
                peerId: target.peerId,
              ),
            );
    } else {
      final name = source.info.name;
      final apps = view.apps;
      final query = _query.trim().toLowerCase();
      final runningIds = {for (final task in view.tasks) task.appId};
      final sessions = _coordinator.sessionsFor(source);
      final peerId = _sendPeerOf(source);
      body = PhoneAppsView(
        movingTitle: l10n.shellAppsMoving,
        flows: [
          for (final session in sessions)
            if (!session.state.isTerminal)
              PhoneAppsFlow(
                title: session.handle.title,
                detail: l10n.shellAppsRunsOn(name),
                action: l10n.shellAppsEnd,
                onAction: () => unawaited(_coordinator.close(session)),
              ),
        ],
        appsTitle: l10n.shellAppsOn(name),
        notice: source.state.value.failure == null
            ? null
            : _failureText(source.state.value.failure!.reason, source),
        search: !_isLandscapeSource(source) && apps != null
            ? PhoneAppsSearch(
                controller: _searchController,
                hint: l10n.windowStreamSearchApps,
                onChanged: (value) => setState(() => _query = value),
              )
            : null,
        closeLabel: l10n.windowStreamCloseWindow,
        tasks: [
          for (final task in view.tasks)
            PhoneAppsTask(
              title: task.label,
              picture:
                  NativeWindowActivity
                      .lastFrames
                      .value[NativeWindowActivity.frameKey(
                    source.info.id,
                    task.id,
                  )] ??
                  view.snapshots[task.id],
              closing: _closingTasks.contains(_taskKey(source, task)),
              badge: _closingTasks.contains(_taskKey(source, task))
                  ? l10n.windowStreamClosing
                  : task.streamed || _sessionOf(source, task) != null
                  ? l10n.windowStreamStreaming
                  : task.shownOn != null
                  ? l10n.flowTaskOpenOn(
                      task.shownOn!.isEmpty
                          ? l10n.windowStreamThatDevice
                          : task.shownOn!,
                    )
                  : null,
              onTap: () {
                if (_closingTasks.contains(_taskKey(source, task))) return;
                final session = _sessionOf(source, task);
                if (session != null) {
                  _focus(session);
                } else {
                  unawaited(_open(source, OpenTask(task)));
                }
              },
              onClose: () => unawaited(_closeTask(source, task)),
            ),
        ],
        failure: apps == null && view.failure != null
            ? PhoneAppsFailure(
                title: l10n.windowStreamLoadFailed,
                body: _failureText(view.failure!.reason, source),
                retry: l10n.windowStreamRetry,
                onRetry: () => unawaited(_controller.reload()),
              )
            : null,
        loading: apps == null && view.failure == null,
        noApps: l10n.windowStreamNoApps,
        apps: apps == null
            ? null
            : [
                for (final app in apps)
                  if ((_showSystem || !app.system) &&
                      (query.isEmpty ||
                          app.label.toLowerCase().contains(query) ||
                          app.id.toLowerCase().contains(query)))
                    PhoneAppsEntry(
                      label: app.label,
                      hue: flowAppHue(app.id, brightness),
                      icon: view.icons[app.id],
                      busy: _opening.any(
                        (key) => key.startsWith('${source.info.id}/${app.id}/'),
                      ),
                      running: runningIds.contains(app.id),
                      openHere: sessions.any(
                        (session) =>
                            session.handle.target.appId == app.id &&
                            !session.state.isTerminal,
                      ),
                      onTap: () => unawaited(
                        _open(source, OpenApp(app.id, label: app.label)),
                      ),
                    ),
              ],
        sendTitle: l10n.windowStreamSendTo(name),
        send: peerId == null
            ? null
            : _newPhoneSend(
                cardId: source.info.id,
                name: name,
                hue: _hue(source),
                peerId: peerId,
              ),
      );
    }
    return PhonePage(
      title: l10n.shellTabApps,
      background: c.content,
      // Beside a sidebar the toolbar above has the tabs.
      bar: WhisperLayout.of(context).compact,
      end: blocking != null
          ? null
          : Builder(
              builder: (button) => PhoneBarButton(
                key: const ValueKey('apps-more'),
                glyph: WhisperGlyph.more,
                iconSize: 15,
                weight: 2.4,
                label: l10n.windowStreamQuality,
                onTap: () => _openNewPhoneMenu(button),
              ),
            ),
      child: body,
    );
  }

  Widget _newPhoneSend({
    required String cardId,
    required String name,
    required Color hue,
    required String peerId,
  }) => ShellSendWindows(
    touch: true,
    deviceName: name,
    available: WsSvrManager().canOfferWindowsTo(peerId),
    onSend: (window, from, picture) => unawaited(
      _send(
        cardId: cardId,
        name: name,
        hue: hue,
        peerId: peerId,
        window: window,
        from: from,
        picture: picture,
      ),
    ),
  );

  /// The phone's 更多: how sharp windows come over, whether system apps show.
  void _openNewPhoneMenu(BuildContext button) {
    final quality = _coordinator.quality.value;
    final apps = _controller.selectedView?.apps ?? const <AppEntry>[];
    unawaited(
      showPanelMenu(
        button,
        anchor: panelMenuAnchor(button),
        touch: true,
        title: l10n.windowStreamQualityHint,
        items: [
          for (final option in WindowStreamQuality.values.reversed)
            PanelMenuEntry(
              label: _qualityName(option),
              checked: option == quality,
              onSelected: () => unawaited(_coordinator.setQuality(option)),
            ),
          if (apps.any((app) => app.system)) ...[
            const PanelMenuEntry.separator(),
            PanelMenuEntry(
              label: l10n.windowStreamShowSystemApps,
              checked: _showSystem,
              onSelected: () => setState(() => _showSystem = !_showSystem),
            ),
          ],
        ],
      ),
    );
  }

  /// Nothing to show yet: the same cases as [_buildBlocking], in the new words
  /// and at a finger's size.
  Widget? _newPhoneBlocking() {
    Widget state(String title, String body, {Widget? action}) =>
        ShellDeviceState(
          touch: true,
          art: const SizedBox.shrink(),
          title: title,
          body: body,
          action: action,
        );
    if (_startError != null || !_coordinator.supported) {
      return state(l10n.windowStreamUnsupported, '');
    }
    final adbFailure = _coordinator.adbFailure;
    final refused = _coordinator.devices.where(_isRefused).firstOrNull;
    final nothing = _controller.sources.isEmpty && _controller.sendOnly.isEmpty;
    if (nothing && refused != null) {
      return state(
        refused.adb.model.isEmpty
            ? l10n.windowStreamNotPaired
            : '${refused.adb.model} · ${l10n.windowStreamNotPaired}',
        _failureText(refused.failure!.reason),
      );
    }
    if (nothing && _coordinator.devices.isEmpty) {
      return state(
        l10n.windowStreamNoDevices,
        _coordinator.adbSupported
            ? (adbFailure == null
                  ? l10n.windowStreamNoDevicesHintDesktop
                  : _failureText(adbFailure.reason))
            : l10n.windowStreamNoDevicesHintMobile,
        action: adbFailure == null
            ? null
            : PhoneButton(
                label: l10n.windowStreamRetry,
                kind: PhoneButtonKind.primary,
                large: true,
                onTap: () => unawaited(_coordinator.retry()),
              ),
      );
    }
    return null;
  }

  /// 工具栏的更多: how sharp windows come over, and whether system apps show.
  void _openNewAppsMenu(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject()! as RenderBox;
    final quality = _coordinator.quality.value;
    unawaited(
      showFilesMenu(
        buttonContext,
        position: box.localToGlobal(
          Offset(box.size.width, box.size.height + 6),
        ),
        alignRight: true,
        items: [
          FilesMenuItem(label: l10n.windowStreamQualityHint, enabled: false),
          for (final option in WindowStreamQuality.values.reversed)
            FilesMenuItem(
              label: _qualityName(option),
              checked: option == quality,
              onSelected: () => unawaited(_coordinator.setQuality(option)),
            ),
          const FilesMenuItem.separator(),
          FilesMenuItem(
            label: l10n.windowStreamShowSystemApps,
            checked: _showSystem,
            onSelected: () => setState(() => _showSystem = !_showSystem),
          ),
        ],
      ),
    );
  }

  String _qualityName(WindowStreamQuality quality) => switch (quality) {
    WindowStreamQuality.smooth => l10n.windowStreamQualitySmooth,
    WindowStreamQuality.standard => l10n.windowStreamQualityStandard,
    WindowStreamQuality.high => l10n.windowStreamQualityHigh,
    WindowStreamQuality.best => l10n.windowStreamQualityBest,
  };

  Widget _buildSearchField(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return CupertinoSearchTextField(
      controller: _searchController,
      placeholder: l10n.windowStreamSearchApps,
      onChanged: (value) => setState(() => _query = value),
      style: TextStyle(color: colors.label, fontSize: 14.5),
      placeholderStyle: TextStyle(color: colors.secondaryLabel, fontSize: 14.5),
      backgroundColor: colors.dark
          ? Colors.white.withValues(alpha: 0.09)
          : Colors.black.withValues(alpha: 0.055),
      borderRadius: BorderRadius.circular(19),
      padding: const EdgeInsetsDirectional.fromSTEB(6, 9, 12, 9),
      prefixInsets: const EdgeInsetsDirectional.fromSTEB(12, 0, 2, 2),
      suffixInsets: const EdgeInsetsDirectional.fromSTEB(0, 0, 8, 2),
    );
  }

  /// A phone refused because its Whisper is not paired and trusted here.
  bool _isRefused(WindowStreamDevice device) =>
      device.failure?.reason == WindowStreamFailureReason.untrustedDevice ||
      device.failure?.reason == WindowStreamFailureReason.whisperMissing;

  /// The device's Whisper peer when this one can also send it windows: a
  /// computer or phone connected through Whisper, or an adb phone's Whisper.
  String? _sendPeerOf(WindowSource? source) {
    if (source == null || !supportsWindowStreamSource()) {
      return null;
    }
    if (source is RemotePeerSource) {
      return source.peerId;
    }
    return _coordinator.peerIdFor(source);
  }

  String _targetCardId(WindowStreamPeer peer) => 'send:${peer.peerId}';

  Color _targetHue(WindowStreamPeer peer) => FlowSpaceTokens.deviceHue(
    _targetCardId(peer),
    Theme.of(context).brightness,
  );

  /// Sends [window] to [peerId]: the card flies onto the device's card on
  /// the shelf while the offer goes out; the device card swells as it lands.
  Future<void> _send({
    required String cardId,
    required String name,
    required Color hue,
    required String peerId,
    required RemoteWindowInfo window,
    required Rect from,
    required Uint8List? picture,
  }) async {
    final targetBox =
        (ShellFlyTargets.rowOf(peerId))?.currentContext?.findRenderObject()
            as RenderBox?;
    final to = targetBox != null && targetBox.hasSize
        ? targetBox.localToGlobal(Offset.zero) & targetBox.size
        : from;
    final sent = WindowStreamHost.shared.offer(peerId, window);
    await flowFlyWindow(
      context,
      from: from,
      to: to,
      hue: hue,
      picture: picture,
    );
    if (!mounted) {
      return;
    }
    final ok = await sent;
    if (!mounted) {
      return;
    }
    showAppToast(
      ok ? l10n.windowStreamSent(name) : l10n.windowStreamSendFailed,
      tone: ok ? AppToastTone.success : AppToastTone.error,
    );
  }

  /// The stream of [task], if it is open here.
  WindowStreamSession? _sessionOf(WindowSource source, TaskEntry task) {
    for (final session in _coordinator.sessionsFor(source)) {
      if (session.state.isTerminal) {
        continue;
      }
      final handle = session.handle;
      final target = handle.target;
      if (handle is RemoteStreamHandle && handle.window.id == task.id) {
        return session;
      }
      if (target is OpenTask && target.task.id == task.id) {
        return session;
      }
    }
    return null;
  }

  /// Brings an open window forward: its own window on a desktop, its task
  /// on Android, the viewer page elsewhere.
  void _focus(WindowStreamSession session) {
    if (NativeWindowActivity.supports(session)) {
      unawaited(NativeWindowActivity.open(session, coordinator: _coordinator));
    } else if (session.flutterHosted) {
      unawaited(Navigator.of(context).push(flowWindowRoute(session)));
    } else {
      _coordinator.focus(session);
    }
  }

  /// Windows asked to close from here, until their device says how it went.
  final _closingTasks = <String>{};

  String _taskKey(WindowSource source, TaskEntry task) =>
      '${source.info.id}/${task.id}';

  /// Closes the window on its device, as its own close button would; a
  /// stream of it ends with it. Its card waits, dimmed, until the device
  /// has seen it go; a window that stays (asking whether to save) says so.
  Future<void> _closeTask(WindowSource source, TaskEntry task) async {
    if (source is! ClosesTasks) {
      HapticFeedback.mediumImpact();
      final session = _sessionOf(source, task);
      if (session != null) {
        await _coordinator.close(session);
      }
      return;
    }
    final key = _taskKey(source, task);
    if (_closingTasks.contains(key)) {
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _closingTasks.add(key));
    final session = _sessionOf(source, task);
    final outcome = source is ConfirmsTaskClose
        ? await (source as ConfirmsTaskClose).closeTaskAndWait(task)
        : (await (source as ClosesTasks).closeTask(task)
              ? TaskCloseOutcome.closed
              : TaskCloseOutcome.failed);
    if (outcome == TaskCloseOutcome.closed) {
      // The app is gone; its window here goes with it.
      if (session != null && !session.state.isTerminal) {
        await _coordinator.close(session);
      }
      _controller.forgetTask(source, task.id);
    }
    if (!mounted) {
      return;
    }
    setState(() => _closingTasks.remove(key));
    switch (outcome) {
      case TaskCloseOutcome.closed:
        break;
      case TaskCloseOutcome.stillOpen:
        HapticFeedback.heavyImpact();
        showAppToast(
          l10n.windowStreamCloseStillOpen(_appName(source, task)),
          tone: AppToastTone.warning,
          duration: const Duration(seconds: 6),
          action: AppToastAction(
            label: l10n.windowStreamCloseShow,
            onPressed: () {
              final open = _sessionOf(source, task);
              if (open != null) {
                _focus(open);
              } else {
                unawaited(_open(source, OpenTask(task)));
              }
            },
          ),
        );
      case TaskCloseOutcome.failed:
        showAppToast(l10n.windowStreamCloseFailed, tone: AppToastTone.error);
    }
    await _controller.reload();
  }

  /// The app's own name for [task] ("记事本"), not its window title.
  String _appName(WindowSource source, TaskEntry task) {
    for (final app in _controller.selectedView?.apps ?? const <AppEntry>[]) {
      if (app.id == task.appId && app.label.isNotEmpty) {
        return app.label;
      }
    }
    return task.label;
  }
}
