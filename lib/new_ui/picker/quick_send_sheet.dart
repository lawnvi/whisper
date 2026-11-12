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
import 'package:whisper/widget/media_message_preview.dart' show MediaFileKind;
import 'package:whisper/widget/media_pile.dart';
import 'package:whisper/widget/media_thumbnail.dart';
import 'package:whisper/widget/quick_send_chooser.dart';
import 'package:whisper/state/peer_aliases.dart';

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
    formFactor: DeviceFormFactors.shared.formFactorOf(target.id),
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
                name: PeerAliases.shared.labelOf(target.id, target.name),
                kind: _kind(target),
                os: deviceOsFor(target.platform),
                checked: target.id == marked,
              ),
              onTap: () => Navigator.of(context).pop(target.id),
            ),
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!touch) ...[
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
            // What is going, in the middle; then where to.
            _QuickSendPreview(items: widget.items, touch: touch),
            const SizedBox(height: 14),
            if (touch)
              DevicePickerTitle(_title(), centered: true)
            else
              ShellGroupLabel(_title()),
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

/// The text, the pictures and the files waiting to go, in the middle of the
/// sheet: one picture large, several as the pile a conversation shows them
/// in, a single file as its icon. Several files are a short list.
class _QuickSendPreview extends StatelessWidget {
  const _QuickSendPreview({required this.items, required this.touch});

  final List<QuickSendItem> items;
  final bool touch;

  static const _maxFileRows = 3;

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
    // A file by itself needs no row: its name is in the title under it.
    final lone = media.isEmpty && others.length == 1 ? others.single : null;
    final hidden = others.length - _maxFileRows;
    final side = touch ? 128.0 : 104.0;
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
      if (media.isNotEmpty)
        Center(
          key: const ValueKey('quick-send-media'),
          child: Padding(
            // The pile leans out to the right; the front one stays centred.
            padding: EdgeInsets.only(
              left: media.length > 1 ? MediaPile.lean : 0,
            ),
            child: MediaPile(
              behind: [
                for (final item in media.skip(1))
                  MediaThumbnail(
                    source: item.source,
                    kind: item.kind,
                    icon: false,
                  ),
              ],
              front: SizedBox.square(
                dimension: side,
                child: _MediaCard(item: media.first),
              ),
            ),
          ),
        ),
      if (lone != null)
        _LoneFile(item: lone, touch: touch)
      else ...[
        for (final item in others.take(_maxFileRows))
          _FileRow(item: item, touch: touch),
        if (hidden > 0)
          Text(
            l10n.quickSendMoreFiles(hidden),
            style: TextStyle(fontSize: type.tiny, color: c.ink2),
          ),
      ],
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

/// A picture or a video about to go, with the mark of a video on it.
class _MediaCard extends StatelessWidget {
  const _MediaCard({required this.item});

  final QuickSendItem item;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(WhisperRadius.m),
    child: Stack(
      fit: StackFit.expand,
      children: [
        MediaThumbnail(source: item.source, kind: item.kind, name: item.name),
        if (item.kind == MediaFileKind.video)
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Radix.blackA6,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                size: 17,
                color: Colors.white,
              ),
            ),
          ),
      ],
    ),
  );
}

/// The only file about to go: its icon, and how big it is.
class _LoneFile extends StatelessWidget {
  const _LoneFile({required this.item, required this.touch});

  final QuickSendItem item;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final type = WhisperType(touch: touch);
    return Column(
      key: const ValueKey('quick-send-file'),
      mainAxisSize: MainAxisSize.min,
      children: [
        WhisperDocArt(size: touch ? 52 : 44),
        FutureBuilder<String?>(
          future: quickSendFileSizeText(item),
          builder: (context, snapshot) {
            final value = snapshot.data;
            if (value == null) return const SizedBox(height: 4);
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                value,
                style: TextStyle(fontSize: type.note, color: context.wc.ink2),
              ),
            );
          },
        ),
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
