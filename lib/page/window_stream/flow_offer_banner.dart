import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../helper/device_form_factor.dart';
import '../../helper/island_asks.dart';
import '../../helper/notification.dart';
import '../../helper/notification_l10n.dart';
import '../../helper/toast.dart';
import '../../l10n/app_localizations.dart';
import '../../widget/device_glyph.dart';
import '../../widget/island/island_activity.dart';
import '../../widget/island/island_host.dart';
import '../../widget/island/island_views.dart';
import '../../window_stream/core/window_stream_models.dart';
import '../../window_stream/remote/remote_peer_source.dart';
import '../../window_stream/window_stream_coordinator.dart';
import 'flow_open.dart';
import 'flow_space_theme.dart';
import 'flow_space_widgets.dart';

export '../../widget/island/island_host.dart' show IslandHost;

/// Windows other devices send here ("送出去") are one kind of activity on the
/// app's island ([IslandHost]), with file copies, transfers, the speaker and
/// this phone being streamed. This name stays for callers that still mount
/// the island by it; new code uses [IslandHost].
class WindowOfferHost extends StatelessWidget {
  const WindowOfferHost({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) =>
      IslandHost(navigatorKey: navigatorKey, child: child);
}

/// Windows other devices send here ("送出去"): each one arrives as the
/// small island and swells into a card with the window, "忽略" and "查看",
/// settles back after a while, then waits a little and lets go (the window
/// stays in that device's window bar). In the background a notification
/// goes out instead, and the card opens when the app comes back.
class OfferIslandSource extends ChangeNotifier implements IslandSource {
  OfferIslandSource({
    WindowStreamViewer? viewer,
    bool Function()? inForeground,
    Future<void> Function(String title, String body)? notify,
    Future<void> Function()? cancelNotification,
    IslandAsks? asks,
  }) : _viewer = viewer ?? WindowStreamViewer.shared,
       _inForeground = inForeground ?? _appInForeground,
       _notify = notify ?? _postNotification,
       _cancelNotification = cancelNotification ?? _removeNotification,
       _asks =
           asks ??
           (notify == null && Platform.isAndroid ? IslandAsks.shared : null) {
    _viewer.offers.addListener(_onOffers);
    _known.addAll(_viewer.offers.value);
  }

  /// Its own notification: the file-browse question and the "being
  /// streamed" notification (7301) keep theirs.
  static const notificationId = 7302;

  static const openFor = Duration(seconds: 8);
  static const waitsFor = Duration(seconds: 12);

  final WindowStreamViewer _viewer;
  final bool Function() _inForeground;
  final Future<void> Function(String title, String body) _notify;
  final Future<void> Function() _cancelNotification;

  /// On Android the window goes on the island over other apps, "忽略" and
  /// "查看" right there (and on the system's island, as a live update).
  final IslandAsks? _asks;

  /// Where "查看" opens the window.
  GlobalKey<NavigatorState>? navigatorKey;

  final _known = <WindowOffer>{};
  final _ids = Expando<String>();
  WindowOffer? _notified;
  int _next = 0;
  bool _opening = false;

  static bool _appInForeground() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  static Future<void> _postNotification(String title, String body) =>
      NotificationHelper().showNotification(
        title: title,
        body: body,
        id: notificationId,
      );

  static Future<void> _removeNotification() =>
      NotificationHelper().cancelNotification(notificationId);

  String _idOf(WindowOffer offer) => _ids[offer] ??= 'offer:${_next++}';

  static String titleOf(WindowOffer offer) {
    final window = offer.window;
    return window.title.isEmpty ? window.appName : window.title;
  }

  @override
  List<IslandActivity> get activities => [
    for (final offer in _viewer.offers.value)
      IslandActivity(
        id: _idOf(offer),
        kind: IslandKind.offer,
        status: IslandStatus.live,
        since: offer.receivedAt,
        openFor: openFor,
        waitsFor: waitsFor,
        urgent: true,
        presenter: OfferPresenter(
          id: _idOf(offer),
          offer: offer,
          onView: () => unawaited(open(offer)),
          onIgnore: () => settle(offer),
        ),
      ),
  ];

  void _onOffers() {
    final offers = _viewer.offers.value;
    final notified = _notified;
    if (notified != null && !offers.contains(notified)) {
      // Opened, dismissed or gone with its device: the notification too.
      _notified = null;
      final asks = _asks;
      if (asks != null) {
        unawaited(asks.settle(_idOf(notified)));
      } else {
        unawaited(_cancelNotification().catchError((Object _) {}));
      }
    }
    final fresh = offers.where((offer) => !_known.contains(offer)).toList();
    _known
      ..retainWhere(offers.contains)
      ..addAll(offers);
    if (fresh.isNotEmpty && !_inForeground()) {
      final newest = fresh.first;
      final l10n = resolveNotificationL10n();
      final previous = _notified;
      _notified = newest;
      final asks = _asks;
      if (asks != null) {
        if (previous != null) {
          unawaited(asks.settle(_idOf(previous)));
        }
        unawaited(
          asks.ask(
            id: _idOf(newest),
            glyph: 'window',
            title: l10n.windowStreamOfferTitle(newest.source.info.name),
            text: titleOf(newest),
            figure: newest.window.appName,
            platform: newest.source.info.platform.name,
            buttons: [
              IslandAskButton('ignore', l10n.windowStreamOfferIgnore),
              IslandAskButton(
                IslandAsks.open,
                l10n.windowStreamOfferView,
                role: 'primary',
              ),
            ],
            channelName: l10n.notificationChannelRequests,
            onAnswer: (button) {
              if (!_viewer.offers.value.contains(newest)) {
                return;
              }
              if (button == 'ignore') {
                settle(newest);
              } else {
                unawaited(open(newest));
              }
            },
          ),
        );
      } else {
        unawaited(
          _notify(
            l10n.windowStreamOfferTitle(newest.source.info.name),
            titleOf(newest),
          ).catchError((Object _) {}),
        );
      }
    }
    notifyListeners();
  }

