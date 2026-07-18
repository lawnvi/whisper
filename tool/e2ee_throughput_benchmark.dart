import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sodium/sodium.dart';
import 'package:whisper/socket/aead_engine.dart';
import 'package:whisper/socket/authenticated_frame.dart';

Future<void> main(List<String> arguments) async {
  WhisperAead.installNativeAcceleration(await SodiumInit.init());
  final totalMiB = _integerOption(arguments, '--mib', fallback: 256);
  final frameKiB = _integerOption(arguments, '--frame-kib', fallback: 512);
  final requiredMiBps =
      _integerOption(arguments, '--require-mibps', fallback: 119);
  if (totalMiB <= 0 || frameKiB <= 0 || requiredMiBps <= 0) {
    throw ArgumentError('benchmark arguments must be positive');
  }

  final frameBytes = frameKiB * 1024;
  final totalBytes = totalMiB * 1024 * 1024;
  final frames = (totalBytes / frameBytes).ceil();
  final payload = Uint8List(frameBytes);
  Random(7).nextBytes(payload);
  final directionalKey = SecretKeyData.random(
    length: 32,
  );
  final directionalBytes =
      Uint8List.fromList(await directionalKey.extractBytes());
  directionalKey.destroy();
  final sender = await AuthenticatedFrameCodec.create(
    sendKey: SecretKeyData(
      Uint8List.fromList(directionalBytes),
      overwriteWhenDestroyed: true,
    ),
    receiveKey: SecretKeyData.random(
      length: 32,
    ),
  );
  final receiver = await AuthenticatedFrameCodec.create(
    sendKey: SecretKeyData.random(
      length: 32,
    ),
    receiveKey: SecretKeyData(
      Uint8List.fromList(directionalBytes),
      overwriteWhenDestroyed: true,
    ),
  );
  directionalBytes.fillRange(0, directionalBytes.length, 0);

  var encodeMicroseconds = 0;
  var decodeMicroseconds = 0;
  var processedBytes = 0;
  for (var index = 0; index < frames; index += 1) {
    final remaining = totalBytes - processedBytes;
    final clearText = remaining >= frameBytes
        ? payload
        : Uint8List.sublistView(payload, 0, remaining);
    final timer = Stopwatch()..start();
    final encrypted = await sender.encode(clearText);
    timer.stop();
    encodeMicroseconds += timer.elapsedMicroseconds;
    timer
      ..reset()
      ..start();
    final decrypted = await receiver.decode(encrypted);
    timer.stop();
    decodeMicroseconds += timer.elapsedMicroseconds;
    if (decrypted.length != clearText.length) {
      throw StateError('decrypted length mismatch');
    }
    processedBytes += clearText.length;
  }
  sender.close();
  receiver.close();

  final encodeMiBps = _mibPerSecond(processedBytes, encodeMicroseconds);
  final decodeMiBps = _mibPerSecond(processedBytes, decodeMicroseconds);
  final bottleneck = min(encodeMiBps, decodeMiBps);
  print('payload: ${(processedBytes / (1024 * 1024)).toStringAsFixed(0)} MiB');
  print('frame: $frameKiB KiB');
  print('backend: native XChaCha20-Poly1305');
  print('encrypt: ${encodeMiBps.toStringAsFixed(1)} MiB/s');
  print('decrypt: ${decodeMiBps.toStringAsFixed(1)} MiB/s');
  print('required gate: $requiredMiBps MiB/s (default covers 1 GbE)');
  if (bottleneck < requiredMiBps) {
    throw StateError(
      'E2EE throughput ${bottleneck.toStringAsFixed(1)} MiB/s is below '
      '$requiredMiBps MiB/s',
    );
  }
}

int _integerOption(
  List<String> arguments,
  String name, {
  required int fallback,
}) {
  final index = arguments.indexOf(name);
  if (index < 0) {
    return fallback;
  }
  if (index + 1 >= arguments.length) {
    throw FormatException('missing value for $name');
  }
  return int.parse(arguments[index + 1]);
}

double _mibPerSecond(int bytes, int microseconds) {
  if (microseconds <= 0) {
    return double.infinity;
  }
  return bytes / (1024 * 1024) / (microseconds / 1000000);
}

extension on Random {
  void nextBytes(Uint8List output) {
    for (var index = 0; index < output.length; index += 1) {
      output[index] = nextInt(256);
    }
  }
}
