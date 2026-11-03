import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_group_session.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/new_ui/sound/sound_controller.dart';
import 'package:whisper/new_ui/sound/sound_rules.dart';

import 'support/share_page_fixtures.dart';

AudioGroupSink _sink({
  AudioGroupSinkState state = AudioGroupSinkState.active,
  int rtt = 0,
  int jitter = 0,
  int buffer = 0,
  int late = 0,
  int error = 0,
}) => AudioGroupSink(
  sinkPeerId: 'peer',
  sessionId: 's',
  channelRole: AudioChannelRole.stereo,
  state: state,
  rttMicros: rtt,
  jitterMicros: jitter,
  bufferTargetMicros: buffer,
  latePacketCount: late,
  syncErrorMicros: error,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('channel defaults', () {
    test('the first device is stereo', () {
      final members = SoundMembers()..add('a');
      expect(members.roles, {'a': AudioChannelRole.stereo});
    });

    test('a second device splits the two into left and right', () {
      final members = SoundMembers()
        ..add('a')
        ..add('b');
      expect(members.roles, {
        'a': AudioChannelRole.left,
        'b': AudioChannelRole.right,
      });
    });

    test('not when somebody has touched a channel', () {
      final members = SoundMembers()
        ..add('a')
        ..setRole('a', AudioChannelRole.mono)
        ..add('b');
      expect(members.roles, {
        'a': AudioChannelRole.mono,
        'b': AudioChannelRole.stereo,
      });
    });

    test('touched and stereo: a second device still does not split', () {
      final members = SoundMembers()
        ..add('a')
        ..setRole('a', AudioChannelRole.mono)
        ..setRole('a', AudioChannelRole.stereo)
        ..add('b');
      expect(members.roleOf('a'), AudioChannelRole.stereo);
      expect(members.roleOf('b'), AudioChannelRole.stereo);
    });

    test('down to one, it goes back to stereo', () {
      final members = SoundMembers()
        ..add('a')
        ..add('b')
        ..remove('a');
      expect(members.roles, {'b': AudioChannelRole.stereo});
    });

    test('not when somebody has touched a channel', () {
      final members = SoundMembers()
        ..add('a')
        ..add('b')
        ..setRole('b', AudioChannelRole.mono)
        ..remove('a');
      expect(members.roles, {'b': AudioChannelRole.mono});
    });

    test('a third device is stereo and leaves the other two alone', () {
      final members = SoundMembers()
        ..add('a')
        ..add('b')
        ..add('c');
      expect(members.roles, {
        'a': AudioChannelRole.left,
        'b': AudioChannelRole.right,
        'c': AudioChannelRole.stereo,
      });
    });

    test('emptied, it starts over untouched', () {
      final members = SoundMembers()
        ..add('a')
        ..setRole('a', AudioChannelRole.mono)
        ..remove('a');
      expect(members.touched, isFalse);
      members
        ..add('a')
        ..add('b');
      expect(members.roleOf('a'), AudioChannelRole.left);
    });

    test('a group changed elsewhere wins, keeping ones gone for a moment', () {
      final members = SoundMembers()
        ..add('here')
        ..add('away');
      members.adopt({
        'here': AudioChannelRole.mono,
        'new': AudioChannelRole.stereo,
      }, keep: (peer) => peer == 'away');
      expect(members.roles.keys, unorderedEquals(['here', 'away', 'new']));
      expect(members.roleOf('here'), AudioChannelRole.mono);
    });
  });

  group('sync quality', () {
    test('no numbers yet is still estimating', () {
      expect(audioSinkHasSyncData(_sink()), isFalse);
      expect(audioSyncQualityOf(_sink()), AudioSyncQuality.calibrating);
    });

    test('good at the edge of the limits', () {
      expect(
        audioSyncQualityOf(_sink(rtt: 2000, jitter: 8000, error: 12000)),
        AudioSyncQuality.good,
      );
    });

    test('fair past 8 ms jitter or 12 ms error', () {
      expect(audioSyncQualityOf(_sink(jitter: 8001)), AudioSyncQuality.fair);
      expect(audioSyncQualityOf(_sink(error: 12001)), AudioSyncQuality.fair);
      expect(audioSyncQualityOf(_sink(error: -12001)), AudioSyncQuality.fair);
      expect(audioSyncQualityOf(_sink(jitter: 20000)), AudioSyncQuality.fair);
      expect(audioSyncQualityOf(_sink(error: 30000)), AudioSyncQuality.fair);
    });

    test('unstable past 20 ms jitter, 30 ms error, or any late packet', () {
      expect(
        audioSyncQualityOf(_sink(jitter: 20001)),
        AudioSyncQuality.unstable,
      );
      expect(
        audioSyncQualityOf(_sink(error: 30001)),
        AudioSyncQuality.unstable,
      );
      expect(audioSyncQualityOf(_sink(late: 1)), AudioSyncQuality.unstable);
    });

    test('the header shows the worst, or estimating while anyone is', () {
      const good = SoundMemberPhase.good;
      const fair = SoundMemberPhase.fair;
      const bad = SoundMemberPhase.unstable;
      expect(soundHeaderQuality([good, good]), AudioSyncQuality.good);
      expect(soundHeaderQuality([good, fair]), AudioSyncQuality.fair);
      expect(soundHeaderQuality([bad, fair, good]), AudioSyncQuality.unstable);
      expect(soundHeaderQuality([fair, bad]), AudioSyncQuality.unstable);
      expect(
        soundHeaderQuality([bad, SoundMemberPhase.calibrating]),
        AudioSyncQuality.calibrating,
      );
      expect(
        soundHeaderQuality([good, SoundMemberPhase.connecting]),
        AudioSyncQuality.calibrating,
      );
      expect(soundHeaderQuality([]), isNull);
      expect(soundHeaderQuality([SoundMemberPhase.failed]), isNull);
    });

    test('numbers read as the row writes them', () {
      expect(formatAudioMillis(2000), '2');
      expect(formatAudioMillis(1500), '1.5');
      expect(formatAudioMillis(0), '0');
    });
  });

  group('member states', () {
    test('every state maps as surfaces.md says', () {
      SoundMemberPhase of(AudioGroupSinkState state) =>
          soundMemberPhaseOf(_sink(state: state, rtt: 2000));
      expect(of(AudioGroupSinkState.offered), SoundMemberPhase.connecting);
      expect(of(AudioGroupSinkState.accepted), SoundMemberPhase.connecting);
      expect(of(AudioGroupSinkState.connecting), SoundMemberPhase.connecting);
      expect(of(AudioGroupSinkState.active), SoundMemberPhase.good);
      expect(of(AudioGroupSinkState.lagging), SoundMemberPhase.unstable);
      expect(of(AudioGroupSinkState.failed), SoundMemberPhase.failed);
      expect(of(AudioGroupSinkState.stopped), SoundMemberPhase.disconnected);
    });

    test('active without numbers is estimating', () {
      expect(soundMemberPhaseOf(_sink()), SoundMemberPhase.calibrating);
    });
  });

  group('real-time gain', () {
    const channel = MethodChannel('test_sound_gain');
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<AudioGroupCoordinator> playing() async {
      final coordinator = AudioGroupCoordinator(
        platform: AudioPlatform(channel: channel),
        codecFactory: (format) async =>
            PcmPassthroughAudioCodec(AudioCodecConfig.fromStreamFormat(format)),
        playbackGainProvider: () async => 1.0,
        clockMicros: () => 100000,
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.groupOffer,
          groupId: 'g',
          streamId: 'st',
          sessionId: 'se',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          sinkPeerIds: ['phone'],
          format: AudioStreamFormat(
            codec: AudioCodecKind.pcmS16le,
            sampleRate: 48000,
            channels: 2,
            frameDurationMs: 20,
            bitRate: 128000,
          ),
          path: '/audio',
          channelRole: AudioChannelRole.stereo,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac.local',
        remotePort: 10002,
        sendControl: (_, _) {},
      );
      await coordinator.handleControlMessage(
        const AudioGroupControlMessage(
          action: AudioGroupControlAction.clockReport,
          groupId: 'g',
          streamId: 'st',
          sessionId: 'se',
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          clockOffsetMicros: 0,
        ),
        localPeerId: 'phone',
        remoteHost: 'mac.local',
        remotePort: 10002,
        sendControl: (_, _) {},
      );
      return coordinator;
    }

    Future<List<int>> play(
      AudioGroupCoordinator coordinator,
      int sequence,
    ) async {
      final before = calls.length;
      await coordinator.handlePacket(
        AudioGroupPacketFrame(
          groupId: 'g',
          streamId: 'st',
          sessionId: 'se',
          sourcePeerId: 'mac',
          sequence: sequence,
          captureTimeMicros: 0,
          targetPlaybackTimeMicros: 100000,
          durationMicros: 20000,
          channelMask: AudioChannelMask.stereo,
          payload: Uint8List.fromList([100, 0, 200, 0]),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final write = calls
          .skip(before)
          .lastWhere((call) => call.method == 'writePcm');
      final args = write.arguments as Map<Object?, Object?>;
      final bytes = args['pcm'] as Uint8List;
      return Int16List.view(
        bytes.buffer,
        bytes.offsetInBytes,
        bytes.lengthInBytes ~/ 2,
      ).toList();
    }

    test('changing the gain applies to the very next audio', () async {
      final coordinator = await playing();
      expect(await play(coordinator, 1), [100, 200]);
      coordinator.updatePlaybackGain(2);
      expect(await play(coordinator, 2), [200, 400]);
      coordinator.updatePlaybackGain(1.5);
      expect(await play(coordinator, 3), [150, 300]);
      await coordinator.stopLocal();
    });

    test('it stays between 1 and 3', () async {
      final coordinator = await playing();
      coordinator.updatePlaybackGain(9);
      expect(await play(coordinator, 1), [300, 600]);
      coordinator.updatePlaybackGain(.1);
      expect(await play(coordinator, 2), [100, 200]);
      coordinator.updatePlaybackGain(double.nan);
      expect(await play(coordinator, 3), [100, 200]);
      await coordinator.stopLocal();
    });

    test(
      'the page moves it while sliding and saves it on letting go',
      () async {
        final world = SoundWorld();
        addTearDown(world.dispose);
        world.controller.setGain(1.7);
        expect(world.controller.gain, 1.7);
        expect(world.savedGain, isNull);
        await world.controller.commitGain(2.5);
        expect(world.savedGain, 2.5);
      },
    );
  });

  group('the master switch', () {
    late SoundWorld world;

    setUp(() => world = SoundWorld());
    tearDown(() => world.dispose());

    test('checking a device starts playing, with no separate start', () async {
      await world.controller.toggle(imacDevice.uid);
      expect(world.group.session, isNotNull);
      expect(world.controller.on, isTrue);
      expect(
        world.sentGroup.single.$2.action,
        AudioGroupControlAction.groupOffer,
      );
    });

    test('off stops the group and keeps who was checked', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.controller.setChannel(
        xiaomiDevice.uid,
        AudioChannelRole.mono,
      );
      await world.controller.setOn(false);

      expect(world.group.session, isNull);
      expect(world.controller.on, isFalse);
      expect(world.controller.selection, {
        imacDevice.uid: AudioChannelRole.left,
        xiaomiDevice.uid: AudioChannelRole.mono,
      });
      expect(world.controller.hasMembers, isTrue);
    });

    test('on again plays to the same devices on the same channels', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.controller.setOn(false);
      world.sentGroup.clear();

      await world.controller.setOn(true);

      final session = world.group.session!;
      expect(session.sinks[imacDevice.uid]!.channelRole, AudioChannelRole.left);
      expect(
        session.sinks[xiaomiDevice.uid]!.channelRole,
        AudioChannelRole.right,
      );
      expect(world.sentGroup.map((sent) => sent.$2.action).toSet(), {
        AudioGroupControlAction.groupOffer,
      });
    });

    test('rows say stopped, and stay checked', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.setOn(false);
      final row = world.controller.rowFor(imacDevice, connected: true);
      expect(row.phase, SoundRowPhase.stopped);
      expect(row.checked, isTrue);
      expect(row.channel, AudioChannelRole.stereo);
    });

    test('unchecking the last one turns it all off and forgets', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(imacDevice.uid);
      expect(world.group.session, isNull);
      expect(world.controller.hasMembers, isFalse);
      expect(world.controller.on, isFalse);
    });

    test('stopped from somewhere else keeps who was checked', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.group.stopLocal();
      expect(world.controller.on, isFalse);
      expect(world.controller.isSelected(imacDevice.uid), isTrue);
    });

    test('a group started elsewhere shows up here', () async {
      world.group.startGroup(
        sourcePeerId: selfMac.uid,
        sinks: {thinkPadDevice.uid: AudioChannelRole.mono},
        format: const AudioStreamFormat(
          codec: AudioCodecKind.pcmS16le,
          sampleRate: 48000,
          channels: 2,
          frameDurationMs: 20,
          bitRate: 128000,
        ),
        sendControl: (_, _) {},
      );
      expect(world.controller.on, isTrue);
      expect(
        world.controller.channelOf(thinkPadDevice.uid),
        AudioChannelRole.mono,
      );
    });
  });

  group('members come and go on their own', () {
    late SoundWorld world;

    setUp(() => world = SoundWorld());
    tearDown(() => world.dispose());

    test('one failing leaves the others alone', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.accept(imacDevice.uid);
      await world.report(imacDevice.uid);
      await world.reject(xiaomiDevice.uid);

      final failed = world.controller.rowFor(xiaomiDevice, connected: true);
      expect(failed.phase, SoundRowPhase.failed);
      expect(failed.failure, AudioFailureReason.busy);
      expect(failed.checked, isTrue);
      expect(
        world.controller.rowFor(imacDevice, connected: true).phase,
        SoundRowPhase.good,
      );
    });

    test('changing a channel does not restart one that was paused', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.accept(imacDevice.uid);
      await world.accept(xiaomiDevice.uid);
      // It paused on its own side.
      final session = world.group.session!;
      await world.group.handleControlMessage(
        AudioGroupControlMessage(
          action: AudioGroupControlAction.groupStop,
          groupId: session.groupId,
          streamId: session.streamId,
          sessionId: session.sinks[xiaomiDevice.uid]!.sessionId,
          sourcePeerId: selfMac.uid,
          sinkPeerId: xiaomiDevice.uid,
        ),
        localPeerId: selfMac.uid,
        remoteHost: '',
        remotePort: 0,
        sendControl: (_, _) {},
      );
      world.sentGroup.clear();

      await world.controller.setChannel(imacDevice.uid, AudioChannelRole.mono);

      expect(world.sentGroup.map((sent) => (sent.$1, sent.$2.action)), [
        (imacDevice.uid, AudioGroupControlAction.groupUpdate),
      ]);
      final row = world.controller.rowFor(xiaomiDevice, connected: true);
      expect(row.phase, SoundRowPhase.disconnected);
      expect(row.checked, isTrue);
    });

    test('its new channel is kept for when it comes back', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.reject(xiaomiDevice.uid);
      world.sentGroup.clear();
      await world.controller.setChannel(
        xiaomiDevice.uid,
        AudioChannelRole.mono,
      );
      expect(world.sentGroup, isEmpty);
      expect(
        world.group.session!.sinks[xiaomiDevice.uid]!.channelRole,
        AudioChannelRole.mono,
      );
    });

    test('unchecking and checking again retries a failed one', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.reject(xiaomiDevice.uid);
      world.sentGroup.clear();

      await world.controller.toggle(xiaomiDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);

      expect(
        world.sentGroup
            .where((sent) => sent.$1 == xiaomiDevice.uid)
            .map((sent) => sent.$2.action),
        [AudioGroupControlAction.groupStop, AudioGroupControlAction.groupOffer],
      );
    });
  });

  group('a device that can only play alone', () {
    late SoundWorld world;

    setUp(() => world = SoundWorld(solo: {thinkPadDevice.uid}));
    tearDown(() => world.dispose());

    test('is listed, without a channel, saying so', () {
      final row = world.controller.rowFor(thinkPadDevice, connected: true);
      expect(row.phase, SoundRowPhase.soloOnly);
      expect(row.channel, isNull);
    });

    test('checking it clears the others and goes one to one', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(thinkPadDevice.uid);

      expect(world.group.session, isNull);
      expect(world.controller.selection.keys, [thinkPadDevice.uid]);
      expect(world.single.state.peerId, thinkPadDevice.uid);
      expect(world.sentSingle.single.$2.action, AudioControlAction.offer);
      expect(
        world.controller.rowFor(thinkPadDevice, connected: true).channel,
        isNull,
      );
    });

    test('checking another device stops it first', () async {
      await world.controller.toggle(thinkPadDevice.uid);
      await world.controller.toggle(imacDevice.uid);

      expect(world.single.state.peerId, isEmpty);
      expect(world.controller.selection.keys, [imacDevice.uid]);
      expect(world.group.session, isNotNull);
    });
  });

  group('without permission', () {
    test('the list can be checked, but nothing starts', () async {
      final world = SoundWorld(denied: true);
      addTearDown(world.dispose);
      await world.controller.toggle(imacDevice.uid);
      expect(world.controller.isSelected(imacDevice.uid), isTrue);
      expect(world.group.session, isNull);
      expect(world.controller.permissionNeeded, isTrue);
      expect(world.controller.on, isFalse);
      await world.controller.openPermission();
      expect(world.permissionAsked, 1);
    });
  });

  group('this device playing another', () {
    test('playing can pause and disconnect', () async {
      final world = SoundWorld();
      addTearDown(world.dispose);
      await world.offerFrom(imacDevice.uid);
      final view = world.controller.sinkView!;
      expect(view.sourcePeerId, imacDevice.uid);
      expect(view.phase, SoundSinkPhase.playing);
      expect(view.canPause, isTrue);
      expect(view.canResume, isFalse);
    });

    test('paused can resume when the source can take it back', () async {
      final world = SoundWorld();
      addTearDown(world.dispose);
      await world.offerFrom(imacDevice.uid);
      await world.controller.pause();
      final view = world.controller.sinkView!;
      expect(view.phase, SoundSinkPhase.paused);
      expect(view.canResume, isTrue);
      expect(view.canPause, isFalse);
    });

    test('paused can only disconnect when the source cannot', () async {
      final world = SoundWorld(canRejoin: false);
      addTearDown(world.dispose);
      await world.offerFrom(imacDevice.uid);
      await world.controller.pause();
      expect(world.controller.sinkView!.canResume, isFalse);
    });

    test('resuming shows until the source answers', () async {
      final world = SoundWorld();
      addTearDown(world.dispose);
      await world.offerFrom(imacDevice.uid);
      await world.controller.pause();
      await world.controller.resume();
      expect(world.controller.sinkView!.phase, SoundSinkPhase.resuming);
      await world.offerFrom(imacDevice.uid);
      expect(world.controller.sinkView!.phase, SoundSinkPhase.playing);
    });

    test('disconnecting leaves this device free', () async {
      final world = SoundWorld();
      addTearDown(world.dispose);
      await world.offerFrom(imacDevice.uid);
      await world.controller.disconnect();
      expect(world.controller.sinkView, isNull);
    });

    test('checking a device does nothing meanwhile', () async {
      final world = SoundWorld();
      addTearDown(world.dispose);
      await world.offerFrom(imacDevice.uid);
      await world.controller.toggle(thinkPadDevice.uid);
      expect(world.controller.isSelected(thinkPadDevice.uid), isFalse);
    });
  });

  group('capture', () {
    test('a failure to capture is reported until stopped', () async {
      const channel = MethodChannel('test_sound_capture');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'startCapture') {
              throw PlatformException(code: 'permission-denied');
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      var now = 1000000;
      final group = AudioGroupCoordinator(
        platform: AudioPlatform(channel: channel),
        codecFactory: (format) async =>
            PcmPassthroughAudioCodec(AudioCodecConfig.fromStreamFormat(format)),
        playbackGainProvider: () async => 1.0,
        clockMicros: () => now += 1000,
      );
      group.startGroup(
        sourcePeerId: 'mac',
        sinks: const {'phone': AudioChannelRole.stereo},
        format: const AudioStreamFormat(
          codec: AudioCodecKind.pcmS16le,
          sampleRate: 48000,
          channels: 2,
          frameDurationMs: 20,
          bitRate: 128000,
        ),
        sendControl: (_, _) {},
      );
      final session = group.session!;
      final sessionId = session.sinks['phone']!.sessionId;
      await group.handleControlMessage(
        AudioGroupControlMessage(
          action: AudioGroupControlAction.groupAccept,
          groupId: session.groupId,
          streamId: session.streamId,
          sessionId: sessionId,
          sourcePeerId: 'mac',
          sinkPeerId: 'phone',
          channelRole: AudioChannelRole.stereo,
        ),
        localPeerId: 'mac',
        remoteHost: '',
        remotePort: 0,
        sendControl: (_, _) {},
      );
      expect(group.captureFailure, isNull);
      // Capture starts once enough clock samples have come in.
      Object? thrown;
      for (var i = 0; i < 20 && thrown == null; i++) {
        final sentAt = now;
        try {
          await group.handleControlMessage(
            AudioGroupControlMessage(
              action: AudioGroupControlAction.clockReport,
              groupId: session.groupId,
              streamId: session.streamId,
              sessionId: sessionId,
              sourcePeerId: 'mac',
              sinkPeerId: 'phone',
              sentAtMicros: sentAt,
              receivedAtMicros: sentAt + 200,
              sinkClockMicros: sentAt + 300,
            ),
            localPeerId: 'mac',
            remoteHost: '',
            remotePort: 0,
            sendControl: (_, _) {},
          );
        } on PlatformException catch (error) {
          thrown = error;
        }
      }
      expect(thrown, isA<PlatformException>());
      expect(group.captureFailure, AudioFailureReason.permission);
      await group.stopLocal();
      expect(group.captureFailure, isNull);
    });
  });
}
