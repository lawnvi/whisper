# Keyboard And Mouse Sharing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first keyboard and mouse sharing vertical slice for the currently connected trusted desktop peer.

**Architecture:** Reuse the audio-sharing split: control messages travel through the existing chat WebSocket, realtime packets travel through a dedicated `/input` WebSocket, Dart owns session/layout state, and native code owns capture/injection. Use mature helper packages where they reduce risk: `screen_retriever` for display/cursor data and `hotkey_manager` for the force-release shortcut; keep capture/injection in native platform bridges because available full input-simulation packages are not sufficiently verified for this app's Windows/Linux target.

**Tech Stack:** Flutter/Dart, Drift, MethodChannel, shelf WebSocket, macOS Quartz/CoreGraphics, Windows low-level hooks and `SendInput`, Linux X11/XTest with explicit Wayland unsupported errors.

---

## File Structure

- Create `lib/remote_input/remote_input_protocol.dart`: control messages, event types, packet frame codec.
- Create `lib/remote_input/remote_input_platform.dart`: MethodChannel wrapper and native callbacks.
- Create `lib/remote_input/remote_input_packet_transport.dart`: `/input` WebSocket packet transport.
- Create `lib/remote_input/remote_input_manager.dart`: session registry and packet dispatch.
- Create `lib/remote_input/remote_input_layout.dart`: screen rectangles, edge adjacency, traversal hit testing.
- Create `lib/remote_input/remote_input_coordinator.dart`: source/sink state machine.
- Modify `lib/model/message.dart`: append `RemoteInputControl`.
- Modify `lib/model/LocalDatabase.dart`, `lib/model/LocalDatabase.g.dart`: add `RemoteInputLayout` table and migration.
- Modify `lib/socket/svrmanager.dart`: serve `/input`, advertise/handle remote input control, stop on disconnect.
- Modify `lib/state/app_shutdown.dart` callers: stop remote input during desktop shutdown.
- Modify `lib/page/conversation.dart`: add runtime button and status strings.
- Modify `lib/page/settings.dart`: add peer setting toggles and screen layout entry.
- Modify `pubspec.yaml`: add direct `screen_retriever` and `hotkey_manager`.
- Modify platform runners:
  - `macos/Runner/AppDelegate.swift`
  - `windows/runner/CMakeLists.txt`
  - `windows/runner/remote_input_plugin.h`
  - `windows/runner/remote_input_plugin.cpp`
  - `windows/runner/flutter_window.cpp`
  - `linux/CMakeLists.txt`
  - `linux/my_application.cc`
  - `linux/remote_input_plugin.h`
  - `linux/remote_input_plugin.cc`
- Tests:
  - `test/remote_input_protocol_test.dart`
  - `test/remote_input_layout_test.dart`
  - `test/remote_input_platform_test.dart`
  - `test/remote_input_manager_test.dart`
  - `test/remote_input_coordinator_test.dart`
  - update `test/audio_protocol_test.dart` or create `test/message_enum_compatibility_test.dart`

## Library Decisions

- Use `screen_retriever: ^0.2.0` directly. It supports Linux/macOS/Windows display and cursor APIs and is already present transitively in `pubspec.lock`.
- Use `hotkey_manager: ^0.2.3` directly for the force-release hotkey. It supports Linux/macOS/Windows and exposes a Flutter-friendly hotkey recorder for later UI polish.
- Do not depend on `bixat_key_mouse` for the first version. It provides simulation, but its own package page marks Windows and Linux as not tested, and the package has very low adoption.
- Do not depend on `uiohook_dart` for the first version. It is useful as a reference for libuiohook-style capture, but it has one old stable version and low adoption.
- Do not depend on the `mouse` package for the first version. It is narrow, low-adoption, and does not cover keyboard capture/injection.

## Task 1: Remote Input Protocol

**Files:**
- Create: `lib/remote_input/remote_input_protocol.dart`
- Modify: `lib/model/message.dart`
- Test: `test/remote_input_protocol_test.dart`

- [ ] **Step 1: Write failing protocol tests**

Create tests that assert:

