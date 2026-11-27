import 'dart:convert';

import 'package:whisper/model/LocalDatabase.dart' show MessageData;
import 'package:whisper/socket/wire_input_policy.dart'
    show
        WireInputPolicy,
        WireInputReason,
        WireInputRejected,
        isCanonicalTransferId;

/// Purpose of a `/transfer` WebSocket connection.
///
/// Each authenticated peer keeps up to two independent `/transfer` TCP
/// connections on demand: [bulk] for file/folder transfers (`fileData`), and
/// [browse] for mounted-folder reads/writes (`browseData`, `browseWrite`), so
/// latency-sensitive mount traffic never queues behind bulk file bytes inside
/// kernel socket buffers.
enum TransferChannelKind { bulk, browse }

/// Control actions exchanged on `/chat` (`MessageEnum.TransferChannelControl`)
/// to establish, dial back, reject, or close a `/transfer` connection.
enum TransferChannelAction { open, accept, dialBack, reject, close }

/// Wire control envelope for negotiating a `/transfer` data channel.
final class TransferChannelControlMessage {
  const TransferChannelControlMessage({
    required this.action,
    required this.kind,
    required this.sessionId,
    required this.sourcePeerId,
    required this.sinkPeerId,
    this.transportToken = '',
    this.transferPort = 0,
    this.reason = '',
  });

  static const int maxReasonBytes = 128;

  final TransferChannelAction action;
  final TransferChannelKind kind;

  /// Canonical UUID identifying this `/transfer` negotiation attempt.
  final String sessionId;

  /// The peer that initiated `open`.
  final String sourcePeerId;

  /// The peer that responds to `open`.
  final String sinkPeerId;

  /// One-time 32-byte base64url token carried on `accept` and `dialBack`.
  final String transportToken;

  /// Worker-isolate TCP port to dial on `accept` and `dialBack`.
  final int transferPort;

  /// Short machine-readable reason on `reject` / `close` (optional).
  final String reason;

  bool get isTerminal =>
      action == TransferChannelAction.reject ||
      action == TransferChannelAction.close;

  Map<String, Object?> toJson() => <String, Object?>{
    'action': action.name,
    'kind': kind.name,
    'sessionId': sessionId,
    'sourcePeerId': sourcePeerId,
    'sinkPeerId': sinkPeerId,
    if (transportToken.isNotEmpty) 'transportToken': transportToken,
    if (transferPort != 0) 'transferPort': transferPort,
    if (reason.isNotEmpty) 'reason': reason,
  };

  factory TransferChannelControlMessage.fromJson(Map<String, Object?> json) {
    final actionName = json['action'];
    final kindName = json['kind'];
    final sessionId = json['sessionId'];
    final sourcePeerId = json['sourcePeerId'];
    final sinkPeerId = json['sinkPeerId'];
    final transportToken = json['transportToken'] ?? '';
    final transferPort = json['transferPort'] ?? 0;
    final reason = json['reason'] ?? '';
    if (actionName is! String ||
        kindName is! String ||
        sessionId is! String ||
        !isCanonicalTransferId(sessionId) ||
        sourcePeerId is! String ||
        sourcePeerId.isEmpty ||
        sinkPeerId is! String ||
        sinkPeerId.isEmpty ||
        transportToken is! String ||
        transferPort is! int ||
        reason is! String ||
        utf8.encode(reason).length > maxReasonBytes) {
      throw const FormatException('invalid transfer channel control fields');
    }
    final action = TransferChannelAction.values.asNameMap()[actionName];
    final kind = TransferChannelKind.values.asNameMap()[kindName];
    if (action == null || kind == null) {
      throw const FormatException('unknown transfer channel action or kind');
    }
    final expectsDialInfo =
        action == TransferChannelAction.accept ||
        action == TransferChannelAction.dialBack;
    if (expectsDialInfo) {
      if (transportToken.isEmpty || transferPort <= 0 || transferPort > 65535) {
        throw const FormatException(
          'transfer channel accept/dialBack requires token and valid port',
        );
      }
    } else if (transportToken.isNotEmpty || transferPort != 0) {
      throw const FormatException(
        'transfer channel token/port only allowed on accept or dialBack',
      );
    }
    return TransferChannelControlMessage(
      action: action,
      kind: kind,
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      transportToken: transportToken,
      transferPort: transferPort,
      reason: reason,
    );
  }

  static final Set<String> allActions = TransferChannelAction.values
      .map((action) => action.name)
      .toSet();

  /// Decodes and validates a `MessageEnum.TransferChannelControl` wire message
  /// against the authenticated peer pair and canonical message UUID.
  static TransferChannelControlMessage parseWireMessage(
    MessageData message, {
    required String authenticatedPeerId,
    required String localPeerId,
  }) {
    final TransferChannelControlMessage control;
    try {
      final decoded = jsonDecode(message.content ?? '');
      if (decoded is! Map) throw const FormatException('invalid control map');
      final json = decoded.cast<String, Object?>();
      WireInputPolicy.validateControlEnvelope(
        json,
        allowedActions: allActions,
      ).requireAccepted();
      control = TransferChannelControlMessage.fromJson(json);
    } on WireInputRejected {
      rethrow;
    } catch (_) {
      throw const WireInputRejected(WireInputReason.malformedFrame);
    }
    WireInputPolicy.validateControlSessionId(
      messageId: message.uuid,
      sessionId: control.sessionId,
    ).requireAccepted();
    WireInputPolicy.validatePeerPair(
      sourcePeerId: control.sourcePeerId,
      sinkPeerId: control.sinkPeerId,
      authenticatedPeerId: authenticatedPeerId,
      localPeerId: localPeerId,
    ).requireAccepted();
    return control;
  }
}
