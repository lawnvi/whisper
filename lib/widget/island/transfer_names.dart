import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../model/LocalDatabase.dart';
import '../../model/file_transfer.dart';

/// The names of files on their way, as the conversation shows them: from
/// the transfer's message (a folder sent as one stream, a file shared from
/// another app that was staged under an internal name, a file still
/// arriving under a temporary one all have their real name there).
class TransferNames {
  TransferNames({Future<String?> Function(String messageUuid)? lookup})
    : _lookup = lookup ?? _fromDatabase;

  static final TransferNames shared = TransferNames();

  final Future<String?> Function(String messageUuid) _lookup;
  final _names = <String, String>{};
  final _asked = <String>{};
  final _found = StreamController<String>.broadcast();

  /// A transfer id whose name just became known.
  Stream<String> get found => _found.stream;

  /// The name of [snapshot]'s file, if known yet (asks once otherwise).
  String? nameOf(TransferSnapshot snapshot) {
    final known = _names[snapshot.transferId];
    if (known != null) {
      return known;
    }
    if (_asked.add(snapshot.transferId)) {
      unawaited(_ask(snapshot));
    }
    return null;
  }

  Future<void> _ask(TransferSnapshot snapshot) async {
    String? name;
    try {
      name = await _lookup(snapshot.messageUuid);
    } catch (_) {
      name = null;
    }
    name = name?.trim();
    if (name == null || name.isEmpty) {
      name = _fromPath(snapshot);
    }
    if (name == null || name.isEmpty) {
      return;
    }
    _names[snapshot.transferId] = name;
    if (_names.length > 512) {
      _names.remove(_names.keys.first);
    }
    _found.add(snapshot.transferId);
  }

  /// A file sent from where it lies keeps its own name; staged copies and
  /// incoming files do not say theirs in the path.
  static String? _fromPath(TransferSnapshot snapshot) {
    final path = snapshot.finalPath;
    if (snapshot.direction != FileTransferDirection.outgoing ||
        path.isEmpty ||
        path.contains('://')) {
      return null;
    }
    return p.basename(path);
  }

  static Future<String?> _fromDatabase(String messageUuid) async {
    // The island and the notifications are phone things; elsewhere (and
    // in tests) there is no reason to open the database for them.
    if (!(Platform.isAndroid || Platform.isIOS) || messageUuid.isEmpty) {
      return null;
    }
    final message = await LocalDatabase().fetchMessageByUuid(messageUuid);
    return message?.name;
  }
}
