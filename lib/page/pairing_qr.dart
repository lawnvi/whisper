import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/pairing_invite.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/widget/manual_connection_dialog.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_dialog.dart';
import 'package:whisper/widget/subtle_motion.dart';
import 'package:whisper/widget/segmented_tabs.dart';

final class PairingQrResult {
  PairingQrResult.qr(PairingInvite value)
    : invite = value,
      endpoint = PeerEndpoint(host: value.host, port: value.port);

  const PairingQrResult.manual(this.endpoint) : invite = null;

  final PairingInvite? invite;
  final PeerEndpoint endpoint;
}

Future<PairingQrResult?> showPairingQrDialog(
  BuildContext context, {
  required PairingInvite? localInvite,
  String? localPeerId,
  bool startWithAddress = false,
  bool startWithScanner = true,
  PairingQrDialogController? controller,
}) {
  return showWhisperDialog<PairingQrResult>(
    context,
    useSafeArea: false,
    blurBackground:
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS,
    builder: (context) => PairingQrDialog(
      localInvite: localInvite,
      localPeerId: localPeerId,
      startWithAddress: startWithAddress,
      startWithScanner: startWithScanner,
      controller: controller,
    ),
  );
}

final class PairingQrDialogController {
  VoidCallback? _dismiss;

  void dismiss() => _dismiss?.call();

  void _attach(VoidCallback dismiss) => _dismiss = dismiss;

  void _detach(VoidCallback dismiss) {
    if (identical(_dismiss, dismiss)) {
      _dismiss = null;
    }
  }
}

class PairingQrDialog extends StatefulWidget {
  const PairingQrDialog({
    super.key,
    required this.localInvite,
    this.startWithScanner = true,
    this.startWithAddress = false,
    this.localPeerId,
    this.controller,
  });

  final PairingInvite? localInvite;
  final String? localPeerId;
  final bool startWithAddress;
  final bool startWithScanner;
  final PairingQrDialogController? controller;

  @override
  State<PairingQrDialog> createState() => _PairingQrDialogState();
}

