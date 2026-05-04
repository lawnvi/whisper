# Remote Input Key Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace combo-key presets with platform-semantic key translation that works for macOS, Windows, and Linux.

**Architecture:** Native capture continues to send raw platform key events, but every key payload also declares its source platform. A Dart translator runs on the sink before native injection, maps source modifiers into semantic modifiers like `primary`, `shift`, `alt`, `control`, and `meta`, then emits target-native key codes. Linux is included in the protocol and translation maps immediately; Linux native capture/injection remains capability-gated until its backend is implemented and tested.

**Tech Stack:** Flutter/Dart, JSON key payloads inside existing `RemoteInputPacketFrame`, MethodChannel native bridges, macOS Quartz/CoreGraphics key codes, Windows virtual-key codes, Linux evdev key codes with future X11/XTest and Wayland portal/libei adapters.

---

## File Structure

- Create `lib/remote_input/remote_input_key_translation.dart`
  - Defines platform kind parsing, modifier semantics, key-code maps, payload helpers, and sink-side frame translation.
- Modify `lib/remote_input/remote_input_coordinator.dart`
  - Applies key translation before `_platform.injectEvent(packet)` on sink devices.
- Modify `lib/helper/helper.dart`
  - Adds a single Dart helper for the current remote-input platform kind.
- Modify `macos/Runner/MainFlutterWindow.swift`
  - Adds `"sourcePlatform": "macos"` to captured key payloads.
- Modify `windows/runner/remote_input_plugin.cpp`
  - Adds `"sourcePlatform": "windows"` to captured key payloads.
- Test `test/remote_input_key_translation_test.dart`
  - Covers macOS, Windows, and Linux modifier/key translation without native devices.
- Modify `test/remote_input_coordinator_test.dart`
  - Verifies sink injection receives translated key payloads.

## Translation Rules

- `primary`
  - Source macOS: Command.
  - Source Windows/Linux: Control.
  - Target macOS: Command.
  - Target Windows/Linux: Control.
- `control`
  - Source macOS: Control.
  - Source Windows/Linux: Control only when a later raw-mode setting asks for physical passthrough. In the default semantic mode, Windows/Linux Control is `primary`.
  - Target macOS: Control.
  - Target Windows/Linux: Control.
- `shift`, `alt`, `meta`, and `capsLock`
  - Preserve their semantic meaning where the target OS has a distinct equivalent.
  - On macOS, `meta` maps to Command because macOS does not expose a separate Windows/Super key equivalent through the current injection path.
- Regular keys
  - Translate by stable key identity where known: letters, digits, punctuation used by the existing native maps, Tab, Escape, Enter, Space, Backspace, Delete, and arrow keys.
  - Preserve unknown payloads unchanged so unsupported keys fail soft instead of corrupting the input stream.

## Task 1: Dart Key Translator

**Files:**
- Create: `lib/remote_input/remote_input_key_translation.dart`
- Test: `test/remote_input_key_translation_test.dart`

- [ ] **Step 1: Write the failing translator tests**

