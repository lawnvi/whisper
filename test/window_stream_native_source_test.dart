import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every C/C++ source of one platform's plugin (split into common/,
/// receiver/, capture/ and exports_*), without the test tools.
String nativeSources(String platform) {
  final root = Directory('packages/window_stream_native/$platform');
  final files =
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (file) =>
                RegExp(r'\.(c|cc|cpp|h|hpp)$').hasMatch(file.path) &&
                !file.path.contains('${Platform.pathSeparator}tools'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files.map((file) => file.readAsStringSync()).join('\n');
}

/// Definitions of [name] in [source]: a line of return type words, the
/// name, its parameters and a body (calls and prototypes do not match).
int functionDefinitions(String source, String name) => RegExp(
  r'^[ \t]*(?:[A-Za-z_]\w*[ \t*&]+)*'
  '$name'
  r'[ \t]*\([^;{}]*\)\s*\{',
  multiLine: true,
).allMatches(source).length;

void main() {
  const header = 'packages/window_stream_native/src/window_stream_native.h';
  const bindings =
      'packages/window_stream_native/lib/window_stream_native.dart';
  const swiftDir = 'packages/window_stream_native/macos/Classes';

  test(
    'every C entry point exists in the Dart bindings and the macOS code',
    () {
      final functions = RegExp(r'\b(wsn_[a-z_]+)\(')
          .allMatches(File(header).readAsStringSync())
          .map((m) => m.group(1)!)
          .toSet();
      expect(functions, hasLength(greaterThanOrEqualTo(17)));
      final dart = File(bindings).readAsStringSync();
      final swift = Directory(swiftDir)
          .listSync()
          .whereType<File>()
          .map((file) => file.readAsStringSync())
          .join('\n');
      for (final name in functions) {
        expect(
          dart,
          contains("'$name'"),
          reason: '$name missing in Dart bindings',
        );
        expect(
          swift,
          contains('@_cdecl("$name")'),
          reason: '$name missing in Swift',
        );
      }
    },
  );

  test('Windows and Linux plugins define every C entry point', () {
    // DynamicLibrary lookups fail for the whole library if one is missing,
    // so a half-ported platform must still export (stub) all of them.
    final functions = RegExp(r'\b(wsn_[a-z_]+)\(')
        .allMatches(File(header).readAsStringSync())
        .map((m) => m.group(1)!)
        .toSet();
    expect(functions, hasLength(greaterThanOrEqualTo(36)));
    for (final platform in ['windows', 'linux']) {
      final source = nativeSources(platform);
      for (final name in functions) {
        // Exactly one: none fails to load, two fail to link.
        expect(
          functionDefinitions(source, name),
          1,
          reason: '$name must be defined once in the $platform plugin',
        );
      }
    }
  });

  test('API version agrees between header, Swift and Dart', () {
    final headerVersion = RegExp(
      r'#define WSN_API_VERSION (\d+)',
    ).firstMatch(File(header).readAsStringSync())!.group(1);
    expect(
      File(bindings).readAsStringSync(),
      contains('const int wsnApiVersion = $headerVersion;'),
    );
    expect(
      File('$swiftDir/WindowStreamNative.swift').readAsStringSync(),
      contains('return $headerVersion'),
    );
  });

  test('native callbacks are never invoked inside a call from Dart', () {
    final swift = File('$swiftDir/WindowStreamNative.swift').readAsStringSync();
    final emitters = RegExp(
      r'func emit(Input|Window)\([\s\S]*?\n  \}',
    ).allMatches(swift);
    expect(emitters, hasLength(2));
    for (final emitter in emitters) {
      expect(emitter.group(0), contains('callbackQueue.async'));
    }
    // Pushes may emit window events, so they must not be leaf calls.
    final dart = File(bindings).readAsStringSync();
    expect(dart, isNot(contains("'wsn_video_push', isLeaf: true")));
    expect(dart, isNot(contains("'wsn_audio_push', isLeaf: true")));
  });

  test('plugin is FFI-only so child engines do not register it again', () {
    final pubspec = File(
      'packages/window_stream_native/pubspec.yaml',
    ).readAsStringSync();
    // macOS: FFI only (no pluginClass), or every desktop_multi_window child
    // engine would register it again. iOS uses a regular plugin class.
    final macos = RegExp(
      r'macos:\n((?:        .*\n)+)',
    ).firstMatch(pubspec)!.group(1)!;
    expect(macos, contains('ffiPlugin: true'));
    expect(macos, isNot(contains('pluginClass')));
    expect(pubspec, contains('pluginClass: WindowStreamNativePlugin'));
    final podspec = File(
      'packages/window_stream_native/macos/window_stream_native.podspec',
    ).readAsStringSync();
    expect(podspec, contains("s.platform         = :osx, '10.15'"));
  });

  test('window stream assets ship only in desktop packages', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final asset in const [
      'assets/window_stream/scrcpy-server-v5.0.1',
      'assets/window_stream/scrcpy-LICENSE.txt',
      'assets/window_stream/NOTICE.txt',
    ]) {
      final entry = RegExp(
        '- path: ${RegExp.escape(asset)}\\n\\s+platforms: \\[macos, windows, linux\\]',
      );
      expect(pubspec, matches(entry), reason: asset);
    }
  });

  test('bundled scrcpy-server is the verified 5.0.1 release', () {
    final bytes = File(
      'assets/window_stream/scrcpy-server-v5.0.1',
    ).readAsBytesSync();
    expect(
      sha256.convert(bytes).toString(),
      '764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536',
    );
    expect(
      File('assets/window_stream/NOTICE.txt').readAsStringSync(),
      contains('Apache License'),
    );
    final protocol = File(
      'lib/window_stream/android/scrcpy/scrcpy_protocol.dart',
    ).readAsStringSync();
    expect(protocol, contains("serverVersion = '5.0.1'"));
  });

  test('streamed audio plays without rumble and recovers from stalls', () {
    final audio = File('$swiftDir/AudioOutput.swift').readAsStringSync();
    // Phones hand over full-scale PCM with 5-20 Hz rumble: play float
    // samples through a DC blocker so nothing drones or clips in the mix.
    expect(audio, contains('kLinearPCMFormatFlagIsFloat'));
    expect(audio, contains('DCBlocker(cutoffHz: 20'));
    // Phone audio arrives before the phone's volume control: keep headroom
    // and never clip.
    expect(audio, contains('private let headroom: Float = 0.5'));
    expect(audio, contains('static func limit('));
    // A starved renderer restarts with more latency instead of starving
    // again on the next network hiccup.
    expect(
      audio,
      contains(
        'latencyMs = min(max(latencyMs, baseLatencyMs) + 30, maxLatencyMs)',
      ),
    );
    // The buffer covers the output device's own latency, or every packet
    // arrives a little late and is cut: a buzz over garbled speech.
    expect(audio, contains('static func outputLatencyMs()'));
    expect(audio, contains('kAudioStreamPropertyLatency'));
    expect(audio, contains('lead) * 1000 < deviceMs + 5'));
    final surface = File('$swiftDir/StreamSurface.swift').readAsStringSync();
    expect(surface, contains('audio?.statsSnapshot() ?? [0, 0, 0, 0]'));
    expect(
      File(bindings).readAsStringSync(),
      contains('_surfaceStats(surface, out, 9)'),
    );
  });

  test('a Mac host never blocks the peer connection with capture work', () {
    final svr = File('lib/socket/svrmanager.dart').readAsStringSync();
    final handler = svr.substring(
      svr.indexOf('case MessageEnum.WindowStreamControl:'),
      svr.indexOf('case MessageEnum.AudioGroupControl:'),
    );
    // Catalogs and thumbnails take seconds; awaiting them held heartbeats
    // until the phone reconnected and the stale session failed.
    expect(
      handler,
      contains('unawaited(\n                  WindowStreamHost.shared'),
    );
    final host = File(
      'lib/window_stream/remote/window_stream_host.dart',
    ).readAsStringSync();
    expect(host, contains('Future<void> _thumbnailQueue'));
    expect(host, contains('_thumbnailLifetime'));
    expect(host, contains("'apps': apps"));
    expect(host, contains('native.captureLaunchApp(appId)'));
    final windows = File(
      'packages/window_stream_native/macos/Classes/StreamWindow.swift',
    ).readAsStringSync();
    expect(windows, contains('[.fullScreenAuxiliary, .managed]'));
  });

  test('app shutdown closes window streams', () {
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final shutdown = RegExp(
      r'Future<void> _shutdownDesktopResources\(\) \{[\s\S]*?\]\);',
    ).firstMatch(deviceList)!.group(0)!;
    expect(shutdown, contains('WindowStreamCoordinator.shared.shutdown'));
  });

  test('window stream strings exist in every language', () {
    final keys = <String, Set<String>>{};
    for (final language in const ['zh', 'en', 'es']) {
      final arb =
          jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync())
              as Map<String, dynamic>;
      keys[language] = arb.keys
          .where((key) => key.startsWith('windowStream'))
          .toSet();
    }
    expect(keys['zh'], isNotEmpty);
    expect(keys['en'], keys['zh']);
    expect(keys['es'], keys['zh']);
  });

  test('a streamed Mac window moves to a virtual display of its own', () {
    final stage = File('$swiftDir/VirtualStage.swift').readAsStringSync();
    expect(stage, contains('Apache'));
    expect(stage, contains('func releaseWindow()'));
    // The way home survives the app quitting with a window staged.
    expect(stage, contains('atexit'));
    // Without Screen Recording a virtual display hangs ScreenCaptureKit.
    expect(stage, contains('CGPreflightScreenCaptureAccess()'));
    final display = File('$swiftDir/VirtualDisplay.swift').readAsStringSync();
    expect(display, startsWith('// Adapted from Sill'));
    final capture = File('$swiftDir/WindowCapture.swift').readAsStringSync();
    expect(capture, contains('streaming the window in place'));
    expect(capture, contains('stage.leave(self)'));
    // One frame in the encoder; the newest waiting frame wins.
    expect(capture, contains('pending = (pixelBuffer, pts)'));
    final catalog = File('$swiftDir/CaptureCatalog.swift').readAsStringSync();
    // Windows on other desktops and in full screen count; ones an app
    // closed to the menu bar but keeps around do not.
    expect(
      catalog,
      contains('getExcludingDesktopWindows(true, onScreenWindowsOnly: false)'),
    );
    expect(catalog, contains('SLSWindowIsOrderedIn'));
    expect(catalog, contains('ax.minimized.contains(window.windowID)'));
    expect(catalog, isNot(contains('wsn_debug_record_system_audio')));
  });

  test('a streamed Mac window always goes home, alone', () {
    final capture = File('$swiftDir/WindowCapture.swift').readAsStringSync();
    // The registry drops the capture as it stops it: the stop must not
    // depend on anyone else keeping it alive.
    expect(
      capture,
      contains('queue.async { [self] in\n      guard !self.stopped'),
    );
    expect(capture, contains('stage.evictStrangers()'));
    final surface = File('$swiftDir/StreamSurface.swift').readAsStringSync();
    expect(
      surface,
      contains('onMain { [self] in\n      self.windowController?.close()'),
    );
    final stage = File('$swiftDir/VirtualStage.swift').readAsStringSync();
    // Other apps' windows macOS brings back to a returning display go to
    // the main one; the staged app's own windows stay.
    expect(stage, contains('func evictStrangers()'));
    expect(stage, contains('pid != p.pid, pid != ownPid'));
    // Full-screen windows on other Spaces: reached as the app's main window
    // or through its Window menu, then taken out of full screen.
    expect(stage, contains('kAXMainWindowAttribute'));
    expect(stage, contains('pickInWindowMenu(pid: app.processID'));
    expect(stage, isNot(contains('_AXUIElementCreateWithRemoteToken')));
    expect(stage, isNot(contains('_SLPSSetFrontProcessWithOptions')));
  });

  test('a window sent home is never left on no Space', () {
    final stage = File('$swiftDir/VirtualStage.swift').readAsStringSync();
    // A display removed under a window still on its way off it strands the
    // window: shown, but on no Space, and its app cannot bring it back.
    expect(stage, contains('await Self.retire(old, after: leaving)'));
    expect(stage, contains('live.intersects(bounds)'));
    expect(stage, isNot(contains('releaseWindow()\n    destroyDisplay()')));
    // At exit too, the displays wait for the windows to be off them.
    expect(stage, contains('liveBounds(of: id).map(onOurDisplay)'));
    final rescue = File('$swiftDir/StrandedWindows.swift').readAsStringSync();
    expect(rescue, contains('WindowSpaces.spaces(of: id), spaces.isEmpty'));
    // Out to the Dock and back lands it on the desktop in front; never
    // while an app is in full screen.
    expect(rescue, contains('kAXMinimizedAttribute'));
    expect(rescue, contains('WindowSpaces.desktopInFront'));
    expect(stage, contains('StrandedWindows.rescueSoon(after: 1)'));
    final native = File(
      '$swiftDir/WindowStreamNative.swift',
    ).readAsStringSync();
    expect(native, contains('StrandedWindows.rescueSoon()'));
    final server = File('lib/socket/svrmanager.dart').readAsStringSync();
    expect(
      server,
      contains('..localPeerId = localPeerIdFor\n        ..start();'),
    );
  });

  test('touches on the phone leave the Mac pointer where it was', () {
    final injector = File('$swiftDir/WindowInjector.swift').readAsStringSync();
    expect(injector, contains('CGWarpMouseCursorPosition(home)'));
    expect(injector, contains('onTouch?()'));
    final capture = File('$swiftDir/WindowCapture.swift').readAsStringSync();
    // The Mac's own mouse moved over shows; the finger's jumps do not.
    expect(capture, contains('configuration.showsCursor = cursorShown'));
    expect(capture, contains('stream.updateConfiguration(configuration'));
  });

  test('an Android window on the Mac wears its app icon', () {
    final header = File(
      'packages/window_stream_native/src/window_stream_native.h',
    ).readAsStringSync();
    expect(header, contains('wsn_surface_set_icon(int64_t surface'));
    final native = File(
      '$swiftDir/WindowStreamNative.swift',
    ).readAsStringSync();
    expect(native, contains('@_cdecl("wsn_surface_set_icon")'));
    // Every platform exports it, or loading the bindings fails there.
    expect(nativeSources('windows'), contains('wsn_surface_set_icon('));
    expect(nativeSources('linux'), contains('wsn_surface_set_icon('));
    final window = File('$swiftDir/StreamWindow.swift').readAsStringSync();
    expect(window, contains('window.miniwindowImage = image'));
    expect(window, contains('.documentIconButton'));
    final coordinator = File(
      'lib/window_stream/window_stream_coordinator.dart',
    ).readAsStringSync();
    expect(coordinator, contains('backend.setIcon(surface, png)'));
  });

  test('closing a window on Android gives the texture back safely', () {
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/WindowStreamReceiverPlugin.kt',
    ).readAsStringSync();
    expect(plugin, contains('mainHandler.post { producer.release() }'));
    expect(plugin, contains('WIFI_MODE_FULL_LOW_LATENCY'));
  });

  test('Flow lists only phones that are there now', () {
    final coordinator = File(
      'lib/window_stream/window_stream_coordinator.dart',
    ).readAsStringSync();
    expect(coordinator, contains('device.state != AdbDeviceState.offline'));
    final deck = File(
      'lib/page/window_stream/flow_recents_deck.dart',
    ).readAsStringSync();
    // On a touch screen the first tap fans the stack out.
    expect(deck, contains('if (!_expanded && cards.length > 1)'));
  });

  test(
    'a Mac window on a phone is the phone\'s screen as an extra display',
    () {
      final stage = File('$swiftDir/VirtualStage.swift').readAsStringSync();
      // Shaped like the phone, to the right of the Mac's screens; what of it
      // is shown is the window's app only (see the test below).
      expect(stage, contains('static func displaySize(viewport: CGSize'));
      expect(stage, contains('let display: SCDisplay'));
      expect(stage, contains('CGConfigureDisplayOrigin(config, id'));
      final injector = File(
        '$swiftDir/WindowInjector.swift',
      ).readAsStringSync();
      expect(injector, contains('func setCaptureDisplay'));
      final capture = File('$swiftDir/WindowCapture.swift').readAsStringSync();
      expect(capture, contains('configuration.showsCursor = cursorShown'));
      // A still window is sent again when a viewer asks for a picture.
      expect(capture, contains('repeatLastFrameSoon()'));
      // A short pause (switching apps on the phone) leaves the window there.
      expect(capture, contains('withTimeInterval: 60, repeats: false'));
      // A slow network skips frames rather than queueing them.
      expect(capture, contains('func setBusy(_ value: Bool)'));
      final runner = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      expect(runner, contains('CGDisplayVendorNumber(number) != 0x5748'));
    },
  );

  test('an Android window on the Mac can go full screen and take pinyin', () {
    final window = File('$swiftDir/StreamWindow.swift').readAsStringSync();
    expect(window, contains('[.fullScreenPrimary, .managed]'));
    expect(window, contains('windowWillUseStandardFrame'));
    expect(window, contains('extension StreamVideoView: NSTextInputClient'));
    expect(window, contains('inputContext?.handleEvent(event)'));
  });

  test('a Mac window on Android is a task of its own, upright by default', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final activity = RegExp(
      r'<activity\s+android:name=".WindowStreamActivity"[\s\S]*?/>',
    ).firstMatch(manifest)!.group(0)!;
    expect(activity, contains('android:documentLaunchMode="intoExisting"'));
    // Upright on phones by default, turned on request (and remembered).
    expect(activity, isNot(contains('android:screenOrientation=')));
    final kotlin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/WindowStreamActivity.kt',
    ).readAsStringSync();
    // Input methods compose first; only what they commit is sent.
    expect(kotlin, contains('override fun setComposingText'));
    expect(
      kotlin,
      contains('emit("orientation", mapOf("landscape" to landscape))'),
    );
    // Latin letters are sent as typed; what is still being composed shows
    // above the keyboard, and is kept when the composition ends.
    expect(kotlin, contains('InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS'));
    expect(kotlin, contains('showComposing(text)'));
    expect(kotlin, contains('val kept = composing'));
    expect(kotlin, contains('EditorInfo.IME_FLAG_NO_EXTRACT_UI'));
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/WindowStreamReceiverPlugin.kt',
    ).readAsStringSync();
    // The decoder moves between surfaces, and stops when there is none.
    expect(plugin, contains('active.setOutputSurface(target)'));
    expect(plugin, contains('Nowhere to draw'));
    final open = File(
      'lib/page/window_stream/flow_open.dart',
    ).readAsStringSync();
    expect(open, contains('NativeWindowActivity.open(session'));
  });

  test('a Mac source streams only the window asked for, never its display', () {
    final capture = File('$swiftDir/WindowCapture.swift').readAsStringSync();
    final stage = File('$swiftDir/VirtualStage.swift').readAsStringSync();
    // A staged window is its own app on the virtual display, minus the app's
    // other top-level windows; other apps' windows that land there never show.
    expect(
      capture,
      contains(
        'SCContentFilter(display: display, including: [app], '
        'exceptingWindows: excepted)',
      ),
    );
    // No display-wide filter anywhere in the capture path.
    for (final source in [capture, stage]) {
      expect(source, isNot(contains('excludingWindows: [])')));
      expect(source, isNot(contains('excludingApplications:')));
    }
    // Every stream's filter comes from one place, checked against the window
    // id and pid, and a mismatch fails the capture instead of streaming.
    expect(
      RegExp(r'SCContentFilter\(').allMatches(capture).length,
      2,
      reason: 'only filter(for:) builds filters',
    );
    expect(capture, contains('guard let filter = filter(for: target)'));
    expect(capture, contains('refused to capture: '));
    // While a new window of the app is being left out, nothing goes out.
    expect(capture, contains('!holdingFrames'));
    expect(capture, contains('updateContentFilter(filter)'));
  });

  test('a Mac source sends the window app\'s sound, silent here if it can', () {
    final audio = File('$swiftDir/WindowAudio.swift').readAsStringSync();
    final native = File(
      '$swiftDir/WindowStreamNative.swift',
    ).readAsStringSync();
    expect(native, contains('@_cdecl("wsn_capture_set_audio")'));
    // ScreenCaptureKit: only the app's own processes, never this one.
    expect(audio, contains('excludesCurrentProcessAudio = true'));
    expect(
      audio,
      contains(
        'SCContentFilter(display: display, including: apps, '
        'exceptingWindows: [])',
      ),
    );
    // Core Audio tap of the app's processes, silent here while read.
    expect(
      audio,
      contains('CATapDescription(stereoMixdownOfProcesses: processes)'),
    );
    expect(audio, contains('.mutedWhenTapped'));
    expect(audio, contains('kAudioAggregateDeviceIsPrivateKey: true'));
    expect(audio, contains('candidate != getpid()'));
    // 48 kHz stereo s16 in 20 ms chunks.
    expect(audio, contains('static let chunkFrames = 960'));
    expect(audio, contains('vDSP_vfixr16'));
    final plist = File('macos/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('NSAudioCaptureUsageDescription'));
  });
}
