import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/pairing_invite.dart';

class PairingQrScreen extends StatefulWidget {
  const PairingQrScreen({
    super.key,
    required this.localInvite,
    this.startWithScanner = true,
  });

  final PairingInvite localInvite;
  final bool startWithScanner;

  @override
  State<PairingQrScreen> createState() => _PairingQrScreenState();
}

class _PairingQrScreenState extends State<PairingQrScreen>
    with SingleTickerProviderStateMixin {
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
    _tabController?.dispose();
    if (_canScan) {
      unawaited(_scannerController.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.qrPairingTitle),
        bottom: _canScan
            ? TabBar(
                controller: _tabController,
                tabs: <Widget>[
                  Tab(icon: const Icon(Icons.qr_code_2), text: l10n.qrMyCode),
                  Tab(
                    icon: const Icon(Icons.qr_code_scanner),
                    text: l10n.qrScanCode,
                  ),
                ],
              )
            : null,
      ),
      body: _canScan
          ? TabBarView(
              controller: _tabController,
              children: <Widget>[
                _buildMyCode(l10n),
                _buildScanner(l10n),
              ],
            )
          : _buildMyCode(l10n),
    );
  }

  Widget _buildMyCode(AppLocalizations l10n) {
    final inviteText = widget.localInvite.encode();
    final fingerprint = widget.localInvite.publicKeyHash;
    final qrSize =
        (MediaQuery.sizeOf(context).width - 80).clamp(140.0, 264.0).toDouble();
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              children: <Widget>[
                Text(
                  l10n.qrShowCodeHint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                Semantics(
                  label: l10n.qrMyCode,
                  image: true,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.black12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: QrImageView(
                        data: inviteText,
                        version: QrVersions.auto,
                        size: qrSize,
                        gapless: true,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  '${widget.localInvite.host}:${widget.localInvite.port}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.qrFingerprint(
                    '${fingerprint.substring(0, 8)}...${fingerprint.substring(fingerprint.length - 8)}',
                  ),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_isLoopback(widget.localInvite.host)) ...<Widget>[
                  const SizedBox(height: 14),
                  Text(
                    l10n.qrWifiUnavailable,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: inviteText));
                    if (!mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.qrLinkCopied)),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(l10n.qrCopyLink),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScanner(AppLocalizations l10n) {
    return SafeArea(
      child: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
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
                      width: 252,
                      height: 252,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white, width: 3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: Row(
                    children: <Widget>[
                      IconButton.filledTonal(
                        tooltip: l10n.qrToggleTorch,
                        onPressed: _scannerController.toggleTorch,
                        icon: const Icon(Icons.flashlight_on_outlined),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        tooltip: l10n.qrSwitchCamera,
                        onPressed: _scannerController.switchCamera,
                        icon: const Icon(Icons.cameraswitch_outlined),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              children: <Widget>[
                Text(l10n.qrScanHint, textAlign: TextAlign.center),
                if (_scanError != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _scanError!,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
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
        // Disposing the route also releases the camera after a valid scan.
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
