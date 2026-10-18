import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../helper/toast.dart';
import '../../l10n/app_localizations.dart';
import '../../window_stream/core/window_stream_models.dart';
import '../../window_stream/remote/remote_peer_source.dart';
import '../../window_stream/window_stream_coordinator.dart';
import 'flow_open.dart';

/// Desktops: a window another device sends here ("送到") opens at once in
/// a window of its own, as if it had been opened from here. Sending it is
/// already the other person's "show it over there"; the window's own close
/// button turns it away. Phones ask first, on the island
/// (`OfferIslandSource`), because a window there takes the whole screen.
class DesktopOfferOpener {
  DesktopOfferOpener._();

  static final DesktopOfferOpener shared = DesktopOfferOpener._();

  WindowStreamViewer? _viewer;
  WindowStreamCoordinator _streams = WindowStreamCoordinator.shared;
  final _seen = <WindowOffer>{};

  void start({WindowStreamViewer? viewer, WindowStreamCoordinator? streams}) {
    if (_viewer != null) {
      return;
    }
    _streams = streams ?? WindowStreamCoordinator.shared;
    final registry = _viewer = viewer ?? WindowStreamViewer.shared;
    registry.offers.addListener(_onOffers);
    _onOffers();
  }

  void _onOffers() {
    final viewer = _viewer;
    if (viewer == null) {
      return;
    }
    final fresh = [
      for (final offer in viewer.offers.value)
        if (_seen.add(offer)) offer,
    ];
    for (final offer in fresh) {
      viewer.settleOffer(offer);
      unawaited(_open(offer));
    }
    _seen.retainWhere(viewer.offers.value.contains);
  }

  Future<void> _open(WindowOffer offer) async {
    // Sent twice, or already open here: that window comes forward instead.
    for (final session in _streams.sessionsFor(offer.source)) {
      final handle = session.handle;
      if (!session.state.isTerminal &&
          handle is RemoteStreamHandle &&
          handle.window.id == offer.window.id) {
        _streams.focus(session);
        return;
      }
    }
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) {
      return;
    }
    try {
      await openFlowWindow(
        navigator,
        offer.source,
        offer.target,
        coordinator: _streams,
      );
    } catch (error) {
      final context = navigator.context;
      final l10n = context.mounted ? AppLocalizations.of(context) : null;
      if (l10n == null) {
        return;
      }
      showAppToast(
        error is WindowStreamFailure
            ? flowFailureText(l10n, error.reason, source: offer.source)
            : l10n.windowStreamOpenFailed,
        tone: AppToastTone.error,
      );
    }
  }
}
