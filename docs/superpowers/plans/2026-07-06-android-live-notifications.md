# Android 通知"上岛"实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 连接请求系统通知(一键同意/拒绝)、独立传输进度通知(Android 16+ Live Updates,15- 经典降级)、播放端 MediaSession 媒体外壳,全部仅限 Android。

**Architecture:** 三个通知面共用"状态单一来源、原地更新"原则。连接请求走现有 `flutter_local_notifications` 18.x + background isolate 路由;传输进度走新自研 platform channel(`TransferNotificationPlugin` + `TransferForegroundService`,ProgressStyle/promoted ongoing + setProgress 降级);播放端在现有 `AudioSharePlugin` 上外挂 MediaSessionCompat + `mediaPlayback` 前台服务,协议新增 `sinkJoinRequest` 动作与 `audioGroupRejoinV1` 能力实现"暂停=断流、播放=重新加入"。

**Tech Stack:** Flutter/Dart、Kotlin、`flutter_local_notifications` 18.x(不升级)、`androidx.core:core:1.17.0`(ProgressStyle/promoted API)、`androidx.media:media:1.7.0`(MediaSessionCompat)。

**Spec:** `docs/superpowers/specs/2026-07-06-android-live-notifications-design.md`(含产品决策与验收标准,冲突时以 spec 为准)。

## Global Constraints

- 仅 Android:不改 iOS/macOS/Linux/Windows 任何行为;所有新逻辑用 `Platform.isAndroid` 或原生层隔离。
- 播放引擎零改动:`AudioTrack` 写入、时钟同步、追赶/丢帧逻辑(`AudioSharePlugin.kt` 现有方法体、`audio_group_playback_scheduler.dart` 等)不许动。
- 不升级 `flutter_local_notifications`(锁 `^18.0.1`),不新增 pub 依赖。
- 通知一律原地更新同一 notification id,禁止 cancel+重发;进度通知 `setOnlyAlertOnce(true)` + 静音 channel。
- 所有用户可见文案经 ARB 三语(`lib/l10n/app_zh.arb`/`app_en.arb`/`app_es.arb`),改 ARB 后必须 `flutter gen-l10n`;禁止硬编码文案(原生层文案由 Dart 传入)。
- 每个任务结束:`flutter analyze` 与 `flutter test` 通过后才 commit;commit 用 Conventional Commits(scope 用 `socket`/`android`/`audio`/`l10n`)。
- 通知 id 分配:保活 10021(现有)、传输 10022、媒体 10023、连接请求 `20000 + (peerId.hashCode.abs() % 1000)`。
- channel id:连接请求 `whisper.connect_request`(HIGH)、传输 `whisper.transfer`(LOW 静音)、媒体 `whisper.media_playback`(LOW)。

---

### Task 1: GuardedAuthCallback(幂等回调)与连接请求 pending 注册表

**Files:**
- Create: `lib/socket/guarded_auth_callback.dart`
- Create: `lib/helper/connection_request_registry.dart`
- Test: `test/guarded_auth_callback_test.dart`

**Interfaces:**
- Consumes: 无(纯 Dart,无插件依赖)。
- Produces: `GuardedAuthCallback`(`void call(bool allow)`,`bool get resolved`,构造参数 `void Function(bool allow) inner` 与可选 `void Function(bool allow)? onResolved`);`ConnectionRequestRegistry`(`String register(String peerId, GuardedAuthCallback callback)` 返回 requestId、`bool resolve(String requestId, bool allow)`、`GuardedAuthCallback? removeForPeer(String peerId)`、`void clear()`)。Task 2 依赖这两个类型。

- [ ] **Step 1: 写失败测试**

```dart
// test/guarded_auth_callback_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/guarded_auth_callback.dart';
import 'package:whisper/helper/connection_request_registry.dart';

void main() {
  test('guarded callback only fires once', () {
    var calls = <bool>[];
    var resolvedWith = <bool>[];
    final guarded = GuardedAuthCallback(
      calls.add,
      onResolved: resolvedWith.add,
    );
    expect(guarded.resolved, isFalse);
    guarded.call(true);
    guarded.call(false);
    guarded.call(true);
    expect(calls, [true]);
    expect(resolvedWith, [true]);
    expect(guarded.resolved, isTrue);
  });

  test('registry resolves by requestId idempotently', () {
    final registry = ConnectionRequestRegistry();
    var calls = <bool>[];
    final guarded = GuardedAuthCallback(calls.add);
    final requestId = registry.register('peer-a', guarded);
    expect(requestId, startsWith('peer-a#'));
    expect(registry.resolve(requestId, true), isTrue);
    expect(registry.resolve(requestId, false), isFalse); // 已处理过
    expect(registry.resolve('peer-a#999', true), isFalse); // 未知 id
    expect(calls, [true]);
  });

  test('new request for same peer supersedes the old one', () {
    final registry = ConnectionRequestRegistry();
    final first = GuardedAuthCallback((_) {});
    final firstId = registry.register('peer-a', first);
    final second = GuardedAuthCallback((_) {});
    final secondId = registry.register('peer-a', second);
    expect(firstId, isNot(secondId));
    expect(registry.resolve(firstId, true), isFalse); // 旧的失效
    expect(registry.resolve(secondId, true), isTrue);
  });

  test('removeForPeer drops pending entry', () {
    final registry = ConnectionRequestRegistry();
    final guarded = GuardedAuthCallback((_) {});
    final id = registry.register('peer-a', guarded);
    expect(registry.removeForPeer('peer-a'), same(guarded));
    expect(registry.resolve(id, true), isFalse);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/guarded_auth_callback_test.dart`
Expected: FAIL,报找不到 `guarded_auth_callback.dart` / `connection_request_registry.dart`。

- [ ] **Step 3: 最小实现**

```dart
// lib/socket/guarded_auth_callback.dart
/// 包装 onAuth 的确认回调,保证不论从应用内弹窗还是系统通知触达,
/// 都只有第一次调用生效(幂等),并在解析时通知观察者。
class GuardedAuthCallback {
  GuardedAuthCallback(this._inner, {void Function(bool allow)? onResolved})
      : _onResolved = onResolved;

  final void Function(bool allow) _inner;
  final void Function(bool allow)? _onResolved;
  bool _resolved = false;

  bool get resolved => _resolved;

  void call(bool allow) {
    if (_resolved) {
      return;
    }
    _resolved = true;
    _inner(allow);
    _onResolved?.call(allow);
  }
}
```

```dart
// lib/helper/connection_request_registry.dart
import 'package:whisper/socket/guarded_auth_callback.dart';

/// 挂起中的连接请求注册表:requestId -> 回调。
/// requestId 形如 `peerId#seq`,同一 peer 的新请求会顶掉旧请求。
class ConnectionRequestRegistry {
  final Map<String, GuardedAuthCallback> _pendingByRequestId =
      <String, GuardedAuthCallback>{};
  final Map<String, String> _requestIdByPeerId = <String, String>{};
  int _seq = 0;

  String register(String peerId, GuardedAuthCallback callback) {
    final stale = _requestIdByPeerId.remove(peerId);
    if (stale != null) {
      _pendingByRequestId.remove(stale);
    }
    final requestId = '$peerId#${++_seq}';
    _pendingByRequestId[requestId] = callback;
    _requestIdByPeerId[peerId] = requestId;
    return requestId;
  }

  bool resolve(String requestId, bool allow) {
    final callback = _pendingByRequestId.remove(requestId);
    if (callback == null || callback.resolved) {
      return false;
    }
    _requestIdByPeerId.removeWhere((_, id) => id == requestId);
    callback.call(allow);
    return true;
  }

  GuardedAuthCallback? removeForPeer(String peerId) {
    final requestId = _requestIdByPeerId.remove(peerId);
    if (requestId == null) {
      return null;
    }
    return _pendingByRequestId.remove(requestId);
  }

