import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:whisper/cast_receiver/dlna_receiver.dart';
import 'package:whisper/cast_receiver/playback_engine.dart';
import 'package:whisper/cast_receiver/player.dart';
import 'package:whisper/cast_receiver/request_gate.dart';

void main() {
  late _Engine engine;
  late CastPlayer player;
  late DlnaReceiver receiver;
  setUp(() {
    engine = _Engine();
    player = CastPlayer(engineFactory: () async => engine)..activate();
    receiver = DlnaReceiver(
      player,
      InternetAddress.loopbackIPv4,
      _Interface(),
      name: 'Studio & Mac',
    );
  });
  tearDown(() async {
    await receiver.close();
    await player.close();
    player.dispose();
  });
  Future<Map<String, Object>> control(
    String action, [
    Map<String, String> args = const {},
  ]) => receiver.control('AVTransport', action, {'InstanceID': '0', ...args});
  Future<void> play() async {
    await control('SetAVTransportURI', {
      'CurrentURI': 'https://example.com/video.mp4',
      'CurrentURIMetaData': '',
    });
    await control('Play', {'Speed': '1'});
  }

  test('unapproved control does not change active media or volume', () async {
    final gate = CastRequestGate()..open();
    addTearDown(gate.dispose);
    await receiver.close();
    receiver = DlnaReceiver(
      player,
      InternetAddress.loopbackIPv4,
      _Interface(),
      name: 'Test',
      requests: gate,
    );
    await play();
    final request = receiver.control('RenderingControl', 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '10',
    }, senderAddress: '192.168.1.10');
    final denied = expectLater(request, throwsA(isA<ControlError>()));
    expect(engine.volume, 1);
    expect(player.visible, isTrue);
    gate.decide(gate.pending!, false);
    await denied;
    expect(engine.volume, 1);
    expect(engine.disposed, isFalse);
    // Get* needs no approval, so it used to hand anyone the playing URL.
    for (final action in ['GetMediaInfo', 'GetPositionInfo']) {
      final info = await receiver.control('AVTransport', action, {
        'InstanceID': '0',
      }, senderAddress: '192.168.1.10');
      expect(info.values, isNot(contains('https://example.com/video.mp4')));
    }
  });

  test('late engine creation is released when reception is disabled', () async {
    await player.close();
    player.dispose();
    final creating = Completer<void>();
    final created = Completer<CastPlaybackEngine>();
    player = CastPlayer(
      engineFactory: () {
        creating.complete();
        return created.future;
      },
    )..activate();
    await player.command('load', {'url': 'https://example.com/video.mp4'});
    final play = player.command('play');
    await creating.future;
    final close = player.close();
    created.complete(engine);
    await Future.wait([play, close]);
    expect(engine.disposed, isTrue);
    expect(engine.opens, 0);
    expect(player.visible, isFalse);
  });
}

class _Engine implements CastPlaybackEngine {
  bool disposed = false;
  int opens = 0;
  int plays = 0;
  double volume = 1;
  bool failVolume = false;
  Completer<void>? pauseGate;
  final _changes = StreamController<void>.broadcast();
  @override
  CastPlaybackState state = const CastPlaybackState(
    duration: Duration(seconds: 60),
  );
  @override
  VideoController? get videoController => null;
  @override
  Stream<void> get changes => _changes.stream;
  void _state({bool? playing, Duration? position}) {
    state = CastPlaybackState(
      playing: playing ?? state.playing,
      position: position ?? state.position,
      duration: state.duration,
    );
    _changes.add(null);
  }

  @override
  Future<void> open(String uri) async {
    opens++;
    _state(playing: true);
  }

  @override
  Future<void> play() async {
    plays++;
    _state(playing: true);
  }

  @override
  Future<void> pause() async {
    await pauseGate?.future;
    _state(playing: false);
  }

  @override
  Future<void> seek(Duration position) async => _state(position: position);
  @override
  Future<void> setVolume(double value) async {
    if (failVolume) throw StateError('Volume failed');
    volume = value;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _changes.close();
  }
}

class _Interface implements NetworkInterface {
  @override
  List<InternetAddress> get addresses => [InternetAddress.loopbackIPv4];
  @override
  int get index => 1;
  @override
  String get name => 'loopback';
}
