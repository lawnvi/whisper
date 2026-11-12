import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_codec.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/input/input_controller.dart';
import 'package:whisper/new_ui/sound/sound_controller.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_exit_shortcut.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/theme/whisper_device_art.dart';

import 'golden_support.dart';

const _audioChannel = MethodChannel('test_share_pages_audio');
const _inputChannel = MethodChannel('test_share_pages_input');

/// The id that makes `deviceArtFor` pick the wallpaper the references show.
String uidWithWall(String stem, int wall) {
  for (var i = 0; ; i++) {
    final uid = '$stem-$i';
    if (uid.hashCode.abs() % DeviceWallpaper.paired.length == wall) return uid;
  }
}

DeviceData shareDevice(
  String uid,
  String name, {
  String platform = 'macos',
  bool auth = true,
}) => DeviceData(
  id: uid.hashCode.abs() % 100000,
  uid: uid,
  name: name,
  host: '192.168.31.${uid.length}',
  port: 10002,
  platform: platform,
  isServer: true,
  online: true,
  clipboard: false,
  auth: auth,
  lastTime: 0,
);

ChatSessionItem shareSession(
  DeviceData device, {
  bool connected = true,
  bool nearby = true,
}) => ChatSessionItem(
  device: device,
  latestMessage: null,
  preview: '',
  lastTimestamp: 0,
  isConnected: connected,
  isNearby: nearby,
  hasHistory: false,
);

final selfMac = shareDevice('self', 'xiaoxin 的 MacBook Air 13 英寸');
final imacDevice = shareDevice(
  uidWithWall('imac', 0),
  'iMac',
  platform: 'windows',
);
final thinkPadDevice = shareDevice(
  uidWithWall('tp', 1),
  'ThinkPad X1 Carbon 办公笔记本',
);
final xiaomiDevice = shareDevice(
  uidWithWall('mi', 2),
  'Xiaomi 16',
  platform: 'android',
);
final redmiDevice = shareDevice(
  uidWithWall('pad', 0),
  'Redmi Pad',
  platform: 'android',
);
final ubuntuDevice = shareDevice(
  uidWithWall('ubuntu', 3),
  'Ubuntu',
  platform: 'linux',
);

