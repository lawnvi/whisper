import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../helper/android_privacy_permission.dart';

/// Whether the island over other apps (Android) is needed and allowed,
/// read again whenever the app comes back (from the system page that
/// allows it, say). Builds nothing where it is not needed.
class IslandOverlaySetting extends StatefulWidget {
  const IslandOverlaySetting({
    super.key,
    required this.builder,
    this.read = AndroidPrivacyPermission.islandOverlay,
  });

  final Widget Function(BuildContext context, bool allowed) builder;
  final Future<({bool needed, bool allowed})> Function() read;

  @override
  State<IslandOverlaySetting> createState() => _IslandOverlaySettingState();
}

class _IslandOverlaySettingState extends State<IslandOverlaySetting> {
  late final AppLifecycleListener _lifecycle;
  var _needed = false;
  var _allowed = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_refresh()));
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final state = await widget.read();
    if (mounted) {
      setState(() {
        _needed = state.needed;
        _allowed = state.allowed;
      });
    }
  }

  @override
  Widget build(BuildContext context) =>
      _needed ? widget.builder(context, _allowed) : const SizedBox.shrink();
}
