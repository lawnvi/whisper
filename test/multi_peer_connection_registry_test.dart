import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/peer_connection.dart';

void main() {
  group('PeerConnectionRegistry', () {
    test('keeps multiple authenticated peers connected at the same time', () {
      final registry = PeerConnectionRegistry();

      registry.register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 1,
          send: (_) {},
          close: () async {},
        ),
      );
      registry.register(
        PeerConnection(
          peerId: 'peer-c',
          connectionId: 2,
          send: (_) {},
          close: () async {},
        ),
      );

      expect(registry.connectedPeerIds, {'peer-b', 'peer-c'});
      expect(registry.isConnectedTo('peer-b'), isTrue);
      expect(registry.isConnectedTo('peer-c'), isTrue);
    });

    test(
      'disconnecting one peer does not affect other connected peers',
      () async {
        final registry = PeerConnectionRegistry();
        var closedB = false;
        var closedC = false;

        registry.register(
          PeerConnection(
            peerId: 'peer-b',
            connectionId: 1,
            send: (_) {},
            close: () async {
              closedB = true;
            },
          ),
        );
        registry.register(
          PeerConnection(
            peerId: 'peer-c',
            connectionId: 2,
            send: (_) {},
            close: () async {
              closedC = true;
            },
          ),
        );

        await registry.disconnect('peer-b');

        expect(closedB, isTrue);
        expect(closedC, isFalse);
        expect(registry.connectedPeerIds, {'peer-c'});
      },
    );

    test('replacing a duplicate peer closes the old connection', () async {
      final registry = PeerConnectionRegistry();
      var oldClosed = false;
      var newClosed = false;

      registry.register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 1,
          send: (_) {},
          close: () async {
            oldClosed = true;
          },
        ),
      );
      await registry.register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 2,
          send: (_) {},
          close: () async {
            newClosed = true;
          },
        ),
      );

      expect(oldClosed, isTrue);
      expect(newClosed, isFalse);
      expect(registry.connectedPeerIds, {'peer-b'});

      await registry.disconnect('peer-b');
      expect(newClosed, isTrue);
    });

    test(
      'direct replacement runs old cleanup before publishing the new generation',
      () async {
        final registry = PeerConnectionRegistry();
        final cleanupStarted = Completer<void>();
        final releaseCleanup = Completer<void>();
        final events = <String>[];
        await registry.register(
          PeerConnection(
            peerId: 'peer-b',
            connectionId: 1,
            send: (_) {},
            close: () async => events.add('old-close'),
          ),
        );

        final replacementRegistration = registry.register(
          PeerConnection(
            peerId: 'peer-b',
            connectionId: 2,
            send: (_) {},
            close: () async {},
          ),
          afterRemove: (binding) async {
            expect(binding.generation, 1);
            events.add('old-cleanup');
            cleanupStarted.complete();
            await releaseCleanup.future;
            expect(registry.connection('peer-b'), isNull);
          },
          afterRegister: (binding) {
            expect(binding.generation, 2);
            expect(registry.connection('peer-b'), isNull);
            events.add('new-register');
          },
        );
        await cleanupStarted.future;

        expect(registry.connection('peer-b'), isNull);
        expect(events, <String>['old-close', 'old-cleanup']);

        releaseCleanup.complete();
        await replacementRegistration;

        expect(events, <String>['old-close', 'old-cleanup', 'new-register']);
        expect(registry.currentBinding('peer-b')?.generation, 2);
      },
    );

    test('afterRegister failure closes the unpublished connection', () async {
      final registry = PeerConnectionRegistry();
      const binding = TransferConnectionBinding(
        peerId: 'peer-b',
        generation: 9,
      );
      var callbackSawPublishedConnection = false;
      var closed = false;
      Future<bool>? closeTriggeredRemoval;
      final connection = PeerConnection(
        peerId: binding.peerId,
        connectionId: binding.generation,
        send: (_) {},
        close: () async {
          closed = true;
          closeTriggeredRemoval = registry.removeIfCurrent(binding);
          expect(await closeTriggeredRemoval!, isFalse);
        },
      );

      await expectLater(
        registry.register(
          connection,
          afterRegister: (_) {
            callbackSawPublishedConnection =
                registry.connection(binding.peerId) != null;
            throw StateError('stale registration');
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(callbackSawPublishedConnection, isFalse);
      expect(closed, isTrue);
      expect(await closeTriggeredRemoval, isFalse);
      expect(registry.connection(binding.peerId), isNull);
      expect(registry.currentBinding(binding.peerId), isNull);
    });

    test('old connection cleanup cannot remove its replacement', () async {
      final registry = PeerConnectionRegistry();
      Future<bool>? oldCleanup;

      await registry.register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 1,
          send: (_) {},
          close: () async {
            oldCleanup = registry.removeIfCurrent(
              const TransferConnectionBinding(peerId: 'peer-b', generation: 1),
            );
          },
        ),
      );
      final replacement = PeerConnection(
        peerId: 'peer-b',
        connectionId: 2,
        send: (_) {},
        close: () async {},
      );

      await registry.register(replacement);

      expect(await oldCleanup!, isFalse);
      expect(registry.connection('peer-b'), same(replacement));
      expect(registry.isCurrent('peer-b', 2), isTrue);
      expect(registry.isConnectedTo('peer-b'), isTrue);
    });

    test('removeIfCurrent removes only the matching generation', () async {
      final registry = PeerConnectionRegistry();
      var closes = 0;
      await registry.register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 7,
          send: (_) {},
          close: () async => closes += 1,
        ),
      );

      expect(
        await registry.removeIfCurrent(
          const TransferConnectionBinding(peerId: 'peer-b', generation: 6),
        ),
        isFalse,
      );
      expect(registry.isConnectedTo('peer-b'), isTrue);
      expect(
        await registry.removeIfCurrent(
          const TransferConnectionBinding(peerId: 'peer-b', generation: 7),
        ),
        isTrue,
      );
      expect(registry.isConnectedTo('peer-b'), isFalse);
      expect(closes, 1);
    });

    test('sendIfCurrent queues only on the matching generation', () async {
      final registry = PeerConnectionRegistry();
      final sent = <Object>[];
      await registry.register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 7,
          send: sent.add,
          close: () async {},
        ),
      );

      expect(
        registry.sendIfCurrent(
          const TransferConnectionBinding(peerId: 'peer-b', generation: 7),
          'frame',
        ),
        isTrue,
      );
      expect(
        registry.sendIfCurrent(
          const TransferConnectionBinding(peerId: 'peer-b', generation: 6),
          'stale',
        ),
        isFalse,
      );
      expect(sent, <Object>['frame']);
    });

    test('mismatched binding never closes or runs afterRemove', () async {
      final registry = PeerConnectionRegistry();
      var closes = 0;
      var cleanups = 0;
      await registry.register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 7,
          send: (_) {},
          close: () async => closes += 1,
        ),
      );

      final removed = await registry.removeIfCurrent(
        const TransferConnectionBinding(peerId: 'peer-b', generation: 6),
        afterRemove: (_) => cleanups += 1,
      );

      expect(removed, isFalse);
      expect(closes, 0);
      expect(cleanups, 0);
      expect(registry.isCurrent('peer-b', 7), isTrue);
    });

    test('replacement waits for old close and post-remove cleanup', () async {
      final registry = PeerConnectionRegistry();
      final closeStarted = Completer<void>();
      final releaseClose = Completer<void>();
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();
      var replacementRegistered = false;
      await registry.register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 1,
          send: (_) {},
          close: () async {
            closeStarted.complete();
            await releaseClose.future;
          },
        ),
      );

      final removal = registry.removeIfCurrent(
        const TransferConnectionBinding(peerId: 'peer-b', generation: 1),
        afterRemove: (_) async {
          cleanupStarted.complete();
          await releaseCleanup.future;
        },
      );
      await closeStarted.future;
      final replacementRegistration = registry.register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 2,
          send: (_) {},
          close: () async {},
        ),
        afterRegister: (_) => replacementRegistered = true,
      );
      await pumpEventQueue();

      expect(registry.connection('peer-b'), isNull);
      expect(replacementRegistered, isFalse);
      releaseClose.complete();
      await cleanupStarted.future;
      await pumpEventQueue();
      expect(registry.connection('peer-b'), isNull);
      expect(replacementRegistered, isFalse);

      releaseCleanup.complete();
      expect(await removal, isTrue);
      await replacementRegistration;
      expect(registry.isCurrent('peer-b', 2), isTrue);
      expect(replacementRegistered, isTrue);
    });

    test('a blocked peer lifecycle does not delay another peer', () async {
      final registry = PeerConnectionRegistry();
      final closeStarted = Completer<void>();
      final releaseClose = Completer<void>();
      await registry.register(
        PeerConnection(
          peerId: 'peer-b',
          connectionId: 1,
          send: (_) {},
          close: () async {
            closeStarted.complete();
            await releaseClose.future;
          },
        ),
      );

      final removal = registry.removeIfCurrent(
        const TransferConnectionBinding(peerId: 'peer-b', generation: 1),
      );
      await closeStarted.future;
      await registry.register(
        PeerConnection(
          peerId: 'peer-c',
          connectionId: 1,
          send: (_) {},
          close: () async {},
        ),
      );

      expect(registry.isCurrent('peer-c', 1), isTrue);
      releaseClose.complete();
      expect(await removal, isTrue);
    });

    test(
      'generation-bound awaited send never falls through to replacement',
      () async {
        final registry = PeerConnectionRegistry();
        final sendStarted = Completer<void>();
        final releaseSend = Completer<void>();
        final replacementMessages = <Object>[];
        const oldBinding = TransferConnectionBinding(
          peerId: 'peer-b',
          generation: 1,
        );
        await registry.register(
          PeerConnection(
            peerId: 'peer-b',
            connectionId: 1,
            send: (_) {},
            sendAsync: (_) async {
              sendStarted.complete();
              await releaseSend.future;
              return true;
            },
            close: () async {},
          ),
        );

        final send = registry.sendToAwaitedIfCurrent(oldBinding, 'payload');
        await sendStarted.future;
        await registry.register(
          PeerConnection(
            peerId: 'peer-b',
            connectionId: 2,
            send: replacementMessages.add,
            close: () async {},
          ),
        );
        releaseSend.complete();

        expect(await send, isFalse);
        expect(replacementMessages, isEmpty);
        expect(registry.currentBinding('peer-b')?.generation, 2);
      },
    );

    test(
      'close-triggered onDone removal is a no-op without deadlock',
      () async {
        final registry = PeerConnectionRegistry();
        const oldBinding = TransferConnectionBinding(
          peerId: 'peer-b',
          generation: 1,
        );
        await registry.register(
          PeerConnection(
            peerId: 'peer-b',
            connectionId: 1,
            send: (_) {},
            close: () async {
              expect(await registry.removeIfCurrent(oldBinding), isFalse);
            },
          ),
        );

        await registry.register(
          PeerConnection(
            peerId: 'peer-b',
            connectionId: 2,
            send: (_) {},
            close: () async {},
          ),
        );

        expect(registry.isCurrent('peer-b', 2), isTrue);
      },
    );
  });
}
