import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:whisper/helper/device_form_factor.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/picker/device_picker.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/quick_send_chooser.dart';

/// surfaces.md「设备选取器」with what is about to be sent above it: from another
/// app on a phone, as a sheet from the bottom; from a shortcut on a desktop, as a
/// standard sheet. A device is picked by tapping it, 稍后 leaves the content for
/// later, and the list follows connections while it is open.
class QuickSendPicker extends StatefulWidget {
  const QuickSendPicker({
    super.key,
    required this.items,
    required this.targets,
    required this.touch,
    this.initialTargetId,
  });

  final List<QuickSendItem> items;
  final ValueListenable<List<QuickSendTarget>> targets;
  final bool touch;
  final String? initialTargetId;

  @override
  State<QuickSendPicker> createState() => _QuickSendPickerState();
}

class _QuickSendPickerState extends State<QuickSendPicker> {
  /// A single device needs no choosing: it, or the one asked for, is marked and
  /// takes Enter.
  String? _marked(List<QuickSendTarget> targets) {
    if (targets.any((target) => target.id == widget.initialTargetId)) {
      return widget.initialTargetId;
    }
    return targets.length == 1 ? targets.single.id : null;
  }

  String _title() {
    final l10n = context.shellL10n;
    final items = widget.items;
    if (items.length == 1) {
      final only = items.single;
      return only.isText ? l10n.pickerSendText : l10n.pickerSendFile(only.name);
    }
    return l10n.pickerSendItems(items.length);
  }

  DeviceKind _kind(QuickSendTarget target) => deviceKindFor(
    target.platform,
    name: target.name,
    tablet: DeviceFormFactors.shared.isTablet(target.id),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.shellL10n;
    final touch = widget.touch;
    return ValueListenableBuilder<List<QuickSendTarget>>(
      valueListenable: widget.targets,
      builder: (context, targets, _) {
        final marked = _marked(targets);
        final rows = [
          for (final target in targets)
            DevicePickerRow(
              key: ValueKey('quick-send-target-${target.id}'),
              touch: touch,
              autofocus: !touch && target.id == marked,
              device: DevicePickerEntry(
                id: target.id,
                name: target.name,
                kind: _kind(target),
                checked: target.id == marked,
              ),
              onTap: () => Navigator.of(context).pop(target.id),
            ),
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (touch)
              DevicePickerTitle(_title())
            else ...[
              Text(
                l10n.quickSendTitle,
                style: TextStyle(
                  fontSize: const WhisperType(touch: false).head,
                  fontWeight: FontWeight.w600,
                  color: context.wc.ink,
                ),
              ),
              const SizedBox(height: 14),
            ],
            _QuickSendPreview(items: widget.items, touch: touch),
            const SizedBox(height: 14),
            if (!touch) ShellGroupLabel(_title()),
            if (targets.isEmpty)
              _NoTargets(touch: touch)
            else
              ShellGroup(inset: 41, flat: !touch, children: rows),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: touch
                  ? PhoneButton(
                      key: const ValueKey('quick-send-later'),
                      label: l10n.quickSendLater,
                      onTap: () => Navigator.of(context).pop(),
                    )
                  : ShellButton(
                      key: const ValueKey('quick-send-later'),
                      label: l10n.quickSendLater,
                      onTap: () => Navigator.of(context).pop(),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _NoTargets extends StatelessWidget {
  const _NoTargets({required this.touch});

  final bool touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: touch);
    return Padding(
      key: const ValueKey('quick-send-no-targets'),
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        children: [
          WhisperIcon(WhisperGlyph.link, size: 24, color: c.ink3),
          const SizedBox(height: 8),
          Text(
            context.shellL10n.quickSendNoConnectedDevices,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: type.note, height: 1.5, color: c.ink2),
          ),
        ],
      ),
    );
  }
}

/// The text, the pictures and the files waiting to go. The pictures are the same
/// strip as ever: what a phone has to show is its gallery's thumbnails.
class _QuickSendPreview extends StatelessWidget {
  const _QuickSendPreview({required this.items, required this.touch});

  final List<QuickSendItem> items;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    final type = WhisperType(touch: touch);
    final text = items
        .where((item) => item.isText)
        .map((item) => item.text.trim())
        .where((value) => value.isNotEmpty)
        .join('\n');
    final files = items.where((item) => !item.isText).toList(growable: false);
    final media = files
        .where((item) => item.isVisualMedia)
        .toList(growable: false);
    final others = files
        .where((item) => !item.isVisualMedia)
        .toList(growable: false);
    final hidden = others.length - QuickSendContentPreview.maxFileRows;
    final children = <Widget>[
      if (text.isNotEmpty)
        Container(
          key: const ValueKey('quick-send-text'),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(WhisperRadius.s),
          ),
          child: Text(
            // Long pastes only need enough to be recognised.
            text.length <= 500 ? text : text.substring(0, 500),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: type.note, height: 1.4, color: c.ink),
          ),
        ),
      if (media.isNotEmpty) QuickSendMediaStrip(items: media),
      for (final item in others.take(QuickSendContentPreview.maxFileRows))
        _FileRow(item: item, touch: touch),
      if (hidden > 0)
        Text(
          l10n.quickSendMoreFiles(hidden),
          style: TextStyle(fontSize: type.tiny, color: c.ink2),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, child) in children.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          child,
        ],
      ],
    );
  }
}

class _FileRow extends StatefulWidget {
  const _FileRow({required this.item, required this.touch});

  final QuickSendItem item;
  final bool touch;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  late Future<String?> _size = quickSendFileSizeText(widget.item);

  @override
  void didUpdateWidget(_FileRow old) {
    super.didUpdateWidget(old);
    if (old.item.source != widget.item.source ||
        old.item.size != widget.item.size) {
      _size = quickSendFileSizeText(widget.item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = WhisperType(touch: widget.touch);
    return Row(
      children: [
        const WhisperDocArt(size: 24),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            widget.item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: type.body, height: 1.3, color: c.ink),
          ),
        ),
        FutureBuilder<String?>(
          future: _size,
          builder: (context, snapshot) {
            final value = snapshot.data;
            if (value == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Text(
                value,
                style: TextStyle(fontSize: type.note, color: c.ink2),
              ),
            );
          },
        ),
      ],
    );
  }
}
