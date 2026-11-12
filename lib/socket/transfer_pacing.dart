import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/remote_input/remote_input_activity.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/socket/transfer_pacer.dart';

/// Which pacer an outgoing transfer goes through. A paste's files always give
/// way: they are sent while keyboard and mouse are in use. Any other transfer
/// gives way while something live shares the link ([liveTrafficOnLink]), and
/// otherwise only keeps its frames short on a slow link.
final class TransferPacing {
  TransferPacing({
    required bool Function(String transferId) isClipboard,
    bool Function()? live,
    bool Function()? busy,
  }) : _isClipboard = isClipboard,
       _live = live ?? liveTrafficOnLink,
       _busy = busy ?? inputGoingOverLink;

  /// The app's: transfers give way to its sound, keyboard and mouse. A
  /// manager without the app's coordinators (tests) has nothing live.
  factory TransferPacing.forApp({required bool withCoordinators}) =>
      TransferPacing(
        isClipboard: TransferPlacements.shared.isEphemeral,
        live: withCoordinators ? null : () => false,
        busy: withCoordinators ? null : () => false,
      );

  final bool Function(String transferId) _isClipboard;
  final bool Function() _live;
  final bool Function() _busy;

  late final TransferPacer clipboard = TransferPacer(busy: _busy);
  late final TransferPacer general = TransferPacer(
    active: _live,
    busy: _busy,
    report: _log,
  );

  TransferPacer forTransfer(String transferId) =>
      _isClipboard(transferId) ? clipboard : general;
}

/// Whether a key or the pointer went to another device or came from one in
/// the last two seconds: the pointer is in someone's hand.
bool inputGoingOverLink() =>
    RemoteInputActivity.within(const Duration(seconds: 2));

/// What the pacer is doing, every few seconds while something live shares
/// the link, for telling why the pointer lagged from the log.
void _log(TransferPacerLook look) =>
    privacyLog.event(PrivacyEvent.transferPacing, {
      PrivacyField.mode: look.mode,
      PrivacyField.rateKb: look.rate.isFinite ? (look.rate / 1000).round() : -1,
      PrivacyField.linkKb: ((look.link ?? 0) / 1000).round(),
      PrivacyField.sentKb: look.taken ~/ 1000,
      PrivacyField.confirmedKb: look.confirmed ~/ 1000,
      PrivacyField.frames: look.frames,
      PrivacyField.busy: look.busy,
      PrivacyField.loopLagMs: look.lag.inMilliseconds,
      PrivacyField.lateMaxMs: look.wake.inMilliseconds,
    });

/// Whether something live shares the link now: the pointer on another
/// device or this one controlled from elsewhere, or sound going either way.
bool liveTrafficOnLink() =>
    RemoteInputWorkspaceCoordinator.shared.snapshot.status ==
        RemoteInputWorkspaceStatus.active ||
    RemoteInputCoordinator.shared.state.isActive ||
    AudioGroupCoordinator.shared.hasLiveSession ||
    AudioGroupCoordinator.shared.isPlaybackActive;
