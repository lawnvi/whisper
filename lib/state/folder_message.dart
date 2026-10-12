import 'dart:convert';

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/file_transfer_v3.dart';

final Map<String, FolderOfferSummary?> _summaries =
    <String, FolderOfferSummary?>{};
const int _summaryCacheLimit = 256;

/// What a file message says about the folder it carries, or null when it
/// carries a single file. A folder travels as a file message whose offer
/// names the folder checksum scheme.
FolderOfferSummary? folderOfferOf(MessageData message) {
  final content = message.content;
  if (message.type != MessageEnum.File ||
      content == null ||
      !content.contains(fileTransferFolderChecksumAlgorithm)) {
    return null;
  }
  if (_summaries.containsKey(content)) {
    return _summaries[content];
  }
  FolderOfferSummary? summary;
  try {
    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic> &&
        decoded['checksumAlgorithm'] == fileTransferFolderChecksumAlgorithm) {
      summary = FolderOfferSummary.tryParse(decoded['folder']);
    }
  } on FormatException {
    summary = null;
  }
  if (_summaries.length >= _summaryCacheLimit) {
    _summaries.remove(_summaries.keys.first);
  }
  return _summaries[content] = summary;
}
