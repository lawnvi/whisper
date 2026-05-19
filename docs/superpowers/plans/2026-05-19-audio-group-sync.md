# Audio Group Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Build the first C-compatible B-level audio group slice: one source captures once, fans one synchronized stream to multiple sinks, and models sink channel roles plus lightweight sync metadata.

**Architecture:** Add group-specific protocol and runtime types next to the existing one-to-one audio sharing code, then migrate behavior through narrow seams. Control messages stay on the chat WebSocket, realtime audio stays on `/audio` WebSocket for v1, and transport/scheduler interfaces are kept replaceable for a later UDP/QUIC-style upgrade.

**Tech Stack:** Flutter/Dart, `flutter_test`, existing `AudioPlatform`, `AudioCodec`, `AudioPacketTransport`, `AudioShareManager`, `WsSvrManager`.

---

### Task 1: Audio Group Protocol

**Files:**
- Modify: `lib/audio/audio_protocol.dart`
- Modify: `lib/state/peer_profile.dart`
- Test: `test/audio_group_protocol_test.dart`

- [x] **Step 1: Write failing protocol tests**

Create `test/audio_group_protocol_test.dart` with tests for:

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_protocol.dart';

void main() {
  const format = AudioStreamFormat(
    codec: AudioCodecKind.opus,
    sampleRate: 48000,
    channels: 2,
    frameDurationMs: 20,
    bitRate: 128000,
  );

  test('AudioGroupControlMessage round-trips group offer fields', () {
    const message = AudioGroupControlMessage(
      action: AudioGroupControlAction.groupOffer,
      groupId: 'group-1',
      streamId: 'stream-1',
      sessionId: 'session-1',
      sourcePeerId: 'mac',
      sinkPeerId: 'phone-left',
      sinkPeerIds: <String>['phone-left', 'phone-right'],
      format: format,
      transport: AudioTransport.websocket,
      path: '/audio',
      channelRole: AudioChannelRole.left,
      targetLatencyMs: 160,
      sentAtMicros: 100,
      receivedAtMicros: 120,
      sinkClockMicros: 140,
      playbackCursorMicros: 160,
    );

    final decoded = AudioGroupControlMessage.fromJson(message.toJson());

    expect(decoded.action, AudioGroupControlAction.groupOffer);
    expect(decoded.groupId, 'group-1');
    expect(decoded.streamId, 'stream-1');
    expect(decoded.sinkPeerIds, <String>['phone-left', 'phone-right']);
    expect(decoded.channelRole, AudioChannelRole.left);
    expect(decoded.targetLatencyMs, 160);
    expect(decoded.format, format);
  });

  test('AudioGroupPacketFrame encodes synchronized stream metadata', () {
    final packet = AudioGroupPacketFrame(
      groupId: 'group-1',
      streamId: 'stream-1',
      sessionId: 'session-1',
      sourcePeerId: 'mac',
      sequence: 42,
      captureTimeMicros: 1000,
      targetPlaybackTimeMicros: 1200,
      durationMicros: 20000,
      channelMask: AudioChannelMask.stereo,
      payload: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );

    final decoded = AudioGroupPacketFrame.decode(packet.encode());

    expect(decoded.groupId, 'group-1');
    expect(decoded.streamId, 'stream-1');
    expect(decoded.sequence, 42);
    expect(decoded.targetPlaybackTimeMicros, 1200);
    expect(decoded.channelMask, AudioChannelMask.stereo);
    expect(decoded.payload, <int>[1, 2, 3, 4]);
  });

  test('AudioGroupPacketFrame rejects legacy audio packet magic', () {
    final legacy = AudioPacketFrame(
      sessionId: 'audio-1',
      sequence: 1,
      captureTimeMicros: 10,
      payload: Uint8List.fromList(<int>[1]),
    ).encode();

    expect(
      () => AudioGroupPacketFrame.decode(legacy),
      throwsA(isA<FormatException>()),
    );
  });
}
```

- [x] **Step 2: Run red test**

Run:

```bash
flutter test test/audio_group_protocol_test.dart
```

Expected: fails because `AudioGroupControlMessage`, `AudioGroupControlAction`, `AudioGroupPacketFrame`, `AudioChannelRole`, and `AudioChannelMask` are missing.

- [x] **Step 3: Implement protocol types**

Add to `lib/audio/audio_protocol.dart`:

```dart
enum AudioChannelRole { stereo, mono, left, right }

enum AudioChannelMask { stereo, mono, left, right }

