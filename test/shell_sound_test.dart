import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_failure_reason.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/new_ui/sound/sound_controller.dart';
import 'package:whisper/new_ui/sound/sound_rules.dart';

import 'support/share_page_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('channel defaults', () {
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

    test('down to one, it goes back to stereo', () {
      final members = SoundMembers()
        ..add('a')
        ..add('b')
        ..remove('a');
      expect(members.roles, {'b': AudioChannelRole.stereo});
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

    Future<void> stopsThere(String peerId) async {
      final session = world.group.session!;
      await world.group.handleControlMessage(
        AudioGroupControlMessage(
          action: AudioGroupControlAction.groupStop,
          groupId: session.groupId,
          streamId: session.streamId,
          sessionId: session.sinks[peerId]!.sessionId,
          sourcePeerId: selfMac.uid,
          sinkPeerId: peerId,
        ),
        localPeerId: selfMac.uid,
        remoteHost: '',
        remotePort: 0,
        sendControl: (_, _) {},
      );
    }

    test('the last device stopping it turns the switch off', () async {
      final stopped = <String>[];
      world.controller.onMemberStopped = stopped.add;
      await world.controller.toggle(imacDevice.uid);
      expect(world.controller.on, isTrue);
      expect(world.controller.isSending(imacDevice.uid), isTrue);

      await stopsThere(imacDevice.uid);

      expect(world.controller.on, isFalse);
      expect(world.controller.isSending(imacDevice.uid), isFalse);
      expect(world.controller.isSelected(imacDevice.uid), isTrue);
      expect(stopped, [imacDevice.uid]);
      expect(
        world.controller.rowFor(imacDevice).phase,
        SoundRowPhase.disconnected,
      );
    });

    test('one of two stopping leaves the other playing', () async {
      final stopped = <String>[];
      world.controller.onMemberStopped = stopped.add;
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);

      await stopsThere(xiaomiDevice.uid);

      expect(world.controller.on, isTrue);
      expect(world.controller.isSending(imacDevice.uid), isTrue);
      expect(world.controller.isSending(xiaomiDevice.uid), isFalse);
      expect(stopped, [xiaomiDevice.uid]);
    });

    test('turning it on again offers the sound again', () async {
      await world.controller.toggle(imacDevice.uid);
      await stopsThere(imacDevice.uid);
      world.sentGroup.clear();

      await world.controller.setOn(true);

      expect(world.controller.on, isTrue);
      expect(world.sentGroup.map((sent) => (sent.$1, sent.$2.action)), [
        (imacDevice.uid, AudioGroupControlAction.groupOffer),
      ]);
    });

    test('stopping it here is not reported as the other device', () async {
      final stopped = <String>[];
      world.controller.onMemberStopped = stopped.add;
      await world.controller.toggle(imacDevice.uid);
      await world.controller.setOn(false);
      expect(stopped, isEmpty);
    });

    test('one failing leaves the others alone', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.accept(imacDevice.uid);
      await world.report(imacDevice.uid);
      await world.reject(xiaomiDevice.uid);

      final failed = world.controller.rowFor(xiaomiDevice);
      expect(failed.phase, SoundRowPhase.failed);
      expect(failed.failure, AudioFailureReason.busy);
      expect(failed.checked, isTrue);
      expect(world.controller.rowFor(imacDevice).phase, SoundRowPhase.good);
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
      final row = world.controller.rowFor(xiaomiDevice);
      expect(row.phase, SoundRowPhase.disconnected);
      expect(row.checked, isTrue);
    });

    test('unchecking and checking again retries a failed one', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);
      await world.reject(xiaomiDevice.uid);
      world.sentGroup.clear();

      await world.controller.toggle(xiaomiDevice.uid);
      await world.controller.toggle(xiaomiDevice.uid);

      // No stop to the one that failed: it may not know the session any more
      // (it restarted), and an older device drops the connection over one.
      expect(
        world.sentGroup
            .where((sent) => sent.$1 == xiaomiDevice.uid)
            .map((sent) => sent.$2.action),
        [AudioGroupControlAction.groupOffer],
      );
    });
  });

  group('a device that can only play alone', () {
    late SoundWorld world;

    setUp(() => world = SoundWorld(solo: {thinkPadDevice.uid}));
    tearDown(() => world.dispose());

    test('checking it clears the others and goes one to one', () async {
      await world.controller.toggle(imacDevice.uid);
      await world.controller.toggle(thinkPadDevice.uid);

      expect(world.group.session, isNull);
      expect(world.controller.selection.keys, [thinkPadDevice.uid]);
      expect(world.single.state.peerId, thinkPadDevice.uid);
      expect(world.sentSingle.single.$2.action, AudioControlAction.offer);
      expect(world.controller.rowFor(thinkPadDevice).channel, isNull);
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

    test('disconnecting leaves this device free', () async {
      final world = SoundWorld();
      addTearDown(world.dispose);
      await world.offerFrom(imacDevice.uid);
      await world.controller.disconnect();
      expect(world.controller.sinkView, isNull);
    });
  });
}
