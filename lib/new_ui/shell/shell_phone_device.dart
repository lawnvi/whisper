import 'package:flutter/material.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_device_card.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// docs/design/surfaces.md「手机 · 设备页」: what the desktop's card holds, with
/// the pages a desktop shows as tabs as three round entries.
class ShellPhoneDevicePage extends StatelessWidget {
  const ShellPhoneDevicePage({
    super.key,
    required this.device,
    required this.connected,
    required this.entries,
    required this.onSearchHistory,
    required this.onDiagnostics,
    required this.onDisconnect,
    required this.onRemove,
    this.onBack,
  });

  final DeviceData device;
  final bool connected;
  final List<ShellDeviceEntry> entries;
  final VoidCallback onSearchHistory, onDiagnostics;
  final Future<void> Function() onDisconnect;
  final Future<void> Function(String uid) onRemove;

  /// Where back goes when this is not a page of its own in a navigator.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    return Scaffold(
      backgroundColor: c.canvas,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(50),
        child: SafeArea(
          bottom: false,
          child: Align(
            alignment: Alignment.centerLeft,
            child: ShellIconButton(
              glyph: WhisperGlyph.back,
              iconSize: 20,
              weight: 2,
              touch: true,
              color: c.accent,
              label: l10n.back,
              onTap: onBack ?? () => Navigator.of(context).maybePop(),
            ),
          ),
        ),
      ),
      body: ShellDeviceCard(
        device: device,
        connected: connected,
        paired: true,
        statusLine: connected ? l10n.shellCardConnected : l10n.shellRowOffline,
        touch: true,
        topInset: 14,
        entries: entries,
        onSearchHistory: onSearchHistory,
        onDiagnostics: onDiagnostics,
        onDisconnect: onDisconnect,
        onRemove: onRemove,
      ),
    );
  }
}