enum AudioGroupControlAction {
  groupOffer,
  groupAccept,
  groupReject,
  groupUpdate,
  groupStop,
  clockProbe,
  clockReport,
  latencyReport,
  error,
}
```

Then add immutable `AudioGroupControlMessage` and binary `AudioGroupPacketFrame` using magic `WSG1`, following the existing `AudioControlMessage` and `AudioPacketFrame` style.

- [x] **Step 4: Add capability flags**

Extend `PeerCapabilities` with:

```dart
final bool audioGroupSourceV1;
final bool audioGroupSinkV1;
final bool audioSyncClockV1;
final bool audioChannelRoleV1;
```

Default all new fields to `false` for legacy payloads. Include them in `toJson`, `fromJson`, equality-sensitive tests, and local peer profile generation.

- [x] **Step 5: Run green tests**

Run:

```bash
flutter test test/audio_group_protocol_test.dart test/audio_protocol_test.dart
```

Expected: both pass.

### Task 2: Audio Group Runtime Model

**Files:**
- Create: `lib/audio/audio_group_session.dart`
- Test: `test/audio_group_session_test.dart`

- [x] **Step 1: Write failing session tests**

Create tests for:

- a group starts with multiple offered sinks.
- accepting one sink does not activate/reject another sink.
- stopping one sink leaves the group `partial` or `active` when another sink remains active.
- channel roles are stored per sink.

- [x] **Step 2: Run red test**

Run:

```bash
flutter test test/audio_group_session_test.dart
```

Expected: fails because session types are missing.

- [x] **Step 3: Implement model**

Create:

```dart
enum AudioGroupState {
  offering,
  connecting,
  active,
  partial,
  stopping,
  stopped,
  failed,
}

enum AudioGroupSinkState {
  offered,
  accepted,
  connecting,
  active,
  lagging,
  failed,
  stopped,
}

class AudioGroupSink {
  const AudioGroupSink({
    required this.sinkPeerId,
    required this.sessionId,
    required this.channelRole,
    required this.state,
    this.host = '',
    this.port = 0,
    this.clockOffsetMicros = 0,
    this.rttMicros = 0,
    this.jitterMicros = 0,
    this.bufferTargetMicros = 0,
    this.lastPacketSequence = -1,
    this.lastError = '',
  });

  final String sinkPeerId;
  final String sessionId;
  final AudioChannelRole channelRole;
  final AudioGroupSinkState state;
  final String host;
  final int port;
  final int clockOffsetMicros;
  final int rttMicros;
  final int jitterMicros;
  final int bufferTargetMicros;
  final int lastPacketSequence;
  final String lastError;

  bool get isActive => state == AudioGroupSinkState.active;
  bool get isTerminal =>
      state == AudioGroupSinkState.failed ||
      state == AudioGroupSinkState.stopped;
}

class AudioGroupSession {
  const AudioGroupSession({
    required this.groupId,
    required this.streamId,
    required this.sourcePeerId,
    required this.format,
    required this.state,
    required this.sinks,
    this.startedAtMicros = 0,
    this.targetLatencyMs = 160,
  });

  final String groupId;
  final String streamId;
  final String sourcePeerId;
  final AudioStreamFormat format;
  final AudioGroupState state;
  final Map<String, AudioGroupSink> sinks;
  final int startedAtMicros;
  final int targetLatencyMs;

  bool get isLive =>
      state != AudioGroupState.stopped &&
      state != AudioGroupState.failed;
}
```

Include `copyWith`, `isLive`, `activeSinks`, `failedSinks`, `withSink`, `markSink`, and `stateAfterSinkChange`.

- [x] **Step 4: Run green test**

Run:

```bash
flutter test test/audio_group_session_test.dart
```

Expected: passes.

### Task 3: Audio Fanout Transport

**Files:**
- Create: `lib/audio/audio_fanout_transport.dart`
- Test: `test/audio_fanout_transport_test.dart`

- [x] **Step 1: Write failing fanout tests**

Test that:

- one packet is sent to every active sink transport.
- a closed/failed sink is skipped.
- send exceptions mark only that sink failed and do not stop fanout.

- [x] **Step 2: Run red test**

Run:

```bash
flutter test test/audio_fanout_transport_test.dart
```

Expected: fails because fanout transport is missing.

- [x] **Step 3: Implement fanout**

Create `AudioFanoutTransport` with:

```dart
typedef AudioGroupSinkFailure = void Function(String sinkPeerId, Object error);

