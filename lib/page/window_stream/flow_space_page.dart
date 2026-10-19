import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../helper/device_form_factor.dart';
import '../../helper/toast.dart';
import '../../l10n/app_localizations.dart';
import '../../window_stream/adb/adb_host_client.dart';
import '../../window_stream/android/window_activity.dart';
import '../../window_stream/android/scrcpy/scrcpy_compat_source.dart';
import '../../window_stream/core/window_source.dart';
import '../../window_stream/remote/remote_peer_source.dart';
import '../../window_stream/core/window_stream_models.dart';
import '../../window_stream/remote/window_stream_control.dart';
import '../../window_stream/remote/window_stream_host.dart';
import '../../socket/svrmanager.dart';
import '../../window_stream/window_stream_coordinator.dart';
import '../../window_stream/window_stream_support.dart';
import '../remote_files/files_menu.dart';
import 'flow_animated_grid.dart';
import 'flow_app_icon.dart';
import 'flow_desktop_switcher.dart';
import 'flow_recents_deck.dart';
import 'flow_space_controller.dart';
import 'flow_space_theme.dart';
import 'flow_space_widgets.dart';
import 'flow_switcher.dart';
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

/// Development aid: writes what the app currently shows to a PNG, so the
/// Flow Space can be reviewed without screen-recording permission. Debug
/// builds only.
Future<bool> debugCaptureAppFrame(String path) async {
  if (!kDebugMode) {
    return false;
  }
  final view = WidgetsBinding.instance.renderViews.first;
  final layer = view.debugLayer;
  if (layer is! OffsetLayer) {
    return false;
  }
  // The root layer already scales by the device pixel ratio.
  final image = await layer.toImage(
    Offset.zero & (view.size * view.flutterView.devicePixelRatio),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) {
    return false;
  }
  await File(path).writeAsBytes(data.buffer.asUint8List());
  return true;
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
  _FlowMode _mode = _FlowMode.open;

  /// Device cards by source id, so a sent window knows where to fly.
  final _deviceCardKeys = <String, GlobalKey>{};
  String? _receivingSourceId;
  bool _showSystem = false;
  Object? _startError;

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_rebuild);
    NativeWindowActivity.lastFrames.addListener(_rebuild);
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

  String _statusLabel(StreamStatus status) => switch (status) {
    StreamStatus.live => l10n.windowStreamStatusLive,
    StreamStatus.suspended => l10n.windowStreamStatusPaused,
    StreamStatus.opening ||
    StreamStatus.reconnecting => l10n.windowStreamStatusConnecting,
    _ => l10n.windowStreamStatusEnded,
  };

  String _sourceSubtitle(WindowSource source) {
    if (source is ScrcpyCompatSource) {
      for (final device in _coordinator.devices) {
        if (identical(device.source, source)) {
          return device.adb.wireless
              ? l10n.windowStreamViaWifi
              : l10n.windowStreamViaUsb;
        }
      }
    }
    return l10n.windowStreamViaWhisper;
  }

  /// [source]'s device said it is a tablet.
  bool _isTablet(WindowSource source) {
    final peerId = source is RemotePeerSource
        ? source.peerId
        : _coordinator.peerIdFor(source);
    return peerId != null && DeviceFormFactors.shared.isTablet(peerId);
  }

  Color _hue(WindowSource source) =>
      FlowSpaceTokens.deviceHue(source.info.id, Theme.of(context).brightness);

  bool get _touchScreen => Platform.isAndroid || Platform.isIOS;

  /// The row of devices on top. A phone comes here from one device's page,
  /// so it already knows which; only with several to choose from does it
  /// need the row.
  bool get _showShelf =>
      !_touchScreen ||
      (widget.focusPeerId == null &&
          _controller.sources.length + _controller.sendOnly.length > 1);

  /// The page, for the switcher's blurred background.
  final _pageShot = GlobalKey();

  Future<ui.Image?>? _snapshotPage() {
    final boundary = _pageShot.currentContext?.findRenderObject();
    return boundary is RenderRepaintBoundary ? blurredSnapshot(boundary) : null;
  }

  bool _isLandscapeSource(WindowSource source) =>
      source.info.platform != WindowStreamPlatform.android &&
      source.info.platform != WindowStreamPlatform.ios;

  /// Width / height of a recents card: the shape the window has where it
  /// shows. A phone's apps are tall; a computer's windows on a phone are
  /// shown upright unless turned (so they read like the phone's own
  /// recents), and wide everywhere else.
  double _cardAspect(WindowSource source) {
    if (!_isLandscapeSource(source)) {
      return 9 / 19.5;
    }
    if ((Platform.isAndroid || Platform.isIOS) && !RemoteViewport.landscape) {
      final screen = RemoteViewport.screen();
      return screen.height > 0 ? screen.width / screen.height : 9 / 19.5;
    }
    return 16 / 10;
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    // The same plain canvas as the rest of Whisper: no tinted glow.
    return RepaintBoundary(
      key: _pageShot,
      child: Scaffold(
        backgroundColor: colors.canvas,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 900
                ? _buildWide(context, constraints)
                : _buildCompact(context, constraints),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, {required bool compact}) {
    final colors = FlowSpaceColors.of(context);
    final canPop = Navigator.of(context).canPop();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 12 : 20,
        compact ? 4 : 12,
        compact ? FlowSpaceTokens.compactGutter : FlowSpaceTokens.gutter,
        4,
      ),
      child: Row(
        children: [
          if (canPop)
            CupertinoButton(
              padding: const EdgeInsets.all(8),
              minimumSize: const Size(36, 36),
              onPressed: () => Navigator.of(context).maybePop(),
              child: Icon(
                CupertinoIcons.chevron_back,
                color: colors.label,
                size: 22,
              ),
            ),
          Text(
            l10n.windowStreamSpaceTitle,
            style: TextStyle(
              color: colors.label,
              fontSize: compact ? 30 : 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
            ),
          ),
          const Spacer(),
          _buildQualityButton(context),
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

  /// How sharp windows come over: for every window, open ones at once.
  Widget _buildQualityButton(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return ValueListenableBuilder<WindowStreamQuality>(
      valueListenable: _coordinator.quality,
      builder: (context, quality, _) => Semantics(
        button: true,
        label: '${l10n.windowStreamQuality}, ${_qualityName(quality)}',
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          minimumSize: const Size(36, 32),
          color: colors.dark
              ? Colors.white.withValues(alpha: 0.09)
              : Colors.black.withValues(alpha: 0.055),
          borderRadius: BorderRadius.circular(16),
          onPressed: () {
            final box = context.findRenderObject() as RenderBox?;
            final at = box == null
                ? Offset.zero
                : box.localToGlobal(box.size.bottomRight(Offset.zero));
            unawaited(
              showFilesMenu(
                context,
                position: at + const Offset(0, 6),
                alignRight: true,
                touch: _touchScreen,
                items: [
                  FilesMenuItem(
                    label: l10n.windowStreamQualityHint,
                    enabled: false,
                  ),
                  const FilesMenuItem.separator(),
                  for (final option in WindowStreamQuality.values.reversed)
                    FilesMenuItem(
                      label: _qualityName(option),
                      checked: option == quality,
                      onSelected: () =>
                          unawaited(_coordinator.setQuality(option)),
                    ),
                ],
              ),
            );
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.sparkles,
                size: 15,
                color: colors.secondaryLabel,
              ),
              const SizedBox(width: 6),
              Text(
                _qualityName(quality),
                style: TextStyle(
                  color: colors.label,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 3),
              Icon(
                CupertinoIcons.chevron_down,
                size: 11,
                color: colors.secondaryLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }

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

  Widget _buildShelf(BuildContext context, {required double gutter}) {
    final sources = _controller.sources;
    final selected = _controller.selected;
    // One card per phone: skip transports of phones that already have a
    // source, and repeat transports (USB + wireless) of the same model.
    final knownModels = {for (final source in sources) source.info.model};
    final seenModels = <String>{};
    final problems = _coordinator.devices
        .where(
          (device) =>
              (device.source == null ||
                  !_coordinator.isAdbPhoneConnected(device)) &&
              !knownModels.contains(device.adb.model) &&
              seenModels.add(device.adb.model),
        )
        .toList();
    final target = _controller.selectedTarget;
    return SizedBox(
      height: FlowDeviceCard.height + 20,
      child: ListView(
        padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 8),
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        children: [
          for (final source in sources) ...[
            FlowDeviceCard(
              key: _deviceCardKeys.putIfAbsent(source.info.id, GlobalKey.new),
              name: source.info.name,
              subtitle: _sourceSubtitle(source),
              platform: source.info.platform,
              tablet: _isTablet(source),
              hue: _hue(source),
              selected: identical(source, selected),
              receiving: _receivingSourceId == source.info.id,
              windowCount: _coordinator.sessionsFor(source).length,
              onTap: () => _controller.select(source),
            ),
            const SizedBox(width: 12),
          ],
          // Devices that only take windows from here: an iPad.
          for (final peer in _controller.sendOnly) ...[
            FlowDeviceCard(
              key: _deviceCardKeys.putIfAbsent(
                _targetCardId(peer),
                GlobalKey.new,
              ),
              name: peer.name,
              subtitle: l10n.windowStreamReceiveOnly,
              platform: peer.platform,
              tablet: DeviceFormFactors.shared.isTablet(peer.peerId),
              hue: _targetHue(peer),
              selected: target?.peerId == peer.peerId,
              receiving: _receivingSourceId == _targetCardId(peer),
              onTap: () => _controller.selectTarget(peer),
            ),
            const SizedBox(width: 12),
          ],
          for (final device in problems) ...[
            FlowDeviceCard(
              name: device.adb.model.isEmpty
                  ? device.adb.serial
                  : device.adb.model,
              subtitle: _isRefused(device)
                  ? l10n.windowStreamNotPaired
                  : device.source != null
                  ? l10n.windowStreamNotConnected
                  : switch (device.adb.state) {
                      AdbDeviceState.unauthorized ||
                      AdbDeviceState.authorizing =>
                        l10n.windowStreamUnauthorized,
                      AdbDeviceState.device =>
                        l10n.windowStreamStatusConnecting,
                      _ => l10n.windowStreamDeviceOffline,
                    },
              platform: WindowStreamPlatform.android,
              tablet:
                  device.peerId != null &&
                  DeviceFormFactors.shared.isTablet(device.peerId!),
              hue: FlowSpaceTokens.deviceHue(
                device.adb.serial,
                Theme.of(context).brightness,
              ),
              selected: false,
              problem: true,
              onTap: () => showAppToast(
                _isRefused(device)
                    ? _failureText(device.failure!.reason)
                    : device.source != null
                    ? l10n.windowStreamConnectFirst
                    : device.adb.state == AdbDeviceState.unauthorized
                    ? l10n.windowStreamUnauthorized
                    : l10n.windowStreamDeviceOffline,
              ),
            ),
            const SizedBox(width: 12),
          ],
        ],
      ),
    );
  }

  /// A phone refused because its Whisper is not paired and trusted here.
  bool _isRefused(WindowStreamDevice device) =>
      device.failure?.reason == WindowStreamFailureReason.untrustedDevice ||
      device.failure?.reason == WindowStreamFailureReason.whisperMissing;

  /// Message when there is nothing to show yet (no devices, adb problems).
  Widget? _buildBlocking(BuildContext context, {required bool compact}) {
    if (_startError != null || !_coordinator.supported) {
      return FlowEmptyState(
        icon: CupertinoIcons.nosign,
        title: l10n.windowStreamUnsupported,
      );
    }
    final adbFailure = _coordinator.adbFailure;
    final refused = _coordinator.devices.where(_isRefused).firstOrNull;
    final nothing = _controller.sources.isEmpty && _controller.sendOnly.isEmpty;
    if (nothing && refused != null) {
      return FlowEmptyState(
        icon: CupertinoIcons.lock_shield,
        title: refused.adb.model.isEmpty
            ? l10n.windowStreamNotPaired
            : '${refused.adb.model} · ${l10n.windowStreamNotPaired}',
        detail: _failureText(refused.failure!.reason),
      );
    }
    if (nothing && _coordinator.devices.isEmpty) {
      return FlowEmptyState(
        icon: CupertinoIcons.rectangle_stack,
        title: l10n.windowStreamNoDevices,
        detail: _coordinator.adbSupported
            ? (adbFailure == null
                  ? l10n.windowStreamNoDevicesHintDesktop
                  : _failureText(adbFailure.reason))
            : l10n.windowStreamNoDevicesHintMobile,
        actionLabel: adbFailure == null ? null : l10n.windowStreamRetry,
        onAction: adbFailure == null
            ? null
            : () => unawaited(_coordinator.retry()),
      );
    }
    return null;
  }

  Widget _buildWide(BuildContext context, BoxConstraints constraints) {
    return _buildColumn(context, compact: false);
  }

  Widget _buildCompact(BuildContext context, BoxConstraints constraints) {
    return _buildColumn(context, compact: true);
  }

  /// Devices on the shelf, then the selected one's windows (those open here
  /// marked as such) and its apps. A window open here is not listed twice.
  Widget _buildColumn(BuildContext context, {required bool compact}) {
    final blocking = _buildBlocking(context, compact: compact);
    final gutter = compact
        ? FlowSpaceTokens.compactGutter
        : FlowSpaceTokens.gutter;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTopBar(context, compact: compact),
        if (blocking != null)
          Expanded(child: blocking)
        else ...[
          if (_showShelf) _buildShelf(context, gutter: gutter),
          ?_buildModeSwitch(context, gutter: gutter),
          Expanded(child: _buildModeContent(context, compact: compact)),
        ],
      ],
    );
  }

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

  /// "在本机打开" and "送到 ‹设备›" are opposite directions; two cards with
  /// the direction drawn on them keep them apart instead of mixing both
  /// kinds of cards on one page.
  Widget? _buildModeSwitch(BuildContext context, {required double gutter}) {
    final source = _controller.selected;
    if (source == null || _sendPeerOf(source) == null) {
      return null;
    }
    final name = source.info.name;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 6, gutter, 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FlowDirectionPicker(
          sendSelected: _mode == _FlowMode.send,
          hue: _hue(source),
          devicePlatform: source.info.platform,
          deviceTablet: _isTablet(source),
          openTitle: l10n.windowStreamOpenHere,
          openDetail: l10n.windowStreamOpenHereDetail(name),
          sendTitle: l10n.windowStreamSendTo(name),
          sendDetail: l10n.windowStreamSendToDetail(name),
          compact: gutter == FlowSpaceTokens.compactGutter,
          onChanged: (send) =>
              setState(() => _mode = send ? _FlowMode.send : _FlowMode.open),
        ),
      ),
    );
  }

  Widget _buildModeContent(BuildContext context, {required bool compact}) {
    final target = _controller.selectedTarget;
    if (target != null) {
      return FlowSendPanel(
        key: ValueKey('send:${target.peerId}'),
        deviceName: target.name,
        available: WsSvrManager().canOfferWindowsTo(target.peerId),
        gutter: compact
            ? FlowSpaceTokens.compactGutter
            : FlowSpaceTokens.gutter,
        onSend: (window, from, picture) => unawaited(
          _send(
            cardId: _targetCardId(target),
            name: target.name,
            hue: _targetHue(target),
            peerId: target.peerId,
            window: window,
            from: from,
            picture: picture,
          ),
        ),
      );
    }
    final source = _controller.selected;
    final peerId = _sendPeerOf(source);
    if (source == null || peerId == null || _mode == _FlowMode.open) {
      return _buildSourceContent(context, compact: compact);
    }
    return FlowSendPanel(
      key: ValueKey('send:${source.info.id}'),
      deviceName: source.info.name,
      available: WsSvrManager().canOfferWindowsTo(peerId),
      gutter: compact ? FlowSpaceTokens.compactGutter : FlowSpaceTokens.gutter,
      onSend: (window, from, picture) => unawaited(
        _send(
          cardId: source.info.id,
          name: source.info.name,
          hue: _hue(source),
          peerId: peerId,
          window: window,
          from: from,
          picture: picture,
        ),
      ),
    );
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
        _deviceCardKeys[cardId]?.currentContext?.findRenderObject()
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
    setState(() => _receivingSourceId = cardId);
    Timer(const Duration(milliseconds: 380), () {
      if (mounted) {
        setState(() => _receivingSourceId = null);
      }
    });
    final ok = await sent;
    if (!mounted) {
      return;
    }
    showAppToast(
      ok ? l10n.windowStreamSent(name) : l10n.windowStreamSendFailed,
      tone: ok ? AppToastTone.success : AppToastTone.error,
    );
  }

  Widget _buildSourceContent(BuildContext context, {required bool compact}) {
    final view = _controller.selectedView;
    final source = view?.source;
    if (view == null || source == null) {
      return const SizedBox.shrink();
    }
    final gutter = compact
        ? FlowSpaceTokens.compactGutter
        : FlowSpaceTokens.gutter;
    final apps = view.apps;
    if (apps == null) {
      if (view.failure != null) {
        return FlowEmptyState(
          icon: CupertinoIcons.exclamationmark_triangle,
          title: l10n.windowStreamLoadFailed,
          detail: _failureText(view.failure!.reason, source),
          actionLabel: l10n.windowStreamRetry,
          onAction: () => unawaited(_controller.reload()),
        );
      }
      return FlowEmptyState(
        icon: CupertinoIcons.hourglass,
        title: l10n.windowStreamLoadingApps,
        busy: true,
      );
    }
    final hue = _hue(source);
    final brightness = Theme.of(context).brightness;
    final query = _query.trim().toLowerCase();
    final runningIds = {for (final task in view.tasks) task.appId};
    final visibleApps = apps
        .where((app) => _showSystem || !app.system)
        .where(
          (app) =>
              query.isEmpty ||
              app.label.toLowerCase().contains(query) ||
              app.id.toLowerCase().contains(query),
        )
        .toList();
    final landscape = _isLandscapeSource(source);
    final cardAspect = _cardAspect(source);
    final cards = [
      for (final task in view.tasks)
        FlowTaskCard(
          key: '${task.id}',
          title: task.label,
          hue: flowAppHue(task.appId, brightness),
          // As it last looked here, if it was open here (upright, like
          // the phone's own recents); else as it looks over there.
          snapshot:
              NativeWindowActivity
                  .lastFrames
                  .value[NativeWindowActivity.frameKey(
                source.info.id,
                task.id,
              )] ??
              view.snapshots[task.id],
          icon: view.icons[task.appId],
          badge: task.streamed || _sessionOf(source, task) != null
              ? l10n.windowStreamStreaming
              // On another device now: opening it here moves it here.
              : task.shownOn != null
              ? l10n.flowTaskOpenOn(
                  task.shownOn!.isEmpty
                      ? l10n.windowStreamThatDevice
                      : task.shownOn!,
                )
              : null,
          closing: _closingTasks.contains(_taskKey(source, task)),
          closingLabel: l10n.windowStreamClosing,
        ),
    ];
    final tasksByKey = {for (final task in view.tasks) '${task.id}': task};
    void openCard(FlowTaskCard card, Rect rect) {
      final task = tasksByKey[card.key];
      // A window being closed would only open again.
      if (task == null || _closingTasks.contains(_taskKey(source, task))) {
        return;
      }
      final session = _sessionOf(source, task);
      if (session != null) {
        _focus(session);
      } else {
        unawaited(_open(source, OpenTask(task)));
      }
    }

    void closeCard(FlowTaskCard card) {
      final task = tasksByKey[card.key];
      if (task != null) {
        unawaited(_closeTask(source, task));
      }
    }

    final notice = source.state.value.failure;
    return CustomScrollView(
      slivers: [
        if (notice != null)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 0),
            sliver: SliverToBoxAdapter(
              child: FlowNotice(
                icon: notice.reason == WindowStreamFailureReason.sourceLocked
                    ? CupertinoIcons.lock_fill
                    : CupertinoIcons.exclamationmark_triangle_fill,
                text: _failureText(notice.reason, source),
              ),
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(gutter, 18, gutter, 6),
          sliver: SliverToBoxAdapter(
            child: FlowSectionHeader(
              // A phone's recent tasks, a computer's open windows.
              title: landscape
                  ? l10n.windowStreamWindows
                  : l10n.windowStreamRecents,
              count: cards.length,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: cards.isEmpty
              ? Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: gutter,
                    vertical: 12,
                  ),
                  child: Text(
                    l10n.windowStreamNoRecents,
                    style: TextStyle(
                      color: FlowSpaceColors.of(context).secondaryLabel,
                      fontSize: 13,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  // On a touch screen the stack rests against the screen's
                  // edge, the way the switcher it opens into does.
                  padding: EdgeInsets.fromLTRB(
                    _touchScreen ? 0 : gutter,
                    4,
                    gutter,
                    4,
                  ),
                  child: FlowRecentsDeck(
                    cards: cards,
                    cardWidth: cardAspect > 1
                        ? (compact ? 240 : 272)
                        : (compact ? 148 : 168),
                    cardAspect: cardAspect,
                    onOpen: openCard,
                    closeLabel: l10n.windowStreamCloseWindow,
                    onClose: closeCard,
                    curvedStack: _touchScreen,
                    // Every window to choose from: full screen like a
                    // phone's recent apps on a touch screen, a grid a mouse
                    // reaches on a desktop.
                    onShowAll: _touchScreen
                        ? (origins) => showFlowSwitcher(
                            context,
                            backdrop: _snapshotPage(),
                            cards: cards,
                            cardAspect: cardAspect,
                            origins: origins,
                            onOpen: openCard,
                            onClose: closeCard,
                            closeLabel: l10n.windowStreamCloseWindow,
                            rotateLabel: l10n.windowStreamSwitcherRotate,
                          )
                        : (origins) => showFlowDesktopSwitcher(
                            context,
                            cards: cards,
                            cardAspect: cardAspect,
                            origins: origins,
                            onOpen: openCard,
                            onClose: closeCard,
                            title: l10n.windowStreamRecents,
                            closeLabel: l10n.windowStreamCloseWindow,
                          ),
                  ),
                ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(gutter, 22, gutter, 12),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FlowSectionHeader(
                  title: l10n.windowStreamApps,
                  count: visibleApps.length,
                  accessory: apps.any((app) => app.system)
                      ? FlowToggleChip(
                          label: l10n.windowStreamShowSystemApps,
                          value: _showSystem,
                          tint: hue,
                          onChanged: (value) =>
                              setState(() => _showSystem = value),
                        )
                      : null,
                  // Searching is about apps, so it lives on their row; a
                  // phone has no room beside the title, so it goes below.
                  trailing: compact
                      ? null
                      : SizedBox(
                          width: 300,
                          height: 36,
                          child: _buildSearchField(context),
                        ),
                ),
                if (compact) ...[
                  const SizedBox(height: 12),
                  SizedBox(height: 38, child: _buildSearchField(context)),
                ],
              ],
            ),
          ),
        ),
        if (visibleApps.isEmpty)
          SliverToBoxAdapter(
            child: FlowEmptyState(
              icon: CupertinoIcons.square_grid_2x2,
              title: l10n.windowStreamNoApps,
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 0, gutter, compact ? 110 : 40),
            sliver: SliverToBoxAdapter(
              child: FlowAnimatedGrid<AppEntry>(
                items: visibleApps,
                keyOf: (app) => app.id,
                maxCrossAxisExtent: compact ? 92 : 104,
                mainAxisExtent: compact ? 104 : 116,
                crossAxisSpacing: 4,
                mainAxisSpacing: 8,
                itemBuilder: (context, app) {
                  final onDesktop = _coordinator
                      .sessionsFor(source)
                      .any(
                        (session) =>
                            session.handle.target.appId == app.id &&
                            !session.state.isTerminal,
                      );
                  return Center(
                    child: FlowAppTile(
                      label: app.label,
                      hue: flowAppHue(app.id, brightness),
                      icon: view.icons[app.id],
                      running: runningIds.contains(app.id),
                      onDesktop: onDesktop,
                      iconSize: compact ? 56 : 60,
                      busy: _opening.any(
                        (key) => key.startsWith('${source.info.id}/${app.id}/'),
                      ),
                      onTap: (_) => unawaited(
                        _open(source, OpenApp(app.id, label: app.label)),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
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

enum _FlowMode { open, send }
