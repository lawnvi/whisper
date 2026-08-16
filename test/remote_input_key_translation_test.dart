import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  group('RemoteInputKeyTranslator', () {
    test('recognizes Linux platform strings for protocol translation', () {
      expect(
        remoteInputPlatformKindFromString('linux'),
        RemoteInputPlatformKind.linux,
      );
    });

    test('maps Windows Control to macOS Control', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final translated = translator.translateFrame(
        _keyFrame(<String, dynamic>{
          'sourcePlatform': 'windows',
          'keyCode': 0x11,
          'windowsKeyCode': 0x11,
          'macKeyCode': 59,
          'down': true,
        }),
      );

      expect(translated, hasLength(1));
      final payload = _payload(translated.single);
      expect(payload['modifierSemantic'], 'control');
      expect(payload['keyCode'], 59);
      expect(payload['macKeyCode'], 59);
      expect(payload['windowsKeyCode'], 0x11);
      expect(payload['linuxKeyCode'], 29);
      expect(payload['down'], isTrue);
    });

    test('maps Windows Meta to macOS Command', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final translated = translator.translateFrame(
        _keyFrame(<String, dynamic>{
          'sourcePlatform': 'windows',
          'keyCode': 0x5B,
          'windowsKeyCode': 0x5B,
          'macKeyCode': 55,
          'down': true,
        }),
      );

      final payload = _payload(translated.single);
      expect(payload['modifierSemantic'], 'meta');
      expect(payload['keyCode'], 55);
      expect(payload['macKeyCode'], 55);
      expect(payload['windowsKeyCode'], 0x5B);
      expect(payload['linuxKeyCode'], 125);
    });

    test('maps macOS Command to Windows Meta', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.windows,
      );

      final translated = translator.translateFrame(
        _keyFrame(<String, dynamic>{
          'sourcePlatform': 'macos',
          'keyCode': 55,
          'macKeyCode': 55,
          'windowsKeyCode': 0x11,
          'down': true,
        }),
      );

      final payload = _payload(translated.single);
      expect(payload['modifierSemantic'], 'meta');
      expect(payload['keyCode'], 0x5B);
      expect(payload['macKeyCode'], 55);
      expect(payload['windowsKeyCode'], 0x5B);
      expect(payload['linuxKeyCode'], 125);
    });

    test('preserves native macOS Caps Lock companion metadata', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final translated = translator.translateFrame(
        _keyFrame(<String, dynamic>{
          'sourcePlatform': 'macos',
          'keyCode': 57,
          'macKeyCode': 57,
          'modifierSemantic': 'capsLock',
          'macCapsLockKeyCode': 255,
          'macCapsLockFlags': 256,
          'down': false,
        }),
      );

      final payload = _payload(translated.single);
      expect(payload['modifierSemantic'], 'capsLock');
      expect(payload['macKeyCode'], 57);
      expect(payload['macCapsLockKeyCode'], 255);
      expect(payload['macCapsLockFlags'], 256);
      expect(payload['down'], isFalse);
    });

    test('maps Linux Control to macOS Control', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final translated = translator.translateFrame(
        _keyFrame(<String, dynamic>{
          'sourcePlatform': 'linux',
          'keyCode': 29,
          'linuxKeyCode': 29,
          'down': true,
        }),
      );

      final payload = _payload(translated.single);
      expect(payload['modifierSemantic'], 'control');
      expect(payload['macKeyCode'], 59);
      expect(payload['windowsKeyCode'], 0x11);
      expect(payload['linuxKeyCode'], 29);
    });

    test('maps regular C key across all platform code spaces', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.linux,
      );

      final translated = translator.translateFrame(
        _keyFrame(<String, dynamic>{
          'sourcePlatform': 'macos',
          'keyCode': 8,
          'macKeyCode': 8,
          'windowsKeyCode': 0x43,
          'down': true,
        }),
      );

      final payload = _payload(translated.single);
      expect(payload['keySemantic'], 'keyC');
      expect(payload['keyCode'], 46);
      expect(payload['macKeyCode'], 8);
      expect(payload['windowsKeyCode'], 0x43);
      expect(payload['linuxKeyCode'], 46);
    });

    test('maps regular O key across all platform code spaces', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.linux,
      );

      final translated = translator.translateFrame(
        _keyFrame(<String, dynamic>{
          'sourcePlatform': 'macos',
          'keyCode': 31,
          'macKeyCode': 31,
          'windowsKeyCode': 0x4F,
          'down': true,
        }),
      );

      final payload = _payload(translated.single);
      expect(payload['keySemantic'], 'keyO');
      expect(payload['macKeyCode'], 31);
      expect(payload['windowsKeyCode'], 0x4F);
      expect(payload['linuxKeyCode'], 24);
    });

    test('maps slash key across all platform code spaces', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final translated = translator.translateFrame(
        _keyFrame(<String, dynamic>{
          'sourcePlatform': 'windows',
          'keyCode': 0xBF,
          'windowsKeyCode': 0xBF,
          'down': true,
        }),
      );

      final payload = _payload(translated.single);
      expect(payload['keySemantic'], 'slash');
      expect(payload['keyCode'], 44);
      expect(payload['macKeyCode'], 44);
      expect(payload['windowsKeyCode'], 0xBF);
      expect(payload['linuxKeyCode'], 53);
    });

    test('infers bare Windows key codes for macOS sinks', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final translated = translator.translateFrame(
        _keyFrame(<String, dynamic>{'keyCode': 0x41, 'down': true}),
      );

      final payload = _payload(translated.single);
      expect(payload['keySemantic'], 'keyA');
      expect(payload['keyCode'], 0);
      expect(payload['macKeyCode'], 0);
      expect(payload['windowsKeyCode'], 0x41);
      expect(payload['linuxKeyCode'], 30);
    });

    test('infers bare macOS key codes for Windows sinks', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.windows,
      );

      final translated = translator.translateFrame(
        _keyFrame(<String, dynamic>{'keyCode': 8, 'down': true}),
      );

      final payload = _payload(translated.single);
      expect(payload['keySemantic'], 'keyC');
      expect(payload['keyCode'], 0x43);
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

    test('keeps macOS key payloads without key codes unchanged', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.windows,
      );

      final original = _keyFrame(<String, dynamic>{
        'sourcePlatform': 'macos',
        'down': true,
      });

      final translated = translator.translateFrame(original);

      expect(translated.single.payload, original.payload);
    });

    test('keeps key payloads with non-string source platforms unchanged', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final original = _keyFrame(<String, dynamic>{
        'sourcePlatform': 7,
        'keyCode': 0x11,
        'windowsKeyCode': 0x11,
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
