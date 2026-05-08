import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  group('Remote input keyboard regression matrix', () {
    test('keeps plain letter entry stable for mirror typing', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      for (final key in const [
        _KeyCase('m', mac: 46, win: 0x4D, linux: 50, semantic: 'keyM'),
        _KeyCase('i', mac: 34, win: 0x49, linux: 23, semantic: 'keyI'),
        _KeyCase('r', mac: 15, win: 0x52, linux: 19, semantic: 'keyR'),
        _KeyCase('o', mac: 31, win: 0x4F, linux: 24, semantic: 'keyO'),
      ]) {
        final down = _payload(translator
            .translateFrame(_keyFrame({
              'sourcePlatform': 'macos',
              'keyCode': key.mac,
              'macKeyCode': key.mac,
              'windowsKeyCode': key.win,
              'down': true,
            }))
            .single);
        final up = _payload(translator
            .translateFrame(_keyFrame({
              'sourcePlatform': 'macos',
              'keyCode': key.mac,
              'macKeyCode': key.mac,
              'windowsKeyCode': key.win,
              'down': false,
            }))
            .single);

        expect(down['keySemantic'], key.semantic, reason: key.label);
        expect(down['keyCode'], key.mac, reason: key.label);
        expect(down['macKeyCode'], key.mac, reason: key.label);
        expect(down['windowsKeyCode'], key.win, reason: key.label);
        expect(down['linuxKeyCode'], key.linux, reason: key.label);
        expect(down['down'], isTrue, reason: key.label);
        expect(up['keySemantic'], key.semantic, reason: key.label);
        expect(up['down'], isFalse, reason: key.label);
      }
    });

    test('keeps macOS Command text shortcuts as meta plus text keys', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final commandDown = _payload(translator
          .translateFrame(_keyFrame({
            'sourcePlatform': 'macos',
            'keyCode': 55,
            'macKeyCode': 55,
            'down': true,
          }))
          .single);
      expect(commandDown['modifierSemantic'], 'meta');
      expect(commandDown['keyCode'], 55);
      expect(commandDown['macKeyCode'], 55);

      for (final key in const [
        _KeyCase('command+a', mac: 0, win: 0x41, linux: 30, semantic: 'keyA'),
        _KeyCase('command+c', mac: 8, win: 0x43, linux: 46, semantic: 'keyC'),
        _KeyCase('command+x', mac: 7, win: 0x58, linux: 45, semantic: 'keyX'),
        _KeyCase('command+v', mac: 9, win: 0x56, linux: 47, semantic: 'keyV'),
      ]) {
        final payload = _payload(translator
            .translateFrame(_keyFrame({
              'sourcePlatform': 'macos',
              'keyCode': key.mac,
              'macKeyCode': key.mac,
              'windowsKeyCode': key.win,
              'down': true,
            }))
            .single);

        expect(payload['keySemantic'], key.semantic, reason: key.label);
        expect(payload['keyCode'], key.mac, reason: key.label);
        expect(payload['macKeyCode'], key.mac, reason: key.label);
        expect(payload['windowsKeyCode'], key.win, reason: key.label);
        expect(payload['linuxKeyCode'], key.linux, reason: key.label);
      }
    });

    test('keeps Control arrow shortcuts on macOS HID key codes', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final controlDown = _payload(translator
          .translateFrame(_keyFrame({
            'sourcePlatform': 'macos',
            'keyCode': 59,
            'macKeyCode': 59,
            'down': true,
          }))
          .single);
      expect(controlDown['modifierSemantic'], 'control');
      expect(controlDown['keyCode'], 59);

      for (final key in const [
        _KeyCase('control+left',
            mac: 123, win: 0x25, linux: 105, semantic: 'arrowLeft'),
        _KeyCase('control+right',
            mac: 124, win: 0x27, linux: 106, semantic: 'arrowRight'),
        _KeyCase('control+down',
            mac: 125, win: 0x28, linux: 108, semantic: 'arrowDown'),
        _KeyCase('control+up',
            mac: 126, win: 0x26, linux: 103, semantic: 'arrowUp'),
      ]) {
        final payload = _payload(translator
            .translateFrame(_keyFrame({
              'sourcePlatform': 'macos',
              'keyCode': key.mac,
              'macKeyCode': key.mac,
              'windowsKeyCode': key.win,
              'down': true,
            }))
            .single);

        expect(payload['keySemantic'], key.semantic, reason: key.label);
        expect(payload['keyCode'], key.mac, reason: key.label);
        expect(payload['macKeyCode'], key.mac, reason: key.label);
      }
    });

    test('keeps Caps Lock semantic distinct from normal key press/release', () {
      final translator = RemoteInputKeyTranslator(
        targetPlatform: RemoteInputPlatformKind.macos,
      );

      final payload = _payload(translator
          .translateFrame(_keyFrame({
            'sourcePlatform': 'macos',
            'keyCode': 57,
            'macKeyCode': 57,
            'windowsKeyCode': 0x14,
            'down': true,
          }))
          .single);

      expect(payload['modifierSemantic'], 'capsLock');
      expect(payload['keyCode'], 57);
      expect(payload['macKeyCode'], 57);
      expect(payload['windowsKeyCode'], 0x14);
      expect(payload['linuxKeyCode'], 58);
      expect(payload['down'], isTrue);
    });
  });
}

class _KeyCase {
  const _KeyCase(
    this.label, {
    required this.mac,
    required this.win,
    required this.linux,
    required this.semantic,
  });

  final String label;
  final int mac;
  final int win;
  final int linux;
  final String semantic;
}

RemoteInputPacketFrame _keyFrame(Map<String, dynamic> payload) {
  return RemoteInputPacketFrame(
    sessionId: 'input-key-matrix',
    sequence: 1,
    timestampMicros: 2,
    eventType: RemoteInputEventType.key,
    payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
  );
}

Map<String, dynamic> _payload(RemoteInputPacketFrame frame) {
  return jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
}
