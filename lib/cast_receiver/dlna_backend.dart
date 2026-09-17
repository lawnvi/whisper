import 'package:whisper/helper/local.dart';

import 'dlna_receiver.dart';
import 'player.dart';
import 'receiver_backend.dart';
import 'request_gate.dart';

class DlnaBackend extends ReceiverBackend {
  DlnaReceiver? _receiver;
  final CastPlayer _player = CastPlayer.shared;

  @override
  Future<void> start(CastReceiverEndpoint? endpoint) async {
    if (endpoint == null) {
      update(
        CastReceiverState.unavailable,
        issue: CastReceiverIssue.noLanAddress,
      );
      return;
    }
    update(CastReceiverState.starting);
    try {
      _player.activate();
      CastRequestGate.shared.open();
      _receiver = DlnaReceiver(
        _player,
        endpoint.$1,
        endpoint.$2,
        name: await LocalSetting().castReceiverName(),
        requests: CastRequestGate.shared,
      );
      await _receiver!.start();
      update(CastReceiverState.running);
    } on Object {
      await stop();
      update(CastReceiverState.failed, issue: CastReceiverIssue.startupFailed);
    }
  }

  @override
  void updateName(String name) => _receiver?.rename(name);

  @override
  Future<void> stop() async {
    CastRequestGate.shared.close();
    final receiver = _receiver;
    _receiver = null;
    try {
      await receiver?.close();
    } finally {
      await _player.close();
      update(CastReceiverState.stopped);
    }
  }
}