class _PairingQrDialogState extends State<PairingQrDialog>
    with SingleTickerProviderStateMixin {
  late final VoidCallback _dismissCallback = _dismissDialog;
  late final bool _canScan =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  final GlobalKey _scannerKey = GlobalKey(debugLabel: 'pairing-qr-scanner');
  final GlobalKey _manualFormKey = GlobalKey(
    debugLabel: 'pairing-address-form',
  );
  QRViewController? _scannerController;
  StreamSubscription<Barcode>? _scanSubscription;
  late final TabController _tabController;
  bool get _scannerActive =>
      _canScan && _tabController.index == 1 && !_tabController.indexIsChanging;
  int? _selectedTab;
  bool _handlingScan = false;
  String? _scanError;
  bool _copying = false;
  bool _copied = false;
  bool _copyFailed = false;
  Timer? _copyResetTimer;
  ({String data, double size, Widget image})? _qrImageCache;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(_dismissCallback);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectedTab != null) return;
    _tabController = TabController(
      length: _canScan ? 3 : 2,
      vsync: this,
      animationDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      initialIndex: widget.startWithAddress
          ? (_canScan ? 2 : 1)
          : _canScan && widget.startWithScanner
          ? 1
          : 0,
    )..addListener(_onTabChanged);
    _selectedTab = _tabController.index;
  }

  void _onTabChanged() {
    if (!_scannerActive) {
      unawaited(_scanSubscription?.cancel());
      _scanSubscription = null;
      // Removing QRView releases its native camera. Ignore any queued scan.
      _scannerController = null;
      _handlingScan = false;
    }
    if (_selectedTab != _tabController.index) {
      _selectedTab = _tabController.index;
      FocusScope.of(context).unfocus();
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller?._detach(_dismissCallback);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _copyResetTimer?.cancel();
    unawaited(_scanSubscription?.cancel());
    super.dispose();
  }

  void _dismissDialog() {
    if (!mounted) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final windowSize = MediaQuery.sizeOf(context);
    final compact = windowSize.width < 480;
    final dialogWidth = (windowSize.width - (compact ? 24 : 32)).clamp(
      288.0,
      _canScan || compact ? 440.0 : 640.0,
    );
    final textGrowth = (MediaQuery.textScalerOf(context).scale(16) - 16).clamp(
      0.0,
      double.infinity,
    );
    final header = _buildHeader(l10n, compact: compact);
    final switcher = _buildModeSwitcher(l10n, compact: compact);
    final panels = _buildCompactPanels(l10n, compact: compact);
    return SafeArea(
      maintainBottomViewPadding: _canScan,
      minimum: EdgeInsets.all(compact ? 12 : 16),
      child: _KeyboardInsetAnimation(
        builder: (insetDuration) => WhisperGlassDialog(
          insetPadding: EdgeInsets.zero,
          insetAnimationDuration: insetDuration,
          blurBackground: !_canScan,
          borderRadius: compact ? 18 : 26,
          constraints: BoxConstraints(
            minWidth: dialogWidth,
            maxWidth: dialogWidth,
          ),
          contentPadding: EdgeInsets.zero,
          // Derive content size from the Dialog's animated constraints. Reading
          // the final keyboard inset here would resize before its position moves.
          content: LayoutBuilder(
            builder: (context, constraints) {
              final availableHeight = constraints.maxHeight;
              final sideBySide =
                  !_canScan &&
                  windowSize.width >= 600 &&
                  availableHeight >= 328;
              final mobileQrSize = (dialogWidth - 96).clamp(160.0, 200.0);
              final dialogHeight = _canScan
                  ? (mobileQrSize + (compact ? 224 : 256) + textGrowth * 5)
                        .clamp(0.0, availableHeight)
                  : sideBySide
                  ? availableHeight.clamp(0.0, 420.0)
                  : null;
              final content = Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (availableHeight < 280)
                    Row(
                      children: [
                        Expanded(
                          child: _buildModeSwitcher(l10n, compact: true),
                        ),
                        IconButton(
                          tooltip: l10n.close,
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    )
                  else ...[
                    header,
                    if (!sideBySide) switcher,
                  ],
                  Flexible(
                    fit: _canScan || sideBySide ? FlexFit.tight : FlexFit.loose,
                    child: sideBySide ? _buildDesktopPanels(l10n) : panels,
                  ),
                ],
              );
              final frame = SizedBox(
                key: const ValueKey<String>('pairing-qr-dialog-content'),
                width: dialogWidth,
                height: dialogHeight,
                // Moving above the keyboard can reuse the unchanged tab content.
                child: RepaintBoundary(child: content),
              );
              return _canScan
                  ? frame
                  : AnimatedSize(
                      duration: whisperMotionDuration(context),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: frame,
                    );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCompactPanels(AppLocalizations l10n, {required bool compact}) {
    final pages = <Widget>[
      _buildMyCode(l10n, compact: compact || _canScan),
      if (_canScan) _buildScanner(l10n, compact: compact),
      ManualConnectionForm(
        key: _manualFormKey,
        localHost: widget.localInvite?.host,
        fillAvailableHeight: _canScan,
        padding: EdgeInsets.fromLTRB(
          compact ? 16 : 24,
          20,
          compact ? 16 : 24,
          20,
        ),
        onConnect: (endpoint) =>
            Navigator.of(context).pop(PairingQrResult.manual(endpoint)),
      ),
    ];
    return WhisperTabPanels(
      selected: _selectedTab!,
      fit: _canScan ? StackFit.expand : StackFit.loose,
      children: pages,
    );
  }

  Widget _buildHeader(AppLocalizations l10n, {required bool compact}) {
    final theme = Theme.of(context);
    return Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(16, 4, 6, 0)
          : const EdgeInsets.fromLTRB(24, 18, 12, 8),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.qr_code_2_rounded,
            size: compact ? 21 : 24,
            color: theme.colorScheme.onSurface,
          ),
          SizedBox(width: compact ? 8 : 10),
          Expanded(
            child: Text(
              l10n.connectDeviceTitle,
              style:
                  (compact
                          ? theme.textTheme.titleMedium
                          : theme.textTheme.titleLarge)
                      ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: l10n.close,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSwitcher(
    AppLocalizations l10n, {
    required bool compact,
    bool desktopPanel = false,
  }) {
    final scrollTabs =
        MediaQuery.textScalerOf(context).scale(14) > 18 &&
        (_canScan || compact || desktopPanel);
    return Padding(
      padding: desktopPanel
          ? EdgeInsets.zero
          : compact
          ? const EdgeInsets.fromLTRB(16, 0, 16, 0)
          : const EdgeInsets.fromLTRB(24, 10, 24, 0),
      child: WhisperTabBar(
        controller: _tabController,
        scrollable: scrollTabs,
        tabs: [
          Tab(
            child: Text(
              desktopPanel ? l10n.connectionDetailsTab : l10n.connectionQrTab,
              maxLines: 1,
            ),
          ),
          if (_canScan) Tab(child: Text(l10n.connectionScanTab, maxLines: 1)),
          Tab(child: Text(l10n.connectionAddressTab, maxLines: 1)),
        ],
      ),
    );
  }

  Widget _buildDesktopPanels(AppLocalizations l10n) {
    final invite = widget.localInvite;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Row(
        children: [
          SizedBox(
            key: const ValueKey('persistent-pairing-qr'),
            width: 232,
            child: RepaintBoundary(
              child: invite == null
                  ? Text(l10n.qrWifiUnavailable, textAlign: TextAlign.center)
                  : _buildQrCode(invite.encode(), 224, l10n, compact: false),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              children: [
                _buildModeSwitcher(l10n, compact: false, desktopPanel: true),
                const SizedBox(height: 8),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(8, 28, 8, 8),
                        child: invite == null
                            ? Text(l10n.qrWifiUnavailable)
                            : _buildInviteDetails(
                                inviteText: invite.encode(),
                                fingerprint: invite.publicKeyHash,
                                l10n: l10n,
                                compact: false,
                              ),
                      ),
                      ManualConnectionForm(
                        key: _manualFormKey,
                        localHost: widget.localInvite?.host,
                        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                        onConnect: (endpoint) => Navigator.of(
                          context,
                        ).pop(PairingQrResult.manual(endpoint)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMyCode(AppLocalizations l10n, {required bool compact}) {
    final invite = widget.localInvite;
    if (invite == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.qrWifiUnavailable, textAlign: TextAlign.center),
        ),
      );
    }
    final inviteText = invite.encode();
    final fingerprint = invite.publicKeyHash;
    return LayoutBuilder(
      builder: (context, constraints) {
        final useWideLayout = !compact && constraints.maxWidth >= 560;
        final qrSize = compact
            ? (constraints.maxWidth - 96)
                  .clamp(160.0, _canScan ? 200.0 : 240.0)
                  .toDouble()
            : useWideLayout
            ? 224.0
            : (constraints.maxWidth - 88).clamp(144.0, 224.0).toDouble();
        final qrCode = _buildQrCode(inviteText, qrSize, l10n, compact: compact);
        final details = _buildInviteDetails(
          inviteText: inviteText,
          fingerprint: fingerprint,
          l10n: l10n,
          compact: compact,
        );
        return Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              compact
                  ? 16
                  : useWideLayout
                  ? 24
                  : 20,
              compact
                  ? 12
                  : useWideLayout
                  ? 20
                  : 18,
              compact
                  ? 16
                  : useWideLayout
                  ? 24
                  : 20,
              compact ? 16 : 24,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 584),
                child: useWideLayout
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          qrCode,
                          const SizedBox(width: 28),
                          Expanded(child: details),
                        ],
                      )
                    : Column(
                        children: <Widget>[
                          qrCode,
                          SizedBox(height: compact ? 12 : 22),
                          details,
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildQrCode(
    String inviteText,
    double size,
    AppLocalizations l10n, {
    required bool compact,
  }) {
    final palette = context.whisperPalette;
    if (_qrImageCache?.data != inviteText || _qrImageCache?.size != size) {
      // QrImageView re-encodes and rebuilds its matrix on every build, even
      // offstage. Keep its widget and constraints stable during keyboard insets.
      _qrImageCache = (
        data: inviteText,
        size: size,
        image: RepaintBoundary(
          child: SizedBox.square(
            dimension: size,
            child: QrImageView(
              data: inviteText,
              version: QrVersions.auto,
              size: size,
              padding: const EdgeInsets.all(12),
              gapless: true,
              backgroundColor: Colors.white,
            ),
          ),
        ),
      );
    }
    return Semantics(
      label: l10n.qrMyCode,
      image: true,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: palette.borderSubtle),
          borderRadius: BorderRadius.circular(compact ? 10 : 18),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: _qrImageCache!.image,
        ),
      ),
    );
  }

  Widget _buildInviteDetails({
    required String inviteText,
    required String fingerprint,
    required AppLocalizations l10n,
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    final shortFingerprint =
        '${fingerprint.substring(0, 8)}...${fingerprint.substring(fingerprint.length - 8)}';
    if (compact) {
      return Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.wifi_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${widget.localInvite!.host}:${widget.localInvite!.port}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              Semantics(
                liveRegion: true,
                child: IconButton(
                  key: const ValueKey('copy-pairing-invite'),
                  tooltip: _copyTooltip(l10n),
                  visualDensity: VisualDensity.compact,
                  onPressed: _copying ? null : () => _copyInvite(inviteText),
                  icon: _buildCopyIcon(compact: true),
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Icon(
                Icons.verified_user_rounded,
                size: 18,
                color: palette.trusted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.qrFingerprint(shortFingerprint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.textMuted,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildDetailRow(
          icon: Icons.wifi_rounded,
          iconColor: theme.colorScheme.primary,
          child: Text(
            '${widget.localInvite!.host}:${widget.localInvite!.port}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Divider(height: 1, color: palette.borderSubtle),
        ),
        _buildDetailRow(
          icon: Icons.verified_user_rounded,
          iconColor: palette.trusted,
          child: Text(
            l10n.qrFingerprint(shortFingerprint),
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.textMuted,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 22),
        Semantics(
          liveRegion: true,
          value: _copied || _copyFailed ? _copyTooltip(l10n) : null,
          child: Tooltip(
            message: _copyTooltip(l10n),
            child: FilledButton.icon(
              key: const ValueKey('copy-pairing-invite'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                visualDensity: VisualDensity.standard,
              ),
              onPressed: _copying ? null : () => _copyInvite(inviteText),
              icon: _buildCopyIcon(compact: false),
              label: Text(l10n.qrCopyLink),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailRow({
    required IconData icon,
    required Color iconColor,
    required Widget child,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(width: 10),
        Expanded(child: child),
      ],
    );
  }

  String _copyTooltip(AppLocalizations l10n) => _copied
      ? l10n.qrLinkCopied
      : _copyFailed
      ? l10n.qrCopyFailed
      : l10n.qrCopyLink;

  Widget _buildCopyIcon({required bool compact}) => WhisperAnimatedSwitcher(
    value: (_copied, _copyFailed),
    scale: true,
    child: Icon(
      _copied
          ? Icons.check_rounded
          : _copyFailed
          ? Icons.error_outline_rounded
          : Icons.copy_rounded,
      size: compact ? 19 : 20,
      color: compact
          ? _copied
                ? context.whisperPalette.trusted
                : _copyFailed
                ? Theme.of(context).colorScheme.error
                : null
          : null,
    ),
  );

  Future<void> _copyInvite(String inviteText) async {
    if (_copying) return;
    _copyResetTimer?.cancel();
    setState(() => _copying = true);
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: inviteText));
      copied = true;
    } on PlatformException {
      // Report failure on the button too; do not show feedback behind the dialog.
    }
    if (!mounted) return;
    setState(() {
      _copying = false;
      _copied = copied;
      _copyFailed = !copied;
    });
    _copyResetTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _copied = false;
        _copyFailed = false;
      });
    });
  }

  Widget _buildScanner(AppLocalizations l10n, {required bool compact}) {
    final palette = context.whisperPalette;
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 16 : 24,
              compact ? 12 : 16,
              compact ? 16 : 24,
              0,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(compact ? 10 : 18),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scanFrameSize =
                      (constraints.biggest.shortestSide * 0.62)
                          .clamp(compact ? 136.0 : 176.0, 252.0)
                          .toDouble();
                  return Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if (!_scannerActive)
                        const ColoredBox(color: Colors.black),
                      if (_scannerActive)
                        QRView(
                          key: _scannerKey,
                          formatsAllowed: const <BarcodeFormat>[
                            BarcodeFormat.qrcode,
                          ],
                          onQRViewCreated: _onScannerCreated,
                          onPermissionSet: (_, granted) {
                            if (!granted && mounted) {
                              setState(() {
                                _scanError = l10n.qrCameraUnavailable;
                              });
                            }
                          },
                        ),
                      Center(
                        child: IgnorePointer(
                          child: Container(
                            width: scanFrameSize,
                            height: scanFrameSize,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Colors.white,
                                width: 2.5,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: Row(
                          children: <Widget>[
                            IconButton.filled(
                              tooltip: l10n.qrToggleTorch,
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () =>
                                  _scannerController?.toggleFlash(),
                              icon: const Icon(Icons.flashlight_on_outlined),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              tooltip: l10n.qrSwitchCamera,
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () => _scannerController?.flipCamera(),
                              icon: const Icon(Icons.cameraswitch_outlined),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 20,
            compact ? 10 : 14,
            compact ? 16 : 20,
            compact ? 12 : 20,
          ),
          child: Column(
            children: <Widget>[
              Text(
                l10n.qrScanHint,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: palette.textMuted),
              ),
              if (_scanError != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _scanError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _onScannerCreated(QRViewController controller) {
    if (!_scannerActive) return;
    _scannerController = controller;
    unawaited(_scanSubscription?.cancel());
    _scanSubscription = controller.scannedDataStream.listen(_onDetect);
  }

  void _onDetect(Barcode barcode) {
    if (!_scannerActive || _handlingScan) {
      return;
    }
    final value = barcode.code;
    if (value == null) {
      return;
    }
    _handlingScan = true;
    unawaited(_acceptScannedValue(value));
  }

  Future<void> _acceptScannedValue(String value) async {
    final l10n = AppLocalizations.of(context)!;
    final scanner = _scannerController;
    try {
      final invite = PairingInvite.parse(value);
      if (invite.peerId == (widget.localPeerId ?? widget.localInvite?.peerId)) {
        if (mounted) {
          setState(() {
            _scanError = l10n.qrCannotPairSelf;
            _handlingScan = false;
          });
        }
        return;
      }
      try {
        await scanner?.pauseCamera();
      } on CameraException {
        // Disposing the dialog also releases the camera after a valid scan.
      }
      if (mounted && _scannerActive && identical(scanner, _scannerController)) {
        Navigator.of(context).pop(PairingQrResult.qr(invite));
      }
    } on PairingInviteFormatException {
      if (mounted) {
        setState(() {
          _scanError = l10n.qrInvalidCode;
          _handlingScan = false;
        });
      }
    }
  }
}

/// Keep Android's early final inset from interrupting the keyboard animation.
class _KeyboardInsetAnimation extends StatefulWidget {
  const _KeyboardInsetAnimation({required this.builder});

  final Widget Function(Duration duration) builder;

  @override
  State<_KeyboardInsetAnimation> createState() =>
      _KeyboardInsetAnimationState();
}

class _KeyboardInsetAnimationState extends State<_KeyboardInsetAnimation> {
  bool _initialized = false;
  double _bottomInset = 0;
  double? _pendingOpeningInset;
  Timer? _openingInsetTimer;
  Duration _duration = Duration.zero;

  void _cancelPendingOpening() {
    _openingInsetTimer?.cancel();
    _openingInsetTimer = null;
    _pendingOpeningInset = null;
  }

  @override
  void dispose() {
    _cancelPendingOpening();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final duration = whisperMotionDuration(context);
    if (!_initialized || duration == Duration.zero) {
      _initialized = true;
      _cancelPendingOpening();
      _bottomInset = inset;
      _duration = Duration.zero;
      return;
    }
    if (_bottomInset == 0 && inset > 80) {
      // Restarting an IME can report its full height briefly, then return to
      // zero and animate normally. Wait for that progress before moving; if
      // only a final height arrives, interpolate it after this short grace.
      _pendingOpeningInset = inset;
      _openingInsetTimer ??= Timer(const Duration(milliseconds: 100), () {
        final pending = _pendingOpeningInset;
        _cancelPendingOpening();
        if (!mounted || pending == null) return;
        setState(() {
          _bottomInset = pending;
          _duration = duration;
        });
      });
      return;
    }
    _cancelPendingOpening();
    if (inset != _bottomInset) {
      _duration = (inset - _bottomInset).abs() > 80 ? duration : Duration.zero;
      _bottomInset = inset;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return widget.builder(whisperMotionDuration(context));
    }
    final mediaQuery = MediaQuery.of(context);
    return MediaQuery(
      data: mediaQuery.copyWith(
        viewInsets: mediaQuery.viewInsets.copyWith(bottom: _bottomInset),
      ),
      child: widget.builder(_duration),
    );
  }
}
