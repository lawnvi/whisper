import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/whisper_ui.dart';

void main() {
  test('spring numbers match DESIGN.md', () {
    expect(WhisperSprings.smooth.stiffness, closeTo(224, 1));
    expect(WhisperSprings.smooth.damping, closeTo(25.7, .1));
    expect(WhisperSprings.snappy.stiffness, closeTo(504, 1));
    expect(WhisperSprings.snappy.damping, closeTo(40.4, .1));
    expect(WhisperSprings.expressive.stiffness, closeTo(158, 1));
    expect(WhisperSprings.follow.stiffness, closeTo(1755, 1));
  });

  test('order: a device that goes offline goes below the nearby ones', () {
    final o = StableDeviceOrder();
    final first = o.apply({
      'old1': DevicePresence.away,
      'old2': DevicePresence.away,
      'near': DevicePresence.nearby,
      'on': DevicePresence.connected,
    });
    expect(first, ['on', 'near', 'old1', 'old2']);
    final off = o.apply({
      'old1': DevicePresence.away,
      'old2': DevicePresence.away,
      'near': DevicePresence.nearby,
      'on': DevicePresence.away,
    });
    expect(off, [
      'near',
      'on',
      'old1',
      'old2',
    ], reason: 'it heads the away rows, nothing else moves');
    final added = o.apply({
      'old1': DevicePresence.away,
      'old2': DevicePresence.away,
      'near': DevicePresence.nearby,
      'on': DevicePresence.away,
      'new': DevicePresence.nearby,
    });
    expect(added, [
      'near',
      'new',
      'on',
      'old1',
      'old2',
    ], reason: 'a new device does not push down a row above it');
  });

  test(
    'order: a connected device that only drops to nearby stays above away',
    () {
      final o = StableDeviceOrder();
      expect(
        o.apply({
          'a': DevicePresence.connected,
          'b': DevicePresence.connected,
          'c': DevicePresence.nearby,
          'd': DevicePresence.away,
        }),
        ['a', 'b', 'c', 'd'],
      );
      expect(
        o.apply({
          'a': DevicePresence.nearby,
          'b': DevicePresence.connected,
          'c': DevicePresence.nearby,
          'd': DevicePresence.away,
        }),
        ['b', 'a', 'c', 'd'],
      );
    },
  );

  test('order: starting offline, a device that connects moves up', () {
    final o = StableDeviceOrder();
    expect(o.apply({'a': DevicePresence.away, 'b': DevicePresence.away}), [
      'a',
      'b',
    ]);
    expect(o.apply({'a': DevicePresence.away, 'b': DevicePresence.connected}), [
      'b',
      'a',
    ]);
    expect(
      o.apply({'a': DevicePresence.connected, 'b': DevicePresence.connected}),
      ['b', 'a'],
    );
    expect(o.apply({'a': DevicePresence.connected, 'b': DevicePresence.away}), [
      'a',
      'b',
    ]);
    expect(o.apply({'a': DevicePresence.connected}), ['a']);
  });

  group('window buttons', () {
    test('reads the GTK layout', () {
      final stock = WindowButtonLayout.parse('appmenu:close');
      expect(stock.left, isEmpty);
      expect(stock.right, [WindowButton.close]);
      final ubuntu = WindowButtonLayout.parse(':minimize,maximize,close');
      expect(ubuntu.right, WindowButton.values);
      final left = WindowButtonLayout.parse('close,minimize,maximize:');
      expect(left.left, [
        WindowButton.close,
        WindowButton.minimize,
        WindowButton.maximize,
      ]);
      expect(left.right, isEmpty);
    });
  });

  group('WhisperLayout', () {
    DisplayFeature fold(
      Rect bounds, {
      DisplayFeatureState state = DisplayFeatureState.postureHalfOpened,
      DisplayFeatureType type = DisplayFeatureType.fold,
    }) => DisplayFeature(bounds: bounds, type: type, state: state);

    test('the size class comes from the window width at both lines', () {
      WhisperSizeClass of(double w) =>
          WhisperLayout.resolve(size: Size(w, 800), touch: true).sizeClass;
      expect(of(599.9), WhisperSizeClass.compact);
      expect(of(600), WhisperSizeClass.regular);
      expect(of(999.9), WhisperSizeClass.regular);
      expect(of(1000), WhisperSizeClass.expanded);
    });

    test('every state of a tri-fold lands on one step of the same ladder', () {
      WhisperSizeClass of(double w) =>
          WhisperLayout.resolve(size: Size(w, 937), touch: true).sizeClass;
      expect(of(422), WhisperSizeClass.compact);
      expect(of(860), WhisperSizeClass.regular);
      expect(of(1337), WhisperSizeClass.expanded);
    });

    test('density does not follow width', () {
      final split = WhisperLayout.resolve(
        size: const Size(405, 820),
        touch: true,
      );
      expect(split.compact, isTrue);
      expect(split.touch, isTrue);
      final tablet = WhisperLayout.resolve(
        size: const Size(1180, 820),
        touch: true,
      );
      expect(tablet.compact, isFalse);
      expect(tablet.touch, isTrue);
      final desktop = WhisperLayout.resolve(
        size: const Size(1180, 820),
        touch: false,
      );
      expect(desktop.touch, isFalse);
    });

    test('the sidebar is clamped on touch and fixed with a pointer', () {
      double side(double w, bool touch) =>
          WhisperLayout.resolve(size: Size(w, 800), touch: touch).sidebarWidth;
      expect(side(500, true), 0);
      expect(side(640, true), 240);
      expect(side(820, true), closeTo(262.4, .01));
      expect(side(1337, true), 300);
      expect(side(1337, false), 252);
    });

    test('a flat fold changes nothing', () {
      final l = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [
          fold(
            const Rect.fromLTWH(452, 0, 0, 640),
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      );
      expect(l.posture, WhisperPosture.flat);
      expect(l.foldX, isNull);
      expect(l.sidebarWidth, closeTo(289.28, .01));
    });

    test('a half-opened vertical fold puts the sidebar edge on the fold', () {
      final l = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [fold(const Rect.fromLTWH(452, 0, 0, 640))],
      );
      expect(l.posture, WhisperPosture.book);
      expect(l.foldX, 452);
      expect(l.sidebarWidth, 452);
    });

    test('a half-opened horizontal fold is the tabletop posture', () {
      final l = WhisperLayout.resolve(
        size: const Size(640, 904),
        touch: true,
        features: [fold(const Rect.fromLTWH(0, 452, 640, 0))],
      );
      expect(l.posture, WhisperPosture.tabletop);
      expect(l.foldY, 452);
      expect(l.sidebarWidth, 240);
    });

    test('a hinge counts, a camera cutout does not', () {
      final hinge = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [
          fold(
            const Rect.fromLTWH(440, 0, 24, 640),
            type: DisplayFeatureType.hinge,
          ),
        ],
      );
      expect(hinge.posture, WhisperPosture.book);
      expect(hinge.foldX, 440);
      final cutout = WhisperLayout.resolve(
        size: const Size(904, 640),
        touch: true,
        features: [
          fold(
            const Rect.fromLTWH(440, 0, 24, 30),
            type: DisplayFeatureType.cutout,
            state: DisplayFeatureState.unknown,
          ),
        ],
      );
      expect(cutout.posture, WhisperPosture.flat);
    });

    test('a fold outside this window is ignored', () {
      final l = WhisperLayout.resolve(
        size: const Size(400, 640),
        touch: true,
        features: [fold(const Rect.fromLTWH(452, 0, 0, 640))],
      );
      expect(l.posture, WhisperPosture.flat);
    });

    test('short height is its own axis', () {
      expect(
        WhisperLayout.resolve(
          size: const Size(857, 533),
          touch: true,
        ).shortHeight,
        isTrue,
      );
      expect(
        WhisperLayout.resolve(
          size: const Size(533, 857),
          touch: true,
        ).shortHeight,
        isFalse,
      );
    });
  });
}
