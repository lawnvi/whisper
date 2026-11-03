import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:whisper/theme/whisper_ui.dart' show whisperNewUi;
import 'package:whisper/widget/island/island_center.dart';

/// The things on screen that show an activity themselves.
abstract final class IslandHomes {
  /// A file card in a conversation, with its progress on it.
  static String message(String uuid) => 'message:$uuid';

  static const sound = 'sound';
  static const input = 'input';

  /// The list of file copies.
  static const transfers = 'transfers';
}

/// docs/design/surfaces.md「灵动岛」: the island is for what cannot be seen. While
/// [child] is on screen the island leaves activities with this [home] to it.
/// A tab kept behind another, a page under another, a card scrolled out of its
/// list: none of those count, and the island comes back for them.
class IslandHome extends StatefulWidget {
  const IslandHome({
    super.key,
    required this.home,
    required this.child,
    this.center,
  });

  final String home;
  final Widget child;

  /// The app's island by default.
  final IslandCenter? center;

  @override
  State<IslandHome> createState() => _IslandHomeState();
}

class _IslandHomeState extends State<IslandHome> {
  IslandCenter get _center => widget.center ?? IslandCenter.shared;
  String? _marked;
  bool _disposed = false;

  void _update(bool onScreen) {
    // Not in the middle of a build: the island redraws when this changes.
    scheduleMicrotask(() {
      if (_disposed) return;
      final wanted = onScreen ? widget.home : null;
      if (wanted == _marked) return;
      final center = _center;
      if (_marked case final old?) center.leaveHome(old);
      if (wanted != null) center.enterHome(wanted);
      _marked = wanted;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!whisperNewUi && widget.center == null) return;
    _update(
      TickerMode.of(context) && (ModalRoute.of(context)?.isCurrent ?? true),
    );
  }

  @override
  void didUpdateWidget(IslandHome old) {
    super.didUpdateWidget(old);
    if (old.home != widget.home && _marked != null) _update(true);
  }

  @override
  void dispose() {
    _disposed = true;
    final marked = _marked;
    if (marked != null) {
      final center = _center;
      scheduleMicrotask(() => center.leaveHome(marked));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
