import 'package:synchronized/synchronized.dart';
import 'package:whisper/model/LocalDatabase.dart' show MessageData;

enum WireMessageReplayDecision { accept, duplicate, conflict }

final class WireMessageReplayClaim {
  const WireMessageReplayClaim({
    required this.decision,
    this.message,
  });

  final WireMessageReplayDecision decision;
  final MessageData? message;
}

bool hasSameWireMessageIdentity(
  MessageData first,
  MessageData second,
) {
  return first.uuid.isNotEmpty &&
      first.uuid == second.uuid &&
      first.sender == second.sender &&
      first.receiver == second.receiver &&
      first.name == second.name &&
      first.clipboard == second.clipboard &&
      first.size == second.size &&
      first.type == second.type &&
      first.content == second.content &&
      first.message == second.message &&
      first.timestamp == second.timestamp &&
      first.path == second.path &&
      first.md5 == second.md5 &&
      first.fileTimestamp == second.fileTimestamp;
}

WireMessageReplayDecision classifyWireMessageReplay({
  required MessageData? existing,
  required MessageData incoming,
}) {
  return classifyWireMessageReplayCandidates(
    existing:
        existing == null ? const <MessageData>[] : <MessageData>[existing],
    incoming: incoming,
  );
}

WireMessageReplayDecision classifyWireMessageReplayCandidates({
  required Iterable<MessageData> existing,
  required MessageData incoming,
}) {
  if (incoming.uuid.isEmpty) {
    return WireMessageReplayDecision.conflict;
  }
  var uuidExists = false;
  for (final candidate in existing) {
    if (candidate.uuid != incoming.uuid) {
      continue;
    }
    uuidExists = true;
    if (hasSameWireMessageIdentity(candidate, incoming)) {
      return WireMessageReplayDecision.duplicate;
    }
  }
  return uuidExists
      ? WireMessageReplayDecision.conflict
      : WireMessageReplayDecision.accept;
}

final class WireMessageReplayGuard {
  final Lock _lock = Lock();

  Future<WireMessageReplayClaim> claim(
    MessageData incoming, {
    required Future<List<MessageData>> Function(String uuid) fetchExisting,
    required Future<MessageData> Function(MessageData message) persist,
  }) {
    return _lock.synchronized(() async {
      final existing = incoming.uuid.isEmpty
          ? const <MessageData>[]
          : await fetchExisting(incoming.uuid);
      if (incoming.uuid.isEmpty) {
        return const WireMessageReplayClaim(
          decision: WireMessageReplayDecision.conflict,
        );
      }
      var uuidExists = false;
      for (final candidate in existing) {
        if (candidate.uuid != incoming.uuid) {
          continue;
        }
        uuidExists = true;
        if (hasSameWireMessageIdentity(candidate, incoming)) {
          return WireMessageReplayClaim(
            decision: WireMessageReplayDecision.duplicate,
            message: candidate,
          );
        }
      }
      if (uuidExists) {
        return const WireMessageReplayClaim(
          decision: WireMessageReplayDecision.conflict,
        );
      }
      return WireMessageReplayClaim(
        decision: WireMessageReplayDecision.accept,
        message: await persist(incoming),
      );
    });
  }
}

Future<bool> sendAcknowledgementBestEffort({
  required Future<bool> Function() send,
  void Function(Object error, StackTrace stackTrace)? onError,
}) async {
  try {
    return await send();
  } catch (error, stackTrace) {
    onError?.call(error, stackTrace);
    return false;
  }
}
