import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations_en.dart';
import 'package:whisper/new_ui/shell/shell_device_drop.dart';
import 'package:whisper/socket/file_transfer_engine.dart';

void main() {
  group('what a dragged file message is', () {
    test('its data says which conversation it came from', () {
      expect(chatDragPeerOf([chatMessageDragData('imac', '/a.jpg')]), 'imac');
      expect(chatDragPeerOf([null, 'other']), isNull);
      expect(chatDragPeerOf(const []), isNull);
    });
  });

  group('a device in the list', () {
    bool takes({
      bool connected = true,
      String? from,
      bool canCopy = true,
      bool onlyFiles = true,
    }) => deviceTakesDrop(
      connected: connected,
      peerId: 'imac',
      fromPeer: from,
      canCopy: canCopy,
      onlyFiles: onlyFiles,
    );

    test('takes a message from another conversation', () {
      expect(takes(from: 'phone'), isTrue);
    });

    test('takes files from elsewhere', () {
      expect(takes(), isTrue);
    });

    test('does not take a message back to its own conversation', () {
      expect(takes(from: 'imac'), isFalse);
    });

    test('does not take anything while it is not connected', () {
      expect(takes(connected: false, from: 'phone'), isFalse);
      expect(takes(connected: false), isFalse);
    });

    test('does not take what is not files', () {
      expect(takes(onlyFiles: false), isFalse);
      expect(takes(canCopy: false), isFalse);
    });
  });

  group('sending what was dropped', () {
    late Directory dir;
    final l10n = AppLocalizationsEn();

    setUp(() => dir = Directory.systemTemp.createTempSync('drop'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('files and folders each go their own way', () async {
      final file = File('${dir.path}/a.txt')..writeAsStringSync('a');
      final folder = Directory('${dir.path}/b')..createSync();
      final files = <String>[], folders = <String>[];
      final sent = await sendDroppedPaths(
        paths: [file.path, folder.path],
        l10n: l10n,
        sendFile: (path) async {
          files.add(path);
          return true;
        },
        sendFolder: (path) async {
          folders.add(path);
          return FolderSendOutcome.sent;
        },
      );
      expect(sent, isTrue);
      expect(files, [file.path]);
      expect(folders, [folder.path]);
    });
  });
}
