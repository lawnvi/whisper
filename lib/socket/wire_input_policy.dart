import 'dart:collection';

import 'package:drift/drift.dart' show Variable;
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';

abstract final class WireInputReason {
  static const String messageSenderMismatch = 'message_sender_mismatch';
  static const String messageReceiverMismatch = 'message_receiver_mismatch';
  static const String messageIdInvalid = 'message_uuid_invalid';
  static const String messageIdConflict = 'message_uuid_conflict';
  static const String messageTypeInvalid = 'message_type_invalid';
  static const String controlSessionMismatch = 'control_session_mismatch';
  static const String sessionNotCurrent = 'session_not_current';
  static const String sessionNotAuthenticated = 'session_not_authenticated';
  static const String malformedFrame = 'wire_format_invalid';
  static const String ackOriginalMismatch = 'ack_original_mismatch';
  static const String transferIdInvalid = 'transfer_id_invalid';
  static const String transferPeerMismatch = 'transfer_peer_mismatch';
  static const String transferNotFound = 'transfer_not_found';
  static const String transferDirectionMismatch = 'transfer_direction_mismatch';
  static const String transferFrameMismatch = 'transfer_frame_mismatch';
  static const String transferOffsetInvalid = 'transfer_offset_invalid';
  static const String transferSizeInvalid = 'transfer_size_invalid';
  static const String transferSequenceInvalid = 'transfer_sequence_invalid';
  static const String transferFlagsInvalid = 'transfer_flags_invalid';
  static const String transferPayloadInvalid = 'transfer_payload_invalid';
  static const String transferInactive = 'transfer_inactive';
}

final class WireInputValidationResult {
  const WireInputValidationResult.accepted()
      : isAccepted = true,
        isIgnored = false,
        reason = '';

  const WireInputValidationResult.ignored()
      : isAccepted = false,
        isIgnored = true,
        reason = '';

  const WireInputValidationResult.rejected(this.reason)
      : isAccepted = false,
        isIgnored = false;

  final bool isAccepted;
  final bool isIgnored;
  final String reason;

  void requireAccepted() {
    if (!isAccepted) {
      throw WireInputRejected(reason);
    }
  }
}

final class WireAcknowledgementValidationResult {
  const WireAcknowledgementValidationResult.accepted(this.original)
      : isAccepted = true,
        reason = '';

  const WireAcknowledgementValidationResult.rejected(this.reason)
      : isAccepted = false,
        original = null;

  final bool isAccepted;
  final String reason;
  final MessageData? original;

  void requireAccepted() {
    if (!isAccepted) {
      throw WireInputRejected(reason);
    }
  }
}

final class WireInputRejected implements Exception {
  const WireInputRejected(this.reason);

  final String reason;

  @override
  String toString() => 'WireInputRejected($reason)';
}

final class _WireControlSessionBinding {
  const _WireControlSessionBinding({
    required this.namespace,
    required this.sessionId,
    required this.authenticatedPeerId,
    required this.localPeerId,
    required this.sourcePeerId,
    required this.sinkPeerId,
    required this.context,
  });

  final String namespace;
  final String sessionId;
  final String authenticatedPeerId;
  final String localPeerId;
  final String sourcePeerId;
  final String sinkPeerId;
  final String context;
}

final class WireControlSessionRegistry {
  WireControlSessionRegistry({this.maxEntries = 4096}) : assert(maxEntries > 0);

  final int maxEntries;
  final LinkedHashMap<String, _WireControlSessionBinding> _bindings =
      LinkedHashMap<String, _WireControlSessionBinding>();

  int get length => _bindings.length;

  bool forget({
    required String namespace,
    required String sessionId,
  }) {
    if (namespace.isEmpty || sessionId.isEmpty) {
      return false;
    }
    return _bindings.remove('$namespace\u0000$sessionId') != null;
  }

