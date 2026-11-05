import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart' as permissions;
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_touch.dart';
import 'package:whisper/page/pairing_qr.dart';
import 'package:whisper/state/pairing_invite.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// What the page needs of a running camera.
class PhoneScannerHandle {
  const PhoneScannerHandle({
    required this.toggleTorch,
    required this.flip,
    required this.pause,
  });

  final Future<void> Function() toggleTorch, flip, pause;
}

/// The camera in the viewfinder. Tests put something else there: a camera is a
/// platform view with nothing behind it.
typedef PhoneScannerBuilder =
    Widget Function(
      BuildContext context, {
      required ValueChanged<PhoneScannerHandle> onReady,
      required ValueChanged<String> onCode,
      required ValueChanged<bool> onPermission,
    });

/// surfaces.md「手机 · 连接设备」, the prototype's `placeConnect`: three tabs,
/// starting on this phone's code. The camera only runs on the scan tab.
class PhoneConnectPage extends StatefulWidget {
  const PhoneConnectPage({
    super.key,
    required this.localInvite,
    required this.localName,
    this.localPeerId,
    this.fingerprint,
    this.startWithAddress = false,
    this.controller,
    this.reloadInvite,
    this.scanner = phoneQrScanner,
    this.openSettings = _openAppSettings,
  });

  final PairingInvite? localInvite;
  final String localName;
  final String? localPeerId;

  /// This device's identity, known without a network.
  final String? fingerprint;
  final bool startWithAddress;
  final PairingQrDialogController? controller;

  /// Asks again for this device's address, after it had none.
  final Future<PairingInvite?> Function()? reloadInvite;
  final PhoneScannerBuilder scanner;
  final Future<void> Function() openSettings;

  @override
  State<PhoneConnectPage> createState() => _PhoneConnectPageState();
}

Future<void> _openAppSettings() => permissions.openAppSettings();

