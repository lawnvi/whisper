import 'package:flutter/widgets.dart';

import '../../page/window_stream/flow_offer_banner.dart';
import '../../remote_files/fs_copies.dart';
import 'island_center.dart';
import 'sources/audio_source.dart';
import 'sources/copy_source.dart';
import 'sources/streamed_source.dart';
import 'sources/transfer_source.dart';

/// Puts every kind of activity on the app's island, once.
abstract final class IslandSetup {
  static OfferIslandSource? _offers;

  /// The app's island with all its sources; [navigatorKey] opens windows
  /// sent here.
  static IslandCenter install(GlobalKey<NavigatorState> navigatorKey) {
    final center = IslandCenter.shared;
    final offers = _offers;
    if (offers != null) {
      offers.navigatorKey = navigatorKey;
      return center;
    }
    _offers = OfferIslandSource()..navigatorKey = navigatorKey;
    center
      ..addSource(_offers!)
      ..addSource(StreamedIslandSource())
      ..addSource(CopyIslandSource(FileCopies.shared))
      ..addSource(TransferIslandSource())
      ..addSource(AudioIslandSource());
    return center;
  }
}
