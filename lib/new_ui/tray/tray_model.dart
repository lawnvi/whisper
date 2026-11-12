import 'package:whisper/theme/whisper_device_art.dart';

/// Everything the tray panel shows. The panel has an engine of its own, whose
/// singletons are not the app's, so its whole state crosses as plain maps.
class TrayDevice {
  const TrayDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.order,
    this.kind = '',
  });

  factory TrayDevice.fromMap(Map<dynamic, dynamic> m) => TrayDevice(
    id: m['id'] as String,
    name: m['name'] as String,
    platform: m['platform'] as String,
    order: m['order'] as int,
    kind: m['kind'] as String? ?? '',
  );

  /// [name] is what it is called here, which may be a name given to it;
  /// [kind] is a `DeviceKind`'s name, worked out by the app, which knows
  /// what it said it is.
  final String id, name, platform, kind;

  /// What to draw: as [kind] says, else as the platform suggests.
  DeviceKind get deviceKind =>
      DeviceKind.values.asNameMap()[kind] ?? deviceKindFor(platform);

  /// Which wallpaper it gets.
  final int order;

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'platform': platform,
    'order': order,
    'kind': kind,
  };
}

class TrayMoment {
  const TrayMoment({
    required this.id,
    required this.title,
    required this.detail,
    this.progress,
    this.cancelable = false,
    this.answers = const [],
  });

  factory TrayMoment.fromMap(Map<dynamic, dynamic> m) => TrayMoment(
    id: m['id'] as String,
    title: m['title'] as String,
    detail: m['detail'] as String,
    progress: (m['progress'] as num?)?.toDouble(),
    cancelable: m['cancelable'] as bool? ?? false,
    answers: [for (final a in m['answers'] as List) a as String],
  );

  final String id, title, detail;

  /// A transfer's, 0 to 1. Null for a request.
  final double? progress;
  final bool cancelable;

  /// A request's answers, the first one being the likely one.
  final List<String> answers;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'detail': detail,
    'progress': progress,
    'cancelable': cancelable,
    'answers': answers,
  };
}

class TrayFlow {
  const TrayFlow({
    required this.id,
    required this.title,
    required this.detail,
    required this.action,
  });

  factory TrayFlow.fromMap(Map<dynamic, dynamic> m) => TrayFlow(
    id: m['id'] as String,
    title: m['title'] as String,
    detail: m['detail'] as String,
    action: m['action'] as String,
  );

  final String id, title, detail, action;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'detail': detail,
    'action': action,
  };
}

class TrayClip {
  const TrayClip({required this.text, required this.line, this.image = false});

  factory TrayClip.fromMap(Map<dynamic, dynamic> m) => TrayClip(
    text: m['text'] as String,
    line: m['line'] as String,
    image: m['image'] as bool? ?? false,
  );

  final String text;

  /// Where it came from and when.
  final String line;
  final bool image;

  Map<String, Object?> toMap() => {'text': text, 'line': line, 'image': image};
}

class TrayState {
  const TrayState({
    this.dark = false,
    this.current = '',
    this.currentImage = false,
    this.targets = const [],
    this.nearby = const [],
    this.moments = const [],
    this.soundOn = false,
    this.soundStatus = '',
    this.inputOn = false,
    this.inputStatus = '',
    this.flows = const [],
    this.clips = const [],
    this.locale = 'zh',
  });

  factory TrayState.fromMap(Map<dynamic, dynamic> m) => TrayState(
    dark: m['dark'] as bool? ?? false,
    current: m['current'] as String? ?? '',
    currentImage: m['currentImage'] as bool? ?? false,
    targets: [
      for (final d in m['targets'] as List)
        TrayDevice.fromMap(d as Map<dynamic, dynamic>),
    ],
    nearby: [
      for (final d in m['nearby'] as List)
        TrayDevice.fromMap(d as Map<dynamic, dynamic>),
    ],
    moments: [
      for (final d in m['moments'] as List)
        TrayMoment.fromMap(d as Map<dynamic, dynamic>),
    ],
    soundOn: m['soundOn'] as bool? ?? false,
    soundStatus: m['soundStatus'] as String? ?? '',
    inputOn: m['inputOn'] as bool? ?? false,
    inputStatus: m['inputStatus'] as String? ?? '',
    flows: [
      for (final d in m['flows'] as List)
        TrayFlow.fromMap(d as Map<dynamic, dynamic>),
    ],
    clips: [
      for (final d in m['clips'] as List)
        TrayClip.fromMap(d as Map<dynamic, dynamic>),
    ],
    locale: m['locale'] as String? ?? 'zh',
  );

  final bool dark;
  final String current;
  final bool currentImage;

  /// Connected: click one to send.
  final List<TrayDevice> targets;

  /// Shown instead when nothing is connected, with 连接.
  final List<TrayDevice> nearby;
  final List<TrayMoment> moments;
  final bool soundOn, inputOn;
  final String soundStatus, inputStatus;
  final List<TrayFlow> flows;

  /// The recent ones, without the current one.
  final List<TrayClip> clips;
  final String locale;

  Map<String, Object?> toMap() => {
    'dark': dark,
    'current': current,
    'currentImage': currentImage,
    'targets': [for (final d in targets) d.toMap()],
    'nearby': [for (final d in nearby) d.toMap()],
    'moments': [for (final d in moments) d.toMap()],
    'soundOn': soundOn,
    'soundStatus': soundStatus,
    'inputOn': inputOn,
    'inputStatus': inputStatus,
    'flows': [for (final d in flows) d.toMap()],
    'clips': [for (final d in clips) d.toMap()],
    'locale': locale,
  };
}
