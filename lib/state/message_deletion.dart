import 'dart:io';

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/folder_message.dart';

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
  if (folderOfferOf(message) != null) {
    // Only a folder message may take a directory with it, and only the
    // directory itself: a link standing in its place is left alone.
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    try {
      await Directory(path).delete(recursive: true);
    } on FileSystemException {
      if (await Directory(path).exists()) rethrow;
    }
    return;
  }
  final file = File(path);
  if (!await file.exists()) return;
  try {
    await file.delete();
  } on FileSystemException {
    // Another process may have removed the file after the existence check.
    if (await file.exists()) rethrow;
  }
}
