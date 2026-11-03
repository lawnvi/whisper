import 'package:flutter/material.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/page/pairing_qr.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// The port everyone is on unless they changed it.
const int _usualPort = 10002;

/// `地址和端口` is one line: `192.168.1.8`, `192.168.1.8:10002`, `[fe80::1]:10002`.
({String host, int? port, bool portIsBad}) splitManualAddress(String text) {
  final typed = text.trim();
  var host = typed;
  String? port;
  if (typed.startsWith('[')) {
    final end = typed.indexOf(']');
    if (end > 0) {
      host = typed.substring(1, end);
      final rest = typed.substring(end + 1);
      if (rest.startsWith(':')) port = rest.substring(1);
    }
  } else if (':'.allMatches(typed).length == 1) {
    final colon = typed.indexOf(':');
    host = typed.substring(0, colon);
    port = typed.substring(colon + 1);
  }
  if (port == null) return (host: host, port: null, portIsBad: false);
  final value = int.tryParse(port);
  final bad = value == null || value < 1 || value > 65535;
  return (host: host, port: bad ? null : value, portIsBad: bad);
}

/// The prototype's `manualConnect`: the desktop's way to reach a device that
/// cannot be discovered. It starts on this network's first three numbers.
class ShellManualConnect extends StatefulWidget {
  const ShellManualConnect({super.key, this.localHost});

  final String? localHost;

  @override
  State<ShellManualConnect> createState() => _ShellManualConnectState();
}

class _ShellManualConnectState extends State<ShellManualConnect> {
  late final _address = TextEditingController(text: _prefill());
  String? _error;

  String _prefill() {
    final octets = widget.localHost?.split('.') ?? const <String>[];
    return octets.length == 4 ? '${octets.take(3).join('.')}.' : '';
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _connect() {
    final l10n = context.shellL10n;
    final typed = splitManualAddress(_address.text);
    if (typed.portIsBad) {
      setState(() => _error = l10n.manualConnectPortInvalid);
      return;
    }
    try {
      final endpoint = PeerEndpoint(
        host: typed.host,
        port: typed.port ?? _usualPort,
      );
      Navigator.of(context).pop(PairingQrResult.manual(endpoint));
    } on ArgumentError {
      setState(() => _error = l10n.manualConnectAddressInvalid);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.shellManualConnectTitle,
          style: TextStyle(
            fontSize: type.head,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        ),
        const SizedBox(height: 14),
        ShellField(
          label: l10n.shellManualConnectField,
          controller: _address,
          touch: false,
          autofocus: true,
          error: _error,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            ShellButton(
              label: l10n.cancel,
              onTap: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 8),
            ShellButton(
              label: l10n.shellConnect,
              kind: ShellButtonKind.primary,
              onTap: _connect,
            ),
          ],
        ),
      ],
    );
  }
}
