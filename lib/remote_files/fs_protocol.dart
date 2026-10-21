/// Control messages for browsing another device's files, carried as
/// `MessageEnum.FileBrowseControl` on the chat channel.
///
/// One session per file-manager window: the browsing device (wire
/// "source") sends `open`; the browsed device (wire "sink", the host)
/// asks its user and answers `opened` or `denied`. Within the session every
/// request carries a `requestId` and gets one `result` or `failed`.
/// File contents never travel here: copies are ordinary resumable
/// transfers, placed into the chosen folder once they complete. Only a
/// [FileBrowseAction.read] (for a host whose `opened` says `read: 1`) is
/// answered by a `browseData` frame holding the bytes, so that a folder
/// mounted on this device reads just the parts it needs.
///
/// A host whose `opened` says `write: 1` also lets a mounted folder change
/// its files: [create], [move], [touch] and [space], and writes. A file is
/// written through an upload ([writeOpen]): a hidden copy next to it that
/// `browseWrite` frames write into, and that [writeClose] puts in its place
/// in one go, so a write cut short never leaves half a file. A host that
/// allows reading only says `readOnly: true` and refuses all of these.
enum FileBrowseAction {
  open,
  opened,
  denied,
  list,
  thumb,
  mkdir,
  rename,
  remove,
  fetch,
  incoming,
  read,
  result,
  failed,
  close,
  create,
  move,
  touch,
  space,
  writeOpen,
  writeSize,
  writeClose,
}

class FileBrowseMessage {
  const FileBrowseMessage({
    required this.action,
    required this.sessionId,
    required this.clientPeerId,
    required this.hostPeerId,
    this.requestId = 0,
    this.payload = const <String, Object?>{},
  });

  factory FileBrowseMessage.fromJson(Map<String, dynamic> json) {
    final action = FileBrowseAction.values.asNameMap()[json['action']];
    if (action == null) {
      throw const FormatException('unknown file browse action');
    }
    final payload = json['payload'];
    if (payload != null && payload is! Map) {
      throw const FormatException('file browse payload must be an object');
    }
    final requestId = json['requestId'];
    if (requestId != null && (requestId is! int || requestId < 0)) {
      throw const FormatException('invalid request id');
    }
    return FileBrowseMessage(
      action: action,
      sessionId: json['sessionId'] as String,
      clientPeerId: json['sourcePeerId'] as String,
      hostPeerId: json['sinkPeerId'] as String,
      requestId: requestId as int? ?? 0,
      payload: (payload as Map?)?.cast<String, Object?>() ?? const {},
    );
  }

  final FileBrowseAction action;
  final String sessionId;

  /// The device doing the browsing.
  final String clientPeerId;

  /// The device whose files are browsed.
  final String hostPeerId;
  final int requestId;
  final Map<String, Object?> payload;

  bool get isInitial => action == FileBrowseAction.open;

  bool get isTerminal =>
      action == FileBrowseAction.denied || action == FileBrowseAction.close;

  /// Host-to-client actions; everything else goes client-to-host.
  bool get fromHost =>
      action == FileBrowseAction.opened ||
      action == FileBrowseAction.denied ||
      action == FileBrowseAction.result ||
      action == FileBrowseAction.failed;

  FileBrowseMessage reply(
    FileBrowseAction action, [
    Map<String, Object?> payload = const {},
  ]) {
    return FileBrowseMessage(
      action: action,
      sessionId: sessionId,
      clientPeerId: clientPeerId,
      hostPeerId: hostPeerId,
      requestId: requestId,
      payload: payload,
    );
  }

  Map<String, Object?> toJson() => {
    'action': action.name,
    'sessionId': sessionId,
    'sourcePeerId': clientPeerId,
    'sinkPeerId': hostPeerId,
    if (requestId != 0) 'requestId': requestId,
    if (payload.isNotEmpty) 'payload': payload,
  };

  static final Set<String> allActions = {
    for (final action in FileBrowseAction.values) action.name,
  };
}

/// Ranged reads ([FileBrowseAction.read]).
abstract final class FileBrowseRead {
  /// What `opened` carries when the host answers reads.
  static const version = 1;

  /// The most one read may ask for: one frame.
  static const maxLength = 4 * 1024 * 1024;
}

/// Changes from a mounted folder ([FileBrowseAction.writeOpen] and the
/// rest).
abstract final class FileBrowseWrite {
  /// What `opened` carries when the host takes them.
  static const version = 1;

  /// The most one `browseWrite` frame may carry.
  static const maxLength = 4 * 1024 * 1024;
}

/// Why a request failed, as sent on the wire (never paths or messages).
abstract final class FileBrowseError {
  static const notFound = 'notFound';
  static const notAllowed = 'notAllowed';
  static const exists = 'exists';
  static const noTrash = 'noTrash';
  static const io = 'io';
  static const busy = 'busy';

  /// The host allows this device to read its files, not change them.
  static const readOnly = 'readOnly';

  /// A folder to remove still has something in it.
  static const notEmpty = 'notEmpty';

  /// Not a name the host's file system takes.
  static const badName = 'badName';
}
