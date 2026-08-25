import 'dart:convert';
import 'dart:typed_data';

import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

enum RemoteInputScrollUnit {
  wheel,
  pixel,
}

class RemoteInputScrollNormalizer {
  const RemoteInputScrollNormalizer._();

  static const double wheelDelta = 120.0;
  static const double macosPixelsPerWheelTick = 120.0;
  static const double minimumMultiplier = 0.5;
  static const double maximumMultiplier = 3.0;

  static RemoteInputPacketFrame annotateSourceFrame(
    RemoteInputPacketFrame frame, {
    required RemoteInputPlatformKind sourcePlatform,
  }) {
    if (frame.eventType != RemoteInputEventType.mouseWheel) {
      return frame;
    }
    final data = _decodePayload(frame.payload);
    if (data == null) {
      return frame;
    }
    final existing = _semanticFromPayload(data);
    if (existing != null) {
      return _copyWithPayload(frame, <String, dynamic>{
        ...data,
        'sourcePlatform': _sourcePlatformName(data, sourcePlatform),
      });
    }

    final semantic = _capturedSemantic(data, sourcePlatform);
    return _copyWithPayload(frame, <String, dynamic>{
      ...data,
      'sourcePlatform': _platformName(sourcePlatform),
      'scrollUnit': semantic.unit.name,
      'scrollDeltaX': semantic.deltaX,
      'scrollDeltaY': semantic.deltaY,
    });
  }

  static RemoteInputPacketFrame normalizeForTarget(
    RemoteInputPacketFrame frame, {
    required RemoteInputPlatformKind targetPlatform,
    required double scrollMultiplier,
    RemoteInputPlatformKind fallbackSourcePlatform =
        RemoteInputPlatformKind.unknown,
  }) {
    if (frame.eventType != RemoteInputEventType.mouseWheel) {
      return frame;
    }
    final data = _decodePayload(frame.payload);
    if (data == null) {
      return frame;
    }
    final declaredSourcePlatform = remoteInputPlatformKindFromString(
      _stringValue(data['sourcePlatform']),
    );
    final sourcePlatform =
        declaredSourcePlatform == RemoteInputPlatformKind.unknown
            ? fallbackSourcePlatform
            : declaredSourcePlatform;
    final semantic =
        _semanticFromPayload(data) ??
        (sourcePlatform == RemoteInputPlatformKind.unknown
            ? _legacySemantic(data, sourcePlatform)
            : _capturedSemantic(data, sourcePlatform));
    if (semantic == null) {
      return frame;
    }

    final multiplier = clampMultiplier(scrollMultiplier);
    final target = _targetDelta(
      semantic,
      targetPlatform: targetPlatform,
      multiplier: multiplier,
    );

    return _copyWithPayload(frame, <String, dynamic>{
      ...data,
      'sourcePlatform': _sourcePlatformName(data, sourcePlatform),
      'scrollUnit': semantic.unit.name,
      'scrollDeltaX': semantic.deltaX,
      'scrollDeltaY': semantic.deltaY,
      'scrollMultiplier': multiplier,
      'targetScrollUnit': target.unit.name,
      // Native injectors retain fractional remainders so precise touchpad
      // movement is neither exaggerated nor lost between packets.
      'deltaX': target.deltaX,
      'deltaY': target.deltaY,
    });
  }

  static double clampMultiplier(double multiplier) {
    if (multiplier.isNaN || multiplier.isInfinite) {
      return 1.0;
    }
    return multiplier.clamp(minimumMultiplier, maximumMultiplier).toDouble();
  }

  static _ScrollDelta _capturedSemantic(
    Map<String, dynamic> data,
    RemoteInputPlatformKind sourcePlatform,
  ) {
    final rawX = _numberValue(data['deltaX']) ?? 0;
    final rawY = _numberValue(data['deltaY']) ?? 0;
    switch (sourcePlatform) {
      case RemoteInputPlatformKind.windows:
      case RemoteInputPlatformKind.linux:
        return _ScrollDelta(
          unit: RemoteInputScrollUnit.wheel,
          deltaX: rawX / wheelDelta,
          deltaY: rawY / wheelDelta,
        );
      case RemoteInputPlatformKind.macos:
        final pointX = _numberValue(data['pointDeltaX']) ?? 0;
        final pointY = _numberValue(data['pointDeltaY']) ?? 0;
        final fixedX = _numberValue(data['fixedDeltaX']) ?? pointX;
        final fixedY = _numberValue(data['fixedDeltaY']) ?? pointY;
        final declaredPreciseX = _numberValue(data['preciseDeltaX']) ?? fixedX;
        final declaredPreciseY = _numberValue(data['preciseDeltaY']) ?? fixedY;
        final preciseX = declaredPreciseX == 0 && pointX != 0
            ? pointX
            : declaredPreciseX;
        final preciseY = declaredPreciseY == 0 && pointY != 0
            ? pointY
            : declaredPreciseY;
        final declaresPrecision =
            data.containsKey('isPrecise') || data.containsKey('isContinuous');
        final isPrecise =
            _boolValue(data['isPrecise']) || _boolValue(data['isContinuous']);
        if (isPrecise || (!declaresPrecision && (pointX != 0 || pointY != 0))) {
          return _ScrollDelta(
            unit: RemoteInputScrollUnit.pixel,
            deltaX: preciseX,
            deltaY: preciseY,
          );
        }
        return _ScrollDelta(
          unit: RemoteInputScrollUnit.wheel,
          deltaX: rawX,
          deltaY: rawY,
        );
      case RemoteInputPlatformKind.unknown:
        return _legacySemantic(data, sourcePlatform) ??
            const _ScrollDelta(
              unit: RemoteInputScrollUnit.wheel,
              deltaX: 0,
              deltaY: 0,
            );
    }
  }

