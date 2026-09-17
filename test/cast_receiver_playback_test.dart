import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:whisper/cast_receiver/dlna_receiver.dart';
import 'package:whisper/cast_receiver/playback_engine.dart';
import 'package:whisper/cast_receiver/player.dart';
import 'package:whisper/cast_receiver/request_gate.dart';
import 'package:whisper/cast_receiver/upnp.dart';
import 'package:xml/xml.dart';

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
  Future<Map<String, Object>> rendering(
    String action, [
    Map<String, String> args = const {},
  ]) => receiver.control('RenderingControl', action, {
    'InstanceID': '0',
    'Channel': 'Master',
    ...args,
  });
  Future<void> play() async {
    await control('SetAVTransportURI', {
      'CurrentURI': 'https://example.com/video.mp4',
      'CurrentURIMetaData': '',
    });
    await control('Play', {'Speed': '1'});
  }

  test(
    'phone pause waits for the engine; resume retains media and position',
    () async {
      await play();
      await control('Seek', {'Unit': 'REL_TIME', 'Target': '00:00:12'});
      engine.pauseGate = Completer<void>();
      var acknowledged = false;
      final pause = control('Pause').then((_) => acknowledged = true);
      await Future<void>.delayed(Duration.zero);
      expect(acknowledged, isFalse);
      engine.pauseGate!.complete();
      await pause;
      expect(
        (await control('GetTransportInfo'))['CurrentTransportState'],
        'PAUSED_PLAYBACK',
      );
      expect((await control('GetPositionInfo'))['RelTime'], '00:00:12');
      await control('Play', {'Speed': '1'});
      expect(engine.opens, 1);
      expect(engine.plays, 1);
      expect(
        (await control('GetTransportInfo'))['CurrentTransportState'],
        'PLAYING',
      );
    },
  );

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
  });

  test(
    'phone volume and mute affect output and retain the desired volume',
    () async {
      await rendering('SetVolume', {'DesiredVolume': '35'});
      await play();
      expect(engine.volume, .35);
      await rendering('SetMute', {'DesiredMute': '1'});
      expect(engine.volume, 0);
      await rendering('SetVolume', {'DesiredVolume': '60'});
      expect(engine.volume, 0);
      expect((await rendering('GetVolume'))['CurrentVolume'], 60);
      expect((await rendering('GetMute'))['CurrentMute'], 1);
      await rendering('SetMute', {'DesiredMute': '0'});
      expect(engine.volume, .6);
      expect((await rendering('GetMute'))['CurrentMute'], 0);
      engine.failVolume = true;
      await expectLater(
        rendering('SetVolume', {'DesiredVolume': '10'}),
        throwsStateError,
      );
      expect((await rendering('GetVolume'))['CurrentVolume'], 60);
      await control('Stop');
      expect(player.visible, isFalse);
      expect(engine.disposed, isTrue);
    },
  );

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

  test(
    'volume changes during an in-flight notification are delivered',
    () async {
      final callback = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => callback.close(force: true));
      final first = Completer<HttpRequest>();
      final latest = Completer<String>();
      callback.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        if (!first.isCompleted) {
          first.complete(request);
        } else {
          if (!latest.isCompleted) latest.complete(body);
          await request.response.close();
        }
      });
      receiver.subscriptions['test'] = Subscription(
        'test',
        'RenderingControl',
        Uri.parse('http://127.0.0.1:${callback.port}/events'),
      );
      receiver.notifySubscribers();
      final pending = await first.future.timeout(const Duration(seconds: 2));
      await rendering('SetVolume', {'DesiredVolume': '80'});
      receiver.notifySubscribers();
      await pending.response.close();
      final event = XmlDocument.parse(
        await latest.future.timeout(const Duration(seconds: 2)),
      ).findAllElements('LastChange').single.innerText;
      expect(
        XmlDocument.parse(
          event,
        ).findAllElements('Volume').single.getAttribute('val'),
        '80',
      );
    },
  );

  test(
    'receiver uses and updates the device name without changing identity',
    () {
      final uuid = receiver.uuid;
      receiver.rename('工作室 <iMac>');
      final description = XmlDocument.parse(
        deviceDescription(receiver.name, receiver.uuid),
      );
      expect(
        description.findAllElements('friendlyName').single.innerText,
        '工作室 <iMac>',
      );
      expect(receiver.uuid, uuid);
    },
  );
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