  void clear() {
    _pendingByRequestId.clear();
    _requestIdByPeerId.clear();
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/guarded_auth_callback_test.dart`
Expected: PASS(4 个用例)。

- [ ] **Step 5: Commit**

```bash
git add lib/socket/guarded_auth_callback.dart lib/helper/connection_request_registry.dart test/guarded_auth_callback_test.dart
git commit -m "feat(socket): 连接请求幂等回调与 pending 注册表"
```

---

### Task 2: 连接请求系统通知(action、isolate 路由、svrmanager 挂接)

**Files:**
- Create: `lib/helper/connection_request_notifications.dart`
- Modify: `lib/helper/notification.dart`(initialize 加回调参数)
- Modify: `lib/socket/svrmanager.dart:1081-1115`(onAuth 分发点)与 `:456-464`(`_releaseIncomingAuthForSink`)
- Modify: `lib/main.dart:46-47` 附近(初始化 notifier)
- Modify: `android/app/src/main/AndroidManifest.xml`(补 ActionBroadcastReceiver)
- Modify: `lib/l10n/app_zh.arb`、`lib/l10n/app_en.arb`、`lib/l10n/app_es.arb`
- Test: `test/connection_request_notification_source_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `GuardedAuthCallback`、`ConnectionRequestRegistry`;现有 `NotificationHelper`、`ISocketEvent.onAuth` 分发逻辑。
- Produces: `ConnectionRequestNotifier`(单例:`Future<void> initialize(FlutterLocalNotificationsPlugin plugin)`、`Future<void> maybeShowForAuthRequest({required String peerId, required String deviceName, required String host, required GuardedAuthCallback callback})`、`Future<void> dismissForPeer(String peerId)`、`void handleNotificationResponse(NotificationResponse response)`、`static const portName/acceptActionId/rejectActionId`、`static int notificationIdForPeer(String peerId)`);顶层 `@pragma('vm:entry-point') void connectionRequestNotificationBackgroundHandler(NotificationResponse response)`。

- [ ] **Step 1: 写失败的 source test**

```dart
// test/connection_request_notification_source_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('connection request notification is wired end to end', () {
    final notifier =
        File('lib/helper/connection_request_notifications.dart')
            .readAsStringSync();
    final helper = File('lib/helper/notification.dart').readAsStringSync();
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    // notifier 核心要素
    expect(notifier, contains("'whisper.connect_request'"));
    expect(notifier, contains("@pragma('vm:entry-point')"));
    expect(notifier, contains('IsolateNameServer.registerPortWithName'));
    expect(notifier, contains('IsolateNameServer.lookupPortByName'));
    expect(notifier, contains("acceptActionId = 'whisper_connect_accept'"));
    expect(notifier, contains("rejectActionId = 'whisper_connect_reject'"));
    expect(notifier, contains('AppLifecycleState.resumed'));

    // 前台/后台响应回调都接上了
    expect(helper, contains('onDidReceiveNotificationResponse'));
    expect(
        helper, contains('onDidReceiveBackgroundNotificationResponse:'));
    expect(helper,
        contains('connectionRequestNotificationBackgroundHandler'));

    // svrmanager:守卫回调 + 通知入口 + 断连清理
    expect(manager, contains('GuardedAuthCallback('));
    expect(manager, contains('maybeShowForAuthRequest'));
    expect(
      manager,
      matches(RegExp(
          r'_releaseIncomingAuthForSink[\s\S]{0,400}dismissForPeer')),
    );

    // manifest 补了 action receiver
    expect(
      manifest,
      contains(
          'com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver'),
    );

    // main.dart 初始化
    expect(main, contains('ConnectionRequestNotifier().initialize'));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/connection_request_notification_source_test.dart`
Expected: FAIL(notifier 文件不存在)。

- [ ] **Step 3: 实现 ConnectionRequestNotifier**

```dart
// lib/helper/connection_request_notifications.dart
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:whisper/helper/connection_request_registry.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/socket/guarded_auth_callback.dart';

/// 后台 isolate 中的通知 action 回调:把决定送回主 isolate。
/// 主 isolate 端口不存在时进程已重启,pending 请求必然失效,
/// 原地把通知更新为"已过期"。
@pragma('vm:entry-point')
Future<void> connectionRequestNotificationBackgroundHandler(
    NotificationResponse response) async {
  final requestId = response.payload;
  if (requestId == null || requestId.isEmpty) {
    return;
  }
  final port =
      IsolateNameServer.lookupPortByName(ConnectionRequestNotifier.portName);
  if (port != null) {
    port.send(<String, Object?>{
      'requestId': requestId,
      'allow': response.actionId == ConnectionRequestNotifier.acceptActionId,
    });
    return;
  }
  await ConnectionRequestNotifier.showExpired(
    FlutterLocalNotificationsPlugin(),
    requestId,
  );
}

class ConnectionRequestNotifier {
  static final ConnectionRequestNotifier _instance =
      ConnectionRequestNotifier._internal();

  factory ConnectionRequestNotifier() => _instance;

  ConnectionRequestNotifier._internal();

  static const String portName = 'whisper.connect_request.port';
  static const String acceptActionId = 'whisper_connect_accept';
  static const String rejectActionId = 'whisper_connect_reject';
  static const String channelId = 'whisper.connect_request';

  final ConnectionRequestRegistry registry = ConnectionRequestRegistry();
  FlutterLocalNotificationsPlugin? _plugin;
  ReceivePort? _receivePort;

  static int notificationIdForPeer(String peerId) =>
      20000 + (peerId.hashCode.abs() % 1000);

  static String _peerIdOfRequest(String requestId) =>
      requestId.split('#').first;

  AppLocalizations get _l10n =>
      lookupAppLocalizations(PlatformDispatcher.instance.locale);

  Future<void> initialize(FlutterLocalNotificationsPlugin plugin) async {
    if (!Platform.isAndroid) {
      return;
    }
    _plugin = plugin;
    IsolateNameServer.removePortNameMapping(portName);
    final port = ReceivePort();
    IsolateNameServer.registerPortWithName(port.sendPort, portName);
    port.listen((message) {
      if (message is Map) {
        _resolve(message['requestId'] as String? ?? '',
            message['allow'] as bool? ?? false);
      }
    });
    _receivePort = port;
  }

  /// app 非前台(Android)才发系统通知;前台仍走应用内弹窗。
  Future<void> maybeShowForAuthRequest({
    required String peerId,
    required String deviceName,
    required String host,
    required GuardedAuthCallback callback,
  }) async {
    final plugin = _plugin;
    if (!Platform.isAndroid || plugin == null || peerId.isEmpty) {
      return;
    }
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    final requestId = registry.register(peerId, callback);
    final l10n = _l10n;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        l10n.connectRequest,
        channelDescription: l10n.connectRequest,
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.call,
        autoCancel: false,
        ongoing: true,
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            acceptActionId,
            l10n.allow,
            showsUserInterface: false,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            rejectActionId,
            l10n.refuse,
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      ),
    );
    await plugin.show(
      notificationIdForPeer(peerId),
      l10n.connectRequest,
      l10n.connectRequestNotificationBody(deviceName, host),
      details,
      payload: requestId,
    );
  }

  /// 前台(主 isolate)action 响应入口。
  void handleNotificationResponse(NotificationResponse response) {
    final requestId = response.payload;
    if (requestId == null ||
        (response.actionId != acceptActionId &&
            response.actionId != rejectActionId)) {
      return;
    }
    _resolve(requestId, response.actionId == acceptActionId);
  }

  Future<void> dismissForPeer(String peerId) async {
    registry.removeForPeer(peerId);
    await _plugin?.cancel(notificationIdForPeer(peerId));
  }

  void _resolve(String requestId, bool allow) {
    if (requestId.isEmpty) {
      return;
    }
    final handled = registry.resolve(requestId, allow);
    if (!handled) {
      // 请求已在别处处理或已失效:原地转"已过期",不静默吞掉。
      final plugin = _plugin;
      if (plugin != null) {
        showExpired(plugin, requestId);
      }
      return;
    }
    _plugin?.cancel(notificationIdForPeer(_peerIdOfRequest(requestId)));
  }

  static Future<void> showExpired(
      FlutterLocalNotificationsPlugin plugin, String requestId) async {
    final l10n =
        lookupAppLocalizations(PlatformDispatcher.instance.locale);
    await plugin.show(
      notificationIdForPeer(_peerIdOfRequest(requestId)),
      l10n.connectRequest,
      l10n.connectRequestExpired,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          l10n.connectRequest,
          importance: Importance.low,
          priority: Priority.low,
          autoCancel: true,
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: NotificationHelper.initialize 接回调**

修改 `lib/helper/notification.dart` 第 40 行的初始化调用(保留原有设置对象不动):

```dart
// 文件头部新增 import:
import 'package:whisper/helper/connection_request_notifications.dart';

// 将原来的:
//   await _notificationsPlugin.initialize(initializationSettings);
// 替换为:
    await _notificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (response) {
        ConnectionRequestNotifier().handleNotificationResponse(response);
      },
      onDidReceiveBackgroundNotificationResponse:
          connectionRequestNotificationBackgroundHandler,
    );
```

并在 `NotificationHelper` 类中暴露插件实例(`ConnectionRequestNotifier.initialize` 要用):

```dart
  FlutterLocalNotificationsPlugin get plugin => _notificationsPlugin;
```

- [ ] **Step 5: main.dart 初始化 notifier**

在 `lib/main.dart:47`(`await notificationHelper.initialize();` 之后)插入:

```dart
  await ConnectionRequestNotifier().initialize(notificationHelper.plugin);
```

并加 import `package:whisper/helper/connection_request_notifications.dart`。

- [ ] **Step 6: svrmanager 挂接**

修改 `lib/socket/svrmanager.dart` 的 onAuth 分发块(现 1081-1115 行)。把原始 callback 闭包提取为局部变量并用 `GuardedAuthCallback` 包装,通知与弹窗共用同一守卫:

```dart
          logger.i("AUTH message: ${message.sender} - $sender");
          Future<void> respond(bool allow) async {
            try {
              logger.i("AUTH message: ${message.message} ||| $allow");
              if (asServer) {
                await _auth(allow, sink: sink, peerId: peerId);
              }
              if (allow) {
                receiver = peerId;
                if (peerId.isNotEmpty && sink != null) {
                  await _registerPeerConnection(
                    peerId: peerId,
                    sink: sink,
                    profile: profile,
                  );
                }
                _setRemoteProfile(profile, peerId: peerId);
                _dispatchToAll((event) => event.onConnect());
                unawaited(_resumeRecoverableOutgoingTransfers());
              } else {
                close();
              }
              _dispatchToAll((listener) => listener.afterAuth(allow, device));
            } finally {
              if (asServer && peerId.isNotEmpty) {
                _authRequestGate.releaseIncoming(peerId);
                if (sink != null) {
                  _incomingAuthPeerIdsBySink.remove(sink);
                }
              }
            }
          }