```dart
test('remote input control round-trips offer fields', () {
  const message = RemoteInputControlMessage(
    action: RemoteInputControlAction.offer,
    sessionId: 'input-1',
    sourcePeerId: 'mac',
    sinkPeerId: 'win',
    transport: RemoteInputTransport.websocket,
    path: '/input',
    layoutEdge: RemoteInputEdge.right,
    releaseHotkey: 'ctrl+alt+esc',
  );

  final decoded = RemoteInputControlMessage.fromJson(message.toJson());

  expect(decoded.action, RemoteInputControlAction.offer);
  expect(decoded.sessionId, 'input-1');
  expect(decoded.sourcePeerId, 'mac');
  expect(decoded.sinkPeerId, 'win');
  expect(decoded.transport, RemoteInputTransport.websocket);
  expect(decoded.path, '/input');
  expect(decoded.layoutEdge, RemoteInputEdge.right);
  expect(decoded.releaseHotkey, 'ctrl+alt+esc');
});

test('remote input packet frame encodes and decodes mouse movement', () {
  final frame = RemoteInputPacketFrame(
    sessionId: 'input-1',
    sequence: 7,
    timestampMicros: 42,
    eventType: RemoteInputEventType.mouseMove,
    payload: Uint8List.fromList(<int>[1, 2, 3]),
  );

  final decoded = RemoteInputPacketFrame.decode(frame.encode());

  expect(decoded.sessionId, 'input-1');
  expect(decoded.sequence, 7);
  expect(decoded.timestampMicros, 42);
  expect(decoded.eventType, RemoteInputEventType.mouseMove);
  expect(decoded.payload, <int>[1, 2, 3]);
});

test('remote input control message enum is appended', () {
  expect(MessageEnum.RemoteInputControl.index, MessageEnum.AudioControl.index + 1);
});
```

- [ ] **Step 2: Verify tests fail**

Run:

```bash
flutter test test/remote_input_protocol_test.dart
```

Expected: compile failure because `RemoteInputControlMessage`, `RemoteInputPacketFrame`, and `MessageEnum.RemoteInputControl` do not exist.

- [ ] **Step 3: Implement protocol**

Add enums and frame codec modeled after `AudioControlMessage` and `AudioPacketFrame`, with magic `WRI1`.

- [ ] **Step 4: Verify tests pass**

Run:

```bash
flutter test test/remote_input_protocol_test.dart
```

Expected: all protocol tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/remote_input/remote_input_protocol.dart lib/model/message.dart test/remote_input_protocol_test.dart
git commit -m "feat: add remote input protocol"
```

## Task 2: Layout Persistence And Edge Detection

**Files:**
- Create: `lib/remote_input/remote_input_layout.dart`
- Modify: `lib/model/LocalDatabase.dart`
- Modify: `lib/model/LocalDatabase.g.dart`
- Test: `test/remote_input_layout_test.dart`

- [ ] **Step 1: Write failing layout tests**

Test stored layout defaults and geometry:

```dart
test('detects right-edge adjacency with partial vertical overlap', () {
  const local = RemoteInputScreenRect(x: 0, y: 0, width: 1000, height: 800);
  const peer = RemoteInputScreenRect(x: 1000, y: 240, width: 900, height: 600);

  final edge = RemoteInputLayoutGeometry.adjacentEdge(local: local, peer: peer);

  expect(edge, RemoteInputEdge.right);
});

test('does not create an edge for separated screens', () {
  const local = RemoteInputScreenRect(x: 0, y: 0, width: 1000, height: 800);
  const peer = RemoteInputScreenRect(x: 1050, y: 0, width: 900, height: 600);

  final edge = RemoteInputLayoutGeometry.adjacentEdge(local: local, peer: peer);

  expect(edge, isNull);
});
```

- [ ] **Step 2: Verify tests fail**

Run:

```bash
flutter test test/remote_input_layout_test.dart
```

Expected: compile failure because layout types do not exist.

- [ ] **Step 3: Implement layout model and Drift table**

Add `RemoteInputLayout` table with the fields from the spec. Increase schema version and add migration. Run:

```bash
dart run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 4: Verify tests pass**