  void settle(WindowOffer offer) => _viewer.settleOffer(offer);

  WindowOffer? _offerOf(String id) {
    for (final offer in _viewer.offers.value) {
      if (_ids[offer] == id) {
        return offer;
      }
    }
    return null;
  }

  /// Opens [offer] like any other window of that device.
  Future<void> open(WindowOffer offer) async {
    if (_opening) {
      return;
    }
    _opening = true;
    _viewer.settleOffer(offer);
    final navigator = navigatorKey?.currentState;
    try {
      if (navigator != null) {
        // Not awaited past the open: the page stays up while it is viewed.
        unawaited(
          openFlowWindow(navigator, offer.source, offer.target).then<void>(
            (_) {},
            onError: (Object error) {
              final context = navigator.context;
              final l10n = context.mounted
                  ? AppLocalizations.of(context)
                  : null;
              if (l10n != null) {
                showAppToast(
                  error is WindowStreamFailure
                      ? flowFailureText(l10n, error.reason)
                      : l10n.windowStreamOpenFailed,
                  tone: AppToastTone.error,
                );
              }
            },
          ),
        );
        await WindowStreamCoordinator.shared.start();
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Stream<String> get spotlights => const Stream<String>.empty();

  @override
  void retired(String id) {}

  @override
  void dismissed(IslandActivity activity) {
    final offer = _offerOf(activity.id);
    if (offer != null) {
      settle(offer);
    }
  }

  @override
  void expired(IslandActivity activity) => dismissed(activity);

  @override
  void dispose() {
    _viewer.offers.removeListener(_onOffers);
    super.dispose();
  }
}

class OfferPresenter extends IslandPresenter {
  const OfferPresenter({
    required this.id,
    required this.offer,
    required this.onView,
    required this.onIgnore,
  });

  final String id;
  final WindowOffer offer;
  final VoidCallback onView;
  final VoidCallback onIgnore;

  String get _title => OfferIslandSource.titleOf(offer);

  IconData get _glyph => flowDeviceGlyph(
    offer.source.info.platform,
    tablet: DeviceFormFactors.shared.isTablet(offer.source.peerId),
  );

  @override
  Widget compact(BuildContext context) {
    return IslandCompactLine(
      leading: OfferAppIcon(offer: offer, size: 22, radius: 6),
      title: _title,
      trailing: DeviceGlyph(_glyph, size: 16, color: FlowSpaceTokens.live),
    );
  }

  @override
  Widget glyph(BuildContext context, double size) =>
      OfferAppIcon(offer: offer, size: size, radius: size * 0.27);

  void _view() {
    HapticFeedback.selectionClick();
    onView();
  }

  @override
  Widget featured(BuildContext context, IslandControls controls) {
    final l10n = AppLocalizations.of(context)!;
    final picture = offer.thumbnail;
    final dim = Colors.white.withValues(alpha: 0.55);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tapping the window itself opens it, as before.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _view,
            child: Row(
              children: [
                OfferAppIcon(offer: offer, size: 46, radius: 12),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          DeviceGlyph(_glyph, size: 13, color: dim),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              l10n.windowStreamOfferFrom(
                                offer.source.info.name,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: dim,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
                if (picture != null) ...[
                  const SizedBox(width: 12),
                  DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: ShapeDecoration(
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(9),
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.14),
                          width: 0.5,
                        ),
                      ),
                    ),
                    child: ClipRSuperellipse(
                      borderRadius: BorderRadius.circular(9),
                      child: Image.memory(
                        picture,
                        width: 70,
                        height: 46,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: IslandCapsuleButton(
                  label: l10n.windowStreamOfferIgnore,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onIgnore();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: IslandCapsuleButton(
                  label: l10n.windowStreamOfferView,
                  background: Colors.white,
                  foreground: Colors.black,
                  onPressed: onView,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget row(BuildContext context, IslandControls controls) {
    final l10n = AppLocalizations.of(context)!;
    return IslandRowLine(
      leading: OfferAppIcon(offer: offer, size: 22, radius: 6),
      title: _title,
      status: l10n.windowStreamOfferFrom(offer.source.info.name),
      onTap: () => controls.feature(id),
      trailing: IslandCapsuleButton(
        label: l10n.windowStreamOfferView,
        background: Colors.white,
        foreground: Colors.black,
        height: 28,
        onPressed: onView,
      ),
    );
  }

  @override
  String describe(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return '${l10n.windowStreamOfferTitle(offer.source.info.name)}, $_title';
  }
}

/// The window's app, or a plain window when its icon is not known.
class OfferAppIcon extends StatelessWidget {
  const OfferAppIcon({
    super.key,
    required this.offer,
    required this.size,
    required this.radius,
  });

  final WindowOffer offer;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final icon = offer.icon;
    if (icon != null) {
      return Image.memory(
        icon,
        width: size,
        height: size,
        gaplessPlayback: true,
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: IslandColors.tile,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      child: Icon(
        CupertinoIcons.macwindow,
        size: size * 0.55,
        color: Colors.white70,
      ),
    );
  }
}