/// A sound world: real coordinators, no network, everything sent is recorded.
class SoundWorld {
  SoundWorld({
    Set<String>? connected,
    Set<String>? solo,
    bool canRejoin = true,
    bool denied = false,
  }) : connected =
           connected ?? {imacDevice.uid, thinkPadDevice.uid, xiaomiDevice.uid},
       solo = solo ?? {},
       _canRejoin = canRejoin,
       _denied = denied {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_audioChannel, (call) async {
          calls.add(call);
          return null;
        });
    platform = AudioPlatform(channel: _audioChannel);
    group = AudioGroupCoordinator(
      platform: platform,
      playbackGainProvider: () async => 1,
      codecFactory: (format) async =>
          PcmPassthroughAudioCodec(AudioCodecConfig.fromStreamFormat(format)),
    );
    single = AudioShareCoordinator(
      manager: AudioShareManager(),
      platform: platform,
      playbackGainProvider: () async => 1,
    );
    controller = ShellSoundController(
      group: group,
      single: single,
      platform: platform,
      backend: SoundBackend(
        isConnected: this.connected.contains,
        supportsGroupSink: (peer) => !this.solo.contains(peer),
        canRejoinFrom: (_) => _canRejoin,
        sendGroupControl: (peer, control) => sentGroup.add((peer, control)),
        sendSingleControl: (peer, control) => sentSingle.add((peer, control)),
        deviceFor: (peer) => devices[peer],
        selfPeerId: () async => selfMac.uid,
        captureDenied: () => _denied,
        requestCapture: () async => permissionAsked++,
        loadGain: () async => loadedGain,
        saveGain: (gain) async => savedGain = gain,
      ),
    );
  }

  final Set<String> connected;
  final Set<String> solo;
  final bool _canRejoin;
  bool _denied;
  final calls = <MethodCall>[];
  final sentGroup = <(String, AudioGroupControlMessage)>[];
  final sentSingle = <(String, AudioControlMessage)>[];
  final devices = <String, DeviceData>{
    for (final d in [imacDevice, thinkPadDevice, xiaomiDevice, redmiDevice])
      d.uid: d,
  };
  late final AudioPlatform platform;
  late final AudioGroupCoordinator group;
  late final AudioShareCoordinator single;
  late final ShellSoundController controller;
  int permissionAsked = 0;
  double loadedGain = 1;
  double? savedGain;

  set denied(bool value) => _denied = value;

  List<ChatSessionItem> get sessions => [
    for (final d in [imacDevice, thinkPadDevice, xiaomiDevice, redmiDevice])
      shareSession(d, connected: connected.contains(d.uid)),
    shareSession(ubuntuDevice, connected: false, nearby: false),
  ];

  /// The device replies to its offer: it is now playing, no numbers yet.
  Future<void> accept(String peer) async {
    final session = group.session!;
    await group.handleControlMessage(
      AudioGroupControlMessage(
        action: AudioGroupControlAction.groupAccept,
        groupId: session.groupId,
        streamId: session.streamId,
        sessionId: session.sinks[peer]!.sessionId,
        sourcePeerId: selfMac.uid,
        sinkPeerId: peer,
        channelRole: session.sinks[peer]!.channelRole,
      ),
      localPeerId: selfMac.uid,
      remoteHost: '',
      remotePort: 0,
      sendControl: (_, _) {},
    );
  }

  /// The numbers it reports about itself.
  Future<void> report(
    String peer, {
    int rttMs = 2,
    int jitterMs = 1,
    int bufferMs = 80,
    int late = 0,
    int errorMs = 0,
  }) async {
    final session = group.session!;
    await group.handleControlMessage(
      AudioGroupControlMessage(
        action: AudioGroupControlAction.latencyReport,
        groupId: session.groupId,
        streamId: session.streamId,
        sessionId: session.sinks[peer]!.sessionId,
        sourcePeerId: selfMac.uid,
        sinkPeerId: peer,
        rttMicros: rttMs * 1000,
        jitterMicros: jitterMs * 1000,
        bufferDepthMicros: bufferMs * 1000,
        latePacketCount: late,
        syncErrorMicros: errorMs * 1000,
      ),
      localPeerId: selfMac.uid,
      remoteHost: '',
      remotePort: 0,
      sendControl: (_, _) {},
    );
  }

  /// The device says it cannot play.
  Future<void> reject(String peer, {String reason = 'busy'}) async {
    final session = group.session!;
    await group.handleControlMessage(
      AudioGroupControlMessage(
        action: AudioGroupControlAction.groupReject,
        groupId: session.groupId,
        streamId: session.streamId,
        sessionId: session.sinks[peer]!.sessionId,
        sourcePeerId: selfMac.uid,
        sinkPeerId: peer,
        errorMessage: reason,
      ),
      localPeerId: selfMac.uid,
      remoteHost: '',
      remotePort: 0,
      sendControl: (_, _) {},
    );
  }

  /// [source] starts playing its sound here.
  Future<void> offerFrom(String source) async {
    await group.handleControlMessage(
      AudioGroupControlMessage(
        action: AudioGroupControlAction.groupOffer,
        groupId: 'group',
        streamId: 'stream',
        sessionId: 'session',
        sourcePeerId: source,
        sinkPeerId: selfMac.uid,
        sinkPeerIds: [selfMac.uid],
        format: const AudioStreamFormat(
          codec: AudioCodecKind.pcmS16le,
          sampleRate: 48000,
          channels: 2,
          frameDurationMs: 20,
          bitRate: 128000,
        ),
        path: '/audio',
        channelRole: AudioChannelRole.stereo,
      ),
      localPeerId: selfMac.uid,
      remoteHost: '$source.local',
      remotePort: 10002,
      sendControl: (peer, control) => sentGroup.add((peer, control)),
    );
  }

  void dispose() {
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_audioChannel, null);
  }
}

class _NoTransport implements RemoteInputPacketTransport {
  @override
  void send(RemoteInputPacketFrame packet) {}

  @override
  Future<void> close() async {}
}

