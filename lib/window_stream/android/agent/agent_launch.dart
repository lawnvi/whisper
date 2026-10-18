import 'dart:convert';
import 'dart:typed_data';

import '../../adb/adb_host_client.dart' show shellProcessPattern;
import 'agent_wire.dart';

/// A running persistent agent, as its state file describes it to adb
/// clients (`StateFile.java`). [token] is empty when the reader is the
/// phone's own Whisper, which uses the app link instead.
class AgentDaemonState {
  const AgentDaemonState({
    required this.pid,
    required this.protocol,
    required this.version,
    required this.jarSha,
    required this.socket,
    required this.token,
  });

  static AgentDaemonState? parse(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return null;
    }
    try {
      final json = jsonDecode(text.substring(start, end + 1));
      if (json is! Map || json['pid'] is! int || json['protocol'] is! int) {
        return null;
      }
      final hex = '${json['token'] ?? ''}';
      return AgentDaemonState(
        pid: json['pid'] as int,
        protocol: json['protocol'] as int,
        version: '${json['version'] ?? ''}',
        jarSha: '${json['jarSha'] ?? ''}',
        socket: '${json['socket'] ?? AgentWire.daemonSocket}',
        token: _parseHex(hex) ?? Uint8List(0),
      );
    } on FormatException {
      return null;
    }
  }

  final int pid;
  final int protocol;
  final String version;
  final String jarSha;
  final String socket;
  final Uint8List token;

  bool get hasToken => token.length == AgentWire.tokenBytes;

  static Uint8List? _parseHex(String hex) {
    if (hex.isEmpty || hex.length.isOdd) {
      return null;
    }
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final value = int.tryParse(hex.substring(2 * i, 2 * i + 2), radix: 16);
      if (value == null) {
        return null;
      }
      out[i] = value;
    }
    return out;
  }
}

/// What [AgentLaunch.probeScript] found on the phone.
class AgentProbe {
  const AgentProbe({this.running, required this.jarPresent});

  /// The persistent agent that is running, if any.
  final AgentDaemonState? running;

  /// Our build's jar is already on the phone (hash checked).
  final bool jarPresent;
}

/// Shell scripts that find, start and replace the persistent agent. The
/// same text runs through a desktop's adb and through the phone's own
/// wireless debugging, so both behave alike.
abstract final class AgentLaunch {
  static const String stateDir = '/data/local/tmp/whisper-agent';
  static const String statePath = '$stateDir/state.json';
  static const String _agentPattern = AgentWire.mainClass;

  /// Lines a phone-side reader gets in place of the token.
  static const String _hideToken =
      r'''sed 's/"token":"[0-9a-f]*"/"token":""/' ''';

  /// Ends agents and fallback servers that older desktops left behind
  /// (they hold virtual displays), removes jars of other builds (never the
  /// running agent's), then prints the running persistent agent's state and
  /// whether this build's jar is there.
  static String probeScript(AgentSidecar sidecar, {bool withToken = true}) {
    final jar = sidecar.devicePath;
    return [
      'S=$statePath; J=$jar; R=',
      'if [ -f \$S ]; then P=\$(sed -n \'s/.*"pid":\\([0-9]*\\).*/\\1/p\' \$S); '
          'if [ -n "\$P" ] && tr \'\\0\' \' \' < /proc/\$P/cmdline 2>/dev/null | grep -q -- --daemon; '
          'then R=\$P; fi; fi',
      'for p in \$(pgrep -f ${shellProcessPattern(_agentPattern)}); do '
          'tr \'\\0\' \' \' < /proc/\$p/cmdline 2>/dev/null | grep -q -- --daemon || kill \$p; done',
      'for p in \$(pgrep -f ${shellProcessPattern('whisper-scrcpy')}); do '
          'pkill -P \$p; kill \$p; done',
      'D=; [ -n "\$R" ] && D=/data/local/tmp/whisper-agent-'
          '\$(sed -n \'s/.*"jarSha":"\\([0-9a-f]\\{16\\}\\).*/\\1/p\' \$S).jar',
      'for f in /data/local/tmp/whisper-agent-*.jar; do '
          '[ "\$f" = "\$J" ] || [ "\$f" = "\$D" ] || rm -f "\$f"; done',
      'echo @@state; [ -n "\$R" ] && ${withToken ? 'cat \$S' : '$_hideToken\$S'}; echo',
      'echo @@jar; sha256sum \$J 2>/dev/null; echo @@end',
    ].join('\n');
  }

  static AgentProbe parseProbe(String output, AgentSidecar sidecar) {
    final state = _section(output, '@@state', '@@jar');
    final jar = _section(output, '@@jar', '@@end');
    return AgentProbe(
      running: AgentDaemonState.parse(state),
      jarPresent: jar.contains(sidecar.jarSha256),
    );
  }

  /// Starts the persistent agent detached from this shell (`setsid`, no
  /// terminal, stdio on /dev/null) so it outlives adb, after checking the
  /// jar's hash; [copyFrom] first copies the jar from there (the phone's
  /// own Whisper puts it in its external files folder, which the shell
  /// user can read). Waits up to 5 s for the state file and prints it.
  static String startScript(
    AgentSidecar sidecar, {
    String? copyFrom,
    bool withToken = true,
  }) {
    final jar = sidecar.devicePath;
    return [
      'S=$statePath; J=$jar',
      if (copyFrom != null)
        'cat ${_quote(copyFrom)} > \$J.part && mv \$J.part \$J && chmod 644 \$J',
      'sha256sum \$J 2>/dev/null | grep -q ${sidecar.jarSha256} || { echo @@badjar; exit 1; }',
      'rm -f \$S',
      'CLASSPATH=\$J setsid app_process / ${AgentWire.mainClass} --daemon '
          '</dev/null >/dev/null 2>&1 &',
      'i=0; while [ \$i -lt 50 ]; do grep -q \'"pid":\' \$S 2>/dev/null && break; '
          'sleep 0.1; i=\$((i+1)); done',
      'echo @@state; ${withToken ? 'cat \$S' : '$_hideToken\$S'} 2>/dev/null; echo; echo @@end',
    ].join('\n');
  }

  static AgentDaemonState? parseStart(String output) =>
      output.contains('@@badjar')
      ? null
      : AgentDaemonState.parse(_section(output, '@@state', '@@end'));

  /// Whether a running agent of [running] should make way for this build's:
  /// only a newer build replaces it, and never while windows stream.
  static bool shouldReplace(
    AgentDaemonState running,
    AgentSidecar ours, {
    required int streams,
  }) {
    if (streams > 0) {
      return false;
    }
    if (running.protocol != AgentWire.protocolVersion) {
      return true;
    }
    final order = compareVersions(ours.agentVersion, running.version);
    return order > 0 || (order == 0 && running.jarSha != ours.jarSha256);
  }

  /// Dotted numeric version order ("2.0.10" > "2.0.9").
  static int compareVersions(String a, String b) {
    List<int> parts(String v) =>
        v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final x = parts(a);
    final y = parts(b);
    for (var i = 0; i < x.length || i < y.length; i++) {
      final left = i < x.length ? x[i] : 0;
      final right = i < y.length ? y[i] : 0;
      if (left != right) {
        return left.compareTo(right);
      }
    }
    return 0;
  }

  static String _section(String text, String from, String to) {
    final start = text.indexOf(from);
    if (start < 0) {
      return '';
    }
    final end = text.indexOf(to, start + from.length);
    return text.substring(start + from.length, end < 0 ? text.length : end);
  }

  static String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
}
