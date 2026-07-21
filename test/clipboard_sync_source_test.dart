import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clipboard watcher reads text through the text-only sync guard', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(
      source,
      contains("import 'package:whisper/helper/clipboard_sync.dart';"),
    );
    expect(source, contains('final text = await readClipboardTextForSync('));
    expect(source, contains('await _clipboardImageReader.readImageBytes()'));
    expect(source, contains('if (text == null)'));
  });

  test('manual clipboard message send uses the text-only sync guard', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(
      source,
      contains("import 'package:whisper/helper/clipboard_sync.dart';"),
    );
    expect(
      source,
      contains('var str = await readClipboardTextForSync() ?? "";'),
    );
  });

  test('remote clipboard writes await source-aware suppression', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('await copyToClipboard('));
    expect(source, contains('sourcePeerId: session.remotePeerId'));
  });

  test('remote clipboard follows connected keyboard workspace targets', () {
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final workspace = File(
      'lib/remote_input/remote_input_workspace_coordinator.dart',
    ).readAsStringSync();

    expect(deviceList, contains('workspace.targets.values'));
    expect(deviceList, contains('target.isConnected'));
    expect(deviceList, contains('workspaceTarget?.sessionId == sessionId'));
    expect(workspace, contains('manager: RemoteInputManager.shared'));
    expect(workspace, contains('remoteClipboardV1:'));
  });

  test('clipboard sync text bypasses chat persistence and dispatch', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(
      source,
      contains('message.type == MessageEnum.Text && !message.clipboard'),
    );
    expect(source, contains('if (clipboard) {'));
    expect(source, contains('return _sendMessageData(draft, peerId: peerId)'));
    final textCase = source.substring(
      source.indexOf('case MessageEnum.Text:'),
      source.indexOf('case MessageEnum.Notification:'),
    );
    final clipboardBranch = textCase.substring(
      textCase.indexOf('if (message.clipboard)'),
      textCase.indexOf('_dispatchToAll'),
    );
    expect(clipboardBranch, contains('await _ackMessage(message)'));
    expect(clipboardBranch, contains('return;'));
  });
}
