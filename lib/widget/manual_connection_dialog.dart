import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/ipv4_address_policy.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/theme/app_theme.dart';

/// Embedded in the connection tabs; drafts survive switching to the QR code.
class ManualConnectionForm extends StatefulWidget {
  const ManualConnectionForm({
    super.key,
    required this.onConnect,
    this.localHost,
    this.fillAvailableHeight = false,
    this.padding = const EdgeInsets.fromLTRB(20, 24, 20, 24),
  });

  final ValueChanged<PeerEndpoint> onConnect;
  final String? localHost;
  final bool fillAvailableHeight;
  final EdgeInsets padding;

  @override
  State<ManualConnectionForm> createState() => _ManualConnectionFormState();
}

class _ManualConnectionFormState extends State<ManualConnectionForm>
    with AutomaticKeepAliveClientMixin {
  final _formKey = GlobalKey<FormState>();
  late final _address = TextEditingController(text: _initialAddress());
  final _port = TextEditingController(text: '10002');
  final _addressFocus = FocusNode();
  final _portFocus = FocusNode();
  bool _submitted = false;

  @override
  bool get wantKeepAlive => true;

  String _initialAddress() {
    final local = widget.localHost;
    if (local == null || Ipv4AddressPolicy.parseCanonical(local) == null) {
      return '192.168.1.10';
    }
    final octets = local.split('.');
    // Keep the local prefix as an editing convenience, without targeting self.
    octets[3] = octets[3] == '10' ? '20' : '10';
    return octets.join('.');
  }

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
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    const decoration = InputDecoration(
      isDense: true,
      filled: false,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
      errorMaxLines: 3,
      contentPadding: EdgeInsets.zero,
    );
    final inputStyle = theme.textTheme.bodyLarge?.copyWith(
      fontSize: 17,
      height: 1.4,
    );
    return SingleChildScrollView(
      padding: widget.padding,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          // Keyboard insets only resize the viewport; keep the form's layout
          // and paint independent of the dialog's movement.
          child: RepaintBoundary(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.start,
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
                      Container(
                        key: const ValueKey('connection-input-group'),
                        decoration: BoxDecoration(
                          color: palette.surfaceElevated,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: palette.borderSubtle),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ConnectionInputRow(
                              label: l10n.connectionAddressLabel,
                              focusNode: _addressFocus,
                              child: TextFormField(
                                key: const ValueKey('connection-address'),
                                controller: _address,
                                focusNode: _addressFocus,
                                decoration: decoration,
                                style: inputStyle,
                                keyboardType: TextInputType.url,
                                autocorrect: false,
                                enableSuggestions: false,
                                textInputAction: TextInputAction.next,
                                onFieldSubmitted: (_) =>
                                    _portFocus.requestFocus(),
                                validator: (value) {
                                  try {
                                    PeerEndpoint(
                                      host: value!.trim(),
                                      port: 10002,
                                    );
                                    return null;
                                  } on ArgumentError {
                                    return l10n.manualConnectAddressInvalid;
                                  }
                                },
                              ),
                            ),
                            Divider(
                              height: 0.75,
                              thickness: 0.75,
                              indent: 16,
                              endIndent: 16,
                              color: palette.borderSubtle,
                            ),
                            _ConnectionInputRow(
                              label: l10n.port,
                              focusNode: _portFocus,
                              child: TextFormField(
                                key: const ValueKey('connection-port'),
                                controller: _port,
                                focusNode: _portFocus,
                                decoration: decoration,
                                style: inputStyle,
                                // Match the address field so switching focus does not
                                // resize/reconfigure the IME; the formatter keeps this
                                // field numeric without changing the keyboard layout.
                                keyboardType: TextInputType.url,
                                autocorrect: false,
                                enableSuggestions: false,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                textInputAction: TextInputAction.done,
                                onFieldSubmitted: (_) => _connect(),
                                validator: (value) {
                                  final port = int.tryParse(value!.trim());
                                  return port == null ||
                                          port < 1 ||
                                          port > 65535
                                      ? l10n.manualConnectPortInvalid
                                      : null;
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: EdgeInsets.only(
                      top: widget.fillAvailableHeight ? 40 : 24,
                    ),
                    child: FilledButton(
                      key: const ValueKey('connect-by-address'),
                      onPressed: _connect,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        visualDensity: VisualDensity.standard,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        textStyle: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
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

class _ConnectionInputRow extends StatelessWidget {
  const _ConnectionInputRow({
    required this.label,
    required this.focusNode,
    required this.child,
  });

  final String label;
  final FocusNode focusNode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextFieldTapRegion(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: focusNode.requestFocus,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListenableBuilder(
                  listenable: focusNode,
                  builder: (context, _) => ExcludeSemantics(
                    child: Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.3,
                        color: focusNode.hasFocus
                            ? theme.colorScheme.primary
                            : context.whisperPalette.textMuted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Semantics(label: label, child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
