import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart' show ShellField;
import 'package:whisper/new_ui/shell/shell_network_quality.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/peer_aliases.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// The device card's rows about the device itself, in the card's own rows
/// so they add nothing new to look at: the name it is given here, the
/// version it runs, and where it is on the network. This device's own
/// address is under its name at the bottom left. A value is copied when its
/// row is pressed.
class ShellDeviceAbout extends StatefulWidget {
  const ShellDeviceAbout({
    super.key,
    required this.device,
    required this.connected,
    this.touch = false,
  });

  final DeviceData device;
  final bool connected, touch;

  @override
  State<ShellDeviceAbout> createState() => _ShellDeviceAboutState();
}

class _ShellDeviceAboutState extends State<ShellDeviceAbout> {
  void _copy(String value) {
    unawaited(Clipboard.setData(ClipboardData(text: value)));
    showAppToast(context.shellL10n.shellCardCopied(value));
  }

  Future<void> _rename() async {
    final device = widget.device;
    await showShellSheet<void>(
      context,
      scrolls: false,
      builder: (context) => _RenameSheet(device: device),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.shellL10n;
    final device = widget.device;
    final touch = widget.touch;
    final version = widget.connected
        ? WsSvrManager().remoteProfileFor(device.uid)?.appVersion ?? ''
        : '';
    return ListenableBuilder(
      listenable: PeerAliases.shared,
      builder: (context, _) {
        final alias = PeerAliases.shared.aliasOf(device.uid);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShellGroup(
              children: [
                ShellRow(
                  touch: touch,
                  label: l10n.shellCardAlias,
                  chevron: true,
                  onTap: () => unawaited(_rename()),
                  trailing: _Value(
                    alias ?? device.name,
                    touch: touch,
                    faint: alias == null,
                  ),
                ),
                if (version.isNotEmpty)
                  ShellRow(
                    touch: touch,
                    label: l10n.shellCardVersion,
                    onTap: () => _copy(version),
                    trailing: _Value(version, touch: touch),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            ShellGroup(
              children: [
                if (widget.connected)
                  ShellNetworkRow(device: device, touch: touch),
                if (device.host.isNotEmpty)
                  ShellRow(
                    touch: touch,
                    label: l10n.shellCardAddress,
                    onTap: () => _copy(device.host),
                    trailing: _Value(device.host, touch: touch),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.text, {required this.touch, this.faint = false});

  final String text;
  final bool touch, faint;

  // At most about half the row: the label keeps its words.
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 150),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.end,
      style: TextStyle(
        fontSize: WhisperType(touch: touch).note,
        color: faint ? context.wc.ink3 : context.wc.ink2,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}

/// The name given to a device here: typed in, or emptied to go back to
/// its own.
class _RenameSheet extends StatefulWidget {
  const _RenameSheet({required this.device});

  final DeviceData device;

  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final _name = TextEditingController(
    text: PeerAliases.shared.aliasOf(widget.device.uid) ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final typed = _name.text.trim();
    final runes = typed.runes;
    final kept = runes.length > PeerAliases.maxRunes
        ? String.fromCharCodes(runes.take(PeerAliases.maxRunes))
        : typed;
    // Its own name typed in is no name given.
    unawaited(
      PeerAliases.shared.rename(
        widget.device.uid,
        kept == widget.device.name ? '' : kept,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    return ShellSheetBody(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.shellCardAlias,
            style: TextStyle(
              fontSize: type.head,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 14),
          ShellField(
            label: l10n.shellCardAlias,
            controller: _name,
            hint: widget.device.name,
            touch: false,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.shellCardAliasNote(widget.device.name),
            style: TextStyle(fontSize: type.note, height: 1.4, color: c.ink2),
          ),
        ],
      ),
      actions: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ShellButton(
            label: l10n.cancel,
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
          ShellButton(
            label: l10n.shellDone,
            kind: ShellButtonKind.primary,
            onTap: _save,
          ),
        ],
      ),
    );
  }
}