  void clearPeer(
    String authenticatedPeerId, {
    Map<String, Set<String>> preservedSessions = const <String, Set<String>>{},
  }) {
    if (authenticatedPeerId.isEmpty) {
      return;
    }
    _bindings.removeWhere(
      (_, binding) =>
          binding.authenticatedPeerId == authenticatedPeerId &&
          !(preservedSessions[binding.namespace]?.contains(binding.sessionId) ??
              false),
    );
  }

  void clearAll() {
    _bindings.clear();
  }

  WireInputValidationResult validateAndRemember({
    required String namespace,
    required String sessionId,
    required String sourcePeerId,
    required String sinkPeerId,
    required String authenticatedPeerId,
    required String localPeerId,
    required bool isInitialOffer,
    required bool isIncoming,
    bool reverseInitialDirection = false,
    String context = '',
  }) {
    if (namespace.isEmpty ||
        !isCanonicalTransferId(sessionId) ||
        authenticatedPeerId.isEmpty ||
        localPeerId.isEmpty) {
      return const WireInputValidationResult.rejected(
        WireInputReason.controlSessionMismatch,
      );
    }
    final key = '$namespace\u0000$sessionId';
    final existing = _bindings.remove(key);
    if (existing != null) {
      _bindings[key] = existing;
      if (existing.authenticatedPeerId != authenticatedPeerId ||
          existing.localPeerId != localPeerId ||
          existing.sourcePeerId != sourcePeerId ||
          existing.sinkPeerId != sinkPeerId ||
          existing.context != context) {
        return const WireInputValidationResult.rejected(
          WireInputReason.controlSessionMismatch,
        );
      }
      return const WireInputValidationResult.accepted();
    }

    final sourceMustBeAuthenticated =
        reverseInitialDirection ? !isIncoming : isIncoming;
    final hasExpectedOfferDirection = sourceMustBeAuthenticated
        ? sourcePeerId == authenticatedPeerId && sinkPeerId == localPeerId
        : sourcePeerId == localPeerId && sinkPeerId == authenticatedPeerId;
    if (!isInitialOffer || !hasExpectedOfferDirection) {
      return const WireInputValidationResult.rejected(
        WireInputReason.controlSessionMismatch,
      );
    }
    if (_bindings.length >= maxEntries) {
      return const WireInputValidationResult.rejected(
        WireInputReason.controlSessionMismatch,
      );
    }
    _bindings[key] = _WireControlSessionBinding(
      namespace: namespace,
      sessionId: sessionId,
      authenticatedPeerId: authenticatedPeerId,
      localPeerId: localPeerId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      context: context,
    );
    return const WireInputValidationResult.accepted();
  }
}

final RegExp _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

bool isCanonicalTransferId(String value) => _canonicalUuid.hasMatch(value);

abstract final class WireInputPolicy {
  static WireInputValidationResult validateClaimedPeerId({
    required String claimedPeerId,
    required String authenticatedPeerId,
  }) {
    if (authenticatedPeerId.isEmpty || claimedPeerId != authenticatedPeerId) {
      return const WireInputValidationResult.rejected(
        WireInputReason.messageSenderMismatch,
      );
    }
    return const WireInputValidationResult.accepted();
  }

  static WireInputValidationResult validatePeerPair({
    required String sourcePeerId,
    required String sinkPeerId,
    required String authenticatedPeerId,
    required String localPeerId,
  }) {
    final forward =
        sourcePeerId == authenticatedPeerId && sinkPeerId == localPeerId;
    final reverse =
        sourcePeerId == localPeerId && sinkPeerId == authenticatedPeerId;
    if (authenticatedPeerId.isEmpty ||
        localPeerId.isEmpty ||
        (!forward && !reverse)) {
      return const WireInputValidationResult.rejected(
        WireInputReason.messageSenderMismatch,
      );
    }
    return const WireInputValidationResult.accepted();
  }

  static WireInputValidationResult validateControlSessionId({
    required String messageId,
    required String sessionId,
  }) {
    if (!isCanonicalTransferId(messageId) || sessionId != messageId) {
      return const WireInputValidationResult.rejected(
        WireInputReason.messageIdInvalid,
      );
    }
    return const WireInputValidationResult.accepted();
  }

