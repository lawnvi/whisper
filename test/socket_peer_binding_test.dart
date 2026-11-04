import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/wire_input_policy.dart';

void main() {
  test('session binding rejects a socket replaced by a newer generation', () {
    expect(
      WireInputPolicy.validateSessionBinding(
        isAuthenticated: true,
        sessionPeerId: 'peer-a',
        sinkPeerId: 'peer-a',
        sessionGeneration: 7,
        isCurrentSession: true,
        isCurrentConnection: true,
      ).isAccepted,
      isTrue,
    );
    expect(
      WireInputPolicy.validateSessionBinding(
        isAuthenticated: true,
        sessionPeerId: 'peer-a',
        sinkPeerId: 'peer-a',
        sessionGeneration: 7,
        isCurrentSession: false,
        isCurrentConnection: false,
      ).reason,
      WireInputReason.sessionNotCurrent,
    );
  });
}
