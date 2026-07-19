import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';

const _messageId = '01234567-89ab-4cde-8fab-0123456789ab';

MessageData _message({
  MessageEnum type = MessageEnum.Text,
  String uuid = _messageId,
  String sender = 'peer-a',
  String receiver = 'local',
  bool acked = false,
  String content = 'hello',
}) {
  return MessageData(
    id: 0,
    sender: sender,
    receiver: receiver,
    name: '',
    clipboard: false,
    size: 0,
    type: type,
    content: content,
    message: '',
    timestamp: 1,
    uuid: uuid,
    acked: acked,
    path: '',
    md5: '',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('canonical wire identifiers', () {
    test('accepts only lowercase canonical UUID text', () {
      expect(isCanonicalTransferId(_messageId), isTrue);
      expect(isCanonicalTransferId(''), isFalse);
      expect(isCanonicalTransferId('transfer-1'), isFalse);
      expect(
        isCanonicalTransferId('../../$_messageId'),
        isFalse,
      );
      expect(
        isCanonicalTransferId(_messageId.toUpperCase()),
        isFalse,
      );
      expect(
        isCanonicalTransferId('${_messageId}0'),
        isFalse,
      );
    });
  });

  group('WireInputPolicy.validateMessage', () {
    test('accepts a bound authenticated business message', () {
      expect(
        WireInputPolicy.validateMessage(
          _message(),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).isAccepted,
        isTrue,
      );
    });

    test('rejects sender and receiver substitution with stable reasons', () {
      expect(
        WireInputPolicy.validateMessage(
          _message(sender: 'peer-b'),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).reason,
        WireInputReason.messageSenderMismatch,
      );
      expect(
        WireInputPolicy.validateMessage(
          _message(receiver: 'other-local'),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).reason,
        WireInputReason.messageReceiverMismatch,
      );
    });

    test('rejects an empty or non-canonical business UUID', () {
      for (final uuid in <String>['', 'message-1', _messageId.toUpperCase()]) {
        expect(
          WireInputPolicy.validateMessage(
            _message(uuid: uuid),
            authenticatedPeerId: 'peer-a',
            localPeerId: 'local',
          ).reason,
          WireInputReason.messageIdInvalid,
        );
      }
    });

    test('rejects unknown and standalone legacy file message types', () {
      for (final type in <MessageEnum>[
        MessageEnum.UNKONWN,
        MessageEnum.File,
        MessageEnum.FileSignal,
        MessageEnum.TransferControl,
      ]) {
        expect(
          WireInputPolicy.validateMessage(
            _message(type: type),
            authenticatedPeerId: 'peer-a',
            localPeerId: 'local',
          ).reason,
          WireInputReason.messageTypeInvalid,
        );
      }
    });

    test('leaves pre-auth Auth envelopes to the handshake state machine', () {
      expect(
        WireInputPolicy.validateMessage(
          _message(
            type: MessageEnum.Auth,
            uuid: '',
            sender: '',
            receiver: '',
          ),
          authenticatedPeerId: '',
          localPeerId: 'local',
        ).isAccepted,
        isTrue,
      );
    });
  });

  test('nested peer profile cannot claim another authenticated identity', () {
    expect(
      WireInputPolicy.validateClaimedPeerId(
        claimedPeerId: 'peer-a',
        authenticatedPeerId: 'peer-a',
      ).isAccepted,
      isTrue,
    );
    expect(
      WireInputPolicy.validateClaimedPeerId(
        claimedPeerId: 'peer-b',
        authenticatedPeerId: 'peer-a',
      ).reason,
      WireInputReason.messageSenderMismatch,
    );
  });

  test('nested control endpoints must be the authenticated peer and local peer',
      () {
    for (final pair in <({String source, String sink})>[
      (source: 'peer-a', sink: 'local'),
      (source: 'local', sink: 'peer-a'),
    ]) {
      expect(
        WireInputPolicy.validatePeerPair(
          sourcePeerId: pair.source,
          sinkPeerId: pair.sink,
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).isAccepted,
        isTrue,
      );
    }
    expect(
      WireInputPolicy.validatePeerPair(
        sourcePeerId: 'peer-b',
        sinkPeerId: 'local',
        authenticatedPeerId: 'peer-a',
        localPeerId: 'local',
      ).reason,
      WireInputReason.messageSenderMismatch,
    );
  });

  test('nested control session id must equal the canonical message UUID', () {
    expect(
      WireInputPolicy.validateControlSessionId(
        messageId: _messageId,
        sessionId: _messageId,
      ).isAccepted,
      isTrue,
    );
    expect(
      WireInputPolicy.validateControlSessionId(
        messageId: _messageId,
        sessionId: '11234567-89ab-4cde-8fab-0123456789ab',
      ).reason,
      WireInputReason.messageIdInvalid,
    );
  });

  test('nested control envelope rejects unknown actions and malformed ids', () {
    final valid = <String, Object?>{
      'action': 'offer',
      'sessionId': _messageId,
      'sourcePeerId': 'peer-a',
      'sinkPeerId': 'local',
    };
    expect(
      WireInputPolicy.validateControlEnvelope(
        valid,
        allowedActions: const <String>{'offer', 'stop'},
      ).isAccepted,
      isTrue,
    );
    expect(
      WireInputPolicy.validateControlEnvelope(
        <String, Object?>{...valid, 'action': 'surprise'},
        allowedActions: const <String>{'offer', 'stop'},
      ).reason,
      WireInputReason.malformedFrame,
    );
    expect(
      WireInputPolicy.validateControlEnvelope(
        <String, Object?>{...valid, 'sourcePeerId': 7},
        allowedActions: const <String>{'offer', 'stop'},
      ).reason,
      WireInputReason.malformedFrame,
    );
  });

  group('WireControlSessionRegistry', () {
    test('binds a control session to one authenticated peer and endpoint pair',
        () {
      final registry = WireControlSessionRegistry();
      expect(
        registry
            .validateAndRemember(
              namespace: 'audio',
              sessionId: _messageId,
              sourcePeerId: 'peer-a',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: true,
            )
            .isAccepted,
        isTrue,
      );
      expect(
        registry
            .validateAndRemember(
              namespace: 'audio',
              sessionId: _messageId,
              sourcePeerId: 'peer-a',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: false,
              isIncoming: false,
            )
            .isAccepted,
        isTrue,
      );
      expect(
        registry
            .validateAndRemember(
              namespace: 'audio',
              sessionId: _messageId,
              sourcePeerId: 'peer-b',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-b',
              localPeerId: 'local',
              isInitialOffer: false,
              isIncoming: true,
            )
            .reason,
        WireInputReason.controlSessionMismatch,
      );
    });

    test('rejects orphan continuations and offers in the wrong direction', () {
      final registry = WireControlSessionRegistry();
      expect(
        registry
            .validateAndRemember(
              namespace: 'remote-input',
              sessionId: _messageId,
              sourcePeerId: 'peer-a',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: false,
              isIncoming: true,
            )
            .reason,
        WireInputReason.controlSessionMismatch,
      );
      expect(
        registry
            .validateAndRemember(
              namespace: 'remote-input',
              sessionId: _messageId,
              sourcePeerId: 'local',
              sinkPeerId: 'peer-a',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: true,
            )
            .reason,
        WireInputReason.controlSessionMismatch,
      );
      expect(
        registry
            .validateAndRemember(
              namespace: 'remote-input',
              sessionId: _messageId,
              sourcePeerId: 'local',
              sinkPeerId: 'peer-a',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: false,
            )
            .isAccepted,
        isTrue,
      );
    });

    test('keeps audio, group audio, and remote input namespaces separate', () {
      final registry = WireControlSessionRegistry();
      for (final namespace in <String>['audio', 'audio-group']) {
        expect(
          registry
              .validateAndRemember(
                namespace: namespace,
                sessionId: _messageId,
                sourcePeerId: 'peer-a',
                sinkPeerId: 'local',
                authenticatedPeerId: 'peer-a',
                localPeerId: 'local',
                isInitialOffer: true,
                isIncoming: true,
              )
              .isAccepted,
          isTrue,
        );
      }
    });

    test('binds audio group continuations to one group and stream context', () {
      final registry = WireControlSessionRegistry();
      WireInputValidationResult validate(String context, bool initial) {
        return registry.validateAndRemember(
          namespace: 'audio-group',
          sessionId: _messageId,
          sourcePeerId: 'peer-a',
          sinkPeerId: 'local',
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
          isInitialOffer: initial,
          isIncoming: true,
          context: context,
        );
      }

      expect(validate('group-a\u0000stream-a', true).isAccepted, isTrue);
      expect(validate('group-a\u0000stream-a', false).isAccepted, isTrue);
      expect(
        validate('group-b\u0000stream-a', false).reason,
        WireInputReason.controlSessionMismatch,
      );
      expect(
        validate('group-a\u0000stream-b', false).reason,
        WireInputReason.controlSessionMismatch,
      );
    });

    test('capacity exhaustion never evicts an existing peer binding', () {
      final registry = WireControlSessionRegistry(maxEntries: 1);
      expect(
        registry
            .validateAndRemember(
              namespace: 'audio',
              sessionId: _messageId,
              sourcePeerId: 'peer-b',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-b',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: true,
            )
            .isAccepted,
        isTrue,
      );
      expect(
        registry
            .validateAndRemember(
              namespace: 'audio',
              sessionId: '11234567-89ab-4cde-8fab-0123456789ab',
              sourcePeerId: 'peer-a',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: true,
            )
            .reason,
        WireInputReason.controlSessionMismatch,
      );
      expect(
        registry
            .validateAndRemember(
              namespace: 'audio',
              sessionId: _messageId,
              sourcePeerId: 'peer-b',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-b',
              localPeerId: 'local',
              isInitialOffer: false,
              isIncoming: true,
            )
            .isAccepted,
        isTrue,
      );
      expect(
        registry
            .validateAndRemember(
              namespace: 'audio',
              sessionId: _messageId,
              sourcePeerId: 'peer-a',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: true,
            )
            .reason,
        WireInputReason.controlSessionMismatch,
      );
    });

    test('peer and server cleanup release capacity', () {
      final registry = WireControlSessionRegistry(maxEntries: 1);
      WireInputValidationResult offer(String peerId, String sessionId) {
        return registry.validateAndRemember(
          namespace: 'audio',
          sessionId: sessionId,
          sourcePeerId: peerId,
          sinkPeerId: 'local',
          authenticatedPeerId: peerId,
          localPeerId: 'local',
          isInitialOffer: true,
          isIncoming: true,
        );
      }

      expect(offer('peer-a', _messageId).isAccepted, isTrue);
      expect(
        offer('peer-b', '11234567-89ab-4cde-8fab-0123456789ab').reason,
        WireInputReason.controlSessionMismatch,
      );
      registry.clearPeer('peer-a');
      expect(
        offer('peer-b', '11234567-89ab-4cde-8fab-0123456789ab').isAccepted,
        isTrue,
      );
      registry.clearAll();
      expect(offer('peer-a', _messageId).isAccepted, isTrue);
    });

    test(
        'terminal session removal releases capacity without evicting live work',
        () {
      final registry = WireControlSessionRegistry(maxEntries: 1);
      expect(
        registry
            .validateAndRemember(
              namespace: 'audio',
              sessionId: _messageId,
              sourcePeerId: 'peer-a',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: true,
            )
            .isAccepted,
        isTrue,
      );
      expect(registry.length, 1);

      expect(
          registry.forget(namespace: 'audio', sessionId: _messageId), isTrue);
      expect(registry.length, 0);
      expect(
        registry
            .validateAndRemember(
              namespace: 'remote-input',
              sessionId: '11234567-89ab-4cde-8fab-0123456789ab',
              sourcePeerId: 'peer-b',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-b',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: true,
            )
            .isAccepted,
        isTrue,
      );
    });

    test('audio group sink rejoin can restore a cleared peer binding', () {
      final outgoingRegistry = WireControlSessionRegistry();
      expect(
        outgoingRegistry
            .validateAndRemember(
              namespace: 'audio-group',
              sessionId: _messageId,
              sourcePeerId: 'peer-a',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: false,
              reverseInitialDirection: true,
            )
            .isAccepted,
        isTrue,
      );

      final incomingRegistry = WireControlSessionRegistry();
      expect(
        incomingRegistry
            .validateAndRemember(
              namespace: 'audio-group',
              sessionId: _messageId,
              sourcePeerId: 'local',
              sinkPeerId: 'peer-a',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: true,
              reverseInitialDirection: true,
            )
            .isAccepted,
        isTrue,
      );
      expect(
        WireControlSessionRegistry()
            .validateAndRemember(
              namespace: 'audio-group',
              sessionId: _messageId,
              sourcePeerId: 'peer-a',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: true,
              reverseInitialDirection: true,
            )
            .reason,
        WireInputReason.controlSessionMismatch,
      );
    });

    test('peer cleanup preserves only active coordinator sessions', () {
      final registry = WireControlSessionRegistry(maxEntries: 2);
      for (final sessionId in <String>[
        _messageId,
        '11234567-89ab-4cde-8fab-0123456789ab',
      ]) {
        expect(
          registry
              .validateAndRemember(
                namespace: 'audio',
                sessionId: sessionId,
                sourcePeerId: 'peer-a',
                sinkPeerId: 'local',
                authenticatedPeerId: 'peer-a',
                localPeerId: 'local',
                isInitialOffer: true,
                isIncoming: true,
              )
              .isAccepted,
          isTrue,
        );
      }

      registry.clearPeer(
        'peer-a',
        preservedSessions: <String, Set<String>>{
          'audio': <String>{_messageId},
        },
      );
      expect(
        registry
            .validateAndRemember(
              namespace: 'audio',
              sessionId: _messageId,
              sourcePeerId: 'peer-a',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-a',
              localPeerId: 'local',
              isInitialOffer: false,
              isIncoming: true,
            )
            .isAccepted,
        isTrue,
      );
      expect(
        registry
            .validateAndRemember(
              namespace: 'remote-input',
              sessionId: '31234567-89ab-4cde-8fab-0123456789ab',
              sourcePeerId: 'peer-b',
              sinkPeerId: 'local',
              authenticatedPeerId: 'peer-b',
              localPeerId: 'local',
              isInitialOffer: true,
              isIncoming: true,
            )
            .isAccepted,
        isTrue,
      );
    });
  });

  group('WireInputPolicy.validateMessageFrame', () {
    test('requires an empty zeroed non-transfer header', () {
      WhisperFrameV3 frame({
        String transferId = '',
        int offset = 0,
        int sequence = 0,
        int flags = 0,
      }) {
        return WhisperFrameV3(
          type: WhisperFrameType.message,
          transferId: transferId,
          offset: offset,
          sequence: sequence,
          flags: flags,
          payload: Uint8List(1),
        );
      }

      expect(WireInputPolicy.validateMessageFrame(frame()).isAccepted, isTrue);
      for (final invalid in <WhisperFrameV3>[
        frame(transferId: _messageId),
        frame(offset: 1),
        frame(sequence: 1),
        frame(flags: 1),
      ]) {
        expect(
          WireInputPolicy.validateMessageFrame(invalid).reason,
          WireInputReason.transferFrameMismatch,
        );
      }
    });
  });

  group('WireInputPolicy.validateAcknowledgement', () {
    test('selects only the local outgoing original for the authenticated peer',
        () {
      final original = _message(sender: 'local', receiver: 'peer-a').copyWith(
        id: 7,
      );
      final ack = _message(
        type: MessageEnum.Ack,
        sender: 'peer-a',
        receiver: 'local',
        acked: true,
      );

      final result = WireInputPolicy.validateAcknowledgement(
        acknowledgement: ack,
        candidates: <MessageData>[
          _message(sender: 'peer-a', receiver: 'local').copyWith(id: 6),
          original,
        ],
        authenticatedPeerId: 'peer-a',
        localPeerId: 'local',
      );

      expect(result.isAccepted, isTrue);
      expect(result.original?.id, 7);
    });

    test('rejects ACKs for inbound messages or another peer', () {
      final ack = _message(
        type: MessageEnum.Ack,
        sender: 'peer-a',
        receiver: 'local',
        acked: true,
      );

      for (final candidates in <List<MessageData>>[
        <MessageData>[
          _message(sender: 'peer-a', receiver: 'local').copyWith(id: 3),
        ],
        <MessageData>[
          _message(sender: 'local', receiver: 'peer-b').copyWith(id: 4),
        ],
      ]) {
        expect(
          WireInputPolicy.validateAcknowledgement(
            acknowledgement: ack,
            candidates: candidates,
            authenticatedPeerId: 'peer-a',
            localPeerId: 'local',
          ).reason,
          WireInputReason.ackOriginalMismatch,
        );
      }
    });

    test('rejects an ACK frame that does not assert acknowledgement', () {
      final original = _message(sender: 'local', receiver: 'peer-a').copyWith(
        id: 7,
      );

      expect(
        WireInputPolicy.validateAcknowledgement(
          acknowledgement: _message(
            type: MessageEnum.Ack,
            sender: 'peer-a',
            receiver: 'local',
            acked: false,
          ),
          candidates: <MessageData>[original],
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).reason,
        WireInputReason.ackOriginalMismatch,
      );
    });

    test('rejects an ACK whose echoed message identity was changed', () {
      final original = _message(sender: 'local', receiver: 'peer-a').copyWith(
        id: 7,
      );

      expect(
        WireInputPolicy.validateAcknowledgement(
          acknowledgement: _message(
            type: MessageEnum.Ack,
            sender: 'peer-a',
            receiver: 'local',
            acked: true,
            content: 'different',
          ),
          candidates: <MessageData>[original],
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).reason,
        WireInputReason.ackOriginalMismatch,
      );
    });
  });

  group('WireInputPolicy.acknowledgeOutgoing', () {
    test('updates only the bound local outgoing row for a shared UUID',
        () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final outgoing = await database.insertMessageReturning(
        _message(sender: 'local', receiver: 'peer-a'),
      );
      final inbound = await database.insertMessageReturning(
        _message(sender: 'peer-a', receiver: 'local'),
        acked: false,
      );
      final ack = _message(
        type: MessageEnum.Ack,
        sender: 'peer-a',
        receiver: 'local',
        acked: true,
      );

      final acknowledged = await WireInputPolicy.acknowledgeOutgoing(
        database: database,
        acknowledgement: ack,
        authenticatedPeerId: 'peer-a',
        localPeerId: 'local',
      );

      expect(acknowledged?.id, outgoing.id);
      final rows = await database.fetchMessagesByUuid(_messageId);
      expect(rows.singleWhere((row) => row.id == outgoing.id).acked, isTrue);
      expect(rows.singleWhere((row) => row.id == inbound.id).acked, isFalse);
    });

    test('rejects another peer without changing the outgoing row', () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final outgoing = await database.insertMessageReturning(
        _message(sender: 'local', receiver: 'peer-b'),
      );

      await expectLater(
        WireInputPolicy.acknowledgeOutgoing(
          database: database,
          acknowledgement: _message(
            type: MessageEnum.Ack,
            sender: 'peer-a',
            receiver: 'local',
            acked: true,
          ),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ),
        throwsA(
          isA<WireInputRejected>().having(
            (error) => error.reason,
            'reason',
            WireInputReason.ackOriginalMismatch,
          ),
        ),
      );

      expect(
        (await database.fetchMessagesByUuid(_messageId))
            .singleWhere((row) => row.id == outgoing.id)
            .acked,
        isFalse,
      );
    });
  });
}
