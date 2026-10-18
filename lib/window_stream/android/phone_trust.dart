import '../../model/LocalDatabase.dart';
import '../adb/adb_host_client.dart';
import '../core/window_stream_models.dart';

/// Who a phone's Whisper says it is, read over adb from its window-stream
/// provider (which answers adb only).
class PhoneWhisperIdentity {
  const PhoneWhisperIdentity({required this.peerId, required this.identityKey});

  final String peerId;
  final String identityKey;
}

/// Whether an adb phone may be streamed, and which Whisper peer it is.
class PhoneTrustResult {
  const PhoneTrustResult({this.denied, this.peerId});

  /// Null when allowed.
  final WindowStreamFailureReason? denied;

  /// The phone's Whisper peer id when it reported one.
  final String? peerId;
}

/// Decides whether an adb phone may be streamed: only when its Whisper is
/// paired with this device and trusted, with the identity key on record.
typedef PhoneTrustCheck =
    Future<PhoneTrustResult> Function(AdbHostClient adb, String serial);

abstract final class PhoneTrust {
  static const String authority = 'com.vireen.whisper.window_stream';

  /// Parses `content call` output such as
  /// `Result: Bundle[{identityKey=AbC-_1, peerId=1b2c..., version=1}]`.
  static PhoneWhisperIdentity? parse(String output) {
    String? field(String name) {
      final match = RegExp('[{ ,]$name=([^,}\\]\\s]*)').firstMatch(output);
      final value = match?.group(1);
      return value == null || value.isEmpty || value == 'null' ? null : value;
    }

    final peerId = field('peerId');
    final identityKey = field('identityKey');
    if (peerId == null || identityKey == null) {
      return null;
    }
    return PhoneWhisperIdentity(peerId: peerId, identityKey: identityKey);
  }

  static Future<PhoneWhisperIdentity?> read(
    AdbHostClient adb,
    String serial,
  ) async {
    try {
      final result = await adb.shell(
        serial,
        'content call --uri content://$authority --method identity',
        timeout: const Duration(seconds: 6),
      );
      return parse(result.stdout);
    } catch (_) {
      return null;
    }
  }

  static Future<PhoneTrustResult> check(
    AdbHostClient adb,
    String serial,
  ) async {
    final identity = await read(adb, serial);
    if (identity == null) {
      return const PhoneTrustResult(
        denied: WindowStreamFailureReason.whisperMissing,
      );
    }
    final device = await LocalDatabase().fetchDevice(identity.peerId);
    final trusted =
        device != null &&
        device.auth &&
        device.identityPublicKey.isNotEmpty &&
        device.identityPublicKey == identity.identityKey;
    return PhoneTrustResult(
      denied: trusted ? null : WindowStreamFailureReason.untrustedDevice,
      peerId: identity.peerId,
    );
  }
}
