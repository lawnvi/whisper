import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/desktop_quick_send_inbox.dart';
import 'package:whisper/theme/app_theme.dart';

class DesktopQuickSendPeer {
  const DesktopQuickSendPeer({
    required this.id,
    required this.name,
    required this.isConnected,
  });

  final String id;
  final String name;
  final bool isConnected;
}

Future<String?> showDesktopQuickSendDialog(
  BuildContext context, {
  required List<DesktopQuickSendDraft> drafts,
  required List<DesktopQuickSendPeer> peers,
  String? initialPeerId,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _DesktopQuickSendDialog(
      drafts: drafts,
      peers: peers,
      initialPeerId: initialPeerId,
    ),
  );
}

class _DesktopQuickSendDialog extends StatefulWidget {
  const _DesktopQuickSendDialog({
    required this.drafts,
    required this.peers,
    required this.initialPeerId,
  });

  final List<DesktopQuickSendDraft> drafts;
  final List<DesktopQuickSendPeer> peers;
  final String? initialPeerId;

  @override
  State<_DesktopQuickSendDialog> createState() =>
      _DesktopQuickSendDialogState();
}

class _DesktopQuickSendDialogState extends State<_DesktopQuickSendDialog> {
  String? _selectedPeerId;

  @override
  void initState() {
    super.initState();
    final preferred = widget.peers
        .where(
          (peer) => peer.id == widget.initialPeerId && peer.isConnected,
        )
        .firstOrNull;
    _selectedPeerId = preferred?.id ??
        widget.peers.where((peer) => peer.isConnected).firstOrNull?.id;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textCount =
        widget.drafts.where((draft) => draft.text.isNotEmpty).length;
    final fileCount = widget.drafts.fold<int>(
      0,
      (count, draft) => count + draft.filePaths.length,
    );
    final palette = context.whisperPalette;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.outbox_rounded),
          const SizedBox(width: 10),
          Expanded(child: Text(l10n.desktopQuickSendTitle)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.desktopQuickSendSummary(textCount, fileCount),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: palette.textMuted,
                  ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ...widget.drafts.take(4).map(_buildDraftRow),
                  if (widget.drafts.length > 4)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                      child: Text(
                        l10n.desktopQuickSendMore(widget.drafts.length - 4),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: palette.textMuted,
                            ),
                      ),
                    ),
                  const Divider(height: 24),
                  Text(
                    l10n.desktopQuickSendChooseDevice,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  if (widget.peers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        l10n.desktopQuickSendNoTrustedDevices,
                        style: TextStyle(color: palette.textMuted),
                      ),
                    ),
                  ...widget.peers.map(_buildPeerRow),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.desktopQuickSendLater),
        ),
        FilledButton.icon(
          onPressed: _selectedPeerId == null
              ? null
              : () => Navigator.of(context).pop(_selectedPeerId),
          icon: const Icon(Icons.send_rounded),
          label: Text(l10n.desktopQuickSendSend),
        ),
      ],
    );
  }

  Widget _buildDraftRow(DesktopQuickSendDraft draft) {
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    final title = draft.text.isNotEmpty
        ? draft.text.replaceAll(RegExp(r'\s+'), ' ').trim()
        : draft.filePaths.isEmpty
            ? ''
            : p.basename(draft.filePaths.first);
    final fileCount = draft.filePaths.length;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(
        draft.text.isNotEmpty ? Icons.text_snippet_outlined : Icons.attach_file,
        color: theme.colorScheme.primary,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: fileCount == 0
          ? null
          : Text(
              AppLocalizations.of(context)!.desktopQuickSendFiles(fileCount),
              style: TextStyle(color: palette.textMuted),
            ),
    );
  }

  Widget _buildPeerRow(DesktopQuickSendPeer peer) {
    final l10n = AppLocalizations.of(context)!;
    return RadioListTile<String>(
      value: peer.id,
      groupValue: _selectedPeerId,
      onChanged: peer.isConnected
          ? (value) => setState(() => _selectedPeerId = value)
          : null,
      contentPadding: EdgeInsets.zero,
      secondary: Icon(
        peer.isConnected ? Icons.lock_rounded : Icons.lock_clock_outlined,
        size: 20,
      ),
      title: Text(
        peer.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle:
          peer.isConnected ? null : Text(l10n.desktopQuickSendDeviceOffline),
    );
  }
}