Create `test/remote_input_key_translation_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  group('RemoteInputKeyTranslator', () {
    test('maps Windows Control to macOS primary Command', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final translated = translator.translateFrame(_keyFrame(<String, dynamic>{
        'sourcePlatform': 'windows',
        'keyCode': 0x11,
        'windowsKeyCode': 0x11,
        'macKeyCode': 59,
        'down': true,
      }));

      expect(translated, hasLength(1));
      final payload = _payload(translated.single);
      expect(payload['modifierSemantic'], 'primary');
      expect(payload['macKeyCode'], 55);
      expect(payload['windowsKeyCode'], 0x11);
      expect(payload['linuxKeyCode'], 29);
      expect(payload['down'], isTrue);
    });

    test('maps macOS Command to Windows primary Control', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.windows,
      );

      final translated = translator.translateFrame(_keyFrame(<String, dynamic>{
        'sourcePlatform': 'macos',
        'keyCode': 55,
        'macKeyCode': 55,
        'windowsKeyCode': 0x11,
        'down': true,
      }));

      final payload = _payload(translated.single);
      expect(payload['modifierSemantic'], 'primary');
      expect(payload['macKeyCode'], 55);
      expect(payload['windowsKeyCode'], 0x11);
      expect(payload['linuxKeyCode'], 29);
    });

    test('maps Linux Control to macOS primary Command', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final translated = translator.translateFrame(_keyFrame(<String, dynamic>{
        'sourcePlatform': 'linux',
        'keyCode': 29,
        'linuxKeyCode': 29,
        'down': true,
      }));

      final payload = _payload(translated.single);
      expect(payload['modifierSemantic'], 'primary');
      expect(payload['macKeyCode'], 55);
      expect(payload['windowsKeyCode'], 0x11);
      expect(payload['linuxKeyCode'], 29);
    });

    test('maps regular C key across all platform code spaces', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.linux,
      );

      final translated = translator.translateFrame(_keyFrame(<String, dynamic>{
        'sourcePlatform': 'macos',
        'keyCode': 8,
        'macKeyCode': 8,
        'windowsKeyCode': 0x43,
        'down': true,
      }));

      final payload = _payload(translated.single);
      expect(payload['keySemantic'], 'keyC');
      expect(payload['macKeyCode'], 8);
      expect(payload['windowsKeyCode'], 0x43);
      expect(payload['linuxKeyCode'], 46);
    });

    test('keeps unknown key payloads unchanged', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.windows,
      );

      final original = _keyFrame(<String, dynamic>{
        'sourcePlatform': 'linux',
        'keyCode': 9999,
        'linuxKeyCode': 9999,
        'down': true,
      });

      final translated = translator.translateFrame(original);

      expect(translated.single.payload, original.payload);
    });
  });
}

RemoteInputPacketFrame _keyFrame(Map<String, dynamic> payload) {
  return RemoteInputPacketFrame(
    sessionId: 'input-keys-1',
    sequence: 1,
    timestampMicros: 2,
    eventType: RemoteInputEventType.key,
    payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
  );
}

Map<String, dynamic> _payload(RemoteInputPacketFrame frame) {
  return jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
}
```

- [ ] **Step 2: Run the translator tests and confirm they fail**

Run:

```bash
flutter test test/remote_input_key_translation_test.dart
```

Expected: compile failure because `remote_input_key_translation.dart`, `RemoteInputKeyTranslator`, and `RemoteInputPlatformKind` do not exist.

- [ ] **Step 3: Implement the translator**

Create `lib/remote_input/remote_input_key_translation.dart` with this structure:

```dart
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:whisper/remote_input/remote_input_protocol.dart';

enum RemoteInputPlatformKind {
  macos,
  windows,
  linux,
  unknown,
}

enum RemoteInputModifierSemantic {
  primary,
  control,
  shift,
  alt,
  meta,
  capsLock,
}

class RemoteInputKeyCodeSet {
  const RemoteInputKeyCodeSet({
    required this.semantic,
    required this.macKeyCode,
    required this.windowsKeyCode,
    required this.linuxKeyCode,
  });

  final String semantic;
  final int macKeyCode;
  final int windowsKeyCode;
  final int linuxKeyCode;

  Map<String, dynamic> toPayloadFields() {
    return <String, dynamic>{
      'keySemantic': semantic,
      'macKeyCode': macKeyCode,
      'windowsKeyCode': windowsKeyCode,
      'linuxKeyCode': linuxKeyCode,
    };
  }
}

class RemoteInputKeyTranslator {
  RemoteInputKeyTranslator({
    required this.targetPlatform,
  });

  final RemoteInputPlatformKind targetPlatform;

  List<RemoteInputPacketFrame> translateFrame(RemoteInputPacketFrame frame) {
    if (frame.eventType != RemoteInputEventType.key) {
      return <RemoteInputPacketFrame>[frame];
    }
    final data = _decodePayload(frame.payload);
    if (data == null) {
      return <RemoteInputPacketFrame>[frame];
    }
    final sourcePlatform = remoteInputPlatformKindFromString(
      data['sourcePlatform'] as String?,
    );
    final translated = _translatePayload(data, sourcePlatform);
    if (translated == null) {
      return <RemoteInputPacketFrame>[frame];
    }
    return <RemoteInputPacketFrame>[
      RemoteInputPacketFrame(
        sessionId: frame.sessionId,
        sequence: frame.sequence,
        timestampMicros: frame.timestampMicros,
        eventType: frame.eventType,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(translated))),
      ),
    ];
  }

  Map<String, dynamic>? _translatePayload(
    Map<String, dynamic> data,
    RemoteInputPlatformKind sourcePlatform,
  ) {
    final modifier = _modifierSemantic(data, sourcePlatform);
    if (modifier != null) {
      final codes = _modifierCodes(modifier);
      return <String, dynamic>{
        ...data,
        ...codes.toPayloadFields(),
        'modifierSemantic': modifier.name,
      };
    }
    final key = _regularKeyCodesFor(data, sourcePlatform);
    if (key == null) {
      return null;
    }
    return <String, dynamic>{
      ...data,
      ...key.toPayloadFields(),
    };
  }
}

RemoteInputPlatformKind currentRemoteInputPlatformKind() {
  if (Platform.isMacOS) {
    return RemoteInputPlatformKind.macos;
  }
  if (Platform.isWindows) {
    return RemoteInputPlatformKind.windows;
  }
  if (Platform.isLinux) {
    return RemoteInputPlatformKind.linux;
  }
  return RemoteInputPlatformKind.unknown;
}

RemoteInputPlatformKind remoteInputPlatformKindFromString(String? value) {
  switch ((value ?? '').toLowerCase()) {
    case 'macos':
    case 'mac':
      return RemoteInputPlatformKind.macos;
    case 'windows':
    case 'win':
      return RemoteInputPlatformKind.windows;
    case 'linux':
      return RemoteInputPlatformKind.linux;
    default:
      return RemoteInputPlatformKind.unknown;
  }
}
```

