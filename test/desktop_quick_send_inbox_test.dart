import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/desktop_quick_send_inbox.dart';

final String _hashA = 'A' * 43;
final String _hashB = 'B' * 43;

class _MemoryStore implements DesktopQuickSendStore {
  _MemoryStore() : drafts = <DesktopQuickSendDraft>[];

  List<DesktopQuickSendDraft> drafts;
  int saveCount = 0;
  bool failNextSave = false;

  @override
  Future<List<DesktopQuickSendDraft>> load() async => List.of(drafts);

  @override
  Future<void> save(List<DesktopQuickSendDraft> drafts) async {
    saveCount++;
    if (failNextSave) {
      failNextSave = false;
      throw const FileSystemException('injected save failure');
    }
    this.drafts = List.of(drafts);
  }
}

class _BlockingStore extends _MemoryStore {
  Completer<void>? saveGate;
  Completer<void>? saveStarted;

  @override
  Future<void> save(List<DesktopQuickSendDraft> drafts) async {
    saveStarted?.complete();
    await saveGate?.future;
    await super.save(drafts);
  }
}

class _FakePlatform implements DesktopQuickSendPlatform {
  DesktopQuickSendArgumentsHandler? handler;
  List<DesktopQuickSendNativeEntry> pending =
      const <DesktopQuickSendNativeEntry>[];
  final List<String> acknowledgements = <String>[];
  final List<bool> acknowledgementResults = <bool>[];

  @override
  Future<bool> acknowledge(String nativeEntryId) async {
    acknowledgements.add(nativeEntryId);
    return acknowledgementResults.isEmpty
        ? true
        : acknowledgementResults.removeAt(0);
  }

  @override
  Future<List<DesktopQuickSendNativeEntry>> consumePendingEntries() async =>
      pending;

