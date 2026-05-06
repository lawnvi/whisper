import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  test('peer profile round-trips remote input topology capability and displays',
      () {
    final profile = PeerProfile(
      device: DeviceData(
        id: 1,
        uid: 'peer-a',
        name: 'Peer A',
        host: '127.0.0.1',
        port: 9000,
        password: '',
        platform: 'macos',
        isServer: true,
        online: true,
        clipboard: true,
        auth: true,
        lastTime: 1,
        around: true,
      ),
      trustedPeerIds: const <String>['peer-b'],
      autoApproveNewDevices: false,
      autoConnectEnabled: true,
      protocolVersion: 4,
      capabilities: const PeerCapabilities(
        remoteInputSourceV1: true,
        remoteInputSinkV1: true,
        remoteInputTopologyV1: true,
      ),
      displayTopology: const RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1234,
        displays: [
          RemoteInputDisplay(
            displayId: 'main',
            name: 'Built-in',
            x: 0,
            y: 0,
            width: 1440,
            height: 900,
            scale: 2,
            isPrimary: true,
          ),
        ],
      ),
    );

    final decoded = PeerProfile.fromJson(profile.toJson());

    expect(decoded.capabilities.remoteInputTopologyV1, isTrue);
    expect(decoded.displayTopology?.platform, 'macos');
    expect(decoded.displayTopology?.primaryDisplay.displayId, 'main');
  });
}
