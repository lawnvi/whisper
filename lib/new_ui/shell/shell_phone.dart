import 'package:flutter/material.dart';
import 'package:whisper/new_ui/shell/shell_data.dart';
import 'package:whisper/new_ui/shell/shell_first_device.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_sidebar.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// docs/design/surfaces.md「手机」: a large title and one list, whole rows edge to
/// edge. Beside the content on a tablet or an open foldable it is the sidebar,
/// and it is the same list: scrolled where it was through a fold.
class ShellPhoneList extends StatelessWidget {
  const ShellPhoneList({
    super.key,
    required this.data,
    required this.actions,
    required this.order,
    required this.onSelect,
    this.sidebar = false,
    this.selectedPeerId,
  });

  final ShellData data;
  final ShellActions actions;
  final List<String> order;
  final ValueChanged<String> onSelect;

  /// Beside the content, on `sidebar-solid`.
  final bool sidebar;
  final String? selectedPeerId;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: true);
    final byId = {for (final s in data.sessions) s.device.uid: s};
    final rows = [
      for (final id in order)
        if (byId[id] != null) byId[id]!,
    ];
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ColoredBox(
      color: sidebar ? c.sidebarSolid : c.content,
      child: SafeArea(
        bottom: false,
        right: !sidebar,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.shellPhoneDevices,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.large,
                        fontWeight: FontWeight.w700,
                        color: c.ink,
                      ),
                    ),
                  ),
                  _TopButton(
                    glyph: WhisperGlyph.plus,
                    label: l10n.shellAddDevice,
                    onTap: () => actions.openPairing(),
                  ),
                  _TopButton(
                    glyph: WhisperGlyph.gear,
                    label: l10n.shellSettings,
                    onTap: actions.openSettings,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (rows.isNotEmpty || data.loading)
                    SingleChildScrollView(
                      padding: sidebar
                          ? EdgeInsets.fromLTRB(10, 0, 10, 24 + bottom)
                          : EdgeInsets.only(bottom: bottom + 8),
                      child: ShellDeviceRows(
                        rows: rows,
                        selectedPeerId: selectedPeerId,
                        factsFor: data.factsFor,
                        isPaired: data.isPaired,
                        second: c.ink2,
                        onSelect: onSelect,
                        contextActions: (device) =>
                            actions.contextActions(device),
                        touch: true,
                        edgeToEdge: !sidebar,
                      ),
                    ),
                  // Beside the content it stands in the content, with room.
                  if (!sidebar)
                    ShellFirstDevice(
                      touch: true,
                      visible: rows.isEmpty && !data.loading,
                      self: data.self,
                      onConnect: () => actions.openPairing(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopButton extends StatelessWidget {
  const _TopButton({
    required this.glyph,
    required this.label,
    required this.onTap,
  });

  final WhisperGlyph glyph;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    radius: WhisperRadius.xs,
    label: label,
    child: SizedBox(
      width: 44,
      height: 48,
      child: Center(child: WhisperIcon(glyph, size: 20, color: context.wc.ink)),
    ),
  );
}
