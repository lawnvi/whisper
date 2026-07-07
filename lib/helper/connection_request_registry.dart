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
