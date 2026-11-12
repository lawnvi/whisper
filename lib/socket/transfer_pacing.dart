import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/remote_input/remote_input_activity.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/socket/link_delay.dart';
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
    LinkDelay? delay,
  }) : _isClipboard = isClipboard,
       _live = live ?? liveTrafficOnLink,
       _busy = busy ?? inputGoingOverLink,
       _delay = delay;

  /// The app's: transfers give way to its sound, keyboard and mouse. A
  /// manager without the app's coordinators (tests) has nothing live.
  factory TransferPacing.forApp({required bool withCoordinators}) =>
      TransferPacing(
        isClipboard: TransferPlacements.shared.isEphemeral,
        live: withCoordinators ? null : () => false,
        busy: withCoordinators ? null : () => false,
        delay: withCoordinators ? LinkDelay.shared : null,
      );

  final bool Function(String transferId) _isClipboard;
  final bool Function() _live;
  final bool Function() _busy;

  /// How long the keyboard and mouse datagrams wait, where they can say.
  final LinkDelay? _delay;

  late final TransferPacer clipboard = TransferPacer(
    busy: _busy,
    queueing: _delay?.queueing,
    probe: _delay == null ? null : (wanted) => _delay.want(#clipboard, wanted),
  );
  late final TransferPacer general = TransferPacer(
    active: _live,
    busy: _busy,
    queueing: _delay?.queueing,
    probe: _delay == null ? null : (wanted) => _delay.want(#general, wanted),
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
      if (look.queue != null) PrivacyField.queueMs: look.queue!.inMilliseconds,
    });

/// Whether something live shares the link now: keyboard and mouse shared
/// with another device, either way, or sound going either way.
///
/// Shared, not only in use: the pointer may cross at any moment, and a
/// transfer that went unheld until then has filled the link. It counted
/// what the link carries for the next seconds before it held back, and the
/// pointer lagged all the while.
bool liveTrafficOnLink() {
  final workspace = RemoteInputWorkspaceCoordinator.shared.snapshot.status;
  final runtime = RemoteInputCoordinator.shared.state.status;
  return workspace == RemoteInputWorkspaceStatus.armed ||
      workspace == RemoteInputWorkspaceStatus.active ||
      runtime == RemoteInputRuntimeStatus.armed ||
      runtime == RemoteInputRuntimeStatus.active ||
      AudioGroupCoordinator.shared.hasLiveSession ||
      AudioGroupCoordinator.shared.isPlaybackActive;
}
