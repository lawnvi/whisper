import 'dart:io';

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';

bool canDeleteReceivedMessageFile(MessageData message, String? selfUid) =>
    selfUid != null &&
    message.type == MessageEnum.File &&
    message.receiver == selfUid &&
    message.sender != selfUid;

Future<void> deleteReceivedMessageFile(
  MessageData message, {
  required String? selfUid,
  required String path,
}) async {
  // Enforce ownership here as well as in the confirmation UI. Sent originals
  // and the transfer assistant's local files must never be removed.
  if (!canDeleteReceivedMessageFile(message, selfUid) || path.isEmpty) return;
  final file = File(path);
  if (!await file.exists()) return;
  try {
    await file.delete();
  } on FileSystemException {
    // Another process may have removed the file after the existence check.
    if (await file.exists()) rethrow;
  }
}
