import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 多 peer 场景下入站鉴权与解码路径的源级回归:
/// 1. 鉴权前的 socket 不得抢占全局默认发送目标 `_sink`;
/// 2. 拒绝连接请求只关闭该条 socket,不得触发全局 close 断开所有 peer;
/// 3. 入站待确认的连接请求必须有超时自动拒绝,不能无限半开;
/// 4. 消息解码需容忍 Error(枚举序号越界),降级为 UNKONWN 而非丢弃整条消息。
void main() {
  final source =
      File('lib/socket/svrmanager.dart').readAsStringSync();

  String section(String startMarker, String endMarker) {
    final start = source.indexOf(startMarker);
    expect(start, greaterThanOrEqualTo(0),
        reason: '未找到代码段起点: $startMarker');
    final end = source.indexOf(endMarker, start);
    expect(end, greaterThan(start), reason: '未找到代码段终点: $endMarker');
    return source.substring(start, end);
  }

  test('pre-auth sockets never take over the global default sink', () {
    expect(source.contains('_sink = webSocket.sink'), isFalse,
        reason: '入站 socket 在鉴权前不得写全局 _sink(svrmanager startServer)');
    expect(source.contains('_sink = channelSink'), isFalse,
        reason: '出站 socket 在鉴权前不得写全局 _sink(svrmanager connectToServer)');
    // 鉴权成功后仍由 _registerPeerConnection 统一设置。
    final register = section(
      'Future<void> _registerPeerConnection(',
      '_setRemoteProfile(profile, peerId: peerId);',
    );
    expect(register.contains('_sink = sink;'), isTrue,
        reason: '鉴权后的 _registerPeerConnection 应保留 _sink 设置');
  });

  test('rejecting an auth request closes only that socket', () {
    final respond = section(
      'Future<void> respond(bool allow) async {',
      'final guarded = GuardedAuthCallback(',
    );
    expect(respond.contains('sink?.close()'), isTrue,
        reason: '拒绝时应只关闭本条 socket');
    expect(RegExp(r'(?<![\w.?])close\(\);').hasMatch(respond), isFalse,
        reason: '拒绝连接请求不得调用全局 close() 断开所有 peer');
  });

  test('pending incoming auth requests time out with auto-reject', () {
    expect(source.contains('incomingAuthRequestTimeout'), isTrue,
        reason: '应存在入站鉴权超时常量');
    final authCase = section(
      'case MessageEnum.Auth:',
      'case MessageEnum.Ack:',
    );
    expect(authCase.contains('incomingAuthRequestTimeout'), isTrue,
        reason: 'Auth 分支应启动超时定时器');
    expect(authCase.contains('guarded.call(false)'), isTrue,
        reason: '超时应通过 GuardedAuthCallback 自动拒绝(幂等)');
    expect(authCase.contains('.cancel()'), isTrue,
        reason: '鉴权被处理后应取消超时定时器');
  });

  test('message decode degrades to UNKONWN on Error, not just Exception', () {
    final decode = section(
      'str = utf8.decode(data);',
      'final incomingPeerId =',
    );
    expect(decode.contains('on Exception'), isFalse,
        reason: '枚举序号越界抛 RangeError(Error),on Exception 兜不住,'
            '应 catch 全部并降级为 UNKONWN 消息');
    expect(decode.contains('catch'), isTrue);
  });

  test('socket role (asServer) is per-connection, not global state', () {
    // 设备可同时对不同 peer 兼具 server/client 两种角色:
    // 角色必须随每条 socket 的消息逐层透传,不允许回退到全局可变布尔
    // (旧实现在连接建立时写、Auth 到达时读,双角色并发下会串味)。
    expect(source.contains('bool asServer = true;'), isFalse,
        reason: 'asServer 不得是 WsSvrManager 的全局可变字段');
    expect(source.contains('asServer = true;'), isFalse,
        reason: '不得有对全局 asServer 的赋值(server 侧)');
    expect(source.contains('asServer = false;'), isFalse,
        reason: '不得有对全局 asServer 的赋值(client 侧)');
    expect(
      source.contains('sink: webSocket.sink, asServer: true'),
      isTrue,
      reason: '服务端接入的 socket 必须显式以 asServer: true 处理消息',
    );
    expect(
      source.contains('sink: channelSink, asServer: false'),
      isTrue,
      reason: '本机拨出的 socket 必须显式以 asServer: false 处理消息',
    );
  });

  test('simultaneous dials are resolved deterministically by uid', () {
    final authCase = section(
      'case MessageEnum.Auth:',
      'case MessageEnum.Ack:',
    );
    expect(authCase.contains('hasOutgoing'), isTrue,
        reason: '入站 auth 需检测对同一 peer 的在途出站拨号');
    expect(authCase.contains('resolveSimultaneousDial'), isTrue,
        reason: '互拨时必须走确定性裁决而非 last-writer-wins');
    expect(authCase.contains('SimultaneousDialDecision.keepOutgoing'), isTrue,
        reason: '赢方需关闭入站连接保留出站');
    expect(
      authCase.indexOf('resolveSimultaneousDial') <
          authCase.indexOf('if (asServer) {'),
      isTrue,
      reason: '裁决必须先于信任自动通过分支,否则受信任 peer 互拨会双注册',
    );
  });
}