Run:

```bash
flutter test test/remote_input_layout_test.dart
```

Expected: layout tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/remote_input/remote_input_layout.dart lib/model/LocalDatabase.dart lib/model/LocalDatabase.g.dart test/remote_input_layout_test.dart
git commit -m "feat: persist remote input layouts"
```

## Task 3: Platform Channel And Transport

**Files:**
- Create: `lib/remote_input/remote_input_platform.dart`
- Create: `lib/remote_input/remote_input_packet_transport.dart`
- Test: `test/remote_input_platform_test.dart`

- [ ] **Step 1: Write failing platform tests**

Assert MethodChannel calls:

```dart
test('starts capture with session edge and release hotkey', () async {
  const channel = MethodChannel('test_remote_input');
  final calls = <MethodCall>[];
  final platform = RemoteInputPlatform(channel: channel);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return null;
  });

  await platform.startCapture(
    sessionId: 'input-1',
    edge: RemoteInputEdge.right,
    releaseHotkey: 'ctrl+alt+esc',
  );

  expect(calls.single.method, 'startCapture');
  expect(calls.single.arguments['sessionId'], 'input-1');
  expect(calls.single.arguments['edge'], 'right');
  expect(calls.single.arguments['releaseHotkey'], 'ctrl+alt+esc');
});
```

- [ ] **Step 2: Verify tests fail**

Run:

```bash
flutter test test/remote_input_platform_test.dart
```

Expected: compile failure because `RemoteInputPlatform` does not exist.

- [ ] **Step 3: Implement platform wrapper and transport**

Add `startCapture`, `stopCapture`, `startInjection`, `injectEvent`, `stopInjection`, and native callback streams for input events, edge activation, release, and errors.

- [ ] **Step 4: Verify tests pass**

Run:

```bash
flutter test test/remote_input_platform_test.dart
```

Expected: platform tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/remote_input/remote_input_platform.dart lib/remote_input/remote_input_packet_transport.dart test/remote_input_platform_test.dart
git commit -m "feat: add remote input platform bridge"
```

## Task 4: Session Manager And Coordinator

**Files:**
- Create: `lib/remote_input/remote_input_manager.dart`
- Create: `lib/remote_input/remote_input_coordinator.dart`
- Test: `test/remote_input_manager_test.dart`
- Test: `test/remote_input_coordinator_test.dart`

- [ ] **Step 1: Write failing manager/coordinator tests**

Cover offer/accept, trusted capability checks, armed-to-active edge activation, source packet sending, sink injection, stop/error release, and auto-activation policy.

- [ ] **Step 2: Verify tests fail**

Run:

```bash
flutter test test/remote_input_manager_test.dart test/remote_input_coordinator_test.dart
```

Expected: compile failures because manager and coordinator do not exist.

- [ ] **Step 3: Implement manager/coordinator**

Model structure after `AudioShareManager` and `AudioShareCoordinator`, but add `armed` state and trust/capability gates.

- [ ] **Step 4: Verify tests pass**

Run:

```bash
flutter test test/remote_input_manager_test.dart test/remote_input_coordinator_test.dart
```