RemoteInputTopology topologyOf(List<List<int>> displays) => RemoteInputTopology(
  platform: 'test',
  displays: [
    for (final (i, d) in displays.indexed)
      RemoteInputDisplay(
        displayId: 'd$i',
        name: 'display $i',
        x: d[0],
        y: d[1],
        width: d[2],
        height: d[3],
        scale: 1,
        isPrimary: i == 0,
      ),
  ],
  updatedAt: 1,
);

RemoteInputLayoutData layoutOf(
  String peerId,
  int x,
  int y,
  int width,
  int height, {
  bool enabled = true,
}) => RemoteInputLayoutData(
  peerId: peerId,
  peerName: '',
  x: x,
  y: y,
  width: width,
  height: height,
  enabled: enabled,
  autoActivate: false,
  autoRole: RemoteInputAutoRole.source.name,
  layoutVersion: 3,
  layoutJson: '',
  edgeThresholdPx: 6,
  releaseHotkey: remoteInputReleaseHotkey,
  updatedAt: 1,
);

/// A keyboard and mouse world, as the references draw it.
class InputWorld {
  InputWorld({
    Set<String>? connected,
    Map<String, RemoteInputLayoutData>? layouts,
    Set<String>? unsupported,
    Set<String>? notTrusted,
    Set<String>? notTrustingUs,
    bool denied = false,
  }) : connected = connected ?? {imacDevice.uid, thinkPadDevice.uid},
       layouts =
           layouts ??
           {
             imacDevice.uid: layoutOf(imacDevice.uid, 1512, -229, 2560, 1440),
             thinkPadDevice.uid: layoutOf(
               thinkPadDevice.uid,
               4072,
               -229,
               3840,
               1200,
             ),
             ubuntuDevice.uid: layoutOf(
               ubuntuDevice.uid,
               -1920,
               -49,
               1920,
               1080,
             ),
           },
       unsupported = unsupported ?? {},
       notTrusted = notTrusted ?? {},
       notTrustingUs = notTrustingUs ?? {},
       _denied = denied {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_inputChannel, (call) async => null);
    final manager = RemoteInputManager();
    final platform = RemoteInputPlatform(channel: _inputChannel);
    workspace = RemoteInputWorkspaceCoordinator(
      manager: manager,
      platform: platform,
      transportFactory: (_) async => _NoTransport(),
    );
    runtime = RemoteInputCoordinator(manager: manager, platform: platform);
    controller = ShellInputController(
      workspace: workspace,
      runtime: runtime,
      macHotkey: true,
      backend: InputBackend(
        localTopology: () async => local,
        refreshProfiles: () async {},
        isConnected: this.connected.contains,
        supportsGraph: (peer) =>
            this.connected.contains(peer) && !this.unsupported.contains(peer),
        remoteTopology: (peer) => topologies[peer],
        remoteTrusts: (peer, _) => !this.notTrustingUs.contains(peer),
        localTrusts: (peer) async => !this.notTrusted.contains(peer),
        loadLayout: (peer) async => this.layouts[peer],
        saveLayout: (layout) async {
          this.layouts[layout.peerId] = layout;
          saved.add(layout);
        },
        sendControl: (peer, control) => sent.add((peer, control)),
        selfPeerId: () async => selfMac.uid,
        accessibilityDenied: () => _denied,
        requestAccessibility: () async => permissionAsked++,
      ),
    );
  }

  final Set<String> connected, unsupported, notTrusted, notTrustingUs;
  final Map<String, RemoteInputLayoutData> layouts;
  final bool _denied;
  final saved = <RemoteInputLayoutData>[];
  final sent = <(String, RemoteInputControlMessage)>[];
  int permissionAsked = 0;
  RemoteInputTopology local = topologyOf([
    [0, 0, 1512, 982],
  ]);
  final topologies = <String, RemoteInputTopology>{
    imacDevice.uid: topologyOf([
      [0, 0, 2560, 1440],
    ]),
    thinkPadDevice.uid: topologyOf([
      [0, 0, 1920, 1200],
      [1920, 0, 1920, 1080],
    ]),
  };
  late final RemoteInputWorkspaceCoordinator workspace;
  late final RemoteInputCoordinator runtime;
  late final ShellInputController controller;

  List<ChatSessionItem> get sessions => [
    for (final d in [imacDevice, thinkPadDevice, xiaomiDevice])
      shareSession(d, connected: connected.contains(d.uid)),
    shareSession(ubuntuDevice, connected: connected.contains(ubuntuDevice.uid)),
  ];

  /// The peer answers an offer, and the transport comes up.
  Future<void> accept(String peer) async {
    final offer = sent.lastWhere(
      (entry) =>
          entry.$1 == peer && entry.$2.action == RemoteInputControlAction.offer,
    );
    await workspace.handleControlMessage(
      RemoteInputControlMessage(
        action: RemoteInputControlAction.accept,
        sessionId: offer.$2.sessionId,
        sourcePeerId: selfMac.uid,
        sinkPeerId: peer,
      ),
      localPeerId: selfMac.uid,
      remoteHost: '$peer.local',
      remotePort: 10002,
      sendControlTo: (peer, control) => sent.add((peer, control)),
    );
  }

  /// The peer refuses, for [reason].
  Future<void> reject(String peer, {String reason = 'trustRequired'}) async {
    final offer = sent.lastWhere(
      (entry) =>
          entry.$1 == peer && entry.$2.action == RemoteInputControlAction.offer,
    );
    await workspace.handleControlMessage(
      RemoteInputControlMessage(
        action: RemoteInputControlAction.error,
        sessionId: offer.$2.sessionId,
        sourcePeerId: selfMac.uid,
        sinkPeerId: peer,
        errorMessage: reason,
      ),
      localPeerId: selfMac.uid,
      remoteHost: '$peer.local',
      remotePort: 10002,
      sendControlTo: (peer, control) => sent.add((peer, control)),
    );
  }

  void dispose() {
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_inputChannel, null);
  }
}