class AudioFanoutTransport {
  AudioFanoutTransport({required this.onSinkFailure});
  void attach(String sinkPeerId, AudioPacketTransport transport);
  void detach(String sinkPeerId);
  void send(AudioGroupPacketFrame packet);
  Future<void> closeAll();
}
```

Use `AudioPacketTransport.send` by converting group packets through a small adapter or introduce a group packet sender type if cleaner.

- [x] **Step 4: Run green test**

Run:

```bash
flutter test test/audio_fanout_transport_test.dart
```

Expected: passes.

### Task 4: Playback Scheduler

**Files:**
- Create: `lib/audio/audio_group_playback_scheduler.dart`
- Test: `test/audio_group_playback_scheduler_test.dart`

- [x] **Step 1: Write failing scheduler tests**

Test that:

- packets are buffered by sequence.
- late packets are counted and dropped.
- `left` and `right` channel roles isolate the intended channel.
- latency reports include buffer depth and late packet count.

- [x] **Step 2: Run red test**

Run:

```bash
flutter test test/audio_group_playback_scheduler_test.dart
```

Expected: fails because scheduler is missing.

- [x] **Step 3: Implement minimal scheduler**

Implement a pure-Dart scheduler that accepts decoded PCM through an injectable clock and writer. Keep platform writes behind `AudioPlaybackSink` integration for later.

- [x] **Step 4: Run green test**

Run:

```bash
flutter test test/audio_group_playback_scheduler_test.dart
```

Expected: passes.

### Task 5: Audio Group Coordinator

**Files:**
- Create: `lib/audio/audio_group_coordinator.dart`
- Modify: `lib/audio/audio_capture_source.dart`
- Test: `test/audio_group_coordinator_test.dart`

- [x] **Step 1: Write failing coordinator tests**

Test that:

- source starts capture once for two accepted sinks.
- encoded packets fan out to both sink transports with the same `streamId` and `sequence`.
- source rejects starting a second local group.
- sink rejects a second source while already active.

- [x] **Step 2: Run red test**

Run:

```bash
flutter test test/audio_group_coordinator_test.dart
```

Expected: fails because coordinator is missing.

- [x] **Step 3: Implement source-side coordinator slice**

Implement group creation, sink offer/accept handling, single capture startup, and fanout. Use existing `AudioCaptureSource` but pass group/stream ids consistently.

- [x] **Step 4: Implement sink-side coordinator slice**

Implement offer handling, playback scheduler startup, accept/reject control generation, and stop/error handling.

- [x] **Step 5: Run green test**

Run:

```bash
flutter test test/audio_group_coordinator_test.dart test/audio_share_coordinator_test.dart
```

Expected: both pass.

### Task 6: Socket And Capability Integration

**Files:**
- Modify: `lib/socket/svrmanager.dart`
- Modify: `lib/state/peer_profile.dart`
- Test: `test/audio_group_socket_routing_source_test.dart`

- [x] **Step 1: Write failing routing tests**

Use source tests to require:

- `WsSvrManager` exposes peer-scoped audio group capability checks.
- group control messages route with explicit peer id.
- audio group control handling uses incoming peer id, not selected receiver.

- [x] **Step 2: Run red test**

Run:

```bash
flutter test test/audio_group_socket_routing_source_test.dart
```

Expected: fails until socket integration exists.

- [x] **Step 3: Implement routing**

Add `sendAudioGroupControlTo(peerId, control)` and route incoming group controls to `AudioGroupCoordinator`.

- [x] **Step 4: Run green test**

Run:

```bash
flutter test test/audio_group_socket_routing_source_test.dart
```

Expected: passes.

### Task 7: UI Entry And State

**Files:**
- Modify: `lib/page/conversation.dart`
- Modify: `lib/page/settings.dart` or add a focused group setup widget.
- Test: `test/audio_group_ui_source_test.dart`

- [x] **Step 1: Write failing UI source tests**

Require:

- audio group entry is shown only when connected peers support `audioGroupSinkV1`.
- multiple connected sinks can be selected.
- Android sinks can be selected for audio even when remote input controls are hidden.
- left/right roles are represented in UI state.

- [x] **Step 2: Run red test**

Run:

```bash
flutter test test/audio_group_ui_source_test.dart
```

Expected: fails until UI is wired.

- [x] **Step 3: Implement UI**

Add a minimal but usable group setup flow. Avoid visual polish until the runtime is green.

- [x] **Step 4: Run green test**

Run:

```bash
flutter test test/audio_group_ui_source_test.dart
```

Expected: passes.

### Task 8: Full Verification

**Files:**
- All files touched above.

- [x] **Step 1: Run focused tests**

Run:

```bash
flutter test test/audio_group_protocol_test.dart test/audio_group_session_test.dart test/audio_fanout_transport_test.dart test/audio_group_playback_scheduler_test.dart test/audio_group_coordinator_test.dart
```

Expected: passes.

- [x] **Step 2: Run full static and test suite**

Run:

```bash
flutter analyze
flutter test
```

Expected: both pass.

- [x] **Step 3: Manual verification checklist**

Use one Mac and two Android devices:

- Mac source -> two Android sinks, both play.
- Mac source -> Android left + Android right.
- Disconnect one Android; the other continues.
- Stop source; both sinks stop.
- Try a second source while Android is already a sink; it rejects.
