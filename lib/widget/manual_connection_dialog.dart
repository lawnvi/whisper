import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/widget/app_dialogs.dart';

Future<PeerEndpoint?> showManualConnectionDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final values = await showValidatedInputDialog(
    context,
    title: l10n.connectDeviceTitle,
    description: l10n.connectDeviceDesc,
    fields: [
      InputDialogField(
        initialValue: '',
        label: '192.168.1.10',
        keyboardType: TextInputType.url,
        validator: (value) {
          try {
            PeerEndpoint(host: value, port: 10002);
            return null;
          } on ArgumentError {
            return l10n.manualConnectAddressInvalid;
          }
        },
      ),
      InputDialogField(
        initialValue: '10002',
        label: l10n.port,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        validator: (value) {
          final port = int.tryParse(value);
          return port == null || port < 1 || port > 65535
              ? l10n.manualConnectPortInvalid
              : null;
        },
      ),
    ],
    confirmButtonText: l10n.connect,
    cancelButtonText: l10n.cancel,
  );
  if (values == null) return null;
  return PeerEndpoint(host: values[0], port: int.parse(values[1]));
}
