import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// `key: "value"` lines of one top-level block in DESIGN.md's front matter.
Map<String, String> _frontMatterBlock(String name) {
  final design = File('DESIGN.md').readAsStringSync();
  final header = design.split(RegExp(r'^---$', multiLine: true))[1];
  final lines = header.split('\n');
  final start = lines.indexOf('$name:');
  if (start < 0) throw StateError('$name is not in DESIGN.md');
  final values = <String, String>{};
  for (final line in lines.skip(start + 1)) {
    if (line.isNotEmpty && !line.startsWith(' ')) break;
    final match = RegExp(r'^\s+([\w-]+):\s*(.+)$').firstMatch(line);
    if (match != null) values[match.group(1)!] = match.group(2)!;
  }
  return values;
}

Color _hex(String quoted) => Color(
  0xFF000000 | int.parse(quoted.replaceAll('"', '').substring(1), radix: 16),
);

Color _rgba(String rgba) {
  final match = RegExp(r'rgba\((\d+),(\d+),(\d+),([\d.]+)\)').firstMatch(rgba)!;
  return Color.fromARGB(
    (double.parse(match.group(4)!) * 255).round(),
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

void main() {
  group('tokens match DESIGN.md', () {
    final colors = _frontMatterBlock('colors');
    final overlays = _frontMatterBlock('overlays');

    Map<String, Color> own(WhisperColors c) => {
      'canvas': c.canvas,
      'content': c.content,
      'group': c.group,
      'raised': c.raised,
      'bubble': c.bubble,
      'ink': c.ink,
      'ink2': c.ink2,
      'ink3': c.ink3,
      'accent': c.accent,
      'ok': c.ok,
      'warn': c.warn,
      'bad': c.bad,
      'sidebar-solid': c.sidebarSolid,
    };

    test('solid colors', () {
      own(WhisperColors.light).forEach((name, value) {
        expect(value, _hex(colors[name]!), reason: name);
      });
      own(WhisperColors.dark).forEach((name, value) {
        expect(value, _hex(colors['$name-dark']!), reason: '$name-dark');
      });
      expect(WhisperColors.light.onAccent, _hex(colors['on-accent']!));
    });

    test('the accent is Radix blue', () {
      expect(WhisperColors.light.accent, Radix.blue9);
      expect(WhisperColors.dark.accent, Radix.blueDark9);
    });

    test('overlays', () {
      Map<String, Color> of(WhisperColors c) => {
        'ink2-glass': c.ink2Glass,
        'sep': c.sep,
        'border': c.border,
        'fill': c.fill,
        'fill2': c.fill2,
        'selected': c.selected,
        'sidebar-selected': c.sidebarSelected,
        'sidebar-veil': c.sidebarVeil,
        'scrim': c.scrim,
      };
      of(WhisperColors.light).forEach((name, value) {
        final light = overlays[name]!.replaceAll('"', '').split(' / ').first;
        expect(value, _rgba(light), reason: name);
      });
      of(WhisperColors.dark).forEach((name, value) {
        final dark = overlays[name]!.replaceAll('"', '').split(' / ')[1];
        expect(value, _rgba(dark), reason: '$name dark');
      });
    });

    test('screens, the switch knob and the loops', () {
      final screens = _frontMatterBlock('screens');
      Color color(String name) => _rgba(screens[name]!.replaceAll('"', ''));
      expect(WhisperScreens.menuBar, color('menu-bar'));
      expect(WhisperScreens.shadeTop, color('shade-top'));
      expect(WhisperScreens.shadeBottom, color('shade-bottom'));
      expect(WhisperScreens.label, color('label'));
      expect(WhisperScreens.pointerFill, color('pointer-fill'));
      expect(WhisperScreens.pointerStroke, color('pointer-stroke'));

      // `x y blur rgba(…)` or `0 0 spread rgba(…)`, comma separated.
      void shadows(String value, List<BoxShadow> got) {
        final parts = RegExp(
          r'(?:inset )?([\d.]+)(?:px)? ([\d.]+)(?:px)? ([\d.]+)(?:px)? '
          r'(?:([\d.]+)px )?(rgba\([^)]*\))',
        ).allMatches(value).toList();
        expect(got, hasLength(parts.length), reason: value);
        for (final (i, part) in parts.indexed) {
          final shadow = got[i];
          expect(shadow.offset.dx, double.parse(part.group(1)!), reason: value);
          expect(shadow.offset.dy, double.parse(part.group(2)!), reason: value);
          expect(
            shadow.blurRadius,
            double.parse(part.group(3)!),
            reason: value,
          );
          expect(
            shadow.spreadRadius,
            double.parse(part.group(4) ?? '0'),
            reason: value,
          );
          expect(shadow.color, _rgba(part.group(5)!), reason: value);
        }
      }

      shadows(screens['shadow']!, WhisperScreens.shadow);
      shadows(screens['lifted']!, WhisperScreens.lifted);
      shadows(screens['canvas-inset']!, const [WhisperScreens.canvasInset]);
      shadows(_frontMatterBlock('controls')['knob']!, whisperKnobShadow);

      void textShadow(String value, Shadow got) {
        final part = RegExp(
          r'([\d.]+)(?:px)? ([\d.]+)px ([\d.]+)px (rgba\([^)]*\))',
        ).firstMatch(value)!;
        expect(got.offset.dx, double.parse(part.group(1)!));
        expect(got.offset.dy, double.parse(part.group(2)!));
        expect(got.blurRadius, double.parse(part.group(3)!));
        expect(got.color, _rgba(part.group(4)!));
      }

      textShadow(screens['label-shadow']!, WhisperScreens.labelShadow.single);
      textShadow(screens['pointer-shadow']!, WhisperScreens.pointerShadow);

      expect(
        WhisperLoops.wave.inMilliseconds,
        int.parse(_frontMatterBlock('loops')['wave']!),
      );
    });

    test('the viewfinder, the sheet on a phone and the codes', () {
      final finder = _frontMatterBlock('viewfinder');
      expect(WhisperViewfinder.glow, _hex(finder['glow']!));
      expect(WhisperViewfinder.base, _hex(finder['base']!));
      expect(WhisperViewfinder.qrInk, _hex(finder['qr-ink']!));
      Color rgba(String name) => _rgba(finder[name]!.replaceAll('"', ''));
      expect(WhisperViewfinder.mark, rgba('mark'));
      expect(WhisperViewfinder.line, rgba('line'));
      expect(WhisperViewfinder.hint, rgba('hint'));

      final rounded = _frontMatterBlock('rounded');
      expect(WhisperRadius.sheetTop, double.parse(rounded['sheet-top']!));
      expect(WhisperRadius.sheetBottom, double.parse(rounded['sheet-bottom']!));
      expect(
        WhisperRadius.viewfinderMark,
        double.parse(rounded['viewfinder-mark']!),
      );
      expect(
        WhisperShadow.appIconHighlight,
        _rgba(
          _frontMatterBlock(
            'controls',
          )['app-icon-highlight']!.replaceAll('"', ''),
        ),
      );
      expect(
        WhisperLoops.scan.inMilliseconds,
        int.parse(_frontMatterBlock('loops')['scan']!),
      );
      expect(
        WhisperLoops.slowLoad.inMilliseconds,
        int.parse(_frontMatterBlock('loops')['slow-load']!),
      );
    });

    test('settings icons', () {
      final icons = _frontMatterBlock('settings-icons');
      expect(WhisperSettingsIcons.general, _hex(icons['general']!));
      expect(WhisperSettingsIcons.system, _hex(icons['system']!));
      expect(WhisperSettingsIcons.sharing, _hex(icons['sharing']!));
      expect(WhisperSettingsIcons.notifications, _hex(icons['notifications']!));
      expect(WhisperSettingsIcons.about, _hex(icons['about']!));
    });

    test('radii, type and motion', () {
      final rounded = _frontMatterBlock('rounded');
      expect(WhisperRadius.xs, double.parse(rounded['xs']!));
      expect(WhisperRadius.s, double.parse(rounded['s']!));
      expect(WhisperRadius.m, double.parse(rounded['m']!));
      expect(WhisperRadius.l, double.parse(rounded['l']!));
      expect(WhisperRadius.bubble, double.parse(rounded['bubble']!));
      expect(WhisperRadius.composer, double.parse(rounded['composer']!));
      expect(WhisperRadius.capsule, double.parse(rounded['capsule']!));

      final type = _frontMatterBlock('typography');
      List<double> sizes(String role) => RegExp(
        r'\d+',
      ).allMatches(type[role]!).map((m) => double.parse(m.group(0)!)).toList();
      const pointer = WhisperType(touch: false),
          touch = WhisperType(touch: true);
      expect([pointer.large, touch.large], sizes('large'));
      expect([pointer.title, touch.title], sizes('title'));
      expect([pointer.head, touch.head], sizes('head'));
      expect([pointer.body, touch.body], sizes('body'));
      expect([pointer.note, touch.note], sizes('note'));
      expect([pointer.tiny, touch.tiny], sizes('tiny'));

      final motion = _frontMatterBlock('motion');
      void spring(String name, SpringValues got) {
        final m = RegExp(
          r'stiffness: ([\d.]+), damping: ([\d.]+)',
        ).firstMatch(motion[name]!)!;
        expect(
          got.stiffness,
          closeTo(double.parse(m.group(1)!), 1),
          reason: name,
        );
        expect(
          got.damping,
          closeTo(double.parse(m.group(2)!), .1),
          reason: name,
        );
      }

      spring('follow', SpringValues.of(WhisperSprings.follow));
      spring('snappy', SpringValues.of(WhisperSprings.snappy));
      spring('smooth', SpringValues.of(WhisperSprings.smooth));
      spring('expressive', SpringValues.of(WhisperSprings.expressive));
    });

    test('wallpapers', () {
      final walls = _frontMatterBlock('wallpapers');
      List<Color> stops(String name) => RegExp(
        r'#[0-9A-Fa-f]{6}',
      ).allMatches(walls[name]!).map((m) => _hex(m.group(0)!)).toList();
      expect([
        DeviceWallpaper.self.from,
        DeviceWallpaper.self.to,
      ], stops('self'));
      expect([
        DeviceWallpaper.unpaired.from,
        DeviceWallpaper.unpaired.to,
      ], stops('unpaired'));
      for (var i = 0; i < DeviceWallpaper.paired.length; i++) {
        final wall = DeviceWallpaper.forPairingOrder(i);
        expect([wall.from, wall.to], stops('device-${i + 1}'));
      }
      expect(
        DeviceWallpaper.forPairingOrder(DeviceWallpaper.paired.length),
        DeviceWallpaper.paired.first,
        reason: 'pairing order repeats',
      );
    });

    testWidgets('glass tints', (t) async {
      final glass = _frontMatterBlock('glass');
      for (final (kind, name) in [
        (GlassKind.sidebar, 'sidebar'),
        (GlassKind.control, 'control'),
        (GlassKind.panel, 'panel'),
      ]) {
        final parts = glass[name]!.replaceAll('"', '').split(' / ');
        for (final (index, brightness) in [
          (0, Brightness.light),
          (1, Brightness.dark),
        ]) {
          await t.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.light
                  ? AppTheme.lightTheme
                  : AppTheme.darkTheme,
              home: WhisperGlass(kind: kind, child: const SizedBox()),
            ),
          );
          // MaterialApp animates between themes.
          await t.pumpAndSettle();
          final box = t.widget<DecoratedBox>(
            find.descendant(
              of: find.byType(WhisperGlass),
              matching: find.byType(DecoratedBox),
            ),
          );
          expect(
            (box.decoration as ShapeDecoration).color,
            _rgba(parts[index]),
            reason: '$name $brightness',
          );
        }
      }
    });
  });

  group('wiring', () {
    test('both app themes carry the tokens', () {
      expect(
        AppTheme.lightTheme.extension<WhisperColors>(),
        WhisperColors.light,
      );
      expect(AppTheme.darkTheme.extension<WhisperColors>(), WhisperColors.dark);
    });

    testWidgets('glass without blur falls back to the opaque canvas', (
      t,
    ) async {
      whisperGlassBlurs = false;
      addTearDown(() => whisperGlassBlurs = true);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: const WhisperGlass(kind: GlassKind.panel, child: SizedBox()),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      final box = t.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(WhisperGlass),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(
        (box.decoration as ShapeDecoration).color,
        WhisperColors.light.canvas,
      );
    });

    testWidgets('a segment takes a tap', (t) async {
      var selected = 'a';
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, set) => LiquidSegmented<String>(
                  segments: const {'a': 'One', 'b': 'Two', 'c': 'Three'},
                  selected: selected,
                  onChanged: (value) => set(() => selected = value),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      await t.tap(find.text('Three'));
      expect(selected, 'c');
      await t.pumpAndSettle();
      await t.tap(find.text('Two'));
      expect(selected, 'b');
      await t.pumpAndSettle();
    });

    testWidgets('glass blurs on every platform by default', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: const WhisperGlass(kind: GlassKind.control, child: SizedBox()),
        ),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
    });
  });
}

/// The two numbers DESIGN.md writes down for a spring.
class SpringValues {
  const SpringValues(this.stiffness, this.damping);

  factory SpringValues.of(dynamic spring) =>
      SpringValues(spring.stiffness as double, spring.damping as double);

  final double stiffness, damping;
}