Add private helpers in the same file:

```dart
Map<String, dynamic>? _decodePayload(Uint8List payload) {
  try {
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
  } catch (_) {
    return null;
  }
  return null;
}

int _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return 0;
}

RemoteInputModifierSemantic? _modifierSemantic(
  Map<String, dynamic> data,
  RemoteInputPlatformKind sourcePlatform,
) {
  switch (sourcePlatform) {
    case RemoteInputPlatformKind.macos:
      switch (_intValue(data['macKeyCode'] ?? data['keyCode'])) {
        case 54:
        case 55:
          return RemoteInputModifierSemantic.primary;
        case 56:
        case 60:
          return RemoteInputModifierSemantic.shift;
        case 58:
        case 61:
          return RemoteInputModifierSemantic.alt;
        case 59:
        case 62:
          return RemoteInputModifierSemantic.control;
        case 57:
          return RemoteInputModifierSemantic.capsLock;
      }
      return null;
    case RemoteInputPlatformKind.windows:
      switch (_intValue(data['windowsKeyCode'] ?? data['keyCode'])) {
        case 0x11:
        case 0xA2:
        case 0xA3:
          return RemoteInputModifierSemantic.primary;
        case 0x10:
        case 0xA0:
        case 0xA1:
          return RemoteInputModifierSemantic.shift;
        case 0x12:
        case 0xA4:
        case 0xA5:
          return RemoteInputModifierSemantic.alt;
        case 0x5B:
        case 0x5C:
          return RemoteInputModifierSemantic.meta;
        case 0x14:
          return RemoteInputModifierSemantic.capsLock;
      }
      return null;
    case RemoteInputPlatformKind.linux:
      switch (_intValue(data['linuxKeyCode'] ?? data['keyCode'])) {
        case 29:
        case 97:
          return RemoteInputModifierSemantic.primary;
        case 42:
        case 54:
          return RemoteInputModifierSemantic.shift;
        case 56:
        case 100:
          return RemoteInputModifierSemantic.alt;
        case 125:
        case 126:
          return RemoteInputModifierSemantic.meta;
        case 58:
          return RemoteInputModifierSemantic.capsLock;
      }
      return null;
    case RemoteInputPlatformKind.unknown:
      return null;
  }
}

RemoteInputKeyCodeSet _modifierCodes(RemoteInputModifierSemantic modifier) {
  switch (modifier) {
    case RemoteInputModifierSemantic.primary:
      return const RemoteInputKeyCodeSet(
        semantic: 'primary',
        macKeyCode: 55,
        windowsKeyCode: 0x11,
        linuxKeyCode: 29,
      );
    case RemoteInputModifierSemantic.control:
      return const RemoteInputKeyCodeSet(
        semantic: 'control',
        macKeyCode: 59,
        windowsKeyCode: 0x11,
        linuxKeyCode: 29,
      );
    case RemoteInputModifierSemantic.shift:
      return const RemoteInputKeyCodeSet(
        semantic: 'shift',
        macKeyCode: 56,
        windowsKeyCode: 0x10,
        linuxKeyCode: 42,
      );
    case RemoteInputModifierSemantic.alt:
      return const RemoteInputKeyCodeSet(
        semantic: 'alt',
        macKeyCode: 58,
        windowsKeyCode: 0x12,
        linuxKeyCode: 56,
      );
    case RemoteInputModifierSemantic.meta:
      return const RemoteInputKeyCodeSet(
        semantic: 'meta',
        macKeyCode: 55,
        windowsKeyCode: 0x5B,
        linuxKeyCode: 125,
      );
    case RemoteInputModifierSemantic.capsLock:
      return const RemoteInputKeyCodeSet(
        semantic: 'capsLock',
        macKeyCode: 57,
        windowsKeyCode: 0x14,
        linuxKeyCode: 58,
      );
  }
}
```

