import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_requests.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/web_transfer/web_transfer_coordinator.dart';
import 'package:whisper/widget/context_menu_region.dart';

/// docs/design/surfaces.md「网页传输」: the side of the connect panel that lets
/// a browser in. While it is on screen the page takes new visitors; when one
/// is allowed the panel closes and its conversation opens.
class WebTransferFace extends StatefulWidget {
  const WebTransferFace({super.key, this.touch = false});

  final bool touch;

  @override
  State<WebTransferFace> createState() => _WebTransferFaceState();
}

class _WebTransferFaceState extends State<WebTransferFace> {
  final _web = WebTransferCoordinator.shared;
  final _links = ShareLinkStore.shared;
  late Set<String> _seen = _web.onlineUids;
  bool _copied = false;
  Timer? _copiedReset;

  @override
  void initState() {
    super.initState();
    _web.addListener(_changed);
    _links.addListener(_changed);
    unawaited(_web.open());
    unawaited(_links.refreshAddresses());
  }

  @override
  void dispose() {
    _web.removeListener(_changed);
    _links.removeListener(_changed);
    _copiedReset?.cancel();
    unawaited(_web.close());
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final online = _web.onlineUids;
    if (online.difference(_seen).isNotEmpty) {
      // Someone was let in: what comes next is the conversation.
      _seen = online;
      unawaited(Navigator.of(context).maybePop());
      return;
    }
    _seen = online;
    setState(() {});
  }

