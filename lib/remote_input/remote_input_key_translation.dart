import 'dart:convert';
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

    if (data.containsKey('sourcePlatform') &&
        data['sourcePlatform'] is! String) {
      return <RemoteInputPacketFrame>[frame];
    }
    final sourcePlatform = _effectiveSourcePlatform(
      data,
      remoteInputPlatformKindFromString(_stringValue(data['sourcePlatform'])),
      targetPlatform,
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
        'keyCode': _targetKeyCode(codes, targetPlatform),
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
      'keyCode': _targetKeyCode(key, targetPlatform),
    };
  }
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

int? _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return null;
}

String? _stringValue(Object? value) {
  if (value is String) {
    return value;
  }
  return null;
}

RemoteInputPlatformKind _effectiveSourcePlatform(
  Map<String, dynamic> data,
  RemoteInputPlatformKind declared,
  RemoteInputPlatformKind targetPlatform,
) {
  if (declared != RemoteInputPlatformKind.unknown) {
    return declared;
  }
  switch (targetPlatform) {
    case RemoteInputPlatformKind.macos:
      if (_intValue(data['windowsKeyCode']) != null ||
          _modifierSemantic(data, RemoteInputPlatformKind.windows) != null ||
          _regularKeyCodesFor(data, RemoteInputPlatformKind.windows) != null) {
        return RemoteInputPlatformKind.windows;
      }
      if (_intValue(data['linuxKeyCode']) != null ||
          _modifierSemantic(data, RemoteInputPlatformKind.linux) != null ||
          _regularKeyCodesFor(data, RemoteInputPlatformKind.linux) != null) {
        return RemoteInputPlatformKind.linux;
      }
      return RemoteInputPlatformKind.macos;
    case RemoteInputPlatformKind.windows:
      if (_intValue(data['macKeyCode']) != null ||
          _modifierSemantic(data, RemoteInputPlatformKind.macos) != null ||
          _regularKeyCodesFor(data, RemoteInputPlatformKind.macos) != null) {
        return RemoteInputPlatformKind.macos;
      }
      if (_intValue(data['linuxKeyCode']) != null ||
          _modifierSemantic(data, RemoteInputPlatformKind.linux) != null ||
          _regularKeyCodesFor(data, RemoteInputPlatformKind.linux) != null) {
        return RemoteInputPlatformKind.linux;
      }
      return RemoteInputPlatformKind.windows;
    case RemoteInputPlatformKind.linux:
      if (_intValue(data['macKeyCode']) != null ||
          _modifierSemantic(data, RemoteInputPlatformKind.macos) != null ||
          _regularKeyCodesFor(data, RemoteInputPlatformKind.macos) != null) {
        return RemoteInputPlatformKind.macos;
      }
      if (_intValue(data['windowsKeyCode']) != null ||
          _modifierSemantic(data, RemoteInputPlatformKind.windows) != null ||
          _regularKeyCodesFor(data, RemoteInputPlatformKind.windows) != null) {
        return RemoteInputPlatformKind.windows;
      }
      return RemoteInputPlatformKind.linux;
    case RemoteInputPlatformKind.unknown:
      return RemoteInputPlatformKind.unknown;
  }
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
          return RemoteInputModifierSemantic.meta;
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
          return RemoteInputModifierSemantic.control;
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
          return RemoteInputModifierSemantic.control;
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

int _targetKeyCode(
  RemoteInputKeyCodeSet codes,
  RemoteInputPlatformKind targetPlatform,
) {
  switch (targetPlatform) {
    case RemoteInputPlatformKind.macos:
      return codes.macKeyCode;
    case RemoteInputPlatformKind.windows:
      return codes.windowsKeyCode;
    case RemoteInputPlatformKind.linux:
      return codes.linuxKeyCode;
    case RemoteInputPlatformKind.unknown:
      return codes.macKeyCode;
  }
}

const List<RemoteInputKeyCodeSet> _regularKeyCodeSets = <RemoteInputKeyCodeSet>[
  RemoteInputKeyCodeSet(
      semantic: 'keyA', macKeyCode: 0, windowsKeyCode: 0x41, linuxKeyCode: 30),
  RemoteInputKeyCodeSet(
      semantic: 'keyS', macKeyCode: 1, windowsKeyCode: 0x53, linuxKeyCode: 31),
  RemoteInputKeyCodeSet(
      semantic: 'keyD', macKeyCode: 2, windowsKeyCode: 0x44, linuxKeyCode: 32),
  RemoteInputKeyCodeSet(
      semantic: 'keyF', macKeyCode: 3, windowsKeyCode: 0x46, linuxKeyCode: 33),
  RemoteInputKeyCodeSet(
      semantic: 'keyH', macKeyCode: 4, windowsKeyCode: 0x48, linuxKeyCode: 35),
  RemoteInputKeyCodeSet(
      semantic: 'keyG', macKeyCode: 5, windowsKeyCode: 0x47, linuxKeyCode: 34),
  RemoteInputKeyCodeSet(
      semantic: 'keyZ', macKeyCode: 6, windowsKeyCode: 0x5A, linuxKeyCode: 44),
  RemoteInputKeyCodeSet(
      semantic: 'keyX', macKeyCode: 7, windowsKeyCode: 0x58, linuxKeyCode: 45),
  RemoteInputKeyCodeSet(
      semantic: 'keyC', macKeyCode: 8, windowsKeyCode: 0x43, linuxKeyCode: 46),
  RemoteInputKeyCodeSet(
      semantic: 'keyV', macKeyCode: 9, windowsKeyCode: 0x56, linuxKeyCode: 47),
  RemoteInputKeyCodeSet(
      semantic: 'keyB', macKeyCode: 11, windowsKeyCode: 0x42, linuxKeyCode: 48),
  RemoteInputKeyCodeSet(
      semantic: 'keyQ', macKeyCode: 12, windowsKeyCode: 0x51, linuxKeyCode: 16),
  RemoteInputKeyCodeSet(
      semantic: 'keyW', macKeyCode: 13, windowsKeyCode: 0x57, linuxKeyCode: 17),
  RemoteInputKeyCodeSet(
      semantic: 'keyE', macKeyCode: 14, windowsKeyCode: 0x45, linuxKeyCode: 18),
  RemoteInputKeyCodeSet(
      semantic: 'keyR', macKeyCode: 15, windowsKeyCode: 0x52, linuxKeyCode: 19),
  RemoteInputKeyCodeSet(
      semantic: 'keyY', macKeyCode: 16, windowsKeyCode: 0x59, linuxKeyCode: 21),
  RemoteInputKeyCodeSet(
      semantic: 'keyT', macKeyCode: 17, windowsKeyCode: 0x54, linuxKeyCode: 20),
  RemoteInputKeyCodeSet(
      semantic: 'digit1',
      macKeyCode: 18,
      windowsKeyCode: 0x31,
      linuxKeyCode: 2),
  RemoteInputKeyCodeSet(
      semantic: 'digit2',
      macKeyCode: 19,
      windowsKeyCode: 0x32,
      linuxKeyCode: 3),
  RemoteInputKeyCodeSet(
      semantic: 'digit3',
      macKeyCode: 20,
      windowsKeyCode: 0x33,
      linuxKeyCode: 4),
  RemoteInputKeyCodeSet(
      semantic: 'digit4',
      macKeyCode: 21,
      windowsKeyCode: 0x34,
      linuxKeyCode: 5),
  RemoteInputKeyCodeSet(
      semantic: 'digit6',
      macKeyCode: 22,
      windowsKeyCode: 0x36,
      linuxKeyCode: 7),
  RemoteInputKeyCodeSet(
      semantic: 'digit5',
      macKeyCode: 23,
      windowsKeyCode: 0x35,
      linuxKeyCode: 6),
  RemoteInputKeyCodeSet(
      semantic: 'equal',
      macKeyCode: 24,
      windowsKeyCode: 0xBB,
      linuxKeyCode: 13),
  RemoteInputKeyCodeSet(
      semantic: 'digit9',
      macKeyCode: 25,
      windowsKeyCode: 0x39,
      linuxKeyCode: 10),
  RemoteInputKeyCodeSet(
      semantic: 'digit7',
      macKeyCode: 26,
      windowsKeyCode: 0x37,
      linuxKeyCode: 8),
  RemoteInputKeyCodeSet(
      semantic: 'minus',
      macKeyCode: 27,
      windowsKeyCode: 0xBD,
      linuxKeyCode: 12),
  RemoteInputKeyCodeSet(
      semantic: 'digit8',
      macKeyCode: 28,
      windowsKeyCode: 0x38,
      linuxKeyCode: 9),
  RemoteInputKeyCodeSet(
      semantic: 'digit0',
      macKeyCode: 29,
      windowsKeyCode: 0x30,
      linuxKeyCode: 11),
  RemoteInputKeyCodeSet(
      semantic: 'bracketRight',
      macKeyCode: 30,
      windowsKeyCode: 0xDD,
      linuxKeyCode: 27),
  RemoteInputKeyCodeSet(
      semantic: 'keyO', macKeyCode: 31, windowsKeyCode: 0x4F, linuxKeyCode: 24),
  RemoteInputKeyCodeSet(
      semantic: 'keyU', macKeyCode: 32, windowsKeyCode: 0x55, linuxKeyCode: 22),
  RemoteInputKeyCodeSet(
      semantic: 'bracketLeft',
      macKeyCode: 33,
      windowsKeyCode: 0xDB,
      linuxKeyCode: 26),
  RemoteInputKeyCodeSet(
      semantic: 'keyI', macKeyCode: 34, windowsKeyCode: 0x49, linuxKeyCode: 23),
  RemoteInputKeyCodeSet(
      semantic: 'keyP', macKeyCode: 35, windowsKeyCode: 0x50, linuxKeyCode: 25),
  RemoteInputKeyCodeSet(
      semantic: 'enter',
      macKeyCode: 36,
      windowsKeyCode: 0x0D,
      linuxKeyCode: 28),
  RemoteInputKeyCodeSet(
      semantic: 'keyL', macKeyCode: 37, windowsKeyCode: 0x4C, linuxKeyCode: 38),
  RemoteInputKeyCodeSet(
      semantic: 'keyJ', macKeyCode: 38, windowsKeyCode: 0x4A, linuxKeyCode: 36),
  RemoteInputKeyCodeSet(
      semantic: 'quote',
      macKeyCode: 39,
      windowsKeyCode: 0xDE,
      linuxKeyCode: 40),
  RemoteInputKeyCodeSet(
      semantic: 'keyK', macKeyCode: 40, windowsKeyCode: 0x4B, linuxKeyCode: 37),
  RemoteInputKeyCodeSet(
      semantic: 'semicolon',
      macKeyCode: 41,
      windowsKeyCode: 0xBA,
      linuxKeyCode: 39),
  RemoteInputKeyCodeSet(
      semantic: 'backslash',
      macKeyCode: 42,
      windowsKeyCode: 0xDC,
      linuxKeyCode: 43),
  RemoteInputKeyCodeSet(
      semantic: 'comma',
      macKeyCode: 43,
      windowsKeyCode: 0xBC,
      linuxKeyCode: 51),
  RemoteInputKeyCodeSet(
      semantic: 'slash',
      macKeyCode: 44,
      windowsKeyCode: 0xBF,
      linuxKeyCode: 53),
  RemoteInputKeyCodeSet(
      semantic: 'keyN', macKeyCode: 45, windowsKeyCode: 0x4E, linuxKeyCode: 49),
  RemoteInputKeyCodeSet(
      semantic: 'keyM', macKeyCode: 46, windowsKeyCode: 0x4D, linuxKeyCode: 50),
  RemoteInputKeyCodeSet(
      semantic: 'period',
      macKeyCode: 47,
      windowsKeyCode: 0xBE,
      linuxKeyCode: 52),
  RemoteInputKeyCodeSet(
      semantic: 'tab', macKeyCode: 48, windowsKeyCode: 0x09, linuxKeyCode: 15),
  RemoteInputKeyCodeSet(
      semantic: 'space',
      macKeyCode: 49,
      windowsKeyCode: 0x20,
      linuxKeyCode: 57),
  RemoteInputKeyCodeSet(
      semantic: 'backquote',
      macKeyCode: 50,
      windowsKeyCode: 0xC0,
      linuxKeyCode: 41),
  RemoteInputKeyCodeSet(
      semantic: 'backspace',
      macKeyCode: 51,
      windowsKeyCode: 0x08,
      linuxKeyCode: 14),
  RemoteInputKeyCodeSet(
      semantic: 'escape',
      macKeyCode: 53,
      windowsKeyCode: 0x1B,
      linuxKeyCode: 1),
  RemoteInputKeyCodeSet(
      semantic: 'delete',
      macKeyCode: 117,
      windowsKeyCode: 0x2E,
      linuxKeyCode: 111),
  RemoteInputKeyCodeSet(
      semantic: 'arrowLeft',
      macKeyCode: 123,
      windowsKeyCode: 0x25,
      linuxKeyCode: 105),
  RemoteInputKeyCodeSet(
      semantic: 'arrowRight',
      macKeyCode: 124,
      windowsKeyCode: 0x27,
      linuxKeyCode: 106),
  RemoteInputKeyCodeSet(
      semantic: 'arrowDown',
      macKeyCode: 125,
      windowsKeyCode: 0x28,
      linuxKeyCode: 108),
  RemoteInputKeyCodeSet(
      semantic: 'arrowUp',
      macKeyCode: 126,
      windowsKeyCode: 0x26,
      linuxKeyCode: 103),
];

RemoteInputKeyCodeSet? _regularKeyCodesFor(
  Map<String, dynamic> data,
  RemoteInputPlatformKind sourcePlatform,
) {
  final keyCode = switch (sourcePlatform) {
    RemoteInputPlatformKind.macos =>
      _intValue(data['macKeyCode'] ?? data['keyCode']),
    RemoteInputPlatformKind.windows =>
      _intValue(data['windowsKeyCode'] ?? data['keyCode']),
    RemoteInputPlatformKind.linux =>
      _intValue(data['linuxKeyCode'] ?? data['keyCode']),
    RemoteInputPlatformKind.unknown => null,
  };
  if (keyCode == null) {
    return null;
  }

  for (final codes in _regularKeyCodeSets) {
    if (sourcePlatform == RemoteInputPlatformKind.macos &&
        codes.macKeyCode == keyCode) {
      return codes;
    }
    if (sourcePlatform == RemoteInputPlatformKind.windows &&
        codes.windowsKeyCode == keyCode) {
      return codes;
    }
    if (sourcePlatform == RemoteInputPlatformKind.linux &&
        codes.linuxKeyCode == keyCode) {
      return codes;
    }
  }
  return null;
}
