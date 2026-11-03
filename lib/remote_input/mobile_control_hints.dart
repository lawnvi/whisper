import 'package:shared_preferences/shared_preferences.dart';

/// How to use the control page, said once: after the first time it is only
/// clutter on a page people come back to.
class MobileControlHints {
  static const _key = 'mobile_control_hints_seen';

  final _showing = <String>{};
  Set<String>? _seen;

  /// Until this has finished nothing is shown, so nothing flashes on a return.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _seen = (prefs.getStringList(_key) ?? const <String>[]).toSet();
  }

  /// [text] the first time [id] comes up, and for as long as this page stays.
  String? once(String id, String text) {
    final seen = _seen;
    if (seen == null) return null;
    if (_showing.contains(id)) return text;
    if (seen.contains(id)) return null;
    _showing.add(id);
    seen.add(id);
    final remembered = seen.toList();
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setStringList(_key, remembered),
    );
    return text;
  }
}
