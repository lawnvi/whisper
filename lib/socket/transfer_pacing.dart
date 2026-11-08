import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/remote_files/fs_placement.dart';
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
    bool Function()? audioStrained,
  }) : _isClipboard = isClipboard,
       _live = live ?? liveTrafficOnLink,
       _audioStrained =
           audioStrained ?? (() => AudioGroupCoordinator.shared.audioStrained);

  /// The app's: transfers give way to its sound, keyboard and mouse. A
  /// manager without the app's coordinators (tests) has nothing live.
  factory TransferPacing.forApp({required bool withCoordinators}) =>
      TransferPacing(
        isClipboard: TransferPlacements.shared.isEphemeral,
        live: withCoordinators ? null : () => false,
        audioStrained: withCoordinators ? null : () => false,
      );

  final bool Function(String transferId) _isClipboard;
  final bool Function() _live;
  final bool Function() _audioStrained;

  late final TransferPacer clipboard = TransferPacer(
    audioStrained: _audioStrained,
  );
  late final TransferPacer general = TransferPacer(
    audioStrained: _audioStrained,
    active: _live,
  );

  TransferPacer forTransfer(String transferId) =>
      _isClipboard(transferId) ? clipboard : general;
}

/// Whether something live shares the link now: the pointer on another
/// device or this one controlled from elsewhere, or sound going either way.
bool liveTrafficOnLink() =>
    RemoteInputWorkspaceCoordinator.shared.snapshot.status ==
        RemoteInputWorkspaceStatus.active ||
    RemoteInputCoordinator.shared.state.isActive ||
    AudioGroupCoordinator.shared.hasLiveSession ||
    AudioGroupCoordinator.shared.isPlaybackActive;
