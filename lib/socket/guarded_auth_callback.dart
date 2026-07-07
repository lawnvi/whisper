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
