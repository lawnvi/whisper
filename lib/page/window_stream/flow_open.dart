import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

import '../../window_stream/android/window_activity.dart';
import '../../window_stream/core/window_source.dart';
import '../../window_stream/core/window_stream_models.dart';
import '../../window_stream/window_stream_coordinator.dart';
import 'flow_space_theme.dart';
import 'flow_window_viewer_page.dart';

/// Opens [target] of [source] and, where windows live in Flutter (phones,
/// tablets), shows it full screen with the space's zoom-in transition.
/// Desktops get a native window and nothing is pushed.
Future<WindowStreamSession> openFlowWindow(
  NavigatorState navigator,
  WindowSource source,
  OpenTarget target, {
  WindowStreamCoordinator? coordinator,
}) async {
  final streams = coordinator ?? WindowStreamCoordinator.shared;
  await streams.start();
  final session = await streams.open(source, target);
  if (!session.flutterHosted) {
    return session;
  }
  // A Mac window on Android: a task of its own, in landscape, in recents.
  if (NativeWindowActivity.supports(session) &&
      await NativeWindowActivity.open(session, coordinator: streams)) {
    return session;
  }
  if (navigator.mounted) {
    await navigator.push(flowWindowRoute(session));
  }
  return session;
}

/// What to tell the user when a window can't be opened. Pass the [source]
/// the window came from so the advice names it and fits its platform
/// ("log out and in on ‹device›", a Mac's privacy settings…).
String flowFailureText(
  AppLocalizations l10n,
  WindowStreamFailureReason reason, {
  WindowSource? source,
}) {
  return windowStreamFailureText(
    l10n,
    reason,
    platform: source?.info.platform,
    device: source?.info.name ?? '',
  );
}

/// The viewer page, growing out of where it was opened.
Route<void> flowWindowRoute(WindowStreamSession session) {
  return PageRouteBuilder<void>(
    transitionDuration: FlowSpaceTokens.springDuration,
    reverseTransitionDuration: FlowSpaceTokens.quickDuration,
    pageBuilder: (context, animation, _) =>
        FlowWindowViewerPage(session: session),
    transitionsBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: const SpringCurve(),
      );
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}