          final guarded = GuardedAuthCallback(
            (allow) => unawaited(respond(allow)),
            onResolved: (_) {
              if (asServer && peerId.isNotEmpty) {
                unawaited(
                    ConnectionRequestNotifier().dismissForPeer(peerId));
              }
            },
          );
          if (asServer && peerId.isNotEmpty && (message.message ?? '').isEmpty) {
            unawaited(ConnectionRequestNotifier().maybeShowForAuthRequest(
              peerId: peerId,
              deviceName: device?.name ?? '',
              host: device?.host ?? '',
              callback: guarded,
            ));
          }
          _dispatchToPrimary((event) {
            event.onAuth(device, asServer, message.message ?? "", guarded.call);
          });
          break;
```

注意:`respond` 内容与原闭包逐字一致,只是提出来复用;新增 import `package:whisper/socket/guarded_auth_callback.dart` 与 `package:whisper/helper/connection_request_notifications.dart`。

再修改 `_releaseIncomingAuthForSink`(456-464 行),对端断开时撤销通知:

```dart
  void _releaseIncomingAuthForSink(WebSocketSink? sink) {
    if (sink == null) {
      return;
    }
    final peerId = _incomingAuthPeerIdsBySink.remove(sink);
    if (peerId != null && peerId.isNotEmpty) {
      _authRequestGate.releaseIncoming(peerId);
      unawaited(ConnectionRequestNotifier().dismissForPeer(peerId));
    }
  }
```

(以文件实际代码为准,保持既有语义,只追加 `dismissForPeer`。)

- [ ] **Step 7: manifest 补 receiver**

在 `android/app/src/main/AndroidManifest.xml` 第 82 行(两个 flutterlocalnotifications receiver 旁)追加:

```xml
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver" />
```

- [ ] **Step 8: ARB 三语加键**

`lib/l10n/app_zh.arb`:

```json
  "connectRequestNotificationBody": "{name}({host})请求连接",
  "@connectRequestNotificationBody": {
    "placeholders": {"name": {"type": "String"}, "host": {"type": "String"}}
  },
  "connectRequestExpired": "连接请求已过期",
```

`app_en.arb`:`"connectRequestNotificationBody": "{name} ({host}) wants to connect"`、`"connectRequestExpired": "Connection request expired"`(带同样的 @ 元数据)。
`app_es.arb`:`"connectRequestNotificationBody": "{name} ({host}) quiere conectarse"`、`"connectRequestExpired": "La solicitud de conexión ha expirado"`(带同样的 @ 元数据)。

Run: `flutter gen-l10n`

- [ ] **Step 9: 验证**

Run: `flutter test test/connection_request_notification_source_test.dart && flutter test test/guarded_auth_callback_test.dart && flutter analyze`
Expected: 全部 PASS,analyze 无新告警。再跑一次全量 `flutter test` 确认没有破坏既有 source 测试。

- [ ] **Step 10: Commit**

```bash
git add lib/helper/connection_request_notifications.dart lib/helper/notification.dart lib/main.dart lib/socket/svrmanager.dart android/app/src/main/AndroidManifest.xml lib/l10n/ test/connection_request_notification_source_test.dart
git commit -m "feat(socket): 连接请求系统通知,后台一键同意/拒绝"
```

---

### Task 3: 传输进度聚合器(纯 Dart:加权/单调/节流/终态/速度)

**Files:**
- Create: `lib/helper/transfer_notification_aggregator.dart`
- Test: `test/transfer_notification_aggregator_test.dart`

**Interfaces:**
- Consumes: `TransferSnapshot`、`FileTransferState`、`FileTransferDirection`、`isTerminalFileTransferState`(`lib/model/file_transfer.dart`)。
- Produces: `TransferNotificationCommand`(字段 `kind`(`TransferNotificationKind.progress|terminal|cancel`)、`String title`、`String text`、`int progress`(0-100)、`bool success`)与 `TransferNotificationAggregator`(构造 `({int Function()? nowMillis, required TransferNotificationStrings strings})`,方法 `TransferNotificationCommand? onSnapshot(TransferSnapshot snapshot)`)。`TransferNotificationStrings` 是纯文案回调组(见下),让 l10n 留在调用方。Task 5 依赖全部三个类型。

- [ ] **Step 1: 写失败测试**

```dart
// test/transfer_notification_aggregator_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/transfer_notification_aggregator.dart';
import 'package:whisper/model/file_transfer.dart';

TransferSnapshot snap(
  String id, {
  FileTransferDirection direction = FileTransferDirection.outgoing,
  FileTransferState state = FileTransferState.transferring,
  int size = 100,
  int committed = 0,
}) {
  return TransferSnapshot(
    transferId: id,
    messageUuid: 'm-$id',
    peerUid: 'peer',
    direction: direction,
    state: state,
    finalPath: '/tmp/$id',
    tempPath: '/tmp/$id.part',
    size: size,
    committedBytes: committed,
    lastError: '',
    updatedAt: 0,
  );
}

TransferNotificationStrings strings() => TransferNotificationStrings(
      title: (count) => 'title:$count',
      bodySending: (percent, speed, remaining) => 'send:$percent:$speed',
      bodyReceiving: (percent, speed, remaining) => 'recv:$percent:$speed',
      bodyMixed: (percent, speed, remaining) => 'mixed:$percent:$speed',
      completed: (count) => 'done:$count',
      interrupted: () => 'interrupted',
    );

void main() {
  test('aggregates byte-weighted progress across transfers', () {
    var now = 0;
    final agg =
        TransferNotificationAggregator(nowMillis: () => now, strings: strings());
    expect(agg.onSnapshot(snap('a', size: 100, committed: 50))!.progress, 50);
    now += 2000;
    // a:50/100 + b:0/300 => 50/400 = 12%
    final cmd = agg.onSnapshot(snap('b', size: 300, committed: 0))!;
    expect(cmd.kind, TransferNotificationKind.progress);
    expect(cmd.progress, 50); // 单调:不允许从 50 回退到 12
  });

  test('throttles to one update per second but not terminal', () {
    var now = 0;
    final agg =
        TransferNotificationAggregator(nowMillis: () => now, strings: strings());
    expect(agg.onSnapshot(snap('a', committed: 10)), isNotNull);
    now += 300;
    expect(agg.onSnapshot(snap('a', committed: 20)), isNull); // 节流
    now += 800;
    expect(agg.onSnapshot(snap('a', committed: 30)), isNotNull);
    now += 100;
    final done = agg.onSnapshot(
        snap('a', state: FileTransferState.completed, committed: 100));
    expect(done!.kind, TransferNotificationKind.terminal); // 终态立即发
    expect(done.success, isTrue);
  });

  test('all canceled yields cancel command and resets generation', () {
    var now = 0;
    final agg =
        TransferNotificationAggregator(nowMillis: () => now, strings: strings());
    agg.onSnapshot(snap('a', committed: 90));
    final cmd = agg.onSnapshot(snap('a', state: FileTransferState.canceled));
    expect(cmd!.kind, TransferNotificationKind.cancel);
    // 新一代传输从 0 开始,不受上一代 90% 单调值影响
    now += 2000;
    expect(agg.onSnapshot(snap('b', committed: 10))!.progress, 10);
  });

  test('failure yields interrupted terminal', () {
    var now = 0;
    final agg =
        TransferNotificationAggregator(nowMillis: () => now, strings: strings());
    agg.onSnapshot(snap('a', committed: 10));
    final cmd = agg.onSnapshot(snap('a', state: FileTransferState.failed));
    expect(cmd!.kind, TransferNotificationKind.terminal);
    expect(cmd.success, isFalse);
    expect(cmd.text, 'interrupted');
  });

  test('formats speed from byte deltas', () {
    expect(formatBytesForNotification(0), '0 B');
    expect(formatBytesForNotification(1536), '1.5 KB');
    expect(formatBytesForNotification(3 * 1024 * 1024), '3.0 MB');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/transfer_notification_aggregator_test.dart`
Expected: FAIL(文件不存在)。

- [ ] **Step 3: 实现聚合器**

```dart
// lib/helper/transfer_notification_aggregator.dart
import 'package:whisper/model/file_transfer.dart';

enum TransferNotificationKind { progress, terminal, cancel }

class TransferNotificationCommand {
  const TransferNotificationCommand({
    required this.kind,
    this.title = '',
    this.text = '',
    this.progress = 0,
    this.success = false,
  });

  final TransferNotificationKind kind;
  final String title;
  final String text;
  final int progress;
  final bool success;
}

/// 文案由调用方注入(l10n 留在 UI 层)。
class TransferNotificationStrings {
  const TransferNotificationStrings({
    required this.title,
    required this.bodySending,
    required this.bodyReceiving,
    required this.bodyMixed,
    required this.completed,
    required this.interrupted,
  });

  final String Function(int count) title;
  final String Function(int percent, String speed, String remaining)
      bodySending;
  final String Function(int percent, String speed, String remaining)
      bodyReceiving;
  final String Function(int percent, String speed, String remaining) bodyMixed;
  final String Function(int count) completed;
  final String Function() interrupted;
}

String formatBytesForNotification(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = -1;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// 把逐笔 TransferSnapshot 聚合成单条通知的状态流:
/// 字节加权进度、显示值单调不回退、≥1s 节流(终态豁免)。
class TransferNotificationAggregator {
  TransferNotificationAggregator({
    int Function()? nowMillis,
    required this.strings,
  }) : _nowMillis = nowMillis ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;
  static const int _throttleMillis = 1000;

  final TransferNotificationStrings strings;
  final int Function() _nowMillis;
  final Map<String, TransferSnapshot> _active = <String, TransferSnapshot>{};
  final Map<String, TransferSnapshot> _terminal = <String, TransferSnapshot>{};
  int _lastEmitMillis = -_throttleMillis;
  int _displayedPercent = 0;
  int _lastBytes = 0;
  int _lastBytesMillis = 0;

  TransferNotificationCommand? onSnapshot(TransferSnapshot snapshot) {
    if (isTerminalFileTransferState(snapshot.state)) {
      if (!_active.containsKey(snapshot.transferId) &&
          !_terminal.containsKey(snapshot.transferId)) {
        return null; // 不认识的传输,忽略
      }
      _active.remove(snapshot.transferId);
      _terminal[snapshot.transferId] = snapshot;
      if (_active.isNotEmpty) {
        return _progressCommand(force: true);
      }
      return _finishGeneration();
    }

    _active[snapshot.transferId] = snapshot;
    return _progressCommand(force: false);
  }

  TransferNotificationCommand? _progressCommand({required bool force}) {
    final now = _nowMillis();
    if (!force && now - _lastEmitMillis < _throttleMillis) {
      return null;
    }
    _lastEmitMillis = now;

    final all = <TransferSnapshot>[..._active.values, ..._terminal.values];
    final totalBytes =
        all.fold<int>(0, (sum, s) => sum + (s.size > 0 ? s.size : 0));
    final doneBytes = all.fold<int>(
        0, (sum, s) => sum + s.committedBytes.clamp(0, s.size));
    final rawPercent =
        totalBytes <= 0 ? 0 : (doneBytes * 100 ~/ totalBytes).clamp(0, 100);
    if (rawPercent > _displayedPercent) {
      _displayedPercent = rawPercent;
    }

    final speed = _speedText(doneBytes, now);
    final remaining =
        formatBytesForNotification((totalBytes - doneBytes).clamp(0, totalBytes));
    final hasOutgoing =
        _active.values.any((s) => s.direction == FileTransferDirection.outgoing);
    final hasIncoming =
        _active.values.any((s) => s.direction == FileTransferDirection.incoming);
    final String text;
    if (hasOutgoing && hasIncoming) {
      text = strings.bodyMixed(_displayedPercent, speed, remaining);
    } else if (hasIncoming) {
      text = strings.bodyReceiving(_displayedPercent, speed, remaining);
    } else {
      text = strings.bodySending(_displayedPercent, speed, remaining);
    }
    return TransferNotificationCommand(
      kind: TransferNotificationKind.progress,
      title: strings.title(all.length),
      text: text,
      progress: _displayedPercent,
    );
  }

  String _speedText(int doneBytes, int now) {
    if (_lastBytesMillis == 0 || now <= _lastBytesMillis) {
      _lastBytes = doneBytes;
      _lastBytesMillis = now;
      return '${formatBytesForNotification(0)}/s';
    }
    final deltaBytes = (doneBytes - _lastBytes).clamp(0, doneBytes);
    final deltaMillis = now - _lastBytesMillis;
    _lastBytes = doneBytes;
    _lastBytesMillis = now;
    final perSecond = deltaBytes * 1000 ~/ deltaMillis;
    return '${formatBytesForNotification(perSecond)}/s';
  }

  TransferNotificationCommand _finishGeneration() {
    final results = _terminal.values.toList(growable: false);
    _reset();
    final allCanceled =
        results.every((s) => s.state == FileTransferState.canceled);
    if (allCanceled) {
      return const TransferNotificationCommand(
          kind: TransferNotificationKind.cancel);
    }
    final anyFailed = results.any((s) =>
        s.state == FileTransferState.failed ||
        s.state == FileTransferState.canceled);
    if (anyFailed) {
      return TransferNotificationCommand(
        kind: TransferNotificationKind.terminal,
        title: strings.title(results.length),
        text: strings.interrupted(),
        success: false,
      );
    }
    return TransferNotificationCommand(
      kind: TransferNotificationKind.terminal,
      title: strings.title(results.length),
      text: strings.completed(results.length),
      progress: 100,
      success: true,
    );
  }

  void _reset() {
    _active.clear();
    _terminal.clear();
    _displayedPercent = 0;
    _lastBytes = 0;
    _lastBytesMillis = 0;
    _lastEmitMillis = -_throttleMillis;
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/transfer_notification_aggregator_test.dart`
Expected: PASS(5 个用例)。

- [ ] **Step 5: Commit**

```bash
git add lib/helper/transfer_notification_aggregator.dart test/transfer_notification_aggregator_test.dart
git commit -m "feat(android): 传输通知聚合器(加权/单调/节流/终态)"
```

---

### Task 4: 原生传输通知模块(ProgressStyle + promoted ongoing + 降级)

**Files:**
- Create: `android/app/src/main/kotlin/com/vireen/whisper/TransferNotificationPlugin.kt`
- Create: `android/app/src/main/kotlin/com/vireen/whisper/TransferForegroundService.kt`
- Modify: `android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt`(注册插件)
- Modify: `android/app/src/main/AndroidManifest.xml`(service + 权限)
- Modify: `android/app/build.gradle:92-96`(dependencies 加 androidx.core)
- Test: `test/transfer_notification_source_test.dart`

**Interfaces:**
- Consumes: 无 Dart 依赖(Task 5 才接 Dart 侧)。
- Produces: MethodChannel `com.vireen.whisper/transfer_notifications`,方法 `showProgress`(args: `title: String`、`text: String`、`progress: Int 0-100`)、`showTerminal`(args: `title`、`text`、`success: Boolean`)、`cancel`(无参)。通知 id 10022,channel `whisper.transfer`。

- [ ] **Step 1: 写失败的 source test**

```dart
// test/transfer_notification_source_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native transfer notification supports live updates with fallback', () {
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'TransferNotificationPlugin.kt',
    ).readAsStringSync();
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'TransferForegroundService.kt',
    ).readAsStringSync();
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final mainActivity = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt',
    ).readAsStringSync();

    // Android 16+ Live Updates 与降级链
    expect(service, contains('NotificationCompat.ProgressStyle'));
    expect(service, contains('setRequestPromotedOngoing'));
    expect(service, contains('canPostPromotedNotifications'));
    expect(service, contains('Build.VERSION.SDK_INT >= 36'));
    expect(service, contains('.setProgress(100,')); // 15- 降级
    expect(service, contains('setOnlyAlertOnce(true)'));
    expect(service, contains('STOP_FOREGROUND_DETACH'));

    // FGS 从后台启动失败的兜底
    expect(plugin, contains('ForegroundServiceStartNotAllowedException'));
    expect(plugin, contains("com.vireen.whisper/transfer_notifications"));

    expect(manifest, contains('TransferForegroundService'));
    expect(manifest,
        contains('android.permission.POST_PROMOTED_NOTIFICATIONS'));
    expect(gradle, contains('androidx.core:core:1.17.0'));
    expect(mainActivity, contains('TransferNotificationPlugin()'));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/transfer_notification_source_test.dart`
Expected: FAIL(Kotlin 文件不存在)。

- [ ] **Step 3: 实现 TransferForegroundService**

```kotlin
// android/app/src/main/kotlin/com/vireen/whisper/TransferForegroundService.kt
package com.vireen.whisper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * 传输进度前台服务:持有 id=10022 的进度通知。
 * Android 16+ 且系统允许 promoted 通知时走 ProgressStyle + promoted ongoing
 * (状态栏 chip / 锁屏卡片),否则降级为经典 setProgress。
 * 终态时原地把同一条通知更新为可滑走的结果通知,再 detach 停止服务。
 */
class TransferForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.getStringExtra(EXTRA_COMMAND)) {
            COMMAND_PROGRESS -> {
                val notification = buildProgressNotification(
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                    intent.getIntExtra(EXTRA_PROGRESS, 0),
                )
                startForeground(NOTIFICATION_ID, notification)
            }

            COMMAND_TERMINAL -> {
                showTerminal(
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                )
                stopForeground(STOP_FOREGROUND_DETACH)
                stopSelf()
            }

            COMMAND_CANCEL -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                notificationManager().cancel(NOTIFICATION_ID)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun buildProgressNotification(
        title: String,
        text: String,
        progress: Int,
    ): Notification {
        ensureChannel()
        val clamped = progress.coerceIn(0, 100)
        val builder = baseBuilder(title, text)
            .setOngoing(true)
        if (supportsLiveUpdates()) {
            builder.setStyle(
                NotificationCompat.ProgressStyle()
                    .setProgress(clamped)
            )
            builder.setRequestPromotedOngoing(true)
            builder.setShortCriticalText("$clamped%")
        } else {
            builder.setProgress(100, clamped, false)
        }
        return builder.build()
    }

    private fun showTerminal(title: String, text: String) {
        ensureChannel()
        val notification = baseBuilder(title, text)
            .setOngoing(false)
            .setAutoCancel(true)
            .build()
        notificationManager().notify(NOTIFICATION_ID, notification)
    }

    private fun baseBuilder(title: String, text: String): NotificationCompat.Builder {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(buildContentIntent())
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
    }

    private fun supportsLiveUpdates(): Boolean {
        return Build.VERSION.SDK_INT >= 36 &&
            NotificationManagerCompat.from(this).canPostPromotedNotifications()
    }

    private fun buildContentIntent(): PendingIntent {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Whisper Transfer",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "File transfer progress"
            setShowBadge(false)
        }
        notificationManager().createNotificationChannel(channel)
    }

    companion object {
        const val CHANNEL_ID = "whisper.transfer"
        const val NOTIFICATION_ID = 10022
        const val EXTRA_COMMAND = "command"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
        const val COMMAND_PROGRESS = "progress"
        const val COMMAND_TERMINAL = "terminal"
        const val COMMAND_CANCEL = "cancel"

        fun buildIntent(context: Context, command: String): Intent {
            return Intent(context, TransferForegroundService::class.java)
                .putExtra(EXTRA_COMMAND, command)
        }
    }
}
```

注:`NotificationCompat.ProgressStyle` 与 `setRequestPromotedOngoing`、`NotificationManagerCompat.canPostPromotedNotifications` 需要 `androidx.core:core:1.17.0`(Step 5 添加)。若该版本中 API 名有出入,以 androidx.core 1.17 release notes 为准调整调用名,并同步更新 source test 断言——但降级链结构不变。

- [ ] **Step 4: 实现 TransferNotificationPlugin**

```kotlin
// android/app/src/main/kotlin/com/vireen/whisper/TransferNotificationPlugin.kt
package com.vireen.whisper

import android.app.ForegroundServiceStartNotAllowedException
import android.content.Context
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class TransferNotificationPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.vireen.whisper/transfer_notifications")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "showProgress" -> {
                val intent = TransferForegroundService
                    .buildIntent(context, TransferForegroundService.COMMAND_PROGRESS)
                    .putExtra(TransferForegroundService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_TEXT, call.argument<String>("text") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_PROGRESS, call.argument<Int>("progress") ?: 0)
                startServiceSafely(intent)
                result.success(null)
            }