Add regular key lookup maps in the same file. Start with keys already supported by both native maps and include Linux evdev codes:

```dart
const List<RemoteInputKeyCodeSet> _regularKeyCodes = <RemoteInputKeyCodeSet>[
  RemoteInputKeyCodeSet(semantic: 'keyA', macKeyCode: 0, windowsKeyCode: 0x41, linuxKeyCode: 30),
  RemoteInputKeyCodeSet(semantic: 'keyS', macKeyCode: 1, windowsKeyCode: 0x53, linuxKeyCode: 31),
  RemoteInputKeyCodeSet(semantic: 'keyD', macKeyCode: 2, windowsKeyCode: 0x44, linuxKeyCode: 32),
  RemoteInputKeyCodeSet(semantic: 'keyF', macKeyCode: 3, windowsKeyCode: 0x46, linuxKeyCode: 33),
  RemoteInputKeyCodeSet(semantic: 'keyH', macKeyCode: 4, windowsKeyCode: 0x48, linuxKeyCode: 35),
  RemoteInputKeyCodeSet(semantic: 'keyG', macKeyCode: 5, windowsKeyCode: 0x47, linuxKeyCode: 34),
  RemoteInputKeyCodeSet(semantic: 'keyZ', macKeyCode: 6, windowsKeyCode: 0x5A, linuxKeyCode: 44),
  RemoteInputKeyCodeSet(semantic: 'keyX', macKeyCode: 7, windowsKeyCode: 0x58, linuxKeyCode: 45),
  RemoteInputKeyCodeSet(semantic: 'keyC', macKeyCode: 8, windowsKeyCode: 0x43, linuxKeyCode: 46),
  RemoteInputKeyCodeSet(semantic: 'keyV', macKeyCode: 9, windowsKeyCode: 0x56, linuxKeyCode: 47),
  RemoteInputKeyCodeSet(semantic: 'keyB', macKeyCode: 11, windowsKeyCode: 0x42, linuxKeyCode: 48),
  RemoteInputKeyCodeSet(semantic: 'keyQ', macKeyCode: 12, windowsKeyCode: 0x51, linuxKeyCode: 16),
  RemoteInputKeyCodeSet(semantic: 'keyW', macKeyCode: 13, windowsKeyCode: 0x57, linuxKeyCode: 17),
  RemoteInputKeyCodeSet(semantic: 'keyE', macKeyCode: 14, windowsKeyCode: 0x45, linuxKeyCode: 18),
  RemoteInputKeyCodeSet(semantic: 'keyR', macKeyCode: 15, windowsKeyCode: 0x52, linuxKeyCode: 19),
  RemoteInputKeyCodeSet(semantic: 'keyY', macKeyCode: 16, windowsKeyCode: 0x59, linuxKeyCode: 21),
  RemoteInputKeyCodeSet(semantic: 'keyT', macKeyCode: 17, windowsKeyCode: 0x54, linuxKeyCode: 20),
  RemoteInputKeyCodeSet(semantic: 'digit1', macKeyCode: 18, windowsKeyCode: 0x31, linuxKeyCode: 2),
  RemoteInputKeyCodeSet(semantic: 'digit2', macKeyCode: 19, windowsKeyCode: 0x32, linuxKeyCode: 3),
  RemoteInputKeyCodeSet(semantic: 'digit3', macKeyCode: 20, windowsKeyCode: 0x33, linuxKeyCode: 4),
  RemoteInputKeyCodeSet(semantic: 'digit4', macKeyCode: 21, windowsKeyCode: 0x34, linuxKeyCode: 5),
  RemoteInputKeyCodeSet(semantic: 'digit6', macKeyCode: 22, windowsKeyCode: 0x36, linuxKeyCode: 7),
  RemoteInputKeyCodeSet(semantic: 'digit5', macKeyCode: 23, windowsKeyCode: 0x35, linuxKeyCode: 6),
  RemoteInputKeyCodeSet(semantic: 'digit9', macKeyCode: 25, windowsKeyCode: 0x39, linuxKeyCode: 10),
  RemoteInputKeyCodeSet(semantic: 'digit7', macKeyCode: 26, windowsKeyCode: 0x37, linuxKeyCode: 8),
  RemoteInputKeyCodeSet(semantic: 'digit8', macKeyCode: 28, windowsKeyCode: 0x38, linuxKeyCode: 9),
  RemoteInputKeyCodeSet(semantic: 'digit0', macKeyCode: 29, windowsKeyCode: 0x30, linuxKeyCode: 11),
  RemoteInputKeyCodeSet(semantic: 'enter', macKeyCode: 36, windowsKeyCode: 0x0D, linuxKeyCode: 28),
  RemoteInputKeyCodeSet(semantic: 'tab', macKeyCode: 48, windowsKeyCode: 0x09, linuxKeyCode: 15),
  RemoteInputKeyCodeSet(semantic: 'space', macKeyCode: 49, windowsKeyCode: 0x20, linuxKeyCode: 57),
  RemoteInputKeyCodeSet(semantic: 'backspace', macKeyCode: 51, windowsKeyCode: 0x08, linuxKeyCode: 14),
  RemoteInputKeyCodeSet(semantic: 'escape', macKeyCode: 53, windowsKeyCode: 0x1B, linuxKeyCode: 1),
  RemoteInputKeyCodeSet(semantic: 'delete', macKeyCode: 117, windowsKeyCode: 0x2E, linuxKeyCode: 111),
  RemoteInputKeyCodeSet(semantic: 'arrowLeft', macKeyCode: 123, windowsKeyCode: 0x25, linuxKeyCode: 105),
  RemoteInputKeyCodeSet(semantic: 'arrowRight', macKeyCode: 124, windowsKeyCode: 0x27, linuxKeyCode: 106),
  RemoteInputKeyCodeSet(semantic: 'arrowDown', macKeyCode: 125, windowsKeyCode: 0x28, linuxKeyCode: 108),
  RemoteInputKeyCodeSet(semantic: 'arrowUp', macKeyCode: 126, windowsKeyCode: 0x26, linuxKeyCode: 103),
];

RemoteInputKeyCodeSet? _regularKeyCodesFor(
  Map<String, dynamic> data,
  RemoteInputPlatformKind sourcePlatform,
) {
  final keyCode = switch (sourcePlatform) {
    RemoteInputPlatformKind.macos => _intValue(data['macKeyCode'] ?? data['keyCode']),
    RemoteInputPlatformKind.windows => _intValue(data['windowsKeyCode'] ?? data['keyCode']),
    RemoteInputPlatformKind.linux => _intValue(data['linuxKeyCode'] ?? data['keyCode']),
    RemoteInputPlatformKind.unknown => 0,
  };
  for (final codes in _regularKeyCodes) {
    if (sourcePlatform == RemoteInputPlatformKind.macos && codes.macKeyCode == keyCode) {
      return codes;
    }
    if (sourcePlatform == RemoteInputPlatformKind.windows && codes.windowsKeyCode == keyCode) {
      return codes;
    }
    if (sourcePlatform == RemoteInputPlatformKind.linux && codes.linuxKeyCode == keyCode) {
      return codes;
    }
  }
  return null;
}
```

