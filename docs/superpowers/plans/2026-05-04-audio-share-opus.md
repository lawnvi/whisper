# Audio Share Opus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Build the first audio sharing slice: capability negotiation, control protocol, Opus codec abstraction, and a dedicated realtime WebSocket path ready for native capture/playback.

**Architecture:** Existing chat/file WebSocket remains the control channel. Audio data uses a separate `/audio` WebSocket route with small binary Opus frames. Native platform capture/playback is hidden behind a Dart `AudioPlatform` boundary so Windows/macOS/Linux capture and all-platform playback can be filled in per platform.

**Tech Stack:** Flutter/Dart, `shelf_web_socket`, `opus_codec`, `opus_codec_dart`, Flutter method channels, `flutter_test`.

**Implemented native coverage in this branch:** Android speaker playback via `AudioTrack`; iOS speaker playback via `AVAudioEngine`; macOS speaker playback plus system audio capture via `AVAudioEngine` and `ScreenCaptureKit`; Windows speaker playback via `waveOut` plus WASAPI loopback capture; Linux speaker playback plus PulseAudio/PipeWire-Pulse monitor capture when PulseAudio development libraries are available.

---

### Task 1: Audio Protocol And Capability

**Files:**
- Create: `lib/audio/audio_protocol.dart`
- Modify: `lib/state/peer_profile.dart`
- Test: `test/audio_protocol_test.dart`

- [x] **Step 1: Write failing tests**

Add tests for `PeerCapabilities` audio flags, `AudioControlMessage` JSON round trip, and `AudioPacketFrame` binary round trip.

- [x] **Step 2: Run red tests**

Run: `flutter test test/audio_protocol_test.dart`
Expected: fails because audio protocol types and capability fields do not exist.

- [x] **Step 3: Implement minimal protocol**

Create value classes for audio format, control action, control message, and binary packet frames with a short magic header.

- [x] **Step 4: Run green tests**

Run: `flutter test test/audio_protocol_test.dart`
Expected: passes.

### Task 2: Opus Codec Boundary

**Files:**
- Create: `lib/audio/audio_codec.dart`
- Modify: `pubspec.yaml`
- Test: `test/audio_codec_test.dart`

- [x] **Step 1: Write failing tests**

Add tests using a fake codec to prove the app-level interface encodes/decodes exact frame payloads without binding tests to native libopus.

- [x] **Step 2: Run red tests**

Run: `flutter test test/audio_codec_test.dart`
Expected: fails because `AudioCodec` does not exist.

- [x] **Step 3: Implement minimal codec interface**

Add an abstract `AudioCodec`, `AudioCodecConfig`, fake-friendly implementation helpers, and a production `OpusAudioCodec` shell using `opus_codec_dart`.

- [x] **Step 4: Run green tests**

Run: `flutter test test/audio_codec_test.dart`
Expected: passes.

### Task 3: Dedicated Audio WebSocket Route

**Files:**
- Create: `lib/audio/audio_share_manager.dart`
- Modify: `lib/socket/svrmanager.dart`
- Test: `test/audio_share_manager_test.dart`

- [x] **Step 1: Write failing tests**

Add tests for session state transitions and packet routing into a sink callback.

- [x] **Step 2: Run red tests**

Run: `flutter test test/audio_share_manager_test.dart`
Expected: fails because the manager does not exist.

- [x] **Step 3: Implement minimal realtime manager**

Add `AudioShareManager` with offer/accept/stop control helpers and `/audio` route attachment; keep platform capture/playback out of this task.

- [x] **Step 4: Run green tests**

Run: `flutter test test/audio_share_manager_test.dart`
Expected: passes.

### Task 4: Platform Boundary

**Files:**
- Create: `lib/audio/audio_platform.dart`
- Modify: `android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt`
- Create: `android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt`
- Test: `test/audio_platform_test.dart`

- [x] **Step 1: Write failing tests**

Add method-channel tests verifying start/stop playback calls use the agreed method names and payloads.

- [x] **Step 2: Run red tests**

Run: `flutter test test/audio_platform_test.dart`
Expected: fails because `AudioPlatform` does not exist.

- [x] **Step 3: Implement minimal platform adapter**

Add Dart method channel and Android playback skeleton using `AudioTrack`; leave desktop capture/playback as explicit `notImplemented` platform responses.

- [x] **Step 4: Run green tests**

Run: `flutter test test/audio_platform_test.dart`
Expected: passes.