            "showTerminal" -> {
                val intent = TransferForegroundService
                    .buildIntent(context, TransferForegroundService.COMMAND_TERMINAL)
                    .putExtra(TransferForegroundService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_TEXT, call.argument<String>("text") ?: "")
                startServiceSafely(intent)
                result.success(null)
            }

            "cancel" -> {
                startServiceSafely(
                    TransferForegroundService.buildIntent(context, TransferForegroundService.COMMAND_CANCEL)
                )
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * app 在后台且无豁免时 startForegroundService 会抛
     * ForegroundServiceStartNotAllowedException(Android 12+)。
     * 此时进程必然还活着(保活服务在跑),丢一条日志静默降级即可,
     * 下一次进度更新(app 回前台后)会自动恢复。
     */
    private fun startServiceSafely(intent: android.content.Intent) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (error: Exception) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                error is ForegroundServiceStartNotAllowedException
            ) {
                Log.w("WhisperTransferNotify", "FGS start not allowed, skip update", error)
            } else {
                throw error
            }
        }
    }
}
```

- [ ] **Step 5: 注册与配置**

`MainActivity.kt` 的 `configureFlutterEngine` 中追加一行:

```kotlin
        flutterEngine.plugins.add(TransferNotificationPlugin())
```

`AndroidManifest.xml`:权限区(第 31 行后)追加:

```xml
    <uses-permission android:name="android.permission.POST_PROMOTED_NOTIFICATIONS" />
```

`<application>` 内(KeepAliveForegroundService 声明旁)追加:

```xml
        <service
            android:name=".TransferForegroundService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="dataSync" />
```

`android/app/build.gradle` dependencies 块(92-96 行)追加:

```groovy
    implementation 'androidx.core:core:1.17.0'
```

- [ ] **Step 6: 验证**

Run: `flutter test test/transfer_notification_source_test.dart && flutter build apk --debug`
Expected: source test PASS;debug apk 编译通过(验证 Kotlin 与 androidx.core API 真实存在——这一步必须跑,ProgressStyle API 名以编译结果为准)。

- [ ] **Step 7: Commit**

```bash
git add android/app/src/main/kotlin/com/vireen/whisper/TransferNotificationPlugin.kt android/app/src/main/kotlin/com/vireen/whisper/TransferForegroundService.kt android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt android/app/src/main/AndroidManifest.xml android/app/build.gradle test/transfer_notification_source_test.dart
git commit -m "feat(android): 传输进度原生通知,Android 16 Live Updates 与经典降级"
```

---

### Task 5: TransferNotificationBridge(Dart 桥 + 注册)

**Files:**
- Create: `lib/helper/transfer_notifications.dart`
- Modify: `lib/main.dart`(注册 bridge 为 socket 监听者)
- Modify: `lib/l10n/app_zh.arb`、`app_en.arb`、`app_es.arb`
- Test: `test/transfer_notification_bridge_source_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `TransferNotificationAggregator`/`TransferNotificationCommand`/`TransferNotificationStrings`;Task 4 的 channel `com.vireen.whisper/transfer_notifications`;`ISocketEvent`(`lib/socket/svrmanager.dart:46`,9 个方法全实现,除 `onTransferUpdated` 外皆空实现);`lookupAppLocalizations`。
- Produces: `TransferNotificationBridge`(单例,`void attach()` 内部调 `WsSvrManager().registerEvent(this)`,仅 Android 生效)。

- [ ] **Step 1: 写失败的 source test**

```dart
// test/transfer_notification_bridge_source_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transfer notification bridge listens to socket events on android', () {
    final bridge =
        File('lib/helper/transfer_notifications.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(bridge, contains('implements ISocketEvent'));
    expect(bridge, contains('TransferNotificationAggregator'));
    expect(bridge, contains("'com.vireen.whisper/transfer_notifications'"));
    expect(bridge, contains('onTransferUpdated'));
    expect(bridge, contains('Platform.isAndroid'));
    expect(bridge, contains('lookupAppLocalizations'));
    expect(main, contains('TransferNotificationBridge().attach()'));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/transfer_notification_bridge_source_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现 bridge**

```dart
// lib/helper/transfer_notifications.dart
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:whisper/helper/transfer_notification_aggregator.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/device.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/svrmanager.dart';

/// 订阅 socket 传输事件,把聚合结果推给原生传输通知模块。
/// 仅 Android;进程级单例,应用启动时 attach 一次。
class TransferNotificationBridge implements ISocketEvent {
  static final TransferNotificationBridge _instance =
      TransferNotificationBridge._internal();

  factory TransferNotificationBridge() => _instance;

  TransferNotificationBridge._internal();

  static const MethodChannel _channel =
      MethodChannel('com.vireen.whisper/transfer_notifications');

  TransferNotificationAggregator? _aggregator;

  AppLocalizations get _l10n =>
      lookupAppLocalizations(PlatformDispatcher.instance.locale);

  void attach() {
    if (!Platform.isAndroid) {
      return;
    }
    WsSvrManager().registerEvent(this);
  }

  TransferNotificationAggregator _ensureAggregator() {
    final l10n = _l10n;
    return _aggregator ??= TransferNotificationAggregator(
      strings: TransferNotificationStrings(
        title: (count) => l10n.transferNotificationTitle(count),
        bodySending: (percent, speed, remaining) =>
            l10n.transferNotificationBodySending(percent, speed, remaining),
        bodyReceiving: (percent, speed, remaining) =>
            l10n.transferNotificationBodyReceiving(percent, speed, remaining),
        bodyMixed: (percent, speed, remaining) =>
            l10n.transferNotificationBodyMixed(percent, speed, remaining),
        completed: (count) => l10n.transferNotificationCompleted(count),
        interrupted: () => l10n.transferNotificationInterrupted,
      ),
    );
  }

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    final command = _ensureAggregator().onSnapshot(snapshot);
    if (command == null) {
      return;
    }
    switch (command.kind) {
      case TransferNotificationKind.progress:
        _channel.invokeMethod<void>('showProgress', <String, Object?>{
          'title': command.title,
          'text': command.text,
          'progress': command.progress,
        });
        break;
      case TransferNotificationKind.terminal:
        _channel.invokeMethod<void>('showTerminal', <String, Object?>{
          'title': command.title,
          'text': command.text,
          'success': command.success,
        });
        _aggregator = null;
        break;
      case TransferNotificationKind.cancel:
        _channel.invokeMethod<void>('cancel');
        _aggregator = null;
        break;
    }
  }

  @override
  void onError(String message) {}

  @override
  void onNotice(String message) {}

  @override
  void onMessage(MessageData messageData) {}

  @override
  void onProgress(int size, length) {}

  @override
  void onClose() {}

  @override
  void onConnect() {}

  @override
  void onAuth(DeviceData? deviceData, bool asServer, String msg, var callback) {}

  @override
  void afterAuth(bool allow, DeviceData? device) {}
}
```

注:import 路径(`model/device.dart`、`model/message.dart` 中 `DeviceData`/`MessageData` 的实际来源)以 `lib/page/deviceList.dart` 现有 import 为准照抄;若 `DeviceData` 来自 `LocalDatabase.dart`,改用相同 import。

- [ ] **Step 4: main.dart 注册 + ARB 键**

`lib/main.dart`(`ConnectionRequestNotifier().initialize(...)` 之后)追加:

```dart
  TransferNotificationBridge().attach();