Use `_regularKeyCodesFor` inside `_translatePayload`. Name the list `_regularKeyCodeSets` if the helper name would otherwise collide.

- [ ] **Step 4: Run translator tests and confirm they pass**

Run:

```bash
flutter test test/remote_input_key_translation_test.dart
```

Expected: all translator tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/remote_input/remote_input_key_translation.dart test/remote_input_key_translation_test.dart
git commit -m "feat: add remote input key translator"
```

## Task 2: Sink-Side Translation Wiring

**Files:**
- Modify: `lib/remote_input/remote_input_coordinator.dart`
- Modify: `lib/helper/helper.dart`
- Test: `test/remote_input_coordinator_test.dart`

- [ ] **Step 1: Write the failing coordinator test**

Add a test beside the existing sink injection tests:

```dart
test('sink translates key payloads before native injection', () async {
  final sentControls = <RemoteInputControlMessage>[];
  final manager = RemoteInputManager();
  final coordinator = RemoteInputCoordinator(
    manager: manager,
    platform: platform,
    transportFactory: (_) async => _FakeRemoteInputTransport(),
    keyTranslatorFactory: (platformKind) => RemoteInputKeyTranslator(
      targetPlatform: RemoteInputPlatformKind.macos,
    ),
  );
  const offer = RemoteInputControlMessage(
    action: RemoteInputControlAction.offer,
    sessionId: 'input-key-translate-1',
    sourcePeerId: 'win',
    sinkPeerId: 'mac',
    layoutEdge: RemoteInputEdge.right,
    releaseHotkey: 'ctrl+alt+esc',
  );

  await coordinator.handleControlMessage(
    offer,
    localPeerId: 'mac',
    remoteHost: 'win.local',
    remotePort: 10002,
    isMutuallyTrusted: true,
    localCanInject: true,
    sendControl: sentControls.add,
  );

  manager.handlePacketBytes(
    RemoteInputPacketFrame(
      sessionId: 'input-key-translate-1',
      sequence: 1,
      timestampMicros: 2,
      eventType: RemoteInputEventType.key,
      payload: Uint8List.fromList(utf8.encode(jsonEncode(<String, dynamic>{
        'sourcePlatform': 'windows',
        'keyCode': 0x11,
        'windowsKeyCode': 0x11,
        'macKeyCode': 59,
        'down': true,
      }))),
    ).encode(),
  );
  await Future<void>.delayed(Duration.zero);

  final injectCall = calls.lastWhere((call) => call.method == 'injectEvent');
  final args = injectCall.arguments as Map<Object?, Object?>;
  final payload = jsonDecode(
    utf8.decode(args['payload'] as Uint8List),
  ) as Map<String, dynamic>;

  expect(payload['macKeyCode'], 55);
  expect(payload['modifierSemantic'], 'primary');
});
```

Add imports:

```dart
import 'dart:convert';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
```

- [ ] **Step 2: Run the coordinator test and confirm it fails**

Run:

```bash
flutter test test/remote_input_coordinator_test.dart --plain-name "sink translates key payloads before native injection"
```

Expected: compile failure because `RemoteInputCoordinator` has no `keyTranslatorFactory` argument.

- [ ] **Step 3: Add key translator injection to the coordinator**

Modify `RemoteInputCoordinator` constructor:

```dart
typedef RemoteInputKeyTranslatorFactory = RemoteInputKeyTranslator Function(
  RemoteInputPlatformKind platform,
);