  static _ScrollDelta? _semanticFromPayload(Map<String, dynamic> data) {
    final unit = _scrollUnitFromString(_stringValue(data['scrollUnit']));
    if (unit == null) {
      return null;
    }
    final deltaX = _numberValue(data['scrollDeltaX']);
    final deltaY = _numberValue(data['scrollDeltaY']);
    if (deltaX == null || deltaY == null) {
      return null;
    }
    return _ScrollDelta(unit: unit, deltaX: deltaX, deltaY: deltaY);
  }

  static _ScrollDelta? _legacySemantic(
    Map<String, dynamic> data,
    RemoteInputPlatformKind sourcePlatform,
  ) {
    final rawX = _numberValue(data['deltaX']);
    final rawY = _numberValue(data['deltaY']);
    if (rawX == null || rawY == null) {
      return null;
    }
    return _ScrollDelta(
      unit: RemoteInputScrollUnit.wheel,
      deltaX: _legacyWheelTicks(rawX, sourcePlatform),
      deltaY: _legacyWheelTicks(rawY, sourcePlatform),
    );
  }

  static double _legacyWheelTicks(
    double value,
    RemoteInputPlatformKind sourcePlatform,
  ) {
    switch (sourcePlatform) {
      case RemoteInputPlatformKind.windows:
      case RemoteInputPlatformKind.linux:
        return value / wheelDelta;
      case RemoteInputPlatformKind.macos:
        return value;
      case RemoteInputPlatformKind.unknown:
        if (value.abs() >= wheelDelta / 2) {
          return value / wheelDelta;
        }
        return value;
    }
  }

  static _ScrollDelta _targetDelta(
    _ScrollDelta semantic, {
    required RemoteInputPlatformKind targetPlatform,
    required double multiplier,
  }) {
    final scaledX = semantic.deltaX * multiplier;
    final scaledY = semantic.deltaY * multiplier;
    switch (targetPlatform) {
      case RemoteInputPlatformKind.macos:
        return _ScrollDelta(
          unit: semantic.unit,
          deltaX: scaledX,
          deltaY: scaledY,
        );
      case RemoteInputPlatformKind.windows:
      case RemoteInputPlatformKind.linux:
        return _ScrollDelta(
          unit: RemoteInputScrollUnit.wheel,
          deltaX: _toWheelDelta(scaledX, semantic.unit),
          deltaY: _toWheelDelta(scaledY, semantic.unit),
        );
      case RemoteInputPlatformKind.unknown:
        return _ScrollDelta(
          unit: semantic.unit,
          deltaX: scaledX,
          deltaY: scaledY,
        );
    }
  }

  static double _toWheelDelta(double delta, RemoteInputScrollUnit unit) {
    switch (unit) {
      case RemoteInputScrollUnit.wheel:
        return delta * wheelDelta;
      case RemoteInputScrollUnit.pixel:
        return delta * (wheelDelta / macosPixelsPerWheelTick);
    }
  }

  static String _sourcePlatformName(
    Map<String, dynamic> data,
    RemoteInputPlatformKind fallback,
  ) {
    final existing = _stringValue(data['sourcePlatform']);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    return _platformName(fallback);
  }

  static String _platformName(RemoteInputPlatformKind platform) {
    return platform == RemoteInputPlatformKind.unknown ? '' : platform.name;
  }

  static RemoteInputScrollUnit? _scrollUnitFromString(String? value) {
    switch ((value ?? '').toLowerCase()) {
      case 'wheel':
      case 'tick':
      case 'wheeltick':
        return RemoteInputScrollUnit.wheel;
      case 'pixel':
      case 'pixels':
        return RemoteInputScrollUnit.pixel;
      default:
        return null;
    }
  }

  static Map<String, dynamic>? _decodePayload(Uint8List payload) {
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

  static RemoteInputPacketFrame _copyWithPayload(
    RemoteInputPacketFrame frame,
    Map<String, dynamic> payload,
  ) {
    return RemoteInputPacketFrame(
      sessionId: frame.sessionId,
      sequence: frame.sequence,
      timestampMicros: frame.timestampMicros,
      eventType: frame.eventType,
      payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
  }

  static double? _numberValue(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }

  static String? _stringValue(Object? value) {
    if (value is String) {
      return value;
    }
    return null;
  }

  static bool _boolValue(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    return false;
  }
}

class _ScrollDelta {
  const _ScrollDelta({
    required this.unit,
    required this.deltaX,
    required this.deltaY,
  });

  final RemoteInputScrollUnit unit;
  final double deltaX;
  final double deltaY;
}