```

`app_zh.arb` 追加(en/es 同结构,译文如下):

```json
  "transferNotificationTitle": "正在传输 {count} 个文件",
  "@transferNotificationTitle": {"placeholders": {"count": {"type": "int"}}},
  "transferNotificationBodySending": "发送中 {percent}% · {speed} · 剩余 {remaining}",
  "@transferNotificationBodySending": {"placeholders": {"percent": {"type": "int"}, "speed": {"type": "String"}, "remaining": {"type": "String"}}},
  "transferNotificationBodyReceiving": "接收中 {percent}% · {speed} · 剩余 {remaining}",
  "@transferNotificationBodyReceiving": {"placeholders": {"percent": {"type": "int"}, "speed": {"type": "String"}, "remaining": {"type": "String"}}},
  "transferNotificationBodyMixed": "收发中 {percent}% · {speed} · 剩余 {remaining}",
  "@transferNotificationBodyMixed": {"placeholders": {"percent": {"type": "int"}, "speed": {"type": "String"}, "remaining": {"type": "String"}}},
  "transferNotificationCompleted": "传输完成 · {count} 个文件",
  "@transferNotificationCompleted": {"placeholders": {"count": {"type": "int"}}},
  "transferNotificationInterrupted": "传输已中断,回到应用可恢复",
```

en:`"Transferring {count} files"`、`"Sending {percent}% · {speed} · {remaining} left"`、`"Receiving {percent}% · {speed} · {remaining} left"`、`"Syncing {percent}% · {speed} · {remaining} left"`、`"Transfer complete · {count} files"`、`"Transfer interrupted, reopen the app to resume"`。
es:`"Transfiriendo {count} archivos"`、`"Enviando {percent}% · {speed} · quedan {remaining}"`、`"Recibiendo {percent}% · {speed} · quedan {remaining}"`、`"Sincronizando {percent}% · {speed} · quedan {remaining}"`、`"Transferencia completada · {count} archivos"`、`"Transferencia interrumpida, vuelve a la app para reanudar"`。

Run: `flutter gen-l10n`

- [ ] **Step 5: 验证**

Run: `flutter test test/transfer_notification_bridge_source_test.dart && flutter analyze && flutter test`
Expected: 全部 PASS。

- [ ] **Step 6: Commit**

```bash
git add lib/helper/transfer_notifications.dart lib/main.dart lib/l10n/ test/transfer_notification_bridge_source_test.dart
git commit -m "feat(android): 传输进度独立通知接入 socket 事件流"
```

---

### Task 6: 保活通知降级(移除传输/音频状态,状态单一来源)

**Files:**
- Modify: `lib/page/conversation.dart:144-196`(`_buildAndroidKeepAliveNotification`)
- Modify: `lib/l10n/app_zh.arb`、`app_en.arb`、`app_es.arb`(删 5 个键)
- Modify: `test/android_keep_alive_conversation_source_test.dart`
- Test: 上述既有测试改写后即为验收

**Interfaces:**
- Consumes: Task 5 已上线的独立传输通知(本任务删的是重复呈现)。
- Produces: 无新接口;`AndroidKeepAliveNotification` 的 `progress`/`indeterminateProgress` 字段与 Kotlin 层 `setProgress` 能力保留(公共 API 不动,只是不再从会话页喂状态)——这是对 spec"进度参数路径删除"的最小实现解释:删除的是调用路径,不是底层能力。

- [ ] **Step 1: 改写既有 source test(先红)**

`test/android_keep_alive_conversation_source_test.dart` 中,把断言 `androidBackgroundKeepAliveTransferSending`/`Receiving`/`AudioSharing`/`AudioPlaying` 存在的 4 行(现 12-15 行)替换为反向断言:

```dart
    expect(source, isNot(contains('androidBackgroundKeepAliveTransferSending')));
    expect(source, isNot(contains('androidBackgroundKeepAliveTransferReceiving')));
    expect(source, isNot(contains('androidBackgroundKeepAliveAudioSharing')));
    expect(source, isNot(contains('androidBackgroundKeepAliveAudioPlaying')));
    expect(source, contains('androidBackgroundKeepAliveActiveDesc'));
```

保留该文件其余断言(`_buildAndroidKeepAliveNotification()` 存在、`unawaited(_syncAndroidKeepAliveService())` 等)。

Run: `flutter test test/android_keep_alive_conversation_source_test.dart`
Expected: FAIL(conversation.dart 还引用这些键)。

- [ ] **Step 2: 降级实现**

`lib/page/conversation.dart` 的 `_buildAndroidKeepAliveNotification()`(144-196 行)整体替换为:

```dart
  AndroidKeepAliveNotification _buildAndroidKeepAliveNotification() {
    return AndroidKeepAliveNotification(
      title: l10n.androidBackgroundKeepAliveActiveTitle,
      description: l10n.androidBackgroundKeepAliveActiveDesc,
    );
  }
```

删除函数体内不再使用的局部依赖(如该函数曾是 `percent`、`_transferSnapshots`、`_activeTransferId`、audio 状态的唯一消费点,则一并清理编译器报出的 unused 警告;`_syncAndroidKeepAliveService` 的调用点全部保留)。

- [ ] **Step 3: ARB 删键**

从三份 ARB 中删除 `androidBackgroundKeepAliveTransferSending`、`androidBackgroundKeepAliveTransferReceiving`、`androidBackgroundKeepAliveAudioSharing`、`androidBackgroundKeepAliveAudioPlaying`、`androidBackgroundKeepAliveAudioPreparing` 及各自的 `@` 元数据。

Run: `flutter gen-l10n`

- [ ] **Step 4: 验证**

Run: `flutter analyze && flutter test`
Expected: analyze 无 unused 告警,全量测试 PASS(含改写后的 keep-alive 测试与未动的 `android_foreground_service_source_test.dart`)。

- [ ] **Step 5: Commit**

```bash
git add lib/page/conversation.dart lib/l10n/ test/android_keep_alive_conversation_source_test.dart
git commit -m "refactor(android): 保活通知回归纯保活,状态单一来源"
```

---

### Task 7: 音频协议扩展(sinkJoinRequest 动作 + audioGroupRejoinV1 能力)

**Files:**
- Modify: `lib/audio/audio_protocol.dart:36-46`(enum)
- Modify: `lib/state/peer_profile.dart:99-160`(PeerCapabilities)
- Modify: `lib/socket/svrmanager.dart:1558-1570`(本机能力声明)
- Test: `test/audio_protocol_test.dart`(追加)、`test/peer_profile_test.dart`(追加,若无此文件则新建)

**Interfaces:**
- Consumes: 现有 `AudioGroupControlAction`、`PeerCapabilities`(toJson/fromJson 模式照抄 `remoteInputSourceV1`)。
- Produces: `AudioGroupControlAction.sinkJoinRequest`;`PeerCapabilities.audioGroupRejoinV1: bool`(默认 false,toJson/fromJson 齐全);本机 profile 声明 `audioGroupRejoinV1: true`。Task 8/10 依赖。

- [ ] **Step 1: 写失败测试**

在 `test/audio_protocol_test.dart` 追加:

```dart
  test('sinkJoinRequest action roundtrips and unknown falls back to error', () {
    final msg = AudioGroupControlMessage(
      action: AudioGroupControlAction.sinkJoinRequest,
      groupId: 'g',
      streamId: 's',
      sessionId: 'sess',
      sourcePeerId: 'src',
      sinkPeerId: 'sink',
    );
    final decoded = AudioGroupControlMessage.fromJson(msg.toJson());
    expect(decoded.action, AudioGroupControlAction.sinkJoinRequest);

    final unknown = AudioGroupControlMessage.fromJson(<String, dynamic>{
      ...msg.toJson(),
      'action': 'someFutureAction',
    });
    expect(unknown.action, AudioGroupControlAction.error); // 现状锚定
  });
