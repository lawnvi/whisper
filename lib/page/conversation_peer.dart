import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';

/// The device a conversation is with, as stored: this device itself for
/// 本机, else the stored row, which knows more than the one that was tapped.
DeviceData resolveConversationDeviceSnapshot({
  required DeviceData localDevice,
  required DeviceData selectedDevice,
  required DeviceData? storedDevice,
}) {
  if (localDevice.uid == selectedDevice.uid) {
    return localDevice;
  }
  return storedDevice ?? selectedDevice;
}

/// Where [device] sits for keyboard and mouse sharing: what was saved, or a
/// screen to the right of this one, saved for next time.
Future<RemoteInputLayoutData> remoteInputLayoutFor(DeviceData device) async {
  final saved = await LocalDatabase().fetchRemoteInputLayout(device.uid);
  if (saved != null) {
    return saved;
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  final layout = RemoteInputLayoutData(
    peerId: device.uid,
    peerName: device.label,
    x: 1000,
    y: 0,
    width: 900,
    height: 600,
    enabled: true,
    autoActivate: false,
    autoRole: RemoteInputAutoRole.source.name,
    layoutVersion: 1,
    layoutJson: '',
    edgeThresholdPx: 6,
    releaseHotkey: 'ctrl+alt+esc',
    updatedAt: now,
  );
  await LocalDatabase().upsertRemoteInputLayout(layout);
  return layout;
}
