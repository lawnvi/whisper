import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/auth_request_gate.dart';

void main() {
  group('AuthRequestGate', () {
    test('deduplicates incoming auth prompts per peer until released', () {
      final gate = AuthRequestGate();

      expect(gate.tryClaimIncoming('peer-a'), isTrue);
      expect(gate.tryClaimIncoming('peer-a'), isFalse);
      expect(gate.tryClaimIncoming('peer-b'), isTrue);

      gate.releaseIncoming('peer-a');

      expect(gate.tryClaimIncoming('peer-a'), isTrue);
    });

    test('deduplicates outgoing auth attempts per request key until released',
        () {
      final gate = AuthRequestGate();

      expect(gate.tryClaimOutgoing('peer-a'), isTrue);
      expect(gate.tryClaimOutgoing('peer-a'), isFalse);
      expect(gate.tryClaimOutgoing('192.168.1.8:10002'), isTrue);

      gate.releaseOutgoing('peer-a');

      expect(gate.tryClaimOutgoing('peer-a'), isTrue);
    });

    test('hasOutgoing reflects claim lifecycle', () {
      final gate = AuthRequestGate();
      expect(gate.hasOutgoing('peer:abc'), isFalse);
      expect(gate.tryClaimOutgoing('peer:abc'), isTrue);
      expect(gate.hasOutgoing('peer:abc'), isTrue);
      expect(gate.hasOutgoing(' peer:abc '), isTrue); // trim 一致
      gate.releaseOutgoing('peer:abc');
      expect(gate.hasOutgoing('peer:abc'), isFalse);
      expect(gate.hasOutgoing(''), isFalse);
    });
  });
}
