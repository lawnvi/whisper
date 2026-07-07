import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  test('audioGroupRejoinV1 capability roundtrips and defaults to false', () {
    const caps = PeerCapabilities(audioGroupRejoinV1: true);
    final decoded = PeerCapabilities.fromJson(caps.toJson());
    expect(decoded.audioGroupRejoinV1, isTrue);
    expect(const PeerCapabilities().audioGroupRejoinV1, isFalse);
    expect(
      PeerCapabilities.fromJson(<String, dynamic>{}).audioGroupRejoinV1,
      isFalse,
    );
  });
}
