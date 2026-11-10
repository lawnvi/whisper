import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_group_lane.dart';
import 'package:whisper/audio/audio_packet_gaps.dart';
import 'package:whisper/socket/datagram_seal.dart';

Uint8List _bytes(int length, int fill) =>
    Uint8List.fromList(List<int>.filled(length, fill));

void main() {
  test('a datagram holds a packet and, when both fit, the one before it, '
      'the older first; anything else unpacks to nothing', () {
    const room = DatagramFormat.maxPayloadBytes - 1;
    final current = _bytes(600, 2);
    final previous = _bytes(600, 1);

    final both = packAudioDatagram(current, previous)!;
    expect(unpackAudioDatagram(both).map((p) => p.first), [1, 2]);

    final alone = packAudioDatagram(current, null)!;
    expect(unpackAudioDatagram(alone).single, current);

    // Too big for both: the current one only; too big alone: not by UDP.
    final big = _bytes(room - 2 - 100, 3);
    expect(unpackAudioDatagram(packAudioDatagram(big, previous)!).single, big);
    expect(packAudioDatagram(_bytes(room, 4), null), isNull);

    for (final malformed in [
      Uint8List.fromList([0, 5, 1, 2]), // claims more than there is
      Uint8List.fromList([...alone, 9]), // trailing byte
      Uint8List.fromList([...both, 0, 0]), // a third part
    ]) {
      expect(unpackAudioDatagram(malformed), isEmpty);
    }
  });

  test(
    'each packet plays once; a few that never came are filled in, '
    'a long gap is not, and one that comes after it was filled is dropped',
    () {
      final gaps = AudioPacketGaps();
      final cases = <(int, bool, List<int>)>[
        (1010, true, []),
        (1011, true, []),
        (1011, false, []), // the same packet again
        (1013, true, [1012]), // 1012 never came: filled
        (1012, false, []), // 1012 after all: already filled
        (1014, true, []),
        (1020, true, []), // five missing: silence, not five guesses
        (1016, true, []), // late, but never played or filled: plays
        (1021, true, []),
        (3, true, []), // far behind: the source started counting again
        (5, true, [4]), // and gaps are filled from there
      ];
      for (final (sequence, play, fill) in cases) {
        final taken = gaps.take(sequence);
        expect(taken.play, play, reason: '#$sequence');
        expect(taken.fill, fill, reason: '#$sequence');
      }
    },
  );
}