RemoteInputCoordinator({
  RemoteInputManager? manager,
  RemoteInputPlatform? platform,
  RemoteInputTransportFactory? transportFactory,
  RemoteInputKeyTranslatorFactory? keyTranslatorFactory,
})  : _manager = manager ?? RemoteInputManager.shared,
      _platform = platform ?? RemoteInputPlatform(),
      _transportFactory =
          transportFactory ?? RemoteInputWebSocketPacketTransport.connect,
      _keyTranslatorFactory = keyTranslatorFactory ??
          ((platform) => RemoteInputKeyTranslator(targetPlatform: platform));
```

Add fields:

```dart
final RemoteInputKeyTranslatorFactory _keyTranslatorFactory;
RemoteInputKeyTranslator? _keyTranslator;
```

Clear it in `stopLocal()`:

```dart
_keyTranslator = null;
```

Initialize it in `_startInjection` after `startInjection` succeeds:

```dart
_keyTranslator = _keyTranslatorFactory(currentRemoteInputPlatformKind());
```

Translate before injecting:

```dart
_manager.onPacket = (packet) {
  final translated = _keyTranslator?.translateFrame(packet) ??
      <RemoteInputPacketFrame>[packet];
  for (final frame in translated) {
    unawaited(_platform.injectEvent(frame));
  }
};
```

- [ ] **Step 4: Move platform helper to `helper.dart`**

If the translator file currently imports `dart:io`, move `currentRemoteInputPlatformKind()` to `lib/helper/helper.dart` so platform detection stays with existing helpers:

```dart
import 'package:whisper/remote_input/remote_input_key_translation.dart';

