import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/pairing_invite.dart';
import 'package:whisper/theme/app_theme.dart';

Future<PairingInvite?> showPairingQrDialog(
  BuildContext context, {
  required PairingInvite localInvite,
  bool startWithScanner = true,
  PairingQrDialogController? controller,
}) {
  return showDialog<PairingInvite>(
    context: context,
    builder: (context) => PairingQrDialog(
      localInvite: localInvite,
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
    this.controller,
  });

  final PairingInvite localInvite;
  final bool startWithScanner;
  final PairingQrDialogController? controller;

  @override
  State<PairingQrDialog> createState() => _PairingQrDialogState();
}

class _PairingQrDialogState extends State<PairingQrDialog>
    with SingleTickerProviderStateMixin {
  late final VoidCallback _dismissCallback = _dismissDialog;
  late final bool _canScan = Platform.isAndroid || Platform.isIOS;
  late final MobileScannerController _scannerController =
      MobileScannerController(
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.normal,
      );
  TabController? _tabController;
  bool _handlingScan = false;
  String? _scanError;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(_dismissCallback);
    if (_canScan) {
      _tabController = TabController(
        length: 2,
        vsync: this,
        initialIndex: widget.startWithScanner ? 1 : 0,
      );
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(_dismissCallback);
    _tabController?.dispose();
    if (_canScan) {
      unawaited(_scannerController.dispose());
    }
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
      compact ? 440.0 : 640.0,
    );
    final availableHeight = windowSize.height - (compact ? 24 : 32);
    final dialogHeight = compact
        ? (windowSize.height * 0.72)
              .clamp(360.0, 560.0)
              .clamp(0.0, availableHeight)
        : _canScan
        ? availableHeight.clamp(420.0, 720.0)
        : availableHeight.clamp(360.0, 420.0);
    return SafeArea(
      minimum: EdgeInsets.all(compact ? 12 : 16),
      child: Dialog(
        insetPadding: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        backgroundColor: context.whisperPalette.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(compact ? 16 : 24),
        ),
        child: SizedBox(
          key: const ValueKey<String>('pairing-qr-dialog-content'),
          width: dialogWidth,
          height: dialogHeight,
          child: Column(
            children: <Widget>[
              _buildHeader(l10n, compact: compact),
              if (_canScan) _buildModeSwitcher(l10n, compact: compact),
              Expanded(
                child: _canScan
                    ? TabBarView(
                        controller: _tabController,
                        children: <Widget>[
                          _buildMyCode(l10n, compact: compact),
                          _buildScanner(l10n, compact: compact),
                        ],
                      )
                    : _buildMyCode(l10n, compact: compact),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n, {required bool compact}) {
    final theme = Theme.of(context);
    return Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(16, 8, 6, 4)
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
              l10n.qrPairingTitle,
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

  Widget _buildModeSwitcher(AppLocalizations l10n, {required bool compact}) {
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    return Container(
      height: compact ? 40 : 48,
      margin: compact
          ? const EdgeInsets.fromLTRB(16, 4, 16, 0)
          : const EdgeInsets.fromLTRB(24, 10, 24, 0),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.surfaceMuted,
        borderRadius: BorderRadius.circular(compact ? 10 : 14),
      ),
      child: TabBar(
        controller: _tabController,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(
          color: palette.surfaceElevated,
          borderRadius: BorderRadius.circular(10),
        ),
        labelColor: theme.colorScheme.onSurface,
        unselectedLabelColor: palette.textMuted,
        labelStyle: theme.textTheme.labelLarge,
        tabs: compact
            ? <Widget>[Tab(text: l10n.qrMyCode), Tab(text: l10n.qrScanCode)]
            : <Widget>[
                Tab(
                  icon: const Icon(Icons.qr_code_2_rounded, size: 19),
                  text: l10n.qrMyCode,
                  iconMargin: const EdgeInsets.only(bottom: 2),
                ),
                Tab(
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 19),
                  text: l10n.qrScanCode,
                  iconMargin: const EdgeInsets.only(bottom: 2),
                ),
              ],
      ),
    );
  }

  Widget _buildMyCode(AppLocalizations l10n, {required bool compact}) {
    final inviteText = widget.localInvite.encode();
    final fingerprint = widget.localInvite.publicKeyHash;
    return LayoutBuilder(
      builder: (context, constraints) {
        final useWideLayout = !compact && constraints.maxWidth >= 560;
        final qrSize = compact
            ? (constraints.maxHeight * 0.4).clamp(132.0, 176.0).toDouble()
            : useWideLayout
            ? 224.0
            : (constraints.maxWidth - 88).clamp(144.0, 224.0).toDouble();
        final qrCode = _buildQrCode(inviteText, qrSize, l10n, compact: compact);
        final details = _buildInviteDetails(
          inviteText: inviteText,
          fingerprint: fingerprint,
          l10n: l10n,
          showHint: useWideLayout,
          compact: compact,
        );
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            compact
                ? 16
                : useWideLayout
                ? 24
                : 20,
            compact
                ? 10
                : useWideLayout
                ? 20
                : 18,
            compact
                ? 16
                : useWideLayout
                ? 24
                : 20,
            compact ? 12 : 24,
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
                        Text(
                          l10n.qrShowCodeHint,
                          textAlign: TextAlign.center,
                          style: compact
                              ? Theme.of(context).textTheme.bodyMedium
                              : Theme.of(context).textTheme.titleSmall,
                        ),
                        SizedBox(height: compact ? 10 : 18),
                        qrCode,
                        SizedBox(height: compact ? 12 : 22),
                        details,
                      ],
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
    return Semantics(
      label: l10n.qrMyCode,
      image: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: palette.borderSubtle),
          borderRadius: BorderRadius.circular(compact ? 10 : 18),
        ),
        child: Padding(
          padding: EdgeInsets.all(compact ? 10 : 16),
          child: QrImageView(
            data: inviteText,
            version: QrVersions.auto,
            size: size,
            gapless: true,
            backgroundColor: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildInviteDetails({
    required String inviteText,
    required String fingerprint,
    required AppLocalizations l10n,
    required bool showHint,
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
                  '${widget.localInvite.host}:${widget.localInvite.port}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.qrCopyLink,
                visualDensity: VisualDensity.compact,
                onPressed: () => _copyInvite(inviteText, l10n),
                icon: const Icon(Icons.copy_rounded, size: 19),
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
        if (showHint) ...<Widget>[
          Text(
            l10n.qrShowCodeHint,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.start,
          ),
          const SizedBox(height: 18),
        ],
        _buildDetailRow(
          icon: Icons.wifi_rounded,
          iconColor: theme.colorScheme.primary,
          child: Text(
            '${widget.localInvite.host}:${widget.localInvite.port}',
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
        if (_isLoopback(widget.localInvite.host)) ...<Widget>[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.wifi_off_rounded,
                  size: 19,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    l10n.qrWifiUnavailable,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: () => _copyInvite(inviteText, l10n),
          icon: const Icon(Icons.copy_rounded),
          label: Text(l10n.qrCopyLink),
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

  Future<void> _copyInvite(String inviteText, AppLocalizations l10n) async {
    await Clipboard.setData(ClipboardData(text: inviteText));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.qrLinkCopied)));
  }

  Widget _buildScanner(AppLocalizations l10n, {required bool compact}) {
    final palette = context.whisperPalette;
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 16,
              compact ? 10 : 16,
              compact ? 12 : 16,
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
                      MobileScanner(
                        controller: _scannerController,
                        onDetect: _onDetect,
                        errorBuilder: (context, error) => ColoredBox(
                          color: Colors.black,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                l10n.qrCameraUnavailable,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
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
                              onPressed: _scannerController.toggleTorch,
                              icon: const Icon(Icons.flashlight_on_outlined),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              tooltip: l10n.qrSwitchCamera,
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: _scannerController.switchCamera,
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

  void _onDetect(BarcodeCapture capture) {
    if (_handlingScan) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) {
        continue;
      }
      _handlingScan = true;
      unawaited(_acceptScannedValue(value));
      return;
    }
  }

  Future<void> _acceptScannedValue(String value) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final invite = PairingInvite.parse(value);
      if (invite.peerId == widget.localInvite.peerId) {
        if (mounted) {
          setState(() {
            _scanError = l10n.qrCannotPairSelf;
            _handlingScan = false;
          });
        }
        return;
      }
      try {
        await _scannerController.stop();
      } on MobileScannerException {
        // Disposing the dialog also releases the camera after a valid scan.
      }
      if (mounted) {
        Navigator.of(context).pop(invite);
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

  bool _isLoopback(String host) {
    final address = InternetAddress.tryParse(host.split('%').first);
    return address?.isLoopback ?? false;
  }
}
