import 'package:flutter/material.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/folder_message.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/media_message_preview.dart'
    show MediaFileKind, mediaFileKindFor;
import 'package:whisper/widget/media_thumbnail.dart';

/// Pictures and videos count as sent together when each follows the last
/// within this many seconds.
const chatMediaPileGap = 2;

MediaFileKind? _pileKind(MessageData message) {
  if (message.type != MessageEnum.File || folderOfferOf(message) != null) {
    return null;
  }
  final kind = mediaFileKindFor(name: message.name, path: message.path);
  return kind == MediaFileKind.image || kind == MediaFileKind.video
      ? kind
      : null;
}

/// The pictures and videos the one at [index] was sent together with, as
/// indexes into [messages] from the first sent to the last, or null when it
/// stands alone. [messages] has the newest first.
List<int>? chatMediaPileAt(List<MessageData> messages, int index) {
  if (_pileKind(messages[index]) == null) return null;
  // Whether the message at [newer] followed straight on the one before it.
  bool follows(int newer) {
    if (newer < 0 || newer + 1 >= messages.length) return false;
    final later = messages[newer];
    final earlier = messages[newer + 1];
    final apart = later.timestamp - earlier.timestamp;
    return _pileKind(later) != null &&
        _pileKind(earlier) != null &&
        later.sender == earlier.sender &&
        later.receiver == earlier.receiver &&
        apart >= 0 &&
        apart <= chatMediaPileGap;
  }

  var first = index;
  while (follows(first)) {
    first++;
  }
  var last = index;
  while (follows(last - 1)) {
    last--;
  }
  if (first == last) return null;
  return [for (var i = first; i >= last; i--) i];
}

/// A pile in a conversation: the first message's own picture in front, the
/// ones sent with it behind, and the button beside them on the side away
/// from the edge the message sits against.
class ChatMediaPile extends StatelessWidget {
  const ChatMediaPile({
    super.key,
    required this.front,
    required this.behind,
    required this.gathered,
    required this.fromOther,
    required this.button,
  });

  final Widget front;

  /// The messages behind the first, in the order they were sent.
  final Iterable<MessageData> behind;
  final bool gathered;

  /// Whether the other device sent them: they sit against the left edge.
  final bool fromOther;
  final Widget? button;

  @override
  Widget build(BuildContext context) {
    final piled = Flexible(
      child: MediaPile(
        gathered: gathered,
        towardsStart: !fromOther,
        behind: [
          for (final other in behind.take(MediaPile.maxBehind))
            MediaThumbnail(
              source: other.path,
              kind: _pileKind(other) ?? MediaFileKind.image,
              icon: false,
            ),
        ],
        front: front,
      ),
    );
    final beside = button == null
        ? const SizedBox.shrink()
        : Padding(
            padding: EdgeInsets.only(
              left: fromOther ? 10 : 0,
              right: fromOther ? 0 : 10,
            ),
            child: button,
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: fromOther ? [piled, beside] : [beside, piled],
    );
  }
}

/// Pictures that came together, gathered into one pile: the first in front
/// at its own size, the next ones showing behind it at a slight angle.
/// Opened, the ones behind slide back out of sight.
class MediaPile extends StatelessWidget {
  const MediaPile({
    super.key,
    required this.front,
    required this.behind,
    this.gathered = true,
    this.towardsStart = false,
  });

  /// The picture in front.
  final Widget front;

  /// More of the pile, the nearest first. Each fills the size of [front];
  /// only the first [maxBehind] show.
  final List<Widget> behind;

  /// Whether the pile is gathered.
  final bool gathered;

  /// Whether the pile leans out to the left: a message of this device's,
  /// which sits against the right edge.
  final bool towardsStart;

  static const maxBehind = 2;

  /// How far each one behind is moved, turned and made smaller.
  static const _shift = 11.0;
  static const _turn = 0.045;
  static const _smaller = 0.04;

  /// The room the pile takes beside the front picture.
  static const lean = 22.0;

  @override
  Widget build(BuildContext context) {
    final shown = behind.take(maxBehind).toList(growable: false);
    final sign = towardsStart ? -1.0 : 1.0;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: gathered && shown.isNotEmpty ? 1 : 0),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, t, front) => Padding(
        padding: EdgeInsets.only(
          left: towardsStart ? lean * t : 0,
          right: towardsStart ? 0 : lean * t,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (t > 0)
              for (var depth = shown.length; depth >= 1; depth--)
                Positioned.fill(
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..translateByDouble(sign * _shift * depth * t, 0, 0, 1)
                      ..rotateZ(sign * _turn * depth * t)
                      ..scaleByDouble(
                        1 - _smaller * depth * t,
                        1 - _smaller * depth * t,
                        1,
                        1,
                      ),
                    child: Opacity(
                      opacity: t,
                      child: _Behind(depth: depth, child: shown[depth - 1]),
                    ),
                  ),
                ),
            front!,
          ],
        ),
      ),
      child: front,
    );
  }
}

/// One picture behind the front: cut to the same corners, and a little
/// darker the further back it is.
class _Behind extends StatelessWidget {
  const _Behind({required this.depth, required this.child});

  final int depth;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(WhisperRadius.m),
    child: IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            ColoredBox(color: Colors.black.withValues(alpha: 0.12 * depth)),
          ],
        ),
      ),
    ),
  );
}

/// The small button beside a pile: how many are in it, or to gather them
/// again.
class MediaPileButton extends StatelessWidget {
  const MediaPileButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final touch = !isDesktop();
    return Pressable(
      onTap: onTap,
      radius: 999,
      child: Container(
        height: touch ? 34 : 26,
        padding: EdgeInsets.symmetric(horizontal: touch ? 14 : 11),
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: WhisperType(touch: touch).note,
              height: 1.2,
              color: c.ink2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}