  static WireInputValidationResult validateControlEnvelope(
    Map<String, Object?> json, {
    required Set<String> allowedActions,
  }) {
    final action = json['action'];
    final sessionId = json['sessionId'];
    final sourcePeerId = json['sourcePeerId'];
    final sinkPeerId = json['sinkPeerId'];
    if (action is! String ||
        !allowedActions.contains(action) ||
        sessionId is! String ||
        !isCanonicalTransferId(sessionId) ||
        sourcePeerId is! String ||
        sourcePeerId.isEmpty ||
        sinkPeerId is! String ||
        sinkPeerId.isEmpty) {
      return const WireInputValidationResult.rejected(
        WireInputReason.malformedFrame,
      );
    }
    return const WireInputValidationResult.accepted();
  }

  static WireInputValidationResult validateSessionBinding({
    required bool isAuthenticated,
    required String sessionPeerId,
    required String sinkPeerId,
    required int sessionGeneration,
    required bool isCurrentSession,
    required bool isCurrentConnection,
  }) {
    if (!isAuthenticated ||
        sessionPeerId.isEmpty ||
        sinkPeerId != sessionPeerId ||
        sessionGeneration <= 0 ||
        !isCurrentSession ||
        !isCurrentConnection) {
      return const WireInputValidationResult.rejected(
        WireInputReason.sessionNotCurrent,
      );
    }
    return const WireInputValidationResult.accepted();
  }