```

在 `test/peer_profile_test.dart` 追加(文件已存在则并入,不存在则新建包含标准 main 包裹):

```dart
  test('audioGroupRejoinV1 capability roundtrips and defaults to false', () {
    const caps = PeerCapabilities(audioGroupRejoinV1: true);
    final decoded = PeerCapabilities.fromJson(caps.toJson());
    expect(decoded.audioGroupRejoinV1, isTrue);
    expect(const PeerCapabilities().audioGroupRejoinV1, isFalse);
    expect(
      PeerCapabilities.fromJson(<String, dynamic>{}).audioGroupRejoinV1,
      isFalse,
    );
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/audio_protocol_test.dart test/peer_profile_test.dart`
Expected: FAIL(enum 值与字段不存在)。

- [ ] **Step 3: 实现**

`audio_protocol.dart` enum 追加(放在 `error` 之前,保持 `error` 为 fromJson fallback 不受影响——fallback 是显式传参的,与顺序无关,但排序上新动作放 `latencyReport` 之后更清晰):

```dart
enum AudioGroupControlAction {
  groupOffer,
  groupAccept,
  groupReject,
  groupUpdate,
  groupStop,
  clockProbe,
  clockReport,
  latencyReport,
  sinkJoinRequest,
  error,
}
```

`peer_profile.dart` 的 `PeerCapabilities`:构造参数、final 字段、`toJson`、`fromJson` 四处照 `audioGroupSinkV1` 的写法各加一行 `audioGroupRejoinV1`(默认 `false`)。

`svrmanager.dart:1558` 的本机能力块追加:

```dart
        audioGroupRejoinV1: true,
```

- [ ] **Step 4: 验证并提交**

Run: `flutter test test/audio_protocol_test.dart test/peer_profile_test.dart && flutter analyze`
Expected: PASS。

```bash
git add lib/audio/audio_protocol.dart lib/state/peer_profile.dart lib/socket/svrmanager.dart test/audio_protocol_test.dart test/peer_profile_test.dart
git commit -m "feat(audio): 协议新增 sinkJoinRequest 动作与 audioGroupRejoinV1 能力"
```

---

### Task 8: 协调器 sink 暂停/重加入(暂停=断流,播放=re-offer)

**Files:**
- Modify: `lib/audio/audio_group_coordinator.dart`(新公开方法 + `handleControlMessage` 两处 case)
- Test: `test/audio_group_coordinator_test.dart`(追加)

**Interfaces:**
- Consumes: Task 7 的 `sinkJoinRequest`;现有 `_stopPlaybackOnly()`(`audio_group_coordinator.dart:910`)、`updateGroup`(:153,其"terminal sink 重新 offer"分支 :192 是 rejoin 的复用点)、`_fanout.detachAndClose`(:184)、`AudioGroupSinkState.stopped`。
- Produces(sink 端):`Future<void> pausePlaybackAsSink()`(发 groupStop 给源 + 本地停播 + 存 rejoin 上下文)、`bool get canRejoinAsSink`、`Future<bool> requestRejoinAsSink()`(发 sinkJoinRequest,无上下文返回 false)、`bool get isPlaybackActive`(`_playbackStreamId.isNotEmpty`)。
- Produces(源端):`handleControlMessage` 处理 `sinkJoinRequest` → 对该 sink 走既有 fresh-offer 路径;处理 sink 发来的 `groupStop` 时补 `_fanout.detachAndClose(message.sinkPeerId)`(真正断流)。

- [ ] **Step 1: 写失败测试**

在 `test/audio_group_coordinator_test.dart` 追加(工厂/fake 的构造方式照该文件既有用例——它已有构造 coordinator、伪造 sendControl 收集消息、走 offer/accept 流程的辅助代码,复用之;以下伪代码级骨架按现有辅助函数名对齐后落地):

```dart
  test('pausePlaybackAsSink sends groupStop and keeps rejoin context', () async {
    // 1. 用现有辅助把 coordinator 驱动到 sink 正在播放的状态
    //    (源端 startGroup -> sink handleControlMessage(groupOffer) -> accept)。
    // 2. 调 pausePlaybackAsSink()。
    // 断言:sendControl 收到一条 action == groupStop、sinkPeerId == 本机;
    //       isPlaybackActive == false;canRejoinAsSink == true。
  });

  test('requestRejoinAsSink sends sinkJoinRequest with saved context', () async {
    // 接上题状态,调 requestRejoinAsSink()。
    // 断言:返回 true;sendControl 收到 action == sinkJoinRequest,
    //       groupId/streamId/sourcePeerId 与暂停前一致。
    // 未暂停时直接调,返回 false 且不发消息。
  });

  test('source re-offers a sink on sinkJoinRequest', () async {
    // 源端 startGroup 后,把该 sink 标记 stopped(模拟 sink 发来的 groupStop),
    // 再喂一条 sinkJoinRequest 给 handleControlMessage。
    // 断言:sendControl 向该 sink 发出新的 groupOffer(新 sessionId);
    //       session.sinks[sink].state == offered。
  });

  test('source detaches fanout when sink reports groupStop', () async {
    // 源端 startGroup + sink accepted 后,喂 sink 发来的 groupStop。
    // 断言:fanout 对该 sinkPeerId 已 detach(用测试文件里现有的 fake fanout 或
    //       通过 coordinator 暴露的会话状态判断 state == stopped 且不再计入活跃 fanout)。
  });
```

落地时必须转成可执行断言(该测试文件已有 sendControl 消息收集列表与会话状态断言的先例);若 fake fanout 不存在,给 coordinator 构造注入的 transportFactory 记录 detach 调用。

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/audio_group_coordinator_test.dart`
Expected: 新用例 FAIL(方法不存在)。

- [ ] **Step 3: 实现 sink 端**

`audio_group_coordinator.dart` 新增私有上下文与公开 API(字段区,`_playbackStreamId` 附近):

```dart
  _SinkRejoinContext? _sinkRejoinContext;

  bool get isPlaybackActive => _playbackStreamId.isNotEmpty;
  bool get canRejoinAsSink => _sinkRejoinContext != null;
```

文件底部新增上下文类:

```dart
class _SinkRejoinContext {
  const _SinkRejoinContext({
    required this.groupId,
    required this.streamId,
    required this.sessionId,
    required this.sourcePeerId,
    required this.localPeerId,
    required this.channelRole,
    required this.targetLatencyMs,
    required this.sendControl,
  });

  final String groupId;
  final String streamId;
  final String sessionId;
  final String sourcePeerId;
  final String localPeerId;
  final AudioChannelRole channelRole;
  final int targetLatencyMs;
  final AudioGroupControlSender sendControl;
}
```

公开方法(放在 `stopLocal` 附近;上下文字段取值来源 = sink 侧现有播放状态变量,`_handleOffer` 里存了什么就取什么——`_playbackGroupId`/`_playbackStreamId`/`_playbackLocalPeerId`/`_playbackSendControl` 已存在,channelRole 与 sessionId 若未保存则在 `_handleOffer` 中一并存为 `_playbackSessionId`/`_playbackChannelRole`):

```dart
  /// 暂停=断流:通知源端本 sink 停止(源端会停止对本 sink 的 fanout),
  /// 本地停止播放,但保留重加入所需的上下文。
  Future<void> pausePlaybackAsSink() async {
    final sendControl = _playbackSendControl;
    final streamId = _playbackStreamId;
    if (sendControl == null || streamId.isEmpty) {
      return;
    }
    _sinkRejoinContext = _SinkRejoinContext(
      groupId: _playbackGroupId,
      streamId: streamId,
      sessionId: _playbackSessionId,
      sourcePeerId: _playbackSourcePeerId,
      localPeerId: _playbackLocalPeerId,
      channelRole: _playbackChannelRole,
      targetLatencyMs: _playbackTargetLatencyMs,
      sendControl: sendControl,
    );
    sendControl(
      _playbackSourcePeerId,
      AudioGroupControlMessage(
        action: AudioGroupControlAction.groupStop,
        groupId: _playbackGroupId,
        streamId: streamId,
        sessionId: _playbackSessionId,
        sourcePeerId: _playbackSourcePeerId,
        sinkPeerId: _playbackLocalPeerId,
        channelRole: _playbackChannelRole,
        targetLatencyMs: _playbackTargetLatencyMs,
      ),
    );
    await _stopPlaybackOnly();
    notifyListeners();
  }

  /// 播放=重新加入:向源端请求 re-offer,后续走既有 offer/accept 流程。
  Future<bool> requestRejoinAsSink() async {
    final context = _sinkRejoinContext;
    if (context == null) {
      return false;
    }
    context.sendControl(
      context.sourcePeerId,
      AudioGroupControlMessage(
        action: AudioGroupControlAction.sinkJoinRequest,
        groupId: context.groupId,
        streamId: context.streamId,
        sessionId: context.sessionId,
        sourcePeerId: context.sourcePeerId,
        sinkPeerId: context.localPeerId,
        channelRole: context.channelRole,
        targetLatencyMs: context.targetLatencyMs,
      ),
    );
    return true;
  }
```

上下文来源字段(`_playbackSourcePeerId`/`_playbackSessionId`/`_playbackChannelRole`/`_playbackTargetLatencyMs`)如现文件没有,则在 `_startPlayback`/`_handleOffer`(:397/:879)把 offer 消息里的对应值存下来,并在 `stopLocal`/`_stopPlaybackOnly` 里保持既有清理节奏(`_sinkRejoinContext` 只在 `stopLocal`(彻底断开)与成功 rejoin 后清空,`_stopPlaybackOnly` 不清)。收到新的 `groupOffer` 成功开播后清空 `_sinkRejoinContext` 并 `notifyListeners()`。

- [ ] **Step 4: 实现源端**

`handleControlMessage` 的 switch(:277 附近)改两处:

```dart
      case AudioGroupControlAction.groupStop:
        if (current.sourcePeerId != localPeerId) {
          await stopLocal();
        } else {
          await _fanout.detachAndClose(message.sinkPeerId); // 真正断流
          _setSession(current.markSink(
            message.sinkPeerId,
            state: AudioGroupSinkState.stopped,
            sessionId: message.sessionId,
          ));
        }
        break;
      case AudioGroupControlAction.sinkJoinRequest:
        if (current.sourcePeerId == localPeerId &&
            current.sinks.containsKey(message.sinkPeerId)) {
          final sinks = <String, AudioChannelRole>{
            for (final sink in current.sinks.values)
              sink.sinkPeerId: sink.channelRole,
          };
          await updateGroup(sinks: sinks, sendControl: sendControl);
        }
        break;
```

(`updateGroup` 对 state 为 terminal 的 sink 自动走 fresh-offer 分支——确认 `AudioGroupSinkState.stopped` 的 `isTerminal` 为 true;若不是,把该 sink 先 `markSink(state: failed)` 改为直接在此内联 fresh-offer 逻辑,与 `updateGroup:192-217` 相同的消息构造。以 `audio_group_session.dart` 中 `isTerminal` 定义为准。)

- [ ] **Step 5: 验证并提交**

Run: `flutter test test/audio_group_coordinator_test.dart && flutter analyze && flutter test`
Expected: 全部 PASS(既有协调器用例不许破)。

```bash
git add lib/audio/audio_group_coordinator.dart test/audio_group_coordinator_test.dart
git commit -m "feat(audio): sink 暂停断流与 sinkJoinRequest 重加入"
```

---

### Task 9: 原生媒体外壳(MediaSession + 焦点 + mediaPlayback 前台服务)

**Files:**
- Create: `android/app/src/main/kotlin/com/vireen/whisper/MediaPlaybackService.kt`
- Modify: `android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt`(startPlayback/stopPlayback 挂接 + 焦点 + `updateMediaState`/`mediaControl`;**现有播放方法体不动**)
- Modify: `android/app/src/main/AndroidManifest.xml`(service + 权限)
- Modify: `android/app/build.gradle`(androidx.media)
- Test: `test/android_media_session_source_test.dart`

**Interfaces:**
- Consumes: 现有 channel `com.vireen.whisper/audio_share` 与 `AudioSharePlugin` 生命周期。
- Produces:
  - channel 新方法(Dart→原生)`updateMediaState`:args `state: String`(`playing|paused|buffering|stopped`)、`title: String`、`subtitle: String`、`canResume: Boolean`、`pauseLabel/playLabel/disconnectLabel: String`。`state == stopped` 时拆除通知与服务。
  - channel 回调(原生→Dart)`mediaControl`:args `action: String`(`pause|resume|disconnect|focusPause|focusPauseTransient|focusResume`)。
  - `MediaPlaybackService`(FGS type `mediaPlayback`,通知 id 10023,channel `whisper.media_playback`,MediaStyle,无进度条/时长)。

- [ ] **Step 1: 写失败的 source test**

```dart
// test/android_media_session_source_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio playback exposes a media session shell on android', () {
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MediaPlaybackService.kt',
    ).readAsStringSync();
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt',
    ).readAsStringSync();
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final gradle = File('android/app/build.gradle').readAsStringSync();

    expect(service, contains('MediaSessionCompat'));
    expect(service, contains('MediaStyle'));
    expect(service, contains('PlaybackStateCompat.STATE_BUFFERING'));
    expect(service, isNot(contains('setDuration'))); // 直播流不设时长

    expect(plugin, contains('AudioFocusRequest'));
    expect(plugin, contains('AUDIOFOCUS_LOSS_TRANSIENT'));
    expect(plugin, contains('"mediaControl"'));
    expect(plugin, contains('"updateMediaState"'));
    // 播放引擎零改动锚定:关键播放逻辑仍在
    expect(plugin, contains('PLAYBACK_CATCH_UP_SPEED'));
    expect(plugin, contains('WRITE_NON_BLOCKING'));

    expect(manifest, contains('android:foregroundServiceType="mediaPlayback"'));
    expect(manifest,
        contains('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK'));
    expect(gradle, contains('androidx.media:media:1.7.0'));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/android_media_session_source_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现 MediaPlaybackService**

```kotlin
// android/app/src/main/kotlin/com/vireen/whisper/MediaPlaybackService.kt
package com.vireen.whisper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat

/**
 * 播放端媒体外壳:MediaSession + MediaStyle 通知 + mediaPlayback 前台服务。
 * 只呈现状态、转发控制意图(经 AudioSharePlugin 回 Dart);不触碰播放数据通路。
 * 直播流:不设时长、不显示 seek 条;重连握手期用 STATE_BUFFERING。
 */
class MediaPlaybackService : Service() {
    private var mediaSession: MediaSessionCompat? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        mediaSession = MediaSessionCompat(this, "WhisperMediaSession").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() {
                    AudioSharePlugin.dispatchMediaControl("resume")
                }

                override fun onPause() {
                    AudioSharePlugin.dispatchMediaControl("pause")
                }

                override fun onStop() {
                    AudioSharePlugin.dispatchMediaControl("disconnect")
                }
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val state = intent?.getStringExtra(EXTRA_STATE) ?: STATE_STOPPED
        if (state == STATE_STOPPED) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Whisper"
        val subtitle = intent?.getStringExtra(EXTRA_SUBTITLE) ?: ""
        val canResume = intent?.getBooleanExtra(EXTRA_CAN_RESUME, true) ?: true
        val pauseLabel = intent?.getStringExtra(EXTRA_PAUSE_LABEL) ?: "Pause"
        val playLabel = intent?.getStringExtra(EXTRA_PLAY_LABEL) ?: "Play"
        val disconnectLabel =
            intent?.getStringExtra(EXTRA_DISCONNECT_LABEL) ?: "Disconnect"
        updatePlaybackState(state)
        startForeground(
            NOTIFICATION_ID,
            buildNotification(state, title, subtitle, canResume, pauseLabel, playLabel, disconnectLabel),
        )
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }

    private fun updatePlaybackState(state: String) {
        val playbackState = when (state) {
            STATE_PLAYING -> PlaybackStateCompat.STATE_PLAYING
            STATE_BUFFERING -> PlaybackStateCompat.STATE_BUFFERING
            else -> PlaybackStateCompat.STATE_PAUSED
        }
        val actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_STOP
        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(playbackState, PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN, 1.0f)
                .build(),
        )
    }

    private fun buildNotification(
        state: String,
        title: String,
        subtitle: String,
        canResume: Boolean,
        pauseLabel: String,
        playLabel: String,
        disconnectLabel: String,
    ): Notification {
        ensureChannel()
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(buildContentIntent())
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setOngoing(state == STATE_PLAYING || state == STATE_BUFFERING)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)

        if (state == STATE_PLAYING || state == STATE_BUFFERING) {
            builder.addAction(
                android.R.drawable.ic_media_pause, pauseLabel,
                controlIntent("pause", 1),
            )
        } else if (canResume) {
            builder.addAction(
                android.R.drawable.ic_media_play, playLabel,
                controlIntent("resume", 2),
            )
        }
        builder.addAction(
            android.R.drawable.ic_menu_close_clear_cancel, disconnectLabel,
            controlIntent("disconnect", 3),
        )
        builder.setStyle(
            androidx.media.app.NotificationCompat.MediaStyle()
                .setMediaSession(mediaSession?.sessionToken)
                .setShowActionsInCompactView(0, if (state == STATE_PLAYING) 1 else 0),
        )
        return builder.build()
    }

    private fun controlIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, MediaControlReceiver::class.java)
            .putExtra(EXTRA_CONTROL_ACTION, action)
        return PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildContentIntent(): PendingIntent {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Whisper Media", NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) },
        )
    }

    companion object {
        const val CHANNEL_ID = "whisper.media_playback"
        const val NOTIFICATION_ID = 10023
        const val EXTRA_STATE = "state"
        const val EXTRA_TITLE = "title"
        const val EXTRA_SUBTITLE = "subtitle"
        const val EXTRA_CAN_RESUME = "canResume"
        const val EXTRA_PAUSE_LABEL = "pauseLabel"
        const val EXTRA_PLAY_LABEL = "playLabel"
        const val EXTRA_DISCONNECT_LABEL = "disconnectLabel"
        const val EXTRA_CONTROL_ACTION = "controlAction"
        const val STATE_PLAYING = "playing"
        const val STATE_PAUSED = "paused"
        const val STATE_BUFFERING = "buffering"
        const val STATE_STOPPED = "stopped"
    }
}

