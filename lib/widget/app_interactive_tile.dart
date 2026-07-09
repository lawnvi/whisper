import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

class AppInteractiveTile extends StatefulWidget {
  const AppInteractiveTile({
    super.key,
    required this.semanticLabel,
    required this.title,
    this.selected = false,
    this.toggled,
    this.enabled = true,
    this.onActivate,
    this.leading,
    this.subtitle,
    this.trailing,
  });

  static const focusIndicatorKey = ValueKey<String>(
    'app-interactive-tile-focus-indicator',
  );

  final String semanticLabel;
  final bool selected;
  final bool? toggled;
  final bool enabled;
  final VoidCallback? onActivate;
  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;

  @override
  State<AppInteractiveTile> createState() => _AppInteractiveTileState();
}

class _AppInteractiveTileState extends State<AppInteractiveTile> {
  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  final FocusNode _focusNode = FocusNode();
  bool _focused = false;
  bool _hovered = false;

  bool get _canActivate => widget.enabled && widget.onActivate != null;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _setFocused(bool focused) {
    if (_focused == focused) {
      return;
    }
    setState(() => _focused = focused);
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) {
      return;
    }
    setState(() => _hovered = hovered);
  }

  void _activate() {
    if (_canActivate) {
      widget.onActivate!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final foregroundColor = widget.enabled
        ? colorScheme.onSurface
        : colorScheme.onSurface.withValues(alpha: 0.38);
    final backgroundColor = widget.selected
        ? colorScheme.primary.withValues(alpha: 0.10)
        : _hovered
            ? palette.surfaceMuted
            : Colors.transparent;
    final borderColor = widget.selected
        ? colorScheme.primary
        : palette.borderSubtle.withValues(alpha: 0);

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: widget.semanticLabel,
      button: true,
      enabled: _canActivate,
      selected: widget.selected,
      toggled: widget.toggled,
      focusable: true,
      focused: _focused,
      onFocus: _focusNode.requestFocus,
      onTap: _canActivate ? _activate : null,
      child: FocusableActionDetector(
        enabled: true,
        focusNode: _focusNode,
        includeFocusSemantics: false,
        shortcuts: _shortcuts,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        mouseCursor:
            _canActivate ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onFocusChange: _setFocused,
        onShowHoverHighlight: _setHovered,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _canActivate ? _activate : null,
          child: Container(
            key: AppInteractiveTile.focusIndicatorKey,
            constraints: const BoxConstraints(
              minWidth: WhisperUi.minInteractiveSize,
              minHeight: WhisperUi.minInteractiveSize,
            ),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
              border: Border.all(
                color: _focused ? colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: AnimatedContainer(
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(WhisperUi.radiusSmall),
                border: Border.all(color: borderColor),
              ),
              child: IconTheme(
                data:
                    theme.iconTheme.copyWith(color: foregroundColor, size: 20),
                child: LayoutBuilder(
                  builder: (context, constraints) => _buildContent(
                    theme,
                    palette,
                    foregroundColor,
                    boundedWidth: constraints.hasBoundedWidth,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    ThemeData theme,
    WhisperPalette palette,
    Color foregroundColor, {
    required bool boundedWidth,
  }) {
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DefaultTextStyle(
          style: theme.textTheme.titleSmall!.copyWith(color: foregroundColor),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          child: widget.title,
        ),
        if (widget.subtitle != null) ...<Widget>[
          const SizedBox(height: 2),
          DefaultTextStyle(
            style: theme.textTheme.bodySmall!.copyWith(
              color: widget.enabled ? palette.textMuted : foregroundColor,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            child: widget.subtitle!,
          ),
        ],
      ],
    );

    return Row(
      mainAxisSize: boundedWidth ? MainAxisSize.max : MainAxisSize.min,
      children: <Widget>[
        if (widget.leading != null) ...<Widget>[
          widget.leading!,
          const SizedBox(width: 12),
        ],
        if (boundedWidth) Expanded(child: text) else text,
        if (widget.trailing != null) ...<Widget>[
          const SizedBox(width: 12),
          widget.trailing!,
        ],
      ],
    );
  }
}
