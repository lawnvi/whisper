import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/theme/app_theme.dart';

/// Embedded in the connection tabs; drafts survive switching to the QR code.
class ManualConnectionForm extends StatefulWidget {
  const ManualConnectionForm({
    super.key,
    required this.onConnect,
    this.fillAvailableHeight = false,
    this.padding = const EdgeInsets.fromLTRB(20, 24, 20, 24),
  });

  final ValueChanged<PeerEndpoint> onConnect;
  final bool fillAvailableHeight;
  final EdgeInsets padding;

  @override
  State<ManualConnectionForm> createState() => _ManualConnectionFormState();
}

class _ManualConnectionFormState extends State<ManualConnectionForm>
    with AutomaticKeepAliveClientMixin {
  final _formKey = GlobalKey<FormState>();
  final _address = TextEditingController();
  final _port = TextEditingController(text: '10002');
  final _addressFocus = FocusNode();
  final _portFocus = FocusNode();
  bool _submitted = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _address.dispose();
    _port.dispose();
    _addressFocus.dispose();
    _portFocus.dispose();
    super.dispose();
  }

  void _connect() {
    if (_submitted || !_formKey.currentState!.validate()) return;
    _submitted = true;
    FocusScope.of(context).unfocus();
    widget.onConnect(
      PeerEndpoint(
        host: _address.text.trim(),
        port: int.parse(_port.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final palette = context.whisperPalette;
    InputDecoration decoration(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: palette.surfaceElevated,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.borderSubtle),
      ),
      errorMaxLines: 3,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: widget.padding,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 420,
              minHeight: widget.fillAvailableHeight
                  ? (constraints.maxHeight - widget.padding.vertical).clamp(
                      0.0,
                      double.infinity,
                    )
                  : 0,
            ),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.fillAvailableHeight)
                        Text(
                          l10n.connectionAddressHint,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.textMuted, height: 1.5),
                        ),
                      if (widget.fillAvailableHeight)
                        const SizedBox(height: 16),
                    ],
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        key: const ValueKey('connection-address'),
                        controller: _address,
                        focusNode: _addressFocus,
                        decoration: decoration(
                          l10n.connectionAddressLabel,
                          hint: '192.168.1.10',
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) => _portFocus.requestFocus(),
                        validator: (value) {
                          try {
                            PeerEndpoint(host: value!.trim(), port: 10002);
                            return null;
                          } on ArgumentError {
                            return l10n.manualConnectAddressInvalid;
                          }
                        },
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        key: const ValueKey('connection-port'),
                        controller: _port,
                        focusNode: _portFocus,
                        decoration: decoration(l10n.port),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _connect(),
                        validator: (value) {
                          final port = int.tryParse(value!.trim());
                          return port == null || port < 1 || port > 65535
                              ? l10n.manualConnectPortInvalid
                              : null;
                        },
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: FilledButton(
                      key: const ValueKey('connect-by-address'),
                      onPressed: _connect,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        visualDensity: VisualDensity.standard,
                      ),
                      child: Text(l10n.connect),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