/** 通知 action 按钮 → 转发给 AudioSharePlugin(主线程)→ Dart。 */
class MediaControlReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra(MediaPlaybackService.EXTRA_CONTROL_ACTION) ?: return
        AudioSharePlugin.dispatchMediaControl(action)
    }
}
```

- [ ] **Step 4: AudioSharePlugin 挂接(只加不改)**

`AudioSharePlugin.kt` 修改点(现有方法体一行不动):

1. companion object 追加静态分发(插件实例在 attach 时登记):

```kotlin
        private var activeInstance: AudioSharePlugin? = null

        fun dispatchMediaControl(action: String) {
            val instance = activeInstance ?: return
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                instance.channel.invokeMethod("mediaControl", mapOf("action" to action))
            }
        }
```

`onAttachedToEngine` 末尾加 `activeInstance = this`,`onDetachedFromEngine` 加 `activeInstance = null`,并把 `channel` 可见性从 `private lateinit var` 调整为 `internal lateinit var`(或加 internal getter)。

2. 新增字段与焦点管理(类内新增,不碰既有方法):

```kotlin
    private var focusRequest: android.media.AudioFocusRequest? = null
    private var pausedByTransientLoss = false
    private lateinit var appContext: Context // onAttachedToEngine 里赋 binding.applicationContext

    private val focusListener = android.media.AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            android.media.AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                pausedByTransientLoss = true
                dispatchMediaControl("focusPauseTransient")
            }
            android.media.AudioManager.AUDIOFOCUS_LOSS -> {
                pausedByTransientLoss = false
                dispatchMediaControl("focusPause")
            }
            android.media.AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                audioTrack?.setVolume(0.2f)
            android.media.AudioManager.AUDIOFOCUS_GAIN -> {
                audioTrack?.setVolume(1.0f)
                if (pausedByTransientLoss) {
                    pausedByTransientLoss = false
                    dispatchMediaControl("focusResume")
                }
            }
        }
    }

    private fun requestFocus() {
        val manager = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = android.media.AudioFocusRequest.Builder(android.media.AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = request
            manager.requestAudioFocus(request) // 失败也照常播放,与现状一致
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(
                focusListener,
                android.media.AudioManager.STREAM_MUSIC,
                android.media.AudioManager.AUDIOFOCUS_GAIN,
            )
        }
    }

    private fun abandonFocus() {
        val manager = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val request = focusRequest
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && request != null) {
            manager.abandonAudioFocusRequest(request)
        } else {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(focusListener)
        }
        focusRequest = null
        pausedByTransientLoss = false
    }
```

3. `onMethodCall` 新 case(与既有 case 并列):

```kotlin
            "updateMediaState" -> {
                val state = call.argument<String>("state") ?: MediaPlaybackService.STATE_STOPPED
                if (state == MediaPlaybackService.STATE_PLAYING) {
                    requestFocus()
                } else if (state == MediaPlaybackService.STATE_STOPPED) {
                    abandonFocus()
                }
                val intent = android.content.Intent(appContext, MediaPlaybackService::class.java)
                    .putExtra(MediaPlaybackService.EXTRA_STATE, state)
                    .putExtra(MediaPlaybackService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                    .putExtra(MediaPlaybackService.EXTRA_SUBTITLE, call.argument<String>("subtitle") ?: "")
                    .putExtra(MediaPlaybackService.EXTRA_CAN_RESUME, call.argument<Boolean>("canResume") ?: true)
                    .putExtra(MediaPlaybackService.EXTRA_PAUSE_LABEL, call.argument<String>("pauseLabel") ?: "")
                    .putExtra(MediaPlaybackService.EXTRA_PLAY_LABEL, call.argument<String>("playLabel") ?: "")
                    .putExtra(MediaPlaybackService.EXTRA_DISCONNECT_LABEL, call.argument<String>("disconnectLabel") ?: "")
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        appContext.startForegroundService(intent)
                    } else {
                        appContext.startService(intent)
                    }
                } catch (error: Exception) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                        error is android.app.ForegroundServiceStartNotAllowedException
                    ) {
                        Log.w(TAG, "media FGS start not allowed", error)
                    } else {
                        throw error
                    }
                }
                result.success(null)
            }
```

- [ ] **Step 5: manifest + gradle**

manifest 权限区追加:

```xml
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
```

`<application>` 内追加:

```xml
        <service
            android:name=".MediaPlaybackService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="mediaPlayback" />
        <receiver android:name=".MediaControlReceiver" android:exported="false" />
```

gradle dependencies 追加:

```groovy
    implementation 'androidx.media:media:1.7.0'
