import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';

/// 我的记录: a conversation with this device, for when there is nobody else.
/// Nothing leaves it, so a message is only a row, and an empty `receiver` is what
/// tells it from one sent to someone.
class SelfNotes {
  const SelfNotes(this._db);

  final LocalDatabase _db;

  Future<MessageData> addText(String selfUid, String text) =>
      _add(selfUid, type: MessageEnum.Text, content: text);

  /// [draft] files live in a temporary folder, a screenshot for one: they are
  /// kept where received files go. Anything else is only pointed at, as a file
  /// that was sent is.
  Future<MessageData> addFile(
    String selfUid,
    String path, {
    String? name,
    int? size,
    bool draft = false,
  }) async {
    final kept = draft ? await _keep(path) : path;
    return _add(
      selfUid,
      type: MessageEnum.File,
      name: name ?? p.basename(kept),
      size: size ?? await File(kept).length(),
      path: kept,
    );
  }

  Future<String> _keep(String path) async {
    final directory = await downloadDir();
    final extension = p.extension(path);
    final stem = p.basenameWithoutExtension(path);
    var target = File(p.join(directory.path, '$stem$extension'));
    for (var suffix = 2; await target.exists(); suffix++) {
      target = File(p.join(directory.path, '$stem-$suffix$extension'));
    }
    await File(path).copy(target.path);
    return target.path;
  }

  Future<MessageData> _add(
    String selfUid, {
    required MessageEnum type,
    String name = '',
    int size = 0,
    String content = '',
    String path = '',
  }) => _db.insertMessageReturning(
    MessageData(
      id: 0,
      sender: selfUid,
      receiver: '',
      name: name,
      clipboard: false,
      size: size,
      type: type,
      content: content,
      message: '',
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      acked: true,
      uuid: const Uuid().v4(),
      path: path,
      md5: '',
    ),
    acked: true,
  );
}