RemoteInputPlatformKind currentRemoteInputPlatformKind() {
  if (Platform.isMacOS) {
    return RemoteInputPlatformKind.macos;
  }
  if (Platform.isWindows) {
    return RemoteInputPlatformKind.windows;
  }
  if (Platform.isLinux) {
    return RemoteInputPlatformKind.linux;
  }
  return RemoteInputPlatformKind.unknown;
}
```

Keep `supportsNativeRemoteInput()` as macOS/Windows only in this task:

```dart
bool supportsNativeRemoteInput() {
  return Platform.isMacOS || Platform.isWindows;
}
```

- [ ] **Step 5: Run coordinator and translator tests**

Run:

```bash
flutter test test/remote_input_key_translation_test.dart test/remote_input_coordinator_test.dart
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/helper/helper.dart lib/remote_input/remote_input_coordinator.dart test/remote_input_coordinator_test.dart
git commit -m "feat: translate remote input keys before injection"
```

## Task 3: Native Source Platform Metadata

**Files:**
- Modify: `macos/Runner/MainFlutterWindow.swift`
- Modify: `windows/runner/remote_input_plugin.cpp`

- [ ] **Step 1: Add macOS source platform to key payloads**

In `macos/Runner/MainFlutterWindow.swift`, inside the `"key"` payload in `encodePayload`, include:

```swift
"sourcePlatform": "macos",
```

The full payload block should include:

```swift
payload = [
  "sourcePlatform": "macos",
  "keyCode": macKeyCode,
  "macKeyCode": macKeyCode,
  "windowsKeyCode": windowsVirtualKey(forMacKeyCode: macKeyCode),
  "down": type == .flagsChanged
    ? modifierKeyDown(macKeyCode, flags: event.flags)
    : type == .keyDown
]
```

- [ ] **Step 2: Add Windows source platform to key payloads**

In `windows/runner/remote_input_plugin.cpp`, change `KeyPayload` to emit:

```cpp
std::string KeyPayload(USHORT virtual_key, bool down) {
  std::ostringstream json;
  json << "{\"sourcePlatform\":\"windows\""
       << ",\"keyCode\":" << virtual_key
       << ",\"windowsKeyCode\":" << virtual_key
       << ",\"macKeyCode\":"
       << WindowsVirtualKeyToMac(virtual_key)
       << ",\"down\":" << (down ? "true" : "false") << "}";
  return json.str();
}
```

- [ ] **Step 3: Build macOS**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: macOS debug build succeeds and launches.

- [ ] **Step 4: Build Windows on a Windows machine**

Run on Windows:

```powershell
flutter build windows --debug
```

Expected: Windows debug build succeeds without warnings treated as errors.

- [ ] **Step 5: Commit**

```bash
git add macos/Runner/MainFlutterWindow.swift windows/runner/remote_input_plugin.cpp
git commit -m "feat: tag remote input key source platform"
```

## Task 4: Preserve Current Native Injection Fallbacks

**Files:**
- Modify: `macos/Runner/MainFlutterWindow.swift`
- Modify: `windows/runner/remote_input_plugin.cpp`

- [ ] **Step 1: Confirm macOS injection reads translated `macKeyCode` first**

Keep this behavior in `nativeMacKeyCode(_:)`:

```swift
let nativeKeyCode = intValue(data["macKeyCode"])
if nativeKeyCode > 0 || data["macKeyCode"] != nil {
  return nativeKeyCode
}
```

If the implementation changed while doing Task 3, restore it.

- [ ] **Step 2: Confirm Windows injection reads translated `windowsKeyCode` first**

Keep this behavior in `InjectEvent` for `"key"`:

```cpp
const auto windows_key = JsonNumber(json, "windowsKeyCode");
const int raw_key = static_cast<int>(
    windows_key.value_or(JsonNumber(json, "keyCode").value_or(0)));
input.ki.wVk = windows_key.has_value()
                   ? static_cast<WORD>(raw_key)
                   : MacVirtualKeyToWindows(raw_key);