  void _copy(String url) {
    unawaited(Clipboard.setData(ClipboardData(text: url)));
    setState(() => _copied = true);
    _copiedReset?.cancel();
    _copiedReset = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _pickAddress(BuildContext anchor) {
    final box = anchor.findRenderObject() as RenderBox?;
    if (box == null) return;
    unawaited(
      showWhisperActionMenu(
        anchor,
        anchor: box.localToGlobal(Offset.zero) & box.size,
        items: [
          for (final address in _links.addresses)
            ContextMenuActionItem(
              label: address,
              icon: address == _links.address
                  ? Icons.check
                  : Icons.lan_outlined,
              onSelected: () => _links.preferAddress(address),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    final type = WhisperType(touch: widget.touch);
    final url = _web.urlFor();
    final state = _links.serverState;
    final side = widget.touch ? 196.0 : 148.0;
    final waiting = Text(
      _links.addresses.isEmpty && state.isRunning
          ? l10n.shellSelfNoLan
          : state.phase == ShareServerPhase.failed
          ? l10n.webTransferUnavailable
          : l10n.webTransferStarting,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: type.note, height: 1.5, color: c.ink2),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.webTransferTitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: type.title,
            height: 1.25,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(WhisperRadius.m),
              boxShadow: WhisperShadow.e1(Theme.of(context).brightness),
            ),
            child: url == null
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: Center(
                      child: DefaultTextStyle.merge(
                        style: const TextStyle(color: Colors.black54),
                        child: waiting,
                      ),
                    ),
                  )
                : Semantics(
                    label: l10n.webTransferTitle,
                    image: true,
                    child: QrImageView(
                      data: url,
                      padding: const EdgeInsets.all(10),
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
                  ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          l10n.webTransferHint,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: type.note, height: 1.5, color: c.ink2),
        ),
        const SizedBox(height: 6),
        if (url != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Pressable(
                  onTap: () => _copy(url),
                  radius: WhisperRadius.xs,
                  scale: 1,
                  label: l10n.webTransferCopyAddress,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: WhisperMono.family,
                              fontFamilyFallback: WhisperMono.fallback,
                              fontSize: type.head,
                              height: 1.3,
                              fontWeight: FontWeight.w500,
                              color: c.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        WhisperIcon(
                          _copied ? WhisperGlyph.check : WhisperGlyph.copy,
                          size: 14,
                          color: _copied ? c.ok : c.ink2,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_links.addresses.length > 1)
                Builder(
                  builder: (anchor) => ShellIconButton(
                    glyph: WhisperGlyph.updown,
                    iconSize: 14,
                    touch: widget.touch,
                    color: c.ink2,
                    label: l10n.shellSelfAddress,
                    onTap: () => _pickAddress(anchor),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.no_encryption_outlined,
                size: widget.touch ? 13 : 12,
                color: c.ink2,
              ),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                l10n.webTransferPlain,
                style: TextStyle(
                  fontSize: type.tiny,
                  height: 1.4,
                  color: c.ink2,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The phone's side: the face, and the way back to the code.
class WebTransferPhoneFace extends StatelessWidget {
  const WebTransferPhoneFace({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const WebTransferFace(touch: true),
      const SizedBox(height: 20),
      Center(
        child: PhoneButton(label: context.shellL10n.back, onTap: onBack),
      ),
    ],
  );
}

/// The quiet way into [WebTransferFace] under a pairing code: for when the
/// other device has no Whisper.
class WebTransferEntry extends StatelessWidget {
  const WebTransferEntry({super.key, required this.onTap, this.touch = false});

  final VoidCallback onTap;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: touch);
    return Center(
      child: Pressable(
        onTap: onTap,
        radius: WhisperRadius.xs,
        scale: .97,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 8,
            vertical: touch ? 12 : 6,
          ),
          child: Text(
            context.shellL10n.webTransferEntry,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: type.note,
              height: 1.3,
              color: c.accentText,
            ),
          ),
        ),
      ),
    );
  }
}

/// Puts web transfer's requests on the island and takes them off again when
/// they are answered, given up or expire.
class WebTransferRequests {
  WebTransferRequests({
    required this.l10n,
    required this.onChanged,
    required this.onAllowed,
  });

  final AppLocalizations? Function() l10n;

  /// Visitors came, went or were let in: the device list is out of date.
  final VoidCallback onChanged;
  final ValueChanged<String> onAllowed;

  final _web = WebTransferCoordinator.shared;
  final _asked = <String>{};

  void attach() {
    _web
      ..install()
      ..addListener(_changed);
  }

  void detach() {
    _web.removeListener(_changed);
    for (final uid in _asked) {
      RequestIslandSource.shared.settle(_id(uid));
    }
    _asked.clear();
  }

  static String _id(String uid) => 'web:$uid';

  void _changed() {
    onChanged();
    final open = {for (final request in _web.requests) request.uid: request};
    for (final uid in _asked.toList()) {
      if (!open.containsKey(uid)) {
        _asked.remove(uid);
        RequestIslandSource.shared.settle(_id(uid));
      }
    }
    for (final request in open.values) {
      if (_asked.add(request.uid)) {
        unawaited(_ask(request));
      }
    }
  }

  Future<void> _ask(WebVisitorRequest request) async {
    final l10n = this.l10n();
    if (l10n == null) return;
    final known = await _web.records.db.fetchDevice(request.uid);
    if (!_asked.contains(request.uid)) return;
    final device = DeviceData(
      id: known?.id ?? 0,
      uid: request.uid,
      name: request.name,
      host: '',
      port: 0,
      platform: request.platform,
      isServer: false,
      online: true,
      clipboard: false,
      auth: false,
      lastTime: 0,
    );
    Future<void> answer(bool allow) async {
      _asked.remove(request.uid);
      RequestIslandSource.shared.settle(_id(request.uid));
      await _web.answer(request.uid, allow);
      if (allow) onAllowed(request.uid);
    }

    RequestIslandSource.shared.ask(
      id: _id(request.uid),
      title: known == null
          ? l10n.webTransferAsk(request.name)
          : l10n.webTransferAskAgain(known.label),
      detail: l10n.webTransferCompare,
      art: deviceArtFor(device, size: 48, paired: false),
      code: request.code,
      answers: [
        IslandAnswer(
          l10n.webTransferAllow,
          () => unawaited(answer(true)),
          primary: true,
        ),
        IslandAnswer(l10n.pairingReject, () => unawaited(answer(false))),
      ],
    );
  }
}

/// surfaces.md「网页传输」: a panel's content changing sides. The old one moves
/// 9% to the left and fades, the new one comes in from 9% to the right
/// (reversed when [back]), on the `smooth` spring; the panel's height follows.
class ShellFaceSwitch extends StatefulWidget {
  const ShellFaceSwitch({super.key, required this.child, this.back = false});

  /// Keyed: a new key is a new face.
  final Widget child;
  final bool back;

  @override
  State<ShellFaceSwitch> createState() => _ShellFaceSwitchState();
}

class _ShellFaceSwitchState extends State<ShellFaceSwitch> {
  Widget? _previous;
  int _turn = 0;

  @override
  void didUpdateWidget(ShellFaceSwitch old) {
    super.didUpdateWidget(old);
    if (old.child.key != widget.child.key) {
      _previous = old.child;
      _turn++;
    }
  }

  /// Both faces sit in the same kind of slot, keyed by the face, so the one
  /// leaving keeps its state (and what it started) until it is gone.
  Widget _slot(Widget face, double opacity, double dx, {bool active = true}) =>
      KeyedSubtree(
        key: face.key ?? const ValueKey('face'),
        child: IgnorePointer(
          ignoring: !active,
          child: Opacity(
            opacity: opacity,
            child: FractionalTranslation(
              translation: Offset(dx, 0),
              child: face,
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final direction = widget.back ? -1.0 : 1.0;
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: SpringBuilder(
        value: _turn.toDouble(),
        spring: WhisperSprings.smooth,
        builder: (context, t, _) {
          final p = (t - _turn + 1).clamp(0.0, 1.0);
          final previous = _previous;
          return Stack(
            alignment: Alignment.topCenter,
            children: [
              if (previous != null && p < 1)
                _slot(previous, 1 - p, -.09 * direction * p, active: false),
              _slot(widget.child, p, .09 * direction * (1 - p)),
            ],
          );
        },
      ),
    );
  }
}
