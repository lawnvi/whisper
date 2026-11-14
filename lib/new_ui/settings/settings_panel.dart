import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';

import 'settings_controls.dart';

/// The desktop's settings (docs/design/surfaces.md「设置」): a panel on the
/// canvas with the list of sections on the left, [body] on the right, and the
/// close button on the title's line. [body] comes up from just below each
/// time [bodyKey] changes: another section, or a page under one.
class SettingsPanelFrame extends StatelessWidget {
  const SettingsPanelFrame({
    super.key,
    required this.nav,
    required this.body,
    required this.bodyKey,
    required this.closeLabel,
    required this.onClose,
  });

  static const width = 780.0, height = 560.0, navWidth = 224.0;

  final Widget nav, body;
  final Key bodyKey;
  final String closeLabel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final window = MediaQuery.sizeOf(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(WhisperRadius.l),
    );
    return Center(
      child: SizedBox(
        width: math.min(width, window.width - 32),
        height: math.min(height, window.height - WhisperWindow.sheetGap),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: c.canvas,
            shape: shape,
            shadows: WhisperShadow.e3(Theme.of(context).brightness),
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: shape),
            child: Material(
              type: MaterialType.transparency,
              child: SettingsTextStyle(
                child: Stack(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: navWidth,
                          // Inside its width: the content starts at exactly 224.
                          child: DecoratedBox(
                            position: DecorationPosition.foreground,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(
                                  color: c.sep,
                                  width:
                                      1 /
                                      MediaQuery.devicePixelRatioOf(context),
                                ),
                              ),
                            ),
                            child: nav,
                          ),
                        ),
                        Expanded(
                          // Not a page turn: no direction, up from just below.
                          child: SpringBuilder(
                            key: bodyKey,
                            from: 0,
                            value: 1,
                            animateWhenReduced: true,
                            child: body,
                            builder: (context, t, child) => Opacity(
                              opacity: t.clamp(0.0, 1.0),
                              child: Transform.translate(
                                offset: MediaQuery.disableAnimationsOf(context)
                                    ? Offset.zero
                                    : Offset(0, 5 * (1 - t)),
                                child: child,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    // On the title's line, at the right edge of the groups.
                    Positioned(
                      top: 26,
                      right: 21,
                      child: SettingsCloseButton(
                        label: closeLabel,
                        onTap: onClose,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One entry of the panel's list: its title and coloured tile.
typedef SettingsPanelEntry = ({String title, WhisperGlyph? glyph, Color color});

/// The panel's titles: 「设置」 over the list, and each section's.
TextStyle settingsPanelTitleStyle(BuildContext context) => TextStyle(
  fontSize: WhisperType(touch: SettingsScope.of(context).touch).title,
  height: 1.4,
  fontWeight: FontWeight.w600,
  color: context.wc.ink,
);

/// The desktop panel's list of sections, on the sidebar's glass
/// (docs/design/surfaces.md「设置」).
class SettingsPanelNav extends StatelessWidget {
  const SettingsPanelNav({
    super.key,
    required this.title,
    required this.entries,
    required this.selected,
    required this.onSelect,
  });

  final String title;
  final List<SettingsPanelEntry> entries;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => WhisperGlass(
    kind: GlassKind.sidebar,
    blur: false,
    shape: const RoundedRectangleBorder(),
    child: ListView(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
          child: Text(title, style: settingsPanelTitleStyle(context)),
        ),
        for (final (i, entry) in entries.indexed)
          SettingsNavItem(
            title: entry.title,
            glyph: entry.glyph,
            color: entry.color,
            selected: i == selected,
            onTap: () => onSelect(i),
          ),
      ],
    ),
  );
}

/// The right of the panel: a section's title and groups, or a page under a
/// section, whose title has the way back beside it.
class SettingsPanelPage extends StatelessWidget {
  const SettingsPanelPage({
    super.key,
    required this.title,
    required this.children,
    this.back,
    this.backLabel,
  });

  final String title;
  final List<Widget> children;

  /// Back to the section this page is under, named [backLabel].
  final VoidCallback? back;
  final String? backLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final back = this.back;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 28),
      children: [
        Row(
          children: [
            if (back != null) ...[
              // The arrow over the groups' edge, as the close button is.
              Transform.translate(
                offset: const Offset(-7, 0),
                child: Tooltip(
                  message: backLabel ?? '',
                  child: Pressable(
                    radius: WhisperRadius.xs,
                    label: backLabel,
                    onTap: back,
                    child: SettingsHighlight(
                      hover: c.fill,
                      press: c.fill2,
                      radius: WhisperRadius.xs,
                      child: SizedBox.square(
                        dimension: 28,
                        child: Center(
                          child: WhisperIcon(
                            WhisperGlyph.back,
                            size: 16,
                            weight: 2,
                            color: c.ink2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 1),
            ],
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: settingsPanelTitleStyle(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...children,
      ],
    );
  }
}