final shotKey = GlobalKey();

/// [page] alone in the window, the way the shell gives it the content area.
Future<void> pumpContent(
  WidgetTester tester,
  Widget page, {
  required Size size,
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('zh'),
  double devicePixelRatio = 2,
}) async {
  tester.view.physicalSize = size * devicePixelRatio;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.reset);
  // flutter_test paints shadows without their blur. renderShot puts it back.
  if (_rendering) debugDisableShadows = false;
  await tester.pumpWidget(
    goldenApp(
      Scaffold(
        body: RepaintBoundary(key: shotKey, child: page),
      ),
      brightness: brightness,
      locale: locale,
    ),
  );
  await settle(tester);
}

bool get _rendering =>
    (Platform.environment['WHISPER_RENDER_DIR'] ?? '').isNotEmpty;

/// Lets springs land. Not `pumpAndSettle`: the wave never does.
Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }
}

/// The content area of the reference pictures, which are 1x window shots.
const referenceContent = Rect.fromLTWH(278, 42, 876, 690);
const referenceRegularContent = Rect.fromLTWH(278, 42, 524, 690);

/// With WHISPER_RENDER_DIR set, writes what is on screen, and beside a reference
/// when given one, for looking at. Never compared, and nothing lands in the repo.
Future<void> renderShot(
  WidgetTester tester,
  String name, {
  String? reference,
  Rect crop = referenceContent,
}) async {
  if (!_rendering || !kDebugMode) return;
  final dir = Platform.environment['WHISPER_RENDER_DIR']!;
  final boundary =
      shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    Directory(dir).createSync(recursive: true);
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    if (reference == null) return;
    final bytes = File('docs/design/reference/$reference').readAsBytesSync();
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final w = crop.width * 2, h = crop.height * 2;
    canvas.drawImageRect(
      frame.image,
      crop,
      Rect.fromLTWH(0, 0, w, h),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(w + 16, 0, image.width.toDouble(), image.height.toDouble()),
      Paint(),
    );
    final both = await recorder.endRecording().toImage(
      (w + 16 + image.width).round(),
      h.round(),
    );
    final out = await both.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name-vs.png').writeAsBytesSync(out!.buffer.asUint8List());
  });
  // What the test binding checks for at the end of the test body.
  debugDisableShadows = true;
}