```

If the implementation changed while doing Task 3, restore it.

- [ ] **Step 3: Run remote input tests**

Run:

```bash
flutter test test/remote_input_key_translation_test.dart test/remote_input_coordinator_test.dart test/remote_input_protocol_test.dart
```

Expected: all tests pass.

- [ ] **Step 4: Run analyzer**

Run:

```bash
flutter analyze
```

Expected: no issues found.

- [ ] **Step 5: Commit only if code changed**

```bash
git add macos/Runner/MainFlutterWindow.swift windows/runner/remote_input_plugin.cpp
git commit -m "fix: keep native key injection fallbacks"
```

## Task 5: Linux Protocol Readiness

**Files:**
- Modify: `lib/helper/helper.dart`
- Test: `test/remote_input_key_translation_test.dart`

- [ ] **Step 1: Add explicit Linux capability guard test**

Add to `test/remote_input_key_translation_test.dart`:

```dart
test('recognizes Linux platform strings for protocol translation', () {
  expect(
    remoteInputPlatformKindFromString('linux'),
    RemoteInputPlatformKind.linux,
  );
});
```

- [ ] **Step 2: Keep Linux native capability disabled until backend exists**

Do not change `supportsNativeRemoteInput()` to return true on Linux in this plan. Keep:

```dart
bool supportsNativeRemoteInput() {
  return Platform.isMacOS || Platform.isWindows;
}
```

This keeps Linux peers from advertising source/sink support before a native plugin can capture and inject input.

- [ ] **Step 3: Record Linux backend requirements in code comments near the guard**

Add this concise comment above `supportsNativeRemoteInput()`:

```dart
// Linux is included in the remote input key protocol, but native source/sink
// support stays disabled until an X11 or Wayland backend is implemented.
```

- [ ] **Step 4: Run translator tests**

Run:

```bash
flutter test test/remote_input_key_translation_test.dart
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/helper/helper.dart test/remote_input_key_translation_test.dart
git commit -m "test: cover linux remote input key semantics"
```

## Task 6: Manual Verification Matrix

**Files:**
- No source changes.

- [ ] **Step 1: Verify macOS controls Windows**

On macOS and Windows, start the app from this branch. Enable keyboard/mouse sharing with macOS as source and Windows as sink. Verify:

```text
Command+C on Mac triggers copy on Windows.
Command+V on Mac triggers paste on Windows.
Command+A on Mac triggers select all on Windows.
Shift+Arrow on Mac extends selection on Windows.
Option/Alt modified keys are still delivered as Alt on Windows.
Mouse crossing and return behavior remains fixed.
```

- [ ] **Step 2: Verify Windows controls macOS**

Enable keyboard/mouse sharing with Windows as source and macOS as sink. Verify:

```text
Ctrl+C on Windows triggers copy on macOS.
Ctrl+V on Windows triggers paste on macOS.
Ctrl+A on Windows triggers select all on macOS.
Shift+Arrow on Windows extends selection on macOS.
Alt modified keys are delivered as Option on macOS.
Mouse crossing and return behavior remains fixed.
```

- [ ] **Step 3: Confirm Linux does not falsely advertise native support**

Without a Linux native backend, Linux builds should not advertise `remoteInputSourceV1` or `remoteInputSinkV1`. Verify by reading the auth profile or UI state:

```text
Linux peer remains hidden or disabled for remote input runtime controls.
Key translator tests still cover Linux protocol mapping.
```

- [ ] **Step 4: Final verification commands**

Run:

```bash
flutter test test/remote_input_key_translation_test.dart test/remote_input_coordinator_test.dart test/remote_input_manager_test.dart test/remote_input_platform_test.dart test/remote_input_protocol_test.dart test/remote_input_layout_test.dart
flutter analyze
git diff --check
```

Expected:

```text
All tests passed.
No issues found.
No whitespace errors.
```

## Self-Review

- Spec coverage: The plan covers no-preset combo handling through semantic modifier translation, preserves current macOS/Windows native injection paths, and includes Linux in protocol-level key translation while keeping native capability disabled until the backend exists.
- Placeholder scan: The plan contains concrete files, test snippets, implementation snippets, commands, and expected results.
- Type consistency: `RemoteInputPlatformKind`, `RemoteInputKeyTranslator`, `translateFrame`, `modifierSemantic`, `keySemantic`, `macKeyCode`, `windowsKeyCode`, and `linuxKeyCode` are used consistently across tasks.