  @override
  void setArgumentsHandler(DesktopQuickSendArgumentsHandler? handler) {
    this.handler = handler;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restored drafts stay quiet until a new quick-send request', () async {
    final store = _MemoryStore()
      ..drafts = <DesktopQuickSendDraft>[
        const DesktopQuickSendDraft(
          id: 'restored-draft',
          source: DesktopQuickSendSource.clipboardShortcut,
          text: 'old clipboard',
          filePaths: <String>[],
          receivedAt: 1,
        ),
      ];
    final inbox = DesktopQuickSendInbox(
      store: store,
      platform: _FakePlatform(),
    );

    await inbox.initialize();

    expect(inbox.hasPendingDrafts, isTrue);
    expect(inbox.takePresentationRequest(), isFalse);
    expect(
      (await inbox.addClipboard(
        text: 'new clipboard',
        filePaths: const [],
      )).isAccepted,
      isTrue,
    );
    expect(inbox.takePresentationRequest(), isTrue);
    expect(inbox.takePresentationRequest(), isFalse);
  });

  test(
    'current cold-start arguments request quick-send presentation',
    () async {
      final inbox = DesktopQuickSendInbox(
        store: _MemoryStore(),
        platform: _FakePlatform(),
      );

      await inbox.initialize(
        initialArguments: const <String>['--quick-send-text', 'send now'],
      );

      expect(inbox.takePresentationRequest(), isTrue);
    },
  );

  test(
    'native wake events drain the queue without replaying event arguments',
    () async {
      const channel = MethodChannel('test/desktop_quick_send');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var consumeCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'consumePendingQuickSends');
        consumeCount++;
        return consumeCount == 1
            ? <Map<String, Object?>>[
                <String, Object?>{
                  'id': 'native-once',
                  'arguments': <String>['--quick-send-text', 'queued once'],
                },
              ]
            : const <Map<String, Object?>>[];
      });
      final platform = MethodChannelDesktopQuickSendPlatform(channel: channel);
      final received = <List<String>>[];
      platform.setArgumentsHandler((entry) async {
        received.add(entry.arguments);
        return const DesktopQuickSendEnqueueResult.rejected(
          DesktopQuickSendRejection(
            reason: DesktopQuickSendRejectionReason.fileLimitExceeded,
            limit: desktopQuickSendMaxFilesPerDraft,
          ),
        );
      });
      addTearDown(() {
        platform.setArgumentsHandler(null);
        messenger.setMockMethodCallHandler(channel, null);
      });

      final event = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('quickSendReceived', <String>[
          '--quick-send-text',
          'must not be replayed',
        ]),
      );
      ByteData? firstResponse;
      await messenger.handlePlatformMessage(
        channel.name,
        event,
        (response) => firstResponse = response,
      );
      await messenger.handlePlatformMessage(channel.name, event, null);

      expect(received, <List<String>>[
        <String>['--quick-send-text', 'queued once'],
      ]);
      expect(consumeCount, 2);
      final decoded = const StandardMethodCodec().decodeEnvelope(
        firstResponse!,
      );
      expect(decoded, <Object?>[
        <String, Object?>{
          'id': 'native-once',
          'status': 'rejected',
          'rejection': <String, Object?>{
            'reason': 'fileLimitExceeded',
            'limit': desktopQuickSendMaxFilesPerDraft,
          },
        },
      ]);
    },
  );

  test(
    'native entry is acknowledged only after its draft is durable',
    () async {
      final store = _BlockingStore();
      final platform = _FakePlatform();
      final inbox = DesktopQuickSendInbox(
        store: store,
        platform: platform,
        now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      );
      await inbox.initialize();
      store.saveStarted = Completer<void>();
      store.saveGate = Completer<void>();

      final future = platform.handler!(
        const DesktopQuickSendNativeEntry.arguments(
          id: 'durable-event',
          arguments: <String>['--quick-send-text', 'persist before ack'],
        ),
      );
      await store.saveStarted!.future;

      expect(platform.acknowledgements, isEmpty);
      store.saveGate!.complete();
      expect((await future).isAccepted, isTrue);
      expect(platform.acknowledgements, <String>['durable-event']);
      expect(inbox.drafts.single.id, 'desktop-native-durable-event');
      expect(store.drafts.single.text, 'persist before ack');
    },
  );

  test(
    'redelivered native event uses its stable id and is deduplicated',
    () async {
      final store = _MemoryStore();
      final firstPlatform = _FakePlatform()
        ..pending = const <DesktopQuickSendNativeEntry>[
          DesktopQuickSendNativeEntry.arguments(
            id: 'stable-event',
            arguments: <String>['--quick-send-text', 'deliver once'],
          ),
        ];
      final firstInbox = DesktopQuickSendInbox(
        store: store,
        platform: firstPlatform,
        now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      );
      await firstInbox.initialize();
      expect(firstInbox.drafts.single.id, 'desktop-native-stable-event');

      final replayPlatform = _FakePlatform()..pending = firstPlatform.pending;
      final replayInbox = DesktopQuickSendInbox(
        store: store,
        platform: replayPlatform,
        now: () => DateTime.fromMillisecondsSinceEpoch(5678),
      );
      await replayInbox.initialize();

      expect(replayInbox.drafts, hasLength(1));
      expect(replayInbox.drafts.single.text, 'deliver once');
      expect(replayPlatform.acknowledgements, <String>['stable-event']);
    },
  );

  test('native rejection stays durable until the UI consumes it', () async {
    final platform = _FakePlatform()
      ..pending = const <DesktopQuickSendNativeEntry>[
        DesktopQuickSendNativeEntry.rejection(
          id: 'full-rejection',
          rejection: DesktopQuickSendRejection(
            reason: DesktopQuickSendRejectionReason.draftLimitExceeded,
            limit: desktopQuickSendMaxDrafts,
          ),
        ),
      ];
    final inbox = DesktopQuickSendInbox(
      store: _MemoryStore(),
      platform: platform,
    );
    await inbox.initialize();

    expect(platform.acknowledgements, isEmpty);
    expect(
      inbox.takePendingRejection()?.reason,
      DesktopQuickSendRejectionReason.draftLimitExceeded,
    );
    expect(platform.acknowledgements, isEmpty);
    expect(await inbox.acknowledgePresentedRejection(), isTrue);
    expect(platform.acknowledgements, <String>['full-rejection']);
  });

  test('native clipboard snapshot failure is a visible rejection', () async {
    final entry = DesktopQuickSendNativeEntry.fromPlatformValue(
      <Object?, Object?>{
        'id': 'clipboard-snapshot-rejection',
        'rejection': <Object?, Object?>{
          'reason': 'clipboardSnapshotUnavailable',
          'limit': 0,
        },
      },
    );
    expect(entry, isNotNull);
    final platform = _FakePlatform()
      ..pending = <DesktopQuickSendNativeEntry>[entry!];
    final inbox = DesktopQuickSendInbox(
      store: _MemoryStore(),
      platform: platform,
    );

    await inbox.initialize();

    expect(platform.acknowledgements, isEmpty);
    expect(
      inbox.takePendingRejection()?.reason,
      DesktopQuickSendRejectionReason.clipboardSnapshotUnavailable,
    );
    expect(await inbox.acknowledgePresentedRejection(), isTrue);
    expect(platform.acknowledgements, <String>['clipboard-snapshot-rejection']);
  });

  test('parser only accepts explicit quick-send arguments', () {
    final parsed = DesktopQuickSendArguments.parse(<String>[
      '--unrelated',
      '/tmp/not-shared.txt',
      '--quick-send-text',
      'hello',
      '--quick-send-file',
      '/tmp/shared.txt',
    ]);

    expect(parsed.text, 'hello');
    expect(parsed.filePaths, <String>['/tmp/shared.txt']);
    expect(parsed.captureClipboard, isFalse);
  });

  test(
    'bare quick-send command requests clipboard capture after cold start',
    () async {
      final store = _MemoryStore();
      final inbox = DesktopQuickSendInbox(
        store: store,
        platform: _FakePlatform(),
        now: () => DateTime.fromMillisecondsSinceEpoch(1234),
        idFactory: () => 'clipboard-draft',
      );

      await inbox.initialize(initialArguments: const <String>['--quick-send']);
      var captures = 0;
      await inbox.setClipboardCaptureHandler((nativeEntryId) async {
        expect(nativeEntryId, isNull);
        captures++;
        return inbox.addClipboard(
          text: 'clipboard text',
          filePaths: const <String>[],
        );
      });

      expect(captures, 1);
      expect(inbox.drafts.single.text, 'clipboard text');
      expect(
        DesktopQuickSendArguments.parse(const <String>[
          '--quick-send',
          '/tmp/report.pdf',
        ]).captureClipboard,
        isFalse,
      );
    },
  );

  test(
    'native clipboard capture is stable across failed ack and redelivery',
    () async {
      const nativeEntry = DesktopQuickSendNativeEntry.arguments(
        id: 'clipboard-native',
        arguments: <String>['--quick-send'],
      );
      final store = _MemoryStore();
      final firstPlatform = _FakePlatform()
        ..pending = const <DesktopQuickSendNativeEntry>[nativeEntry]
        ..acknowledgementResults.add(false);
      final firstInbox = DesktopQuickSendInbox(
        store: store,
        platform: firstPlatform,
        now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      );
      var firstCaptures = 0;
      await firstInbox.initialize();
      await firstInbox.setClipboardCaptureHandler((nativeEntryId) {
        firstCaptures++;
        return firstInbox.addClipboard(
          text: 'original clipboard',
          filePaths: const <String>[],
          nativeEntryId: nativeEntryId,
        );
      });

      expect(firstCaptures, 1);
      expect(firstPlatform.acknowledgements, <String>['clipboard-native']);
      expect(firstInbox.drafts.single.id, 'desktop-native-clipboard-native');
      expect(store.drafts.single.text, 'original clipboard');

      final replayPlatform = _FakePlatform()
        ..pending = const <DesktopQuickSendNativeEntry>[nativeEntry];
      final replayInbox = DesktopQuickSendInbox(
        store: store,
        platform: replayPlatform,
        now: () => DateTime.fromMillisecondsSinceEpoch(5678),
      );
      var replayCaptures = 0;
      await replayInbox.initialize();
      await replayInbox.setClipboardCaptureHandler((nativeEntryId) async {
        replayCaptures++;
        return replayInbox.addClipboard(
          text: 'changed clipboard',
          filePaths: const <String>[],
          nativeEntryId: nativeEntryId,
        );
      });

      expect(replayCaptures, 0);
      expect(replayPlatform.acknowledgements, <String>['clipboard-native']);
      expect(replayInbox.drafts, hasLength(1));
      expect(replayInbox.drafts.single.text, 'original clipboard');
    },
  );

  test('failed empty-capture ack retries without recapturing', () async {
    final platform = _FakePlatform()
      ..pending = const <DesktopQuickSendNativeEntry>[
        DesktopQuickSendNativeEntry.arguments(
          id: 'empty-clipboard-native',
          arguments: <String>['--quick-send'],
        ),
      ]
      ..acknowledgementResults.addAll(<bool>[false, true]);
    final inbox = DesktopQuickSendInbox(
      store: _MemoryStore(),
      platform: platform,
    );
    var captures = 0;
    Future<DesktopQuickSendEnqueueResult> capture(String? _) async {
      captures++;
      return const DesktopQuickSendEnqueueResult.empty();
    }

    await inbox.initialize();
    await inbox.setClipboardCaptureHandler(capture);
    expect(captures, 1);
    expect(platform.acknowledgements, <String>['empty-clipboard-native']);

    await inbox.setClipboardCaptureHandler(capture);
    expect(captures, 1);
    expect(platform.acknowledgements, <String>[
      'empty-clipboard-native',
      'empty-clipboard-native',
    ]);
  });

  test(
    'rejected native capture is acknowledged only after presentation',
    () async {
      final store = _MemoryStore()
        ..drafts = List<DesktopQuickSendDraft>.generate(
          desktopQuickSendMaxDrafts,
          (index) => DesktopQuickSendDraft(
            id: 'full-$index',
            source: DesktopQuickSendSource.systemService,
            text: 'pending-$index',
            filePaths: const <String>[],
            receivedAt: index + 1,
          ),
        );
      final platform = _FakePlatform()
        ..pending = const <DesktopQuickSendNativeEntry>[
          DesktopQuickSendNativeEntry.arguments(
            id: 'rejected-clipboard-native',
            arguments: <String>['--quick-send'],
          ),
        ];
      final inbox = DesktopQuickSendInbox(store: store, platform: platform);
      var captures = 0;

      await inbox.initialize();
      await inbox.setClipboardCaptureHandler((nativeEntryId) {
        captures++;
        return inbox.addClipboard(
          text: 'cannot fit',
          filePaths: const <String>[],
          nativeEntryId: nativeEntryId,
        );
      });

      expect(captures, 1);
      expect(platform.acknowledgements, isEmpty);
      expect(
        inbox.takePendingRejection()?.reason,
        DesktopQuickSendRejectionReason.draftLimitExceeded,
      );
      expect(platform.acknowledgements, isEmpty);
      expect(await inbox.acknowledgePresentedRejection(), isTrue);
      expect(platform.acknowledgements, <String>['rejected-clipboard-native']);

      await inbox.setClipboardCaptureHandler((_) async {
        captures++;
        return const DesktopQuickSendEnqueueResult.empty();
      });
      expect(captures, 1);
    },
  );

  test('startup and native payloads are persisted in one inbox', () async {
    final store = _MemoryStore();
    final platform = _FakePlatform()
      ..pending = <DesktopQuickSendNativeEntry>[
        const DesktopQuickSendNativeEntry.arguments(
          id: 'native-service',
          arguments: <String>['--quick-send-text', 'from service'],
        ),
      ];
    var nextId = 0;
    final inbox = DesktopQuickSendInbox(
      store: store,
      platform: platform,
      now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      idFactory: () => 'draft-${nextId++}',
    );

    await inbox.initialize(
      initialArguments: <String>['--quick-send-file', '/tmp/report.pdf'],
    );

    expect(inbox.drafts, hasLength(2));
    expect(inbox.drafts.first.filePaths, <String>['/tmp/report.pdf']);
    expect(inbox.drafts.last.text, 'from service');
    expect(store.saveCount, 1);
    expect(store.drafts, hasLength(2));
  });

  test(
    'accepted parts are removed while a failed file remains retryable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'whisper-quick-send',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = File('${directory.path}/first.txt');
      final second = File('${directory.path}/second.txt');
      await first.writeAsString('first');
      await second.writeAsString('second');
      final store = _MemoryStore();
      final inbox = DesktopQuickSendInbox(
        store: store,
        platform: _FakePlatform(),
        now: () => DateTime.fromMillisecondsSinceEpoch(1234),
        idFactory: () => 'draft',
      );
      await inbox.initialize(
        initialArguments: <String>[
          '--quick-send-text',
          'hello',
          '--quick-send-file',
          first.path,
          '--quick-send-file',
          second.path,
        ],
      );
      var sentTextCount = 0;
      final sentFiles = <String>[];

      final result = await inbox.sendPendingTo(
        peerId: 'trusted-peer',
        trustedIdentityHashFor: (_) => _hashA,
        sendText: (_, draftId, pinnedHash, text) async {
          expect(draftId, 'draft');
          expect(pinnedHash, _hashA);
          expect(text, 'hello');
          sentTextCount++;
          return true;
        },
        sendFile: (_, __, pinnedHash, path) async {
          expect(pinnedHash, _hashA);
          sentFiles.add(path);
          return path != second.path;
        },
      );

      expect(result.isComplete, isFalse);
      expect(result.failedPath, second.path);
      expect(sentTextCount, 1);
      expect(sentFiles, <String>[first.path, second.path]);
      expect(inbox.drafts.single.text, isEmpty);
      expect(inbox.drafts.single.filePaths, <String>[second.path]);
      expect(store.drafts.single.filePaths, <String>[second.path]);
    },
  );

  test('missing files stay pending instead of being discarded', () async {
    final inbox = DesktopQuickSendInbox(
      store: _MemoryStore(),
      platform: _FakePlatform(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      idFactory: () => 'draft',
    );
    await inbox.initialize(
      initialArguments: const <String>[
        '--quick-send-file',
        '/path/that/does/not/exist',
      ],
    );

    final result = await inbox.sendPendingTo(
      peerId: 'trusted-peer',
      trustedIdentityHashFor: (_) => _hashA,
      sendText: (_, __, ___, ____) async => true,
      sendFile: (_, __, ___, ____) async => true,
    );

    expect(result.remainingDrafts, 1);
    expect(inbox.drafts.single.filePaths, isNotEmpty);
  });

  test('text remains pending until its exact draft is acknowledged', () async {
    final store = _MemoryStore();
    final inbox = DesktopQuickSendInbox(
      store: store,
      platform: _FakePlatform(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      idFactory: () => 'stable-draft-id',
    );
    await inbox.initialize(
      initialArguments: const <String>['--quick-send-text', 'keep until ack'],
    );
    String? attemptedId;

    final result = await inbox.sendPendingTo(
      peerId: 'trusted-peer',
      trustedIdentityHashFor: (_) => _hashA,
      sendText: (_, draftId, pinnedHash, __) async {
        attemptedId = draftId;
        expect(pinnedHash, _hashA);
        expect(store.drafts.single.targetPeerId, 'trusted-peer');
        expect(store.drafts.single.pinnedPublicKeyHash, _hashA);
        return false;
      },
      sendFile: (_, __, ___, ____) async => true,
    );

    expect(attemptedId, 'stable-draft-id');
    expect(result.remainingDrafts, 1);
    expect(inbox.drafts.single.id, 'stable-draft-id');
    expect(inbox.drafts.single.text, 'keep until ack');
    expect(inbox.drafts.single.targetPeerId, 'trusted-peer');
    expect(inbox.drafts.single.pinnedPublicKeyHash, _hashA);
    expect(inbox.drafts.single.deliveredPeerId, isEmpty);
    expect(store.drafts.single.text, 'keep until ack');
  });

  test('partially sent draft cannot continue on another peer', () async {
    final directory = await Directory.systemTemp.createTemp(
      'whisper-quick-send-target',
    );
    addTearDown(() => directory.delete(recursive: true));
    final first = File('${directory.path}/first.txt');
    final second = File('${directory.path}/second.txt');
    await first.writeAsString('first');
    await second.writeAsString('second');
    final store = _MemoryStore();
    final inbox = DesktopQuickSendInbox(
      store: store,
      platform: _FakePlatform(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      idFactory: () => 'partial',
    );
    await inbox.initialize(
      initialArguments: <String>[
        '--quick-send-file',
        first.path,
        '--quick-send-file',
        second.path,
      ],
    );
    var fileAttempts = 0;

    final firstAttempt = await inbox.sendPendingTo(
      peerId: 'peer-a',
      trustedIdentityHashFor: (peerId) => peerId == 'peer-a' ? _hashA : _hashB,
      sendText: (_, __, ___, ____) async => true,
      sendFile: (_, __, ___, ____) async => ++fileAttempts == 1,
    );
    expect(firstAttempt.outcome, DesktopQuickSendOutcome.retained);
    expect(inbox.drafts.single.filePaths, <String>[second.path]);
    expect(inbox.drafts.single.deliveredPeerId, 'peer-a');
    final beforeConflict = inbox.drafts.single.toJson();

    final conflict = await inbox.sendPendingTo(
      peerId: 'peer-b',
      trustedIdentityHashFor: (peerId) => peerId == 'peer-a' ? _hashA : _hashB,
      sendText: (_, __, ___, ____) async => fail('text must not cross targets'),
      sendFile: (_, __, ___, ____) async => fail('file must not cross targets'),
    );

    expect(conflict.outcome, DesktopQuickSendOutcome.targetConflict);
    expect(inbox.drafts.single.toJson(), beforeConflict);
    expect(store.drafts.single.toJson(), beforeConflict);
  });

  test('identity change clears binding before the next part is sent', () async {
    final directory = await Directory.systemTemp.createTemp(
      'whisper-quick-send-identity',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/remaining.txt');
    await file.writeAsString('remaining');
    final store = _MemoryStore();
    final inbox = DesktopQuickSendInbox(
      store: store,
      platform: _FakePlatform(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      idFactory: () => 'identity-change',
    );
    await inbox.initialize(
      initialArguments: <String>[
        '--quick-send-text',
        'first part',
        '--quick-send-file',
        file.path,
      ],
    );
    var currentHash = _hashA;
    var fileAttempts = 0;

    final changed = await inbox.sendPendingTo(
      peerId: 'peer-a',
      trustedIdentityHashFor: (_) => currentHash,
      sendText: (_, __, ___, ____) async {
        currentHash = _hashB;
        return true;
      },
      sendFile: (_, __, ___, ____) async {
        fileAttempts++;
        return true;
      },
    );

    expect(changed.outcome, DesktopQuickSendOutcome.targetIdentityInvalid);
    expect(fileAttempts, 0);
    expect(inbox.drafts.single.text, isEmpty);
    expect(inbox.drafts.single.filePaths, <String>[file.path]);
    expect(inbox.drafts.single.targetPeerId, isEmpty);
    expect(inbox.drafts.single.pinnedPublicKeyHash, isEmpty);
    expect(inbox.drafts.single.deliveredPeerId, 'peer-a');
    expect(store.drafts.single.toJson(), inbox.drafts.single.toJson());

    final wrongPeer = await inbox.sendPendingTo(
      peerId: 'peer-b',
      trustedIdentityHashFor: (_) => _hashB,
      sendText: (_, __, ___, ____) async => true,
      sendFile: (_, __, ___, ____) async => true,
    );
    expect(wrongPeer.outcome, DesktopQuickSendOutcome.targetConflict);

    final reselected = await inbox.sendPendingTo(
      peerId: 'peer-a',
      trustedIdentityHashFor: (_) => _hashB,
      sendText: (_, __, ___, ____) async => true,
      sendFile: (_, __, ___, ____) async => false,
    );
    expect(reselected.outcome, DesktopQuickSendOutcome.retained);
    expect(inbox.drafts.single.targetPeerId, 'peer-a');
    expect(inbox.drafts.single.pinnedPublicKeyHash, _hashB);
  });

  test('cold start restores target and partial-delivery lock', () async {
    final directory = await Directory.systemTemp.createTemp(
      'whisper-quick-send-restored-target',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/pending.txt');
    await file.writeAsString('pending');
    final restored = DesktopQuickSendDraft.fromJson(
      DesktopQuickSendDraft(
        id: 'restored',
        source: DesktopQuickSendSource.systemService,
        text: '',
        filePaths: <String>[file.path],
        receivedAt: 1,
        targetPeerId: 'peer-a',
        pinnedPublicKeyHash: _hashA,
        deliveredPeerId: 'peer-a',
      ).toJson(),
    )!;
    final store = _MemoryStore()..drafts = <DesktopQuickSendDraft>[restored];
    final inbox = DesktopQuickSendInbox(
      store: store,
      platform: _FakePlatform(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      idFactory: () => 'unused',
    );
    await inbox.initialize();
    var sends = 0;

    final conflict = await inbox.sendPendingTo(
      peerId: 'peer-b',
      trustedIdentityHashFor: (peerId) => peerId == 'peer-a' ? _hashA : _hashB,
      sendText: (_, __, ___, ____) async => true,
      sendFile: (_, __, ___, ____) async {
        sends++;
        return true;
      },
    );
    expect(conflict.outcome, DesktopQuickSendOutcome.targetConflict);
    expect(sends, 0);
    expect(inbox.drafts.single.preferredTargetPeerId, 'peer-a');

    final invalid = await inbox.sendPendingTo(
      peerId: 'peer-a',
      trustedIdentityHashFor: (_) => _hashB,
      sendText: (_, __, ___, ____) async => true,
      sendFile: (_, __, ___, ____) async {
        sends++;
        return true;
      },
    );
    expect(invalid.outcome, DesktopQuickSendOutcome.targetIdentityInvalid);
    expect(sends, 0);
    expect(inbox.drafts.single.targetPeerId, isEmpty);
    expect(inbox.drafts.single.pinnedPublicKeyHash, isEmpty);
    expect(inbox.drafts.single.deliveredPeerId, 'peer-a');
    expect(store.drafts.single.targetPeerId, isEmpty);
  });

  test('folder arguments are rejected instead of packaged', () async {
    final directory = await Directory.systemTemp.createTemp(
      'whisper-quick-send-folder',
    );
    addTearDown(() => directory.delete(recursive: true));
    final inbox = DesktopQuickSendInbox(
      store: _MemoryStore(),
      platform: _FakePlatform(),
    );

    await inbox.initialize(
      initialArguments: <String>['--quick-send-file', directory.path],
    );

    expect(inbox.drafts, isEmpty);
    expect(
      inbox.takePendingRejection()?.reason,
      DesktopQuickSendRejectionReason.invalidPath,
    );
  });

  test('restart removes folders from previously persisted drafts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'whisper-quick-send-legacy-folder',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = _MemoryStore()
      ..drafts = <DesktopQuickSendDraft>[
        DesktopQuickSendDraft(
          id: 'legacy-folder',
          source: DesktopQuickSendSource.systemService,
          text: '',
          filePaths: <String>[directory.path],
          receivedAt: 1,
        ),
      ];
    final inbox = DesktopQuickSendInbox(
      store: store,
      platform: _FakePlatform(),
    );

    await inbox.initialize();

    expect(inbox.drafts, isEmpty);
    expect(store.drafts, isEmpty);
  });

  test(
    'full inbox rejects a new draft without deleting existing drafts',
    () async {
      final store = _MemoryStore();
      store.drafts = List<DesktopQuickSendDraft>.generate(
        desktopQuickSendMaxDrafts,
        (index) => DesktopQuickSendDraft(
          id: 'existing-$index',
          source: DesktopQuickSendSource.systemService,
          text: 'text-$index',
          filePaths: const <String>[],
          receivedAt: index + 1,
        ),
      );
      final platform = _FakePlatform();
      final inbox = DesktopQuickSendInbox(
        store: store,
        platform: platform,
        now: () => DateTime.fromMillisecondsSinceEpoch(1234),
        idFactory: () => 'must-not-be-created',
      );
      await inbox.initialize();
      final before = inbox.drafts;
      final saveCount = store.saveCount;

      final result = await platform.handler!(
        const DesktopQuickSendNativeEntry.arguments(
          id: 'native-full',
          arguments: <String>['--quick-send-text', 'new content'],
        ),
      );

      expect(result.status, DesktopQuickSendEnqueueStatus.rejected);
      expect(
        result.rejection?.reason,
        DesktopQuickSendRejectionReason.draftLimitExceeded,
      );
      expect(inbox.drafts, before);
      expect(store.drafts, before);
      expect(store.saveCount, saveCount);
      expect(inbox.takePendingRejection(), same(result.rejection));
    },
  );

  test('oversized text is rejected whole instead of being truncated', () async {
    final store = _MemoryStore()
      ..drafts = <DesktopQuickSendDraft>[
        const DesktopQuickSendDraft(
          id: 'existing',
          source: DesktopQuickSendSource.systemService,
          text: 'keep me',
          filePaths: <String>[],
          receivedAt: 1,
        ),
      ];
    final inbox = DesktopQuickSendInbox(
      store: store,
      platform: _FakePlatform(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      idFactory: () => 'oversized',
    );
    await inbox.initialize();
    final saveCount = store.saveCount;

    final result = await inbox.addSystemShare(
      text: 'x' * (desktopQuickSendMaxTextLength + 1),
    );

    expect(
      result.rejection?.reason,
      DesktopQuickSendRejectionReason.textLimitExceeded,
    );
    expect(inbox.drafts, hasLength(1));
    expect(inbox.drafts.single.text, 'keep me');
    expect(store.saveCount, saveCount);
  });

  test('too many or invalid paths reject the entire input', () async {
    final store = _MemoryStore();
    var nextId = 0;
    final inbox = DesktopQuickSendInbox(
      store: store,
      platform: _FakePlatform(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      idFactory: () => 'draft-${nextId++}',
    );
    await inbox.initialize();

    final tooMany = await inbox.addSystemShare(
      filePaths: List<String>.generate(
        desktopQuickSendMaxFilesPerDraft + 1,
        (index) => '/tmp/$index',
      ),
    );
    final invalid = await inbox.addSystemShare(
      filePaths: const <String>['/tmp/valid', 'bad\u0000path'],
    );
    final overlong = await inbox.addSystemShare(
      filePaths: <String>['p' * (desktopQuickSendMaxPathLength + 1)],
    );

    expect(
      tooMany.rejection?.reason,
      DesktopQuickSendRejectionReason.fileLimitExceeded,
    );
    expect(
      invalid.rejection?.reason,
      DesktopQuickSendRejectionReason.invalidPath,
    );
    expect(
      overlong.rejection?.reason,
      DesktopQuickSendRejectionReason.pathLimitExceeded,
    );
    expect(inbox.drafts, isEmpty);
    expect(store.drafts, isEmpty);
  });

  test('content exactly at every boundary is preserved verbatim', () async {
    final inbox = DesktopQuickSendInbox(
      store: _MemoryStore(),
      platform: _FakePlatform(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      idFactory: () => 'boundary',
    );
    await inbox.initialize();
    final text = 'x' * desktopQuickSendMaxTextLength;
    final paths = List<String>.generate(desktopQuickSendMaxFilesPerDraft, (
      index,
    ) {
      final suffix = '$index';
      return '${'p' * (desktopQuickSendMaxPathLength - suffix.length)}$suffix';
    });

    final result = await inbox.addSystemShare(text: text, filePaths: paths);

    expect(result.isAccepted, isTrue);
    expect(inbox.drafts.single.text, text);
    expect(inbox.drafts.single.filePaths, paths);
  });
}
