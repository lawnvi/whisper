import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/new_ui/phone/panel_menu.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// What a picker offers: a device, or a place on one when only places can be
/// told apart ([glyph], a folder).
class DevicePickerEntry {
  const DevicePickerEntry({
    required this.id,
    required this.name,
    this.kind = DeviceKind.desktop,
    this.glyph,
    this.checked = false,
  });

  final String id, name;
  final DeviceKind kind;
  final WhisperGlyph? glyph;
  final bool checked;
}

/// surfaces.md「设备选取器」, the prototype's `showPicker`: every "pick a device"
/// looks like this. A `panel` menu on [anchor]'s button on a desktop and a sheet
/// from the bottom edge on a phone, with what is about to happen in `tiny` on
/// top. Only what can be picked is listed; with nothing to list it says so and
/// resolves to null.
Future<String?> showDevicePicker(
  BuildContext context, {
  required String title,
  required List<DevicePickerEntry> devices,
  BuildContext? anchor,
  bool? touch,
}) async {
  if (devices.isEmpty) {
    showAppToast(context.shellL10n.pickerNoDevices, tone: AppToastTone.warning);
    return null;
  }
  final sheet = touch ?? !isDesktop();
  if (sheet || anchor == null) {
    return showPhoneSheet<String>(
      context,
      builder: (context) => DevicePickerSheet(title: title, devices: devices),
    );
  }
  String? picked;
  await showPanelMenu(
    context,
    anchor: panelMenuAnchor(anchor),
    title: title,
    items: [
      for (final device in devices)
        PanelMenuEntry(
          key: ValueKey('device-picker-${device.id}'),
          label: device.name,
          leading: (color) => DevicePickerGlyph(device: device, color: color),
          checked: device.checked,
          onSelected: () => picked = device.id,
        ),
    ],
  );
  return picked;
}

/// A line glyph at 20: the device's kind, or what the entry asks for.
class DevicePickerGlyph extends StatelessWidget {
  const DevicePickerGlyph({
    super.key,
    required this.device,
    required this.color,
  });

  final DevicePickerEntry device;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final glyph = device.glyph;
    return glyph != null
        ? WhisperIcon(glyph, size: 20, color: color)
        : DeviceGlyph(kind: device.kind, color: color, size: 20);
  }
}

/// The picker as a sheet: the title, then one group of rows at 48.
class DevicePickerSheet extends StatelessWidget {
  const DevicePickerSheet({
    super.key,
    required this.title,
    required this.devices,
    this.onPicked,
  });

  final String title;
  final List<DevicePickerEntry> devices;
  final ValueChanged<String>? onPicked;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DevicePickerTitle(title),
      ShellGroup(
        inset: 41,
        children: [
          for (final device in devices)
            DevicePickerRow(
              key: ValueKey('device-picker-${device.id}'),
              device: device,
              onTap: () => onPicked != null
                  ? onPicked!(device.id)
                  : Navigator.of(context).pop(device.id),
            ),
        ],
      ),
    ],
  );
}

/// `h5`: what is about to happen, in `tiny`.
class DevicePickerTitle extends StatelessWidget {
  const DevicePickerTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    const type = WhisperType(touch: true);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: type.tiny,
          fontWeight: FontWeight.w500,
          color: context.wc.ink2,
        ),
      ),
    );
  }
}

/// One device in a group: line glyph at 20, name, a tick on the one already in
/// mind. 48 high, 40 where there is a pointer.
class DevicePickerRow extends StatefulWidget {
  const DevicePickerRow({
    super.key,
    required this.device,
    required this.onTap,
    this.touch = true,
    this.autofocus = false,
  });

  final DevicePickerEntry device;
  final VoidCallback onTap;
  final bool touch, autofocus;

  @override
  State<DevicePickerRow> createState() => _DevicePickerRowState();
}

class _DevicePickerRowState extends State<DevicePickerRow> {
  bool _down = false, _hover = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: widget.touch);
    final device = widget.device;
    final lit = _down || _hover || _focused;
    return Semantics(
      button: true,
      selected: device.checked,
      label: device.name,
      excludeSemantics: true,
      child: FocusableActionDetector(
        autofocus: widget.autofocus,
        mouseCursor: SystemMouseCursors.basic,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: ColoredBox(
            color: lit ? c.fill : Colors.transparent,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.touch ? 48 : 40),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    DevicePickerGlyph(device: device, color: c.accent),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: type.body,
                          height: 1.3,
                          color: c.ink,
                        ),
                      ),
                    ),
                    if (device.checked) ...[
                      const SizedBox(width: 9),
                      WhisperIcon(
                        WhisperGlyph.check,
                        size: 13,
                        weight: 2,
                        color: c.accent,
                      ),
                    ],
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
