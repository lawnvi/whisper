import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/services.dart';

class MotionSample {
  const MotionSample(this.micros, this.angularVelocity, this.gravity);
  final int micros;
  final List<double> angularVelocity;
  final List<double> gravity;

  factory MotionSample.fromEvent(dynamic event) {
    final data = Map<Object?, Object?>.from(event as Map);
    List<double> vector(String key) =>
        (data[key] as List).map((value) => (value as num).toDouble()).toList();
    return MotionSample(
      (data['micros'] as num).toInt(),
      vector('gyro'),
      vector('gravity'),
    );
  }
}

class MobileMotionSensor {
  static const methods = MethodChannel('com.vireen.whisper/mobile_motion');
  static const events = EventChannel('com.vireen.whisper/mobile_motion/events');
  Future<bool> available() async =>
      await methods.invokeMethod<bool>('available') ?? false;
  Stream<MotionSample> samples() =>
      events.receiveBroadcastStream().map(MotionSample.fromEvent);
}

/// Projects angular velocity onto gravity and the horizontal phone-right axis.
/// Pausing resets time/filter history; it never accumulates movement to replay.
class MobileMotionMapper {
  static const gain = 1200.0;
  static const deadZone = 0.012;
  static const filterSeconds = 0.025;
  double sensitivity = 1;
  int? _previousMicros;
  Offset _filtered = Offset.zero;
  List<double> _bias = [0, 0, 0];
  final List<List<double>> _calibration = [];
  bool calibrating = false;

  void reset() {
    _previousMicros = null;
    _filtered = Offset.zero;
  }

  void calibrate() {
    reset();
    _calibration.clear();
    calibrating = true;
  }

  void cancelCalibration() {
    calibrating = false;
    _calibration.clear();
    reset();
  }

  Offset add(MotionSample sample, {required bool enabled}) {
    final w = sample.angularVelocity, g = sample.gravity;
    if (w.length != 3 ||
        g.length != 3 ||
        [...w, ...g].any((value) => !value.isFinite)) {
      reset();
      return Offset.zero;
    }
    if (calibrating) {
      if (_length(w) > 0.15) {
        _calibration.clear();
      } else {
        _calibration.add(List<double>.of(w));
        if (_calibration.length >= 50) {
          _bias = List.generate(
            3,
            (axis) =>
                _calibration.fold<double>(0, (sum, v) => sum + v[axis]) /
                _calibration.length,
          );
          cancelCalibration();
        }
      }
      return Offset.zero;
    }
    if (!enabled) {
      reset();
      return Offset.zero;
    }
    final previous = _previousMicros;
    _previousMicros = sample.micros;
    if (previous == null) return Offset.zero;
    final dt = (sample.micros - previous) / 1000000;
    if (dt <= 0 || dt > 0.1 || _length(g) < 1) {
      reset();
      return Offset.zero;
    }
    final up = g.map((value) => value / _length(g)).toList();
    final right = [1 - up[0] * up[0], -up[0] * up[1], -up[0] * up[2]];
    final rightLength = _length(right);
    if (rightLength < 0.2) {
      reset();
      return Offset.zero;
    }
    double project(List<double> axis, double length) => List.generate(
      3,
      (i) => (w[i] - _bias[i]) * axis[i] / length,
    ).fold<double>(0, (a, b) => a + b);
    double deadband(double v) =>
        v.abs() <= deadZone ? 0 : v.sign * (v.abs() - deadZone);
    final velocity = Offset(
      -deadband(project(up, 1)),
      -deadband(project(right, rightLength)),
    );
    // A stationary sample stops immediately instead of letting the filter coast.
    final alpha = dt / (filterSeconds + dt);
    _filtered = Offset(
      velocity.dx == 0
          ? 0
          : _filtered.dx + alpha * (velocity.dx - _filtered.dx),
      velocity.dy == 0
          ? 0
          : _filtered.dy + alpha * (velocity.dy - _filtered.dy),
    );
    return _filtered * (dt * gain * sensitivity.clamp(0.5, 3));
  }

  double _length(List<double> v) =>
      math.sqrt(v.fold<double>(0, (sum, n) => sum + n * n));
}