class _PhoneConnectPageState extends State<PhoneConnectPage>
    with WidgetsBindingObserver {
  static const _qrTab = 0, _scanTab = 1, _addressTab = 2;

  late final VoidCallback _dismissCallback = _dismiss;
  late int _tab = widget.startWithAddress ? _addressTab : _qrTab;
  late PairingInvite? _invite = widget.localInvite;
  bool _reloading = false;

  // Scan.
  PhoneScannerHandle? _camera;
  int _cameraGeneration = 0;
  bool _handlingScan = false;
  bool _cameraDenied = false;
  bool _torch = false;
  String? _scanError;

  // Copy.
  bool _copying = false, _copied = false, _copyFailed = false;
  Timer? _copyReset;

  // Address.
  late final _address = TextEditingController(text: _addressPrefill());
  final _port = TextEditingController(text: '10002');
  final _addressFocus = FocusNode(), _portFocus = FocusNode();
  String? _addressError, _portError;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.attach(_dismissCallback);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?.detach(_dismissCallback);
    _copyReset?.cancel();
    _address.dispose();
    _port.dispose();
    _addressFocus.dispose();
    _portFocus.dispose();
    super.dispose();
  }

  /// Back from system settings: the camera may be allowed now.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _cameraDenied && mounted) {
      setState(() {
        _cameraDenied = false;
        _cameraGeneration++;
      });
    }
  }

  void _dismiss() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
  }

  /// The local network's prefix, ready for the last number.
  String _addressPrefill() {
    final host = widget.localInvite?.host;
    if (host == null) return '';
    final octets = host.split('.');
    if (octets.length != 4) return '';
    return '${octets.take(3).join('.')}.';
  }

  void _select(int tab) {
    if (tab == _tab) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _tab = tab;
      if (tab != _scanTab) {
        // Removing the camera's view releases it; a queued scan is ignored.
        _camera = null;
        _handlingScan = false;
        _torch = false;
        _scanError = null;
      }
    });
  }

  Future<void> _reloadInvite() async {
    final reload = widget.reloadInvite;
    if (reload == null || _reloading) return;
    setState(() => _reloading = true);
    PairingInvite? invite;
    try {
      invite = await reload();
    } on Object {
      invite = null;
    }
    if (!mounted) return;
    setState(() {
      _reloading = false;
      _invite = invite;
    });
  }

  Future<void> _copyInvite(String text) async {
    if (_copying) return;
    _copyReset?.cancel();
    setState(() => _copying = true);
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      copied = true;
    } on PlatformException {
      // Said on the button.
    }
    if (!mounted) return;
    setState(() {
      _copying = false;
      _copied = copied;
      _copyFailed = !copied;
    });
    _copyReset = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _copied = false;
        _copyFailed = false;
      });
    });
  }

  void _onCameraReady(PhoneScannerHandle handle) {
    if (_tab == _scanTab) _camera = handle;
  }

  void _onPermission(bool granted) {
    if (!mounted || granted == !_cameraDenied) return;
    setState(() => _cameraDenied = !granted);
  }

  void _onCode(String value) {
    if (_tab != _scanTab || _handlingScan) return;
    _handlingScan = true;
    unawaited(_accept(value));
  }

  Future<void> _accept(String value) async {
    final l10n = AppLocalizations.of(context)!;
    final camera = _camera;
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
        await camera?.pause();
      } on CameraException {
        // Leaving the page releases the camera anyway.
      }
      if (mounted && _tab == _scanTab && identical(camera, _camera)) {
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

  void _connect() {
    if (_submitted) return;
    final l10n = AppLocalizations.of(context)!;
    final host = _address.text.trim();
    final port = int.tryParse(_port.text.trim());
    String? addressError;
    try {
      PeerEndpoint(host: host, port: 10002);
    } on ArgumentError {
      addressError = l10n.manualConnectAddressInvalid;
    }
    final portError = port == null || port < 1 || port > 65535
        ? l10n.manualConnectPortInvalid
        : null;
    setState(() {
      _addressError = addressError;
      _portError = portError;
    });
    if (addressError != null || portError != null) return;
    _submitted = true;
    FocusScope.of(context).unfocus();
    Navigator.of(
      context,
    ).pop(PairingQrResult.manual(PeerEndpoint(host: host, port: port!)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const type = WhisperType(touch: true);
    return PhonePage(
      title: l10n.connectDeviceTitle,
      back: shellPageShowsBack(context),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SizedBox(
                  height: 48,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // The tabs keep their height: a larger text size only
                      // reaches what a pill of 36 can hold.
                      Center(
                        child: MediaQuery.withClampedTextScaling(
                          maxScaleFactor: 1.25,
                          child: LiquidSegmented<int>(
                            key: const ValueKey('connect-tabs'),
                            expand: true,
                            height: 36,
                            fontSize: type.note,
                            segmentPadding: 4,
                            selected: _tab,
                            onChanged: _select,
                            segments: {
                              _qrTab: l10n.connectionQrTab,
                              _scanTab: l10n.connectionScanTab,
                              _addressTab: l10n.connectionAddressTab,
                            },
                          ),
                        ),
                      ),
                      // 36 to look at, 48 to hit: above and below the pill too.
                      for (final (top, height) in const [
                        (0.0, 6.0),
                        (42.0, 6.0),
                      ])
                        Positioned(
                          left: 0,
                          right: 0,
                          top: top,
                          height: height,
                          child: ExcludeSemantics(
                            child: Row(
                              children: [
                                for (final tab in const [
                                  _qrTab,
                                  _scanTab,
                                  _addressTab,
                                ])
                                  Expanded(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => _select(tab),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: WhisperTabView(
                  index: _tab,
                  itemCount: 3,
                  itemBuilder: (context, index) => switch (index) {
                    _qrTab => _buildQr(l10n),
                    _scanTab => _buildScan(l10n),
                    _ => _buildAddress(l10n),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  EdgeInsets get _pagePadding =>
      EdgeInsets.fromLTRB(16, 0, 16, 28 + MediaQuery.paddingOf(context).bottom);

  // ------------------------------------------------------------------ code

  ({String data, Widget image})? _qrCache;

  Widget _qrImage(String data) {
    final cached = _qrCache;
    if (cached?.data == data) return cached!.image;
    final image = RepaintBoundary(
      child: QrImageView(
        key: const ValueKey('connect-qr'),
        data: data,
        size: 196,
        padding: const EdgeInsets.all(10),
        gapless: true,
        backgroundColor: Colors.transparent,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: WhisperViewfinder.qrInk,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: WhisperViewfinder.qrInk,
        ),
      ),
    );
    _qrCache = (data: data, image: image);
    return image;
  }

  Widget _buildQr(AppLocalizations l10n) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final invite = _invite;
    final brightness = Theme.of(context).brightness;
    final text = invite?.encode();
    final fingerprint = invite?.publicKeyHash ?? widget.fingerprint;
    final copyLabel = _copied
        ? l10n.phoneConnectCopied
        : _copyFailed
        ? l10n.phoneConnectCopyFailed
        : l10n.phoneConnectCopyLink;
    return SingleChildScrollView(
      padding: _pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: c.group,
              borderRadius: BorderRadius.circular(WhisperRadius.l),
              boxShadow: WhisperShadow.e1(brightness),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 22, 16, 18),
              // Too short for the code over its words: side by side.
              child: _CodeAndWords(
                beside: WhisperLayout.of(context).shortHeight,
                code: [
                  if (text != null)
                    Semantics(
                      label: l10n.qrMyCode,
                      image: true,
                      child: Container(
                        width: 196,
                        height: 196,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(WhisperRadius.m),
                        ),
                        child: _qrImage(text),
                      ),
                    )
                  else
                    // Where the code would be, so that nothing else moves.
                    ConstrainedBox(
                      key: const ValueKey('connect-no-lan'),
                      constraints: const BoxConstraints(minHeight: 196),
                      child: Center(
                        heightFactor: 1,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              l10n.qrWifiUnavailable,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: type.note,
                                height: 1.5,
                                color: c.ink2,
                              ),
                            ),
                            const SizedBox(height: 12),
                            PhoneButton(
                              key: const ValueKey('connect-retry-lan'),
                              label: l10n.windowStreamRetry,
                              onTap: _reloading
                                  ? null
                                  : () => unawaited(_reloadInvite()),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                words: [
                  Text(
                    widget.localName,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: type.head,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Not without a code, with its room kept for when one comes.
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          ShellGroup(
            children: [
              PhoneInfoRow(
                label: l10n.shellSelfAddress,
                value: invite == null ? '—' : '${invite.host}:${invite.port}',
              ),
              PhoneInfoRow(
                label: l10n.shellSelfFingerprint,
                value: _shortFingerprint(fingerprint),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Center(
            child: Semantics(
              liveRegion: true,
              value: _copied || _copyFailed ? copyLabel : null,
              child: PhoneButton(
                key: const ValueKey('copy-pairing-invite'),
                large: true,
                glyph: _copied
                    ? WhisperGlyph.check
                    : _copyFailed
                    ? WhisperGlyph.warn
                    : WhisperGlyph.copy,
                label: copyLabel,
                onTap: text == null || _copying
                    ? null
                    : () => unawaited(_copyInvite(text)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Three groups of four, as the prototype reads it out.
  String _shortFingerprint(String? value) {
    if (value == null || value.length < 12) return value ?? '—';
    return '${value.substring(0, 4)} '
        '${value.substring(4, 8)} '
        '${value.substring(8, 12)}';
  }

  // ------------------------------------------------------------------ scan

  Widget _buildScan(AppLocalizations l10n) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final error = _scanError;
    return SingleChildScrollView(
      padding: _pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: AspectRatio(
                aspectRatio: 1,
                child: _Viewfinder(
                  denied: _cameraDenied
                      ? _CameraDenied(
                          message: l10n.qrCameraUnavailable,
                          action: l10n.phoneConnectOpenSettings,
                          onAction: () => unawaited(widget.openSettings()),
                        )
                      : null,
                  camera: _tab == _scanTab && !_cameraDenied
                      ? KeyedSubtree(
                          key: ValueKey('camera-$_cameraGeneration'),
                          child: Builder(
                            builder: (context) => widget.scanner(
                              context,
                              onReady: _onCameraReady,
                              onCode: _onCode,
                              onPermission: _onPermission,
                            ),
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _RoundToolButton(
                key: const ValueKey('connect-torch'),
                glyph: WhisperGlyph.bolt,
                label: l10n.qrToggleTorch,
                toggle: true,
                pressed: _torch,
                onTap: () {
                  final camera = _camera;
                  if (camera == null) return;
                  setState(() => _torch = !_torch);
                  unawaited(camera.toggleTorch());
                },
              ),
              const SizedBox(width: 16),
              _RoundToolButton(
                key: const ValueKey('connect-flip'),
                glyph: WhisperGlyph.flip,
                label: l10n.qrSwitchCamera,
                onTap: () => unawaited(_camera?.flip()),
              ),
            ],
          ),
          // Under the tools, with nothing below it: the message moves nothing.
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  key: const ValueKey('connect-scan-error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: type.note,
                    height: 1.5,
                    color: c.warn,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- address

  Widget _buildAddress(AppLocalizations l10n) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final error = _addressError ?? _portError;
    return SingleChildScrollView(
      padding: _pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShellGroup(
            children: [
              _AddressRow(
                label: l10n.shellSelfAddress,
                fieldKey: const ValueKey('connection-address'),
                controller: _address,
                focusNode: _addressFocus,
                wrong: _addressError != null,
                // The same keyboard for both, so that moving between them
                // does not reconfigure it; an address can have letters.
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                onChanged: (_) {
                  if (_addressError != null) {
                    setState(() => _addressError = null);
                  }
                },
                onSubmitted: (_) => _portFocus.requestFocus(),
              ),
              _AddressRow(
                label: l10n.phoneConnectPort,
                fieldKey: const ValueKey('connection-port'),
                controller: _port,
                focusNode: _portFocus,
                wrong: _portError != null,
                keyboardType: TextInputType.url,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (_portError != null) {
                    setState(() => _portError = null);
                  }
                },
                onSubmitted: (_) => _connect(),
              ),
            ],
          ),
          // Its line is always there: a mistake doesn't move the button.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: SizedBox(
              height: type.note * 1.35,
              child: Text(
                error ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: type.note,
                  height: 1.35,
                  color: c.bad,
                ),
              ),
            ),
          ),
          PhoneButton(
            key: const ValueKey('connect-by-address'),
            large: true,
            stretch: true,
            kind: PhoneButtonKind.primary,
            label: l10n.connect,
            onTap: _connect,
          ),
        ],
      ),
    );
  }
}

/// A label, and the value beside it with no box around it, as in a phone's own
/// network settings. The whole row is the target.
class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.label,
    required this.fieldKey,
    required this.controller,
    required this.focusNode,
    required this.wrong,
    required this.keyboardType,
    required this.textInputAction,
    required this.onChanged,
    required this.onSubmitted,
    this.inputFormatters,
  });

  final String label;
  final Key fieldKey;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool wrong;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String> onChanged, onSubmitted;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    const none = InputBorder.none;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: focusNode.requestFocus,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: type.body,
                  height: 1.3,
                  color: c.ink,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Semantics(
                  label: label,
                  child: TextField(
                    key: fieldKey,
                    controller: controller,
                    focusNode: focusNode,
                    textAlign: TextAlign.end,
                    keyboardType: keyboardType,
                    textInputAction: textInputAction,
                    inputFormatters: inputFormatters,
                    autocorrect: false,
                    enableSuggestions: false,
                    cursorColor: c.accent,
                    style: TextStyle(
                      fontSize: type.body,
                      height: 1.3,
                      color: wrong ? c.bad : c.ink2,
                    ),
                    decoration: const InputDecoration(
                      isCollapsed: true,
                      filled: false,
                      border: none,
                      enabledBorder: none,
                      focusedBorder: none,
                      disabledBorder: none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: onChanged,
                    onSubmitted: onSubmitted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.vf-b`: 48, round, outside the viewfinder.
class _CodeAndWords extends StatelessWidget {
  const _CodeAndWords({
    required this.beside,
    required this.code,
    required this.words,
  });

  final bool beside;
  final List<Widget> code, words;

  @override
  Widget build(BuildContext context) => beside
      ? Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Column(mainAxisSize: MainAxisSize.min, children: code),
            const SizedBox(width: 16),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: words,
              ),
            ),
          ],
        )
      : Column(children: [...code, const SizedBox(height: 14), ...words]);
}

class _RoundToolButton extends StatelessWidget {
  const _RoundToolButton({
    super.key,
    required this.glyph,
    required this.label,
    required this.onTap,
    this.pressed = false,
    this.toggle = false,
  });

  final WhisperGlyph glyph;
  final String label;
  final VoidCallback onTap;
  final bool pressed, toggle;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    return Semantics(
      toggled: toggle ? pressed : null,
      child: Pressable(
        onTap: onTap,
        scale: .92,
        radius: 24,
        label: label,
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: pressed ? c.accent : c.group,
            shape: BoxShape.circle,
            boxShadow: WhisperShadow.e1(Theme.of(context).brightness),
          ),
          child: WhisperIcon(
            glyph,
            size: 19,
            color: pressed ? c.onAccent : c.ink,
          ),
        ),
      ),
    );
  }
}

/// `.vf`: a dark square with a picture from the camera on it, four marks at 18%
/// and a line going up and down between them.
class _Viewfinder extends StatelessWidget {
  const _Viewfinder({this.camera, this.denied});

  final Widget? camera, denied;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final denied = this.denied;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WhisperRadius.l),
        boxShadow: WhisperShadow.e1(brightness),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WhisperRadius.l),
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-.4, -.6),
                    radius: 1.2,
                    stops: [0, .7],
                    colors: [WhisperViewfinder.glow, WhisperViewfinder.base],
                    transform: _FlatterGlow(),
                  ),
                ),
              ),
              ?camera,
              IgnorePointer(child: CustomPaint(painter: const _Marks())),
              if (denied == null) _ScanLine(side: box.maxWidth),
              if (denied != null) Center(child: denied),
            ],
          ),
        ),
      ),
    );
  }
}

/// `radial-gradient(120% 90% at 30% 20%, …)`: wider than it is tall.
class _FlatterGlow extends GradientTransform {
  const _FlatterGlow();

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final center = const Alignment(-.4, -.6).withinRect(bounds);
    return Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(1, .75, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }
}

class _CameraDenied extends StatelessWidget {
  const _CameraDenied({
    required this.message,
    required this.action,
    required this.onAction,
  });

  final String message, action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    const type = WhisperType(touch: true);
    return SingleChildScrollView(
      key: const ValueKey('connect-camera-denied'),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: type.note,
              height: 1.5,
              color: WhisperViewfinder.hint,
            ),
          ),
          const SizedBox(height: 14),
          PhoneButton(
            key: const ValueKey('connect-open-settings'),
            kind: PhoneButtonKind.primary,
            label: action,
            onTap: onAction,
          ),
        ],
      ),
    );
  }
}

/// `.ln`: 22% to 78%, there and back.
class _ScanLine extends StatefulWidget {
  const _ScanLine({required this.side});

  final double side;

  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(
    vsync: this,
    duration: WhisperLoops.scan,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _run.stop();
      _run.value = .5;
    } else if (!_run.isAnimating) {
      _run.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _run,
    builder: (context, child) {
      final t = Curves.easeInOut.transform(_run.value);
      return Positioned(
        left: widget.side * .2,
        right: widget.side * .2,
        top: widget.side * (.22 + .56 * t),
        height: 2,
        child: child!,
      );
    },
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: WhisperViewfinder.line,
          borderRadius: BorderRadius.circular(WhisperRadius.thumbBar),
        ),
      ),
    ),
  );
}

/// Four corners, 30 each, a stroke of 3 with an outer radius of 12.
class _Marks extends CustomPainter {
  const _Marks();

  @override
  void paint(Canvas canvas, Size size) {
    const box = 30.0, stroke = 3.0;
    final inset = size.width * .18;
    const radius = WhisperRadius.viewfinderMark - stroke / 2;
    final paint = Paint()
      ..color = WhisperViewfinder.mark
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final corner = Path()
      ..moveTo(stroke / 2, box)
      ..lineTo(stroke / 2, stroke / 2 + radius)
      ..arcToPoint(
        const Offset(stroke / 2 + radius, stroke / 2),
        radius: const Radius.circular(radius),
      )
      ..lineTo(box, stroke / 2);
    for (final (flipX, flipY) in const [
      (false, false),
      (true, false),
      (false, true),
      (true, true),
    ]) {
      canvas.save();
      canvas.translate(
        flipX ? size.width - inset : inset,
        flipY ? size.height - inset : inset,
      );
      canvas.scale(flipX ? -1 : 1, flipY ? -1 : 1);
      canvas.drawPath(corner, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Marks old) => false;
}

/// The real camera, which only reads QR codes.
Widget phoneQrScanner(
  BuildContext context, {
  required ValueChanged<PhoneScannerHandle> onReady,
  required ValueChanged<String> onCode,
  required ValueChanged<bool> onPermission,
}) => _QrCamera(onReady: onReady, onCode: onCode, onPermission: onPermission);

class _QrCamera extends StatefulWidget {
  const _QrCamera({
    required this.onReady,
    required this.onCode,
    required this.onPermission,
  });

  final ValueChanged<PhoneScannerHandle> onReady;
  final ValueChanged<String> onCode;
  final ValueChanged<bool> onPermission;

  @override
  State<_QrCamera> createState() => _QrCameraState();
}

class _QrCameraState extends State<_QrCamera> {
  final _key = GlobalKey(debugLabel: 'phone-connect-camera');
  StreamSubscription<Barcode>? _codes;

  @override
  void dispose() {
    unawaited(_codes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => QRView(
    key: _key,
    formatsAllowed: const [BarcodeFormat.qrcode],
    onPermissionSet: (_, granted) => widget.onPermission(granted),
    onQRViewCreated: (controller) {
      unawaited(_codes?.cancel());
      _codes = controller.scannedDataStream.listen((barcode) {
        final code = barcode.code;
        if (code != null) widget.onCode(code);
      });
      widget.onReady(
        PhoneScannerHandle(
          toggleTorch: () async => controller.toggleFlash(),
          flip: () async {
            await controller.flipCamera();
          },
          pause: controller.pauseCamera,
        ),
      );
    },
  );
}
