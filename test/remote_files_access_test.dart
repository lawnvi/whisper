import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/page/remote_files/files_model.dart';
import 'package:whisper/remote_files/fs_browser.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/remote_files/fs_protocol.dart';

/// Answers every question with [decision], counting them.
class _Gate extends FileBrowseGate {
  _Gate(this.decision);

  FileBrowseDecision decision;
  int asked = 0;

  @override
  Future<FileBrowseDecision> ask(FileBrowseRequest request) async {
    asked++;
    return decision;
  }
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  late Directory home;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    home = await Directory.systemTemp.createTemp('whisper-files-access-');
    await File(p.join(home.path, 'a.txt')).writeAsString('a');
  });

  tearDown(() => home.delete(recursive: true));

  FsHostFiles files(String directory) => FsHostFiles(
    resolver: FsPathResolver([FsRoot(id: 'home', directory: directory)]),
  );

  /// The phone (host) and this Mac (asking), over a loopback "connection".
  FileBrowseHost wire(FileBrowseGate gate) {
    final host = FileBrowseHost(files: files(home.path), gate: gate);
    host.sender = (peerId, message) async {
      final copy = FileBrowseMessage.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      scheduleMicrotask(
        () => RemoteFilesClient.handle(copy, remotePeerId: 'phone'),
      );
      return true;
    };
    RemoteFilesClient.localPeerId = (_) => 'mac';
    RemoteFilesClient.sender = (peerId, message) async {
      final copy = FileBrowseMessage.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      scheduleMicrotask(
        () => host.handle(copy, remotePeerId: 'mac', deviceName: 'Mac'),
      );
      return true;
    };
    return host;
  }

  test(
    'allowed once, a device is not asked again until it disconnects',
    () async {
      final gate = _Gate(FileBrowseDecision.once);
      final host = wire(gate);

      final first = RemoteFilesClient('phone');
      await first.open();
      await first.close();
      // Back to the app and into the file manager again: still allowed.
      final second = RemoteFilesClient('phone');
      await second.open();
      expect(gate.asked, 1);
      await second.close();

      host.closePeer('mac');
      final third = RemoteFilesClient('phone');
      await third.open();
      expect(gate.asked, 2);
      await third.close();
    },
  );

  test('a refusal is asked again, and "always" needs no connection', () async {
    final gate = _Gate(FileBrowseDecision.deny);
    final host = wire(gate);
    await expectLater(
      RemoteFilesClient('phone').open(),
      throwsA(
        isA<RemoteFsException>().having((e) => e.reason, 'reason', 'denied'),
      ),
    );
    gate.decision = FileBrowseDecision.always;
    await RemoteFilesClient('phone').open();
    host.closePeer('mac');
    await RemoteFilesClient('phone').open();
    expect(gate.asked, 2);
  });

  test('silence there is told apart from a refusal', () async {
    wire(_Gate(FileBrowseDecision.noAnswer));
    await expectLater(
      RemoteFilesClient('phone').open(),
      throwsA(
        isA<RemoteFsException>().having((e) => e.reason, 'reason', 'noAnswer'),
      ),
    );
  });

  test('giving up waiting takes the question away there', () async {
    final gate = FileBrowseGate();
    final host = wire(gate);
    final client = RemoteFilesClient('phone');
    final outcome = expectLater(
      client.open(),
      throwsA(
        isA<RemoteFsException>().having((e) => e.reason, 'reason', 'canceled'),
      ),
    );
    await _until(() => gate.pending != null);
    await client.cancelOpen();
    await outcome;
    await _until(() => gate.pending == null);
    expect(host.isOpen(client.sessionId), isFalse);
  });

  group('the file manager', () {
    FilesController controllerWith(FileBrowseGate gate) {
      wire(gate);
      return FilesController(
        local: LocalFsBrowser(files: files(home.path)),
        peers: FilesPeers(
          connected: () => {'phone'},
          canBrowse: (_) => true,
          describe: (_) => (name: 'OnePlus', platform: 'android'),
        ),
      );
    }

    test('shows no answer as its own state, ready to ask again', () async {
      final gate = _Gate(FileBrowseDecision.noAnswer);
      final controller = controllerWith(gate);
      addTearDown(controller.dispose);
      await _until(() => controller.entries.isNotEmpty);
      final phone = controller.deviceById('phone')!;
      await controller.open(phone);
      expect(phone.state, FilesDeviceState.noAnswer);

      gate.decision = FileBrowseDecision.once;
      await controller.retry();
      expect(phone.state, FilesDeviceState.ready);
    });

    test('can stop waiting for the other device', () async {
      final gate = FileBrowseGate();
      final controller = controllerWith(gate);
      addTearDown(controller.dispose);
      await _until(() => controller.entries.isNotEmpty);
      final phone = controller.deviceById('phone')!;
      final opening = controller.open(phone);
      await _until(() => gate.pending != null);
      expect(phone.state, FilesDeviceState.waiting);

      await controller.cancelOpen(phone);
      await opening;
      expect(phone.state, FilesDeviceState.idle);
      await _until(() => gate.pending == null);
    });
  });
}
