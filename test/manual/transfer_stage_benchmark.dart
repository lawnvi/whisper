// Opt-in: how fast each step a file transfer puts every byte through runs on
// this machine (4 MiB frames, as the transfer engine sends them). Run with
//   flutter test test/manual/transfer_stage_benchmark.dart
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sodium/sodium.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/socket/aead_engine.dart';

const _frame = 4 * 1024 * 1024;
const _frames = 64;

@Native<Size Function()>(
  symbol: 'crypto_generichash_statebytes',
  assetId: 'package:sodium/libsodium',
)
external int _blake2bStateBytes();

@Native<Int Function(Pointer<Void>, Pointer<Uint8>, Size, Size)>(
  symbol: 'crypto_generichash_init',
  assetId: 'package:sodium/libsodium',
)
external int _blake2bInit(
  Pointer<Void> state,
  Pointer<Uint8> key,
  int keyLength,
  int outLength,
);

@Native<Int Function(Pointer<Void>, Pointer<Uint8>, Uint64)>(
  symbol: 'crypto_generichash_update',
  assetId: 'package:sodium/libsodium',
  isLeaf: true,
)
external int _blake2bUpdate(Pointer<Void> state, Pointer<Uint8> input, int n);

void main() {
  test('transfer stage throughput', () async {
    HttpOverrides.global = null;
    WhisperAead.installNativeAcceleration(await SodiumInit.init());
    StreamingChecksum.installNativeSha256Acceleration();
    final random = Random(7);
    final data = Uint8List(_frame);
    for (var i = 0; i < data.length; i++) {
      data[i] = random.nextInt(256);
    }
    final results = <String, double>{};

    Future<void> measure(String name, FutureOr<void> Function() run) async {
      await run(); // warm up
      final watch = Stopwatch()..start();
      for (var i = 0; i < _frames; i++) {
        await run();
      }
      watch.stop();
      results[name] =
          _frame * _frames / 1048576 / (watch.elapsedMicroseconds / 1e6);
    }

    final checksum = StreamingChecksum();
    await measure('sha256 (libsodium)', () => checksum.add(data));
    checksum.close();

    if (Platform.isMacOS) {
      final lib = DynamicLibrary.process();
      final init = lib
          .lookupFunction<
            Int Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('CC_SHA256_Init');
      final update = lib
          .lookupFunction<
            Int Function(Pointer<Void>, Pointer<Uint8>, Uint32),
            int Function(Pointer<Void>, Pointer<Uint8>, int)
          >('CC_SHA256_Update');
      final ctx = calloc<Uint8>(128).cast<Void>();
      final native = calloc<Uint8>(_frame);
      native.asTypedList(_frame).setAll(0, data);
      init(ctx);
      await measure('sha256 (CommonCrypto)', () => update(ctx, native, _frame));
      calloc.free(native);
      calloc.free(ctx);
    }
    if (Platform.isWindows) {
      final bcrypt = DynamicLibrary.open('bcrypt.dll');
      final open = bcrypt
          .lookupFunction<
            Int32 Function(
              Pointer<IntPtr>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Uint32,
            ),
            int Function(Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, int)
          >('BCryptOpenAlgorithmProvider');
      final create = bcrypt
          .lookupFunction<
            Int32 Function(
              IntPtr,
              Pointer<IntPtr>,
              Pointer<Uint8>,
              Uint32,
              Pointer<Uint8>,
              Uint32,
              Uint32,
            ),
            int Function(
              int,
              Pointer<IntPtr>,
              Pointer<Uint8>,
              int,
              Pointer<Uint8>,
              int,
              int,
            )
          >('BCryptCreateHash');
      final hashData = bcrypt
          .lookupFunction<
            Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Uint32),
            int Function(int, Pointer<Uint8>, int, int)
          >('BCryptHashData');
      final algorithm = calloc<IntPtr>();
      final hash = calloc<IntPtr>();
      final name = 'SHA256'.toNativeUtf16();
      expect(open(algorithm, name, nullptr, 0), 0);
      expect(create(algorithm.value, hash, nullptr, 0, nullptr, 0, 0), 0);
      final native = calloc<Uint8>(_frame);
      native.asTypedList(_frame).setAll(0, data);
      await measure(
        'sha256 (BCrypt)',
        () => hashData(hash.value, native, _frame, 0),
      );
      calloc.free(native);
      calloc.free(name);
    }

    final state = calloc<Uint8>(_blake2bStateBytes()).cast<Void>();
    _blake2bInit(state, nullptr, 0, 32);
    await measure(
      'blake2b (libsodium generichash)',
      () => _blake2bUpdate(state, data.address, data.length),
    );
    calloc.free(state);

    final key = WhisperAead.takeKey(
      Uint8List.fromList(List.generate(32, (i) => i)),
    );
    final cipher = Uint8List(_frame);
    final mac = Uint8List(16);
    final nonce = Uint8List(24);
    final ad = Uint8List(32);
    await measure(
      'aead encrypt',
      () => key.encryptInto(
        message: data,
        cipherText: cipher,
        mac: mac,
        nonce: nonce,
        additionalData: ad,
      ),
    );
    final sealed = Uint8List.fromList(cipher);
    final sealedMac = Uint8List.fromList(mac);
    await measure('aead decrypt (in place)', () {
      final copy = Uint8List.fromList(sealed);
      key.decrypt(
        cipherText: copy,
        mac: sealedMac,
        nonce: nonce,
        additionalData: ad,
      );
    });
    await measure('copy (Uint8List.fromList)', () => Uint8List.fromList(data));

    final dir = await Directory.systemTemp.createTemp('stage-bench-');
    final file = File(p.join(dir.path, 'bench.bin'));
    final writer = await file.open(mode: FileMode.write);
    await measure('file write', () => writer.writeFrom(data));
    await writer.flush();
    await writer.close();
    final reader = await file.open();
    final into = Uint8List(_frame);
    var offset = 0;
    await measure('file read', () async {
      await reader.setPosition(offset % (await file.length() - _frame));
      offset += _frame;
      await reader.readInto(into);
    });
    await reader.close();
    await dir.delete(recursive: true);

    for (final clientSends in [true, false]) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSocket = Completer<WebSocket>();
      server.listen((request) async {
        serverSocket.complete(
          await WebSocketTransformer.upgrade(
            request,
            compression: CompressionOptions.compressionOff,
          ),
        );
      });
      final client = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}',
        compression: CompressionOptions.compressionOff,
      );
      final serverEnd = await serverSocket.future;
      final sender = clientSends ? client : serverEnd;
      final receiver = clientSends ? serverEnd : client;
      var received = 0;
      final done = Completer<void>();
      receiver.listen((message) {
        received += (message as List<int>).length;
        if (received >= _frame * (_frames + 1)) {
          done.complete();
        }
      });
      final watch = Stopwatch()..start();
      for (var i = 0; i < _frames + 1; i++) {
        sender.add(data);
        await Future<void>.delayed(Duration.zero);
      }
      await done.future;
      watch.stop();
      results[clientSends
              ? 'websocket client→server (masked)'
              : 'websocket server→client'] =
          _frame * (_frames + 1) / 1048576 / (watch.elapsedMicroseconds / 1e6);
      await client.close();
      await serverEnd.close();
      await server.close(force: true);
    }

    // The same bytes over a plain TCP socket, without WebSocket framing.
    {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var received = 0;
      final done = Completer<void>();
      server.listen((socket) {
        socket.listen((chunk) {
          received += chunk.length;
          if (received >= _frame * (_frames + 1) && !done.isCompleted) {
            done.complete();
          }
        });
      });
      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final watch = Stopwatch()..start();
      for (var i = 0; i < _frames + 1; i++) {
        client.add(data);
        await client.flush();
      }
      await done.future;
      watch.stop();
      results['raw tcp socket'] =
          _frame * (_frames + 1) / 1048576 / (watch.elapsedMicroseconds / 1e6);
      client.destroy();
      await server.close();
    }

    final report = StringBuffer('${Platform.operatingSystem} stage MiB/s:\n');
    results.forEach((name, rate) {
      report.writeln('  ${name.padRight(34)} ${rate.toStringAsFixed(0)}');
    });
    // ignore: avoid_print
    print(report);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