```

- [ ] **Step 6: 验证并提交**

Run: `flutter test test/android_media_session_source_test.dart && flutter build apk --debug && flutter test`
Expected: 全部 PASS,apk 编译通过。

```bash
git add android/app/src/main/kotlin/com/vireen/whisper/MediaPlaybackService.kt android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt android/app/src/main/AndroidManifest.xml android/app/build.gradle test/android_media_session_source_test.dart
git commit -m "feat(android): 播放端 MediaSession 媒体外壳与音频焦点"
```

---

### Task 10: AudioMediaSessionBridge(Dart 状态映射与控制分发)

**Files:**
- Create: `lib/audio/audio_media_session.dart`
- Modify: `lib/audio/audio_platform.dart`(`updateMediaState` 方法 + `mediaControl` 回调分发)
- Modify: `lib/main.dart`(attach)
- Modify: `lib/l10n/app_zh.arb`、`app_en.arb`、`app_es.arb`
- Test: `test/audio_media_session_bridge_test.dart`

**Interfaces:**
- Consumes: Task 8 的 `pausePlaybackAsSink`/`requestRejoinAsSink`/`canRejoinAsSink`/`isPlaybackActive`;Task 9 的 channel 方法;`WsSvrManager` 需新增 `PeerProfile? remoteProfileFor(String peerId)`(公开 `_remoteProfilesByPeerId[peerId] ?? (peerId == receiver ? _remoteProfile : null)`,与 `svrmanager.dart:168-171` 现有私有模式一致)。
- Produces: `AudioMediaSessionBridge`(单例,`void attach({required AudioGroupCoordinator coordinator})`:监听 coordinator 变化推 `updateMediaState`;处理 `mediaControl`:`pause|focusPause|focusPauseTransient → pausePlaybackAsSink()`、`resume|focusResume → requestRejoinAsSink()`(先置 buffering)、`disconnect → stopLocal()`);`AudioPlatform.updateMediaState(...)` 与 `AudioPlatform.onMediaControl` 回调字段。

- [ ] **Step 1: 写失败测试**

```dart
// test/audio_media_session_bridge_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 状态映射与门控是纯逻辑,用 source 断言 + 纯函数单测双保险。
  test('media session bridge maps coordinator state and gates resume', () {
    final bridge =
        File('lib/audio/audio_media_session.dart').readAsStringSync();
    final platform =
        File('lib/audio/audio_platform.dart').readAsStringSync();
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(bridge, contains('pausePlaybackAsSink'));
    expect(bridge, contains('requestRejoinAsSink'));
    expect(bridge, contains("'buffering'")); // 重连中间态
    expect(bridge, contains('audioGroupRejoinV1')); // canResume 门控
    expect(bridge, contains('focusPauseTransient'));
    expect(platform, contains("'updateMediaState'"));
    expect(platform, contains('onMediaControl'));
    expect(manager, contains('PeerProfile? remoteProfileFor'));
    expect(main, contains('AudioMediaSessionBridge().attach'));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/audio_media_session_bridge_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现**

`audio_platform.dart` 追加:

```dart
  /// 原生 mediaControl 回调(pause/resume/disconnect/focus*)。
  void Function(String action)? onMediaControl;

  Future<void> updateMediaState({
    required String state,
    required String title,
    required String subtitle,
    required bool canResume,
    required String pauseLabel,
    required String playLabel,
    required String disconnectLabel,
  }) {
    return _channel.invokeMethod<void>('updateMediaState', <String, dynamic>{
      'state': state,
      'title': title,
      'subtitle': subtitle,
      'canResume': canResume,
      'pauseLabel': pauseLabel,
      'playLabel': playLabel,
      'disconnectLabel': disconnectLabel,
    });
  }
```

并在既有 `handleNativeMethodCall`(`audio_platform.dart:11` 注册的 handler)加 case:

```dart
      case 'mediaControl':
        final args = call.arguments as Map?;
        onMediaControl?.call(args?['action'] as String? ?? '');
        return;
```

`svrmanager.dart` 加公开方法(放在 `supportsRemoteInputFor` 附近,与 :168 的私有查询同模式):

```dart
  PeerProfile? remoteProfileFor(String peerId) {
    return _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
  }
```

`lib/audio/audio_media_session.dart`:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/socket/svrmanager.dart';

/// 把播放端(sink)状态镜像到系统媒体外壳,并把媒体控制意图
/// 转回协调器。只读状态、只转发意图,不触碰播放数据通路。
class AudioMediaSessionBridge {
  static final AudioMediaSessionBridge _instance =
      AudioMediaSessionBridge._internal();

  factory AudioMediaSessionBridge() => _instance;

  AudioMediaSessionBridge._internal();

  AudioGroupCoordinator? _coordinator;
  AudioPlatform? _platform;
  bool _rejoining = false;
  Timer? _rejoinTimeout;
  String _lastState = 'stopped';

  AppLocalizations get _l10n =>
      lookupAppLocalizations(PlatformDispatcher.instance.locale);

  void attach({
    required AudioGroupCoordinator coordinator,
    required AudioPlatform platform,
  }) {
    if (!Platform.isAndroid) {
      return;
    }
    _coordinator = coordinator;
    _platform = platform;
    platform.onMediaControl = _handleControl;
    coordinator.addListener(_sync);
  }

  void _handleControl(String action) {
    final coordinator = _coordinator;
    if (coordinator == null) {
      return;
    }
    switch (action) {
      case 'pause':
      case 'focusPause':
      case 'focusPauseTransient':
        coordinator.pausePlaybackAsSink();
        break;
      case 'resume':
      case 'focusResume':
        _rejoining = true;
        _sync();
        coordinator.requestRejoinAsSink().then((sent) {
          if (!sent) {
            _rejoining = false;
            _sync();
          }
        });
        // spec 错误处理:重加入失败不许卡死在 buffering。
        // 10 秒内源端未 re-offer(isPlaybackActive 仍为 false)则回落 paused,
        // 媒体卡上的"播放"按钮即为重试入口。
        _rejoinTimeout?.cancel();
        _rejoinTimeout = Timer(const Duration(seconds: 10), () {
          if (_rejoining && !(_coordinator?.isPlaybackActive ?? false)) {
            _rejoining = false;
            _sync();
          }
        });
        break;
      case 'disconnect':
        coordinator.stopLocal();
        break;
    }
  }

  bool _sourceSupportsRejoin() {
    final session = _coordinator?.session;
    final sourcePeerId = session?.sourcePeerId ?? '';
    if (sourcePeerId.isEmpty) {
      return false;
    }
    return WsSvrManager()
            .remoteProfileFor(sourcePeerId)
            ?.capabilities
            .audioGroupRejoinV1 ==
        true;
  }

  void _sync() {
    final coordinator = _coordinator;
    final platform = _platform;
    if (coordinator == null || platform == null) {
      return;
    }
    final String state;
    if (coordinator.isPlaybackActive) {
      state = 'playing';
      _rejoining = false;
    } else if (_rejoining) {
      state = 'buffering';
    } else if (coordinator.canRejoinAsSink) {
      state = 'paused';
    } else {
      state = 'stopped';
    }
    if (state == _lastState && state != 'playing') {
      return; // 原地更新,避免重复无效刷新
    }
    _lastState = state;
    final l10n = _l10n;
    platform.updateMediaState(
      state: state,
      title: coordinator.session?.sourcePeerId ?? 'Whisper',
      subtitle: l10n.audioPlaybackNotificationSubtitle,
      canResume: _sourceSupportsRejoin(),
      pauseLabel: l10n.mediaActionPause,
      playLabel: l10n.mediaActionPlay,
      disconnectLabel: l10n.mediaActionDisconnect,
    );
  }
}
```

落地校准(实现时按真实 API 对齐,不改变结构):
- 标题应显示来源设备名而非 peerId——用 `WsSvrManager().remoteProfileFor(sourcePeerId)?.deviceName` 或 `LocalDatabase().fetchDevice` 取名,取不到再回落 peerId;`PeerProfile` 的设备名字段名以 `lib/state/peer_profile.dart` 实际定义为准。
- `coordinator.session` 在 sink 端是否非空,以 `_handleOffer` 实现为准;若 sink 端不持有 session,则在 Task 8 的 `_SinkRejoinContext` 上暴露 `String get rejoinSourcePeerId`,此处改用之。
- `attach` 的调用点:`lib/main.dart` 中在 `TransferNotificationBridge().attach()` 之后,用与 `conversation.dart` 相同的方式取共享的 coordinator/platform 实例(`conversation.dart` 里 `_audioCoordinator`/`_audioGroupCoordinator` 的来源照抄;若它们是页面局部构造而非全局单例,则把 bridge 的 attach 放到同一构造点)。

- [ ] **Step 4: ARB 三语**

zh:

```json
  "audioPlaybackNotificationSubtitle": "正在播放系统音频",
  "mediaActionPause": "暂停",
  "mediaActionPlay": "播放",
  "mediaActionDisconnect": "断开",
```

en:`"Playing system audio"`、`"Pause"`、`"Play"`、`"Disconnect"`;es:`"Reproduciendo audio del sistema"`、`"Pausar"`、`"Reproducir"`、`"Desconectar"`。

Run: `flutter gen-l10n`

- [ ] **Step 5: 验证并提交**

Run: `flutter test test/audio_media_session_bridge_test.dart && flutter analyze && flutter test`
Expected: 全部 PASS。

```bash
git add lib/audio/audio_media_session.dart lib/audio/audio_platform.dart lib/socket/svrmanager.dart lib/main.dart lib/l10n/ test/audio_media_session_bridge_test.dart
git commit -m "feat(audio): 播放端媒体状态桥接与暂停/重连控制"
```

---

### Task 11: 收尾——全量回归、真机验证脚本与手测矩阵

**Files:**
- Create: `docs/superpowers/specs/2026-07-06-android-live-notifications-manual-test.md`
- Test: 全量 `flutter analyze` + `flutter test` + debug apk 构建

**Interfaces:**
- Consumes: Tasks 1-10 全部产物。
- Produces: 手测矩阵文档;可交付状态声明。

- [ ] **Step 1: 全量回归**

Run: `flutter analyze && flutter test && flutter build apk --debug`
Expected: 0 error 0 新 warning;全部测试 PASS;apk 编译通过。

- [ ] **Step 2: 写手测矩阵文档**

```markdown
# Android 通知上岛 手测矩阵(发布前逐项过)

结果记录:✅ 通过 / ❌ 失败(附截图) / ⬜ 未测

## 连接请求(任一 Android 设备)
- ⬜ app 退后台,另一台设备发起连接:5 秒内出现 heads-up 通知,含设备名+IP
- ⬜ 通知点"同意":连接建立,通知消失,回 app 见已连接
- ⬜ 通知点"拒绝":对端收到拒绝,通知消失
- ⬜ app 在前台:只弹应用内对话框,不发通知
- ⬜ 应用内已处理后,通知自动消失;通知已处理后再进 app,对话框操作无副作用
- ⬜ 对端请求后立刻断开:通知自动消失
- ⬜ 深度杀掉 app 后点旧通知 action:通知转"已过期",不崩溃

## 传输进度
- ⬜ Android 15-:发起多文件传输,出现单条聚合进度通知,静音、≤1次/秒、不回退
- ⬜ Android 16 Pixel(已授 promoted 权限):状态栏出现进度 chip,锁屏可见进度卡
- ⬜ Android 16 Pixel(拒绝 promoted 权限):降级为经典进度通知,功能不缺
- ⬜ 传输完成:同一条通知原地转"已完成",可滑走,点击进入会话
- ⬜ 中途断开:通知转"已中断,回到应用可恢复"
- ⬜ 全部取消:通知直接消失
- ⬜ 保活开关关闭时以上仍然全部成立
- ⬜ 保活通知本体不再显示传输进度/音频文案

## 播放端媒体
- ⬜ 接收桌面音频:锁屏与通知中心出现媒体卡(标题=来源设备名,无进度条)
- ⬜ 三星 One UI 7:Now Bar 出现媒体卡片
- ⬜ 点暂停:声音停止,源端确认已停止对本机 fanout(源端会话状态该 sink 为 stopped)
- ⬜ 点播放:短暂 buffering 后恢复出声(对端为新版本时)
- ⬜ 对端为旧版本:暂停后媒体卡无"播放"按钮,只有"断开"
- ⬜ 来电:自动暂停;挂断:自动恢复
- ⬜ 打开音乐 app 播放:Whisper 让出,不自动恢复
- ⬜ 导航语音播报(可 duck):音量压低不断流
- ⬜ 连续播放 >6 小时不被系统终止(过夜验证一次)
- ⬜ 断开:媒体卡与前台服务消失

## 回归
- ⬜ 通知转发(手机→桌面)功能不受影响
- ⬜ iOS/macOS/Windows/Linux 构建不受影响(至少 macOS 本地 build 一次)
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-07-06-android-live-notifications-manual-test.md
git commit -m "docs(android): 通知上岛手测矩阵"
```

---

## 残余风险(实现者须知)

1. `NotificationCompat.ProgressStyle`/`setRequestPromotedOngoing`/`canPostPromotedNotifications` 的确切 API 名以 `androidx.core:core:1.17.0` 编译结果为准(Task 4 Step 6 的 `flutter build apk --debug` 是硬门槛);如有出入,调 API 名并同步 source test 断言,降级链结构不变。
2. `AudioGroupSinkState.stopped.isTerminal` 若为 false,Task 8 Step 4 按备用方案内联 fresh-offer。
3. 通知 action 在个别 OEM 深度杀后台下可能延迟;"已过期"兜底路径已覆盖,不追加特殊处理。
4. 真机行为(chip、Now Bar、焦点、6 小时)只能按 Task 11 手测矩阵验证,CI 无法覆盖——不许在未跑手测前声称"已验证"。