  static WireInputValidationResult validateMessageFrame(
    WhisperFrameV3 frame,
  ) {
    if (frame.type != WhisperFrameType.message ||
        frame.transferId.isNotEmpty ||
        frame.offset != 0 ||
        frame.sequence != 0 ||
        frame.flags != 0) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferFrameMismatch,
      );
    }
    return const WireInputValidationResult.accepted();
  }

  static WireInputValidationResult validateMessage(
    MessageData message, {
    required String authenticatedPeerId,
    required String localPeerId,
    bool allowFileOffer = false,
  }) {
    if (message.type == MessageEnum.Auth) {
      return const WireInputValidationResult.accepted();
    }
    final supportedType = switch (message.type) {
      MessageEnum.Ack ||
      MessageEnum.Heartbeat ||
      MessageEnum.Text ||
      MessageEnum.Notification ||
      MessageEnum.AudioControl ||
      MessageEnum.RemoteInputControl ||
      MessageEnum.AudioGroupControl =>
        true,
      MessageEnum.File => allowFileOffer,
      _ => false,
    };
    if (!supportedType) {
      return const WireInputValidationResult.rejected(
        WireInputReason.messageTypeInvalid,
      );
    }
    if (message.sender != authenticatedPeerId || authenticatedPeerId.isEmpty) {
      return const WireInputValidationResult.rejected(
        WireInputReason.messageSenderMismatch,
      );
    }
    if (message.receiver != localPeerId || localPeerId.isEmpty) {
      return const WireInputValidationResult.rejected(
        WireInputReason.messageReceiverMismatch,
      );
    }
    if (!isCanonicalTransferId(message.uuid)) {
      return const WireInputValidationResult.rejected(
        WireInputReason.messageIdInvalid,
      );
    }
    return const WireInputValidationResult.accepted();
  }

  static WireAcknowledgementValidationResult validateAcknowledgement({
    required MessageData acknowledgement,
    required Iterable<MessageData> candidates,
    required String authenticatedPeerId,
    required String localPeerId,
  }) {
    final messageResult = validateMessage(
      acknowledgement,
      authenticatedPeerId: authenticatedPeerId,
      localPeerId: localPeerId,
    );
    if (!messageResult.isAccepted) {
      return WireAcknowledgementValidationResult.rejected(
        messageResult.reason,
      );
    }
    if (acknowledgement.type != MessageEnum.Ack || !acknowledgement.acked) {
      return const WireAcknowledgementValidationResult.rejected(
        WireInputReason.ackOriginalMismatch,
      );
    }
    for (final candidate in candidates) {
      if (candidate.id > 0 &&
          candidate.uuid == acknowledgement.uuid &&
          candidate.sender == localPeerId &&
          candidate.receiver == authenticatedPeerId &&
          candidate.type != MessageEnum.Ack &&
          candidate.type != MessageEnum.Auth &&
          candidate.name == acknowledgement.name &&
          candidate.clipboard == acknowledgement.clipboard &&
          candidate.size == acknowledgement.size &&
          candidate.content == acknowledgement.content &&
          candidate.message == acknowledgement.message &&
          candidate.timestamp == acknowledgement.timestamp &&
          candidate.md5 == acknowledgement.md5 &&
          candidate.fileTimestamp == acknowledgement.fileTimestamp) {
        return WireAcknowledgementValidationResult.accepted(candidate);
      }
    }
    return const WireAcknowledgementValidationResult.rejected(
      WireInputReason.ackOriginalMismatch,
    );
  }

  static Future<MessageData?> acknowledgeOutgoing({
    required LocalDatabase database,
    required MessageData acknowledgement,
    required String authenticatedPeerId,
    required String localPeerId,
    void Function()? requireCurrent,
  }) async {
    final messageResult = validateMessage(
      acknowledgement,
      authenticatedPeerId: authenticatedPeerId,
      localPeerId: localPeerId,
    );
    messageResult.requireAccepted();
    if (acknowledgement.type != MessageEnum.Ack || !acknowledgement.acked) {
      throw const WireInputRejected(WireInputReason.ackOriginalMismatch);
    }
    final candidates = await database.fetchMessagesByUuid(
      acknowledgement.uuid,
    );
    requireCurrent?.call();
    if (candidates.isEmpty) {
      return null;
    }
    final validation = validateAcknowledgement(
      acknowledgement: acknowledgement,
      candidates: candidates,
      authenticatedPeerId: authenticatedPeerId,
      localPeerId: localPeerId,
    );
    validation.requireAccepted();
    final original = validation.original!;
    await database.customUpdate(
      'UPDATE message SET acked = 1 WHERE id = ?',
      variables: <Variable<Object>>[Variable<int>(original.id)],
      updates: {database.message},
    );
    requireCurrent?.call();
    return original.copyWith(acked: true);
  }

  static WireInputValidationResult validateFileOffer({
    required WhisperFrameV3 frame,
    required MessageData message,
    required String authenticatedPeerId,
    required String localPeerId,
  }) {
    final messageResult = validateMessage(
      message,
      authenticatedPeerId: authenticatedPeerId,
      localPeerId: localPeerId,
      allowFileOffer: true,
    );
    if (!messageResult.isAccepted) {
      return messageResult;
    }
    if (!isCanonicalTransferId(frame.transferId)) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferIdInvalid,
      );
    }
    if (frame.type != WhisperFrameType.fileOffer ||
        message.type != MessageEnum.File ||
        frame.transferId != message.uuid) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferFrameMismatch,
      );
    }
    if (frame.flags != 0) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferFlagsInvalid,
      );
    }
    if (frame.sequence != 0) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferSequenceInvalid,
      );
    }
    if (frame.offset != 0) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferOffsetInvalid,
      );
    }
    if (message.size < 0) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferSizeInvalid,
      );
    }
    return const WireInputValidationResult.accepted();
  }

  static WireInputValidationResult validateFileData({
    required WhisperFrameV3 frame,
    required FileTransferData transfer,
    required String authenticatedPeerId,
    required int expectedOffset,
    required int expectedSequence,
    required bool isActive,
  }) {
    if (!isCanonicalTransferId(frame.transferId) ||
        frame.transferId != transfer.transferId) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferIdInvalid,
      );
    }
    if (frame.type != WhisperFrameType.fileData) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferFrameMismatch,
      );
    }
    if (authenticatedPeerId.isEmpty ||
        transfer.peerUid != authenticatedPeerId) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferPeerMismatch,
      );
    }
    if (transfer.direction != FileTransferDirection.incoming) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferDirectionMismatch,
      );
    }
    if (frame.flags != 0) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferFlagsInvalid,
      );
    }
    if (frame.offset < 0) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferOffsetInvalid,
      );
    }
    if (frame.payload.isEmpty ||
        frame.payload.length > fileTransferV3FramePayloadSize) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferPayloadInvalid,
      );
    }
    if (transfer.size < 0 ||
        frame.offset > transfer.size ||
        frame.payload.length > transfer.size - frame.offset) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferSizeInvalid,
      );
    }
    if (isTerminalFileTransferState(transfer.state)) {
      return const WireInputValidationResult.ignored();
    }
    if (!isActive) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferInactive,
      );
    }
    if (frame.sequence < 0 || frame.sequence != expectedSequence) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferSequenceInvalid,
      );
    }
    if (frame.offset != expectedOffset) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferOffsetInvalid,
      );
    }
    return const WireInputValidationResult.accepted();
  }

  static WireInputValidationResult validateFileControl({
    required WhisperFrameV3 frame,
    required FileTransferV3Control control,
    required FileTransferData transfer,
    required String authenticatedPeerId,
  }) {
    final headerResult = validateFileControlHeader(
      frame: frame,
      control: control,
    );
    if (!headerResult.isAccepted) {
      return headerResult;
    }
    if (control.transferId != transfer.transferId) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferFrameMismatch,
      );
    }
    if (authenticatedPeerId.isEmpty ||
        transfer.peerUid != authenticatedPeerId) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferPeerMismatch,
      );
    }
    if ((control.action == FileTransferV3Action.ready ||
            control.action == FileTransferV3Action.ack ||
            control.action == FileTransferV3Action.complete) &&
        transfer.direction != FileTransferDirection.outgoing) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferDirectionMismatch,
      );
    }
    if (control.durableOffset > transfer.size) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferOffsetInvalid,
      );
    }
    if (control.action == FileTransferV3Action.complete &&
        control.durableOffset != control.size) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferOffsetInvalid,
      );
    }
    if (control.size != transfer.size) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferSizeInvalid,
      );
    }
    if (isTerminalFileTransferState(transfer.state)) {
      return const WireInputValidationResult.ignored();
    }
    return const WireInputValidationResult.accepted();
  }

  static WireInputValidationResult validateFileControlHeader({
    required WhisperFrameV3 frame,
    required FileTransferV3Control control,
  }) {
    if (!isCanonicalTransferId(frame.transferId) ||
        !isCanonicalTransferId(control.transferId)) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferIdInvalid,
      );
    }
    final expectedType = switch (control.action) {
      FileTransferV3Action.ready => WhisperFrameType.fileReady,
      FileTransferV3Action.ack => WhisperFrameType.fileAck,
      FileTransferV3Action.complete => WhisperFrameType.fileComplete,
      FileTransferV3Action.cancel => WhisperFrameType.fileCancel,
      FileTransferV3Action.error => WhisperFrameType.fileError,
    };
    if (frame.type != expectedType ||
        frame.transferId != control.transferId ||
        control.protocolVersion != fileTransferV3ProtocolVersion) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferFrameMismatch,
      );
    }
    if (frame.flags != 0) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferFlagsInvalid,
      );
    }
    if (frame.sequence != 0) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferSequenceInvalid,
      );
    }
    if (control.durableOffset < 0 || frame.offset != control.durableOffset) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferOffsetInvalid,
      );
    }
    if (control.size < 0) {
      return const WireInputValidationResult.rejected(
        WireInputReason.transferSizeInvalid,
      );
    }
    return const WireInputValidationResult.accepted();
  }
}
