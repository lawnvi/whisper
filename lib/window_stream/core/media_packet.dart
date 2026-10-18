import 'dart:typed_data';

/// Receives one media packet's bytes, possibly in several chunks.
abstract interface class MediaPacketWriter {
  void write(Uint8List chunk);

  /// Hands the packet to its consumer.
  void commit({required int ptsUs, required bool config, required bool key});

  /// Drops a partial packet (stream ended mid-packet).
  void discard();
}