Expected: all remote input state tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/remote_input/remote_input_manager.dart lib/remote_input/remote_input_coordinator.dart test/remote_input_manager_test.dart test/remote_input_coordinator_test.dart
git commit -m "feat: coordinate remote input sessions"
```

## Task 5: Socket And Shutdown Integration

**Files:**
- Modify: `lib/socket/svrmanager.dart`
- Modify: `lib/page/deviceList.dart`
- Test: update `test/ws_event_dispatch_test.dart` or add focused socket dispatch tests if existing helpers allow it.

- [ ] **Step 1: Write failing socket dispatch test**

Assert `MessageEnum.RemoteInputControl` is parsed and routed to `RemoteInputCoordinator.handleControlMessage`.

- [ ] **Step 2: Verify test fails**

Run the focused socket dispatch test.

- [ ] **Step 3: Integrate `/input` route and control dispatch**

Add `/input` next to `/audio`, send `RemoteInputControl` messages, advertise existing capabilities, and call `RemoteInputCoordinator.shared.stopLocal()` on disconnect/shutdown.

- [ ] **Step 4: Verify tests pass**

Run:

```bash
flutter test test/ws_event_dispatch_test.dart test/app_shutdown_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add lib/socket/svrmanager.dart lib/page/deviceList.dart test/ws_event_dispatch_test.dart test/app_shutdown_test.dart
git commit -m "feat: route remote input sessions"
```

## Task 6: UI And Settings

**Files:**
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Modify: `lib/page/conversation.dart`
- Modify: `lib/page/settings.dart`
- Create or modify focused widget tests where practical.

- [ ] **Step 1: Add dependencies**

Add:

```yaml
screen_retriever: ^0.2.0
hotkey_manager: ^0.2.3
```

Run:

```bash
flutter pub get
```

- [ ] **Step 2: Write failing UI tests or focused state tests**

Assert the conversation action is available only when connected and capable, and settings can persist `autoActivate`.

- [ ] **Step 3: Implement UI**

Add the conversation button, state tooltips/toasts, peer settings toggles, and a first version of the arrangement canvas for the current peer.

- [ ] **Step 4: Verify**

Run:

```bash
dart format lib/page/conversation.dart lib/page/settings.dart
flutter analyze lib/page/conversation.dart lib/page/settings.dart
flutter test
```

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/page/conversation.dart lib/page/settings.dart test
git commit -m "feat: add remote input controls"
```

## Task 7: Native Platform Bridges

**Files:**
- Modify: `macos/Runner/AppDelegate.swift`
- Modify: `windows/runner/CMakeLists.txt`
- Create: `windows/runner/remote_input_plugin.h`
- Create: `windows/runner/remote_input_plugin.cpp`
- Modify: `windows/runner/flutter_window.cpp`
- Modify: `linux/CMakeLists.txt`
- Modify: `linux/my_application.cc`
- Create: `linux/remote_input_plugin.h`
- Create: `linux/remote_input_plugin.cc`

- [ ] **Step 1: macOS native bridge**

Implement MethodChannel methods with permission-aware Quartz/CoreGraphics capture/injection. Return clear `PlatformException` codes for missing accessibility/input monitoring permission.

- [ ] **Step 2: Windows native bridge**

Implement low-level keyboard/mouse hooks for capture and `SendInput` for injection. Register plugin in the runner and add source files to CMake.

- [ ] **Step 3: Linux native bridge**

Implement X11/XTest injection and a clear unsupported error for Wayland. Add required PkgConfig checks to CMake.

- [ ] **Step 4: Build verification**

Run:

```bash
flutter build macos --debug
flutter build windows --debug
flutter build linux --debug
```

Expected: macOS builds on this host. Windows/Linux may require matching hosts; if unavailable, record the environment limitation and run all possible Dart-side tests.

- [ ] **Step 5: Commit**

```bash
git add macos windows linux
git commit -m "feat: add native remote input bridges"
```

## Task 8: Full Verification

**Files:**
- All touched files.

- [ ] **Step 1: Run Dart formatting and checks**

```bash
dart format lib test
git diff --check
flutter analyze
flutter test
```

- [ ] **Step 2: Run available builds**

```bash
flutter build macos --debug
flutter build apk --debug
```

Run Windows/Linux builds on matching hosts when available.

- [ ] **Step 3: Manual verification notes**

Record which of macOS, Windows, and Linux were actually tested with real input sharing, and list remaining gaps.

- [ ] **Step 4: Final commit if needed**

```bash
git add .
git commit -m "test: verify remote input sharing"
```

## Self-Review

- Spec coverage: protocol, persistence, UI, coordinator, transport, platform bridges, safety release paths, library usage, and testing all map to tasks above.
- Red-flag scan: the plan avoids open-ended marker language; platform implementation tasks are bounded by specific APIs and verification commands.
- Type consistency: `RemoteInputControlMessage`, `RemoteInputPacketFrame`, `RemoteInputPlatform`, `RemoteInputCoordinator`, `RemoteInputEdge`, and `RemoteInputEventType` are named consistently across tasks.
