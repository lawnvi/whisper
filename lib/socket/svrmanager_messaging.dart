part of 'svrmanager.dart';

/// Outbound text messages, quick-send acknowledged text, Android notification
/// forwarding, and remote/workspace clipboard relay.
extension WsSvrManagerMessaging on WsSvrManager {
  Future<bool> sendMessageTo(
    String peerId,
    String content, {
    bool clipboard = false,
  }) {
    return _outgoingTextSendLocks.synchronized(
      peerId,
      () => _sendMessageToSerialized(peerId, content, clipboard: clipboard),
    );
  }

  /// Sends a quick-send text with a persistent idempotency key and returns
  /// only after the authenticated peer acknowledges the exact message.
  Future<bool> sendQuickTextToAcknowledged(
    String peerId,
    String content, {
    required String source,
    required String intentId,
    required String expectedPublicKeyHash,
    Duration acknowledgementTimeout = const Duration(seconds: 10),
  }) {
    final messageId = stableQuickSendMessageId(
      source: source,
      intentId: jsonEncode(<String>[intentId, expectedPublicKeyHash]),
      peerId: peerId,
    );
    return _outgoingTextSendLocks.synchronized(
      peerId,
      () => _sendQuickTextToAcknowledgedSerialized(
        peerId,
        content,
        messageId: messageId,
        expectedPublicKeyHash: expectedPublicKeyHash,
        acknowledgementTimeout: acknowledgementTimeout,
      ),
    );
  }

  Future<bool> _sendQuickTextToAcknowledgedSerialized(
    String peerId,
    String content, {
    required String messageId,
    required String expectedPublicKeyHash,
    required Duration acknowledgementTimeout,
  }) async {
    if (peerId.isEmpty ||
        acknowledgementTimeout <= Duration.zero ||
        !isConnectedTo(peerId) ||
        content.trim().isEmpty ||
        !isCanonicalTransferId(messageId)) {
      return false;
    }

    var expectedBinding = await _trustedQuickSendBinding(
      peerId,
      expectedPublicKeyHash,
    );
    if (expectedBinding == null) {
      return false;
    }

    final draft = _buildMessage(
      MessageEnum.Text,
      content,
      '',
      '',
      0,
      false,
      uid: messageId,
      receiverOverride: peerId,
    );
    final database = _database;
    final candidates = await database.fetchMessagesByUuid(messageId);
    if (!await _quickSendBindingRemainsTrusted(
      expectedBinding,
      expectedPublicKeyHash,
    )) {
      return false;
    }
    if (await database.fetchFileTransfer(messageId) != null ||
        candidates.any((candidate) => !_isSameQuickText(candidate, draft))) {
      return false;
    }
    if (!await _quickSendBindingRemainsTrusted(
      expectedBinding,
      expectedPublicKeyHash,
    )) {
      return false;
    }

    MessageData selectedMessage;
    var isNew = false;
    if (candidates.isEmpty) {
      selectedMessage = await database.insertMessageReturning(draft);
      isNew = true;
    } else {
      selectedMessage = candidates.firstWhere(
        (candidate) => candidate.acked,
        orElse: () => candidates.first,
      );
      if (selectedMessage.acked) {
        return true;
      }
    }
    if (isNew) {
      _dispatchOutgoingMessage(selectedMessage);
    }

    expectedBinding = await _trustedQuickSendBinding(
      peerId,
      expectedPublicKeyHash,
      expectedBinding: expectedBinding,
    );
    if (expectedBinding == null) {
      return false;
    }

    final acknowledgement = _outgoingTextAcknowledgements.waitFor(
      peerId: peerId,
      messageId: selectedMessage.uuid,
      timeout: acknowledgementTimeout,
    );
    try {
      if (!_quickSendSessionMatches(expectedBinding, expectedPublicKeyHash)) {
        acknowledgement.cancel();
        return false;
      }
      final accepted = await _sendMessageData(selectedMessage, peerId: peerId);
      if (!accepted) {
        acknowledgement.cancel();
        return false;
      }
      return await acknowledgement.future;
    } catch (_) {
      acknowledgement.cancel();
      rethrow;
    }
  }

  Future<TransferConnectionBinding?> _trustedQuickSendBinding(
    String peerId,
    String expectedPublicKeyHash, {
    TransferConnectionBinding? expectedBinding,
  }) async {
    final binding = _peers.currentBinding(peerId);
    if (binding == null ||
        (expectedBinding != null && binding != expectedBinding) ||
        !_quickSendSessionMatches(binding, expectedPublicKeyHash)) {
      return null;
    }
    final stored = await _database.fetchDevice(peerId);
    if (stored == null ||
        !matchesExpectedQuickSendIdentity(
          expectedPublicKeyHash: expectedPublicKeyHash,
          authenticatedIdentityPublicKey:
              _peers.sessionForPeer(peerId)?.remoteIdentityPublicKey ?? '',
          storedTrusted: stored.auth,
          storedIdentityPublicKey: stored.identityPublicKey,
        ) ||
        !_quickSendSessionMatches(binding, expectedPublicKeyHash)) {
      return null;
    }
    return binding;
  }

  Future<bool> _quickSendBindingRemainsTrusted(
    TransferConnectionBinding binding,
    String expectedPublicKeyHash,
  ) async {
    return await _trustedQuickSendBinding(
          binding.peerId,
          expectedPublicKeyHash,
          expectedBinding: binding,
        ) !=
        null;
  }

  bool _quickSendSessionMatches(
    TransferConnectionBinding binding,
    String expectedPublicKeyHash,
  ) {
    final session = _peers.sessionForPeer(binding.peerId);
    return session != null &&
        session.isAuthenticated &&
        session.connectionGeneration == binding.generation &&
        _peers.currentBinding(binding.peerId) == binding &&
        _policy.isPeerAuthenticationAllowed(binding.peerId) &&
        matchesExpectedQuickSendIdentity(
          expectedPublicKeyHash: expectedPublicKeyHash,
          authenticatedIdentityPublicKey: session.remoteIdentityPublicKey,
          storedTrusted: true,
          storedIdentityPublicKey: session.remoteIdentityPublicKey,
        );
  }

  bool _isSameQuickText(MessageData stored, MessageData draft) {
    return stored.sender == draft.sender &&
        stored.receiver == draft.receiver &&
        stored.name == draft.name &&
        stored.clipboard == draft.clipboard &&
        stored.size == draft.size &&
        stored.type == MessageEnum.Text &&
        stored.content == draft.content &&
        stored.message == draft.message &&
        stored.uuid == draft.uuid &&
        stored.path == draft.path &&
        stored.md5 == draft.md5 &&
        stored.fileTimestamp == draft.fileTimestamp;
  }

  Future<bool> _sendMessageToSerialized(
    String peerId,
    String content, {
    required bool clipboard,
  }) async {
    if (peerId.isEmpty || !isConnectedTo(peerId)) {
      return false;
    }
    if (clipboard && content.isEmpty) {
      final str = await readClipboardTextForSync() ?? '';
      content = str.trimRight();
    }
    if (content.trim().isEmpty) {
      return false;
    }
    final draft = _buildMessage(
      MessageEnum.Text,
      content,
      '',
      '',
      0,
      clipboard,
      receiverOverride: peerId,
    );
    if (clipboard) {
      logger.i('发送剪贴板文本, uuid: ${draft.uuid}');
      return _sendMessageData(draft, peerId: peerId);
    }
    final database = _database;
    final retry = await _outgoingTextRetries.resolve(
      draft,
      fetchByUuid: database.fetchMessagesByUuid,
    );
    if (retry.alreadyAcknowledged) {
      _dispatchOutgoingMessage(retry.message!);
      return true;
    }

    final prepared = await prepareOutgoingTextWithRetryIdentity(
      draft: draft,
      retry: retry.message,
      persist: database.insertMessageReturning,
    );
    final selectedMessage = prepared.message;
    if (prepared.isNew) {
      _dispatchOutgoingMessage(selectedMessage);
    }
    try {
      logger.i('发送消息, uuid: ${selectedMessage.uuid}');
      final accepted = await _sendMessageData(selectedMessage, peerId: peerId);
      if (accepted) {
        _outgoingTextRetries.clearAccepted(selectedMessage);
      } else {
        _outgoingTextRetries.rememberFailure(selectedMessage);
      }
      return accepted;
    } catch (_) {
      _outgoingTextRetries.rememberFailure(selectedMessage);
      rethrow;
    }
  }

  Future<void> sendNotification(
    String? package,
    String? title,
    String? text,
  ) async {
    final targets = connectedPeerIds.toList(growable: false);
    if (targets.isEmpty || (package == null && title == null && text == null)) {
      return;
    }
    final content = <String, Object?>{
      'app': await appName(package),
      'package': package,
      'title': title,
      'text': text,
    };
    final encodedContent = jsonEncode(content);
    for (final peerId in targets) {
      final message = _buildMessage(
        MessageEnum.Notification,
        encodedContent,
        '',
        '',
        0,
        false,
        receiverOverride: peerId,
      );
      await _sendMessageData(message, peerId: peerId);
    }
  }

  Future<bool> publishRemoteClipboard({
    required String peerId,
    required String sessionId,
    required List<RemoteClipboardLocalItem> items,
  }) async {
    if (!(await LocalSetting().instance()).clipboard ||
        !await LocalSetting().clipboardAutoSync()) {
      await _remoteClipboardTransfer.clearSession(
        sessionId,
        notifyPeer: true,
        peerId: peerId,
      );
      return false;
    }
    return _remoteClipboardTransfer.publish(
      peerId: peerId,
      sessionId: sessionId,
      items: items,
    );
  }

  Future<RemoteClipboardPasteResult> prepareRemoteClipboardPaste({
    required String peerId,
    required String sessionId,
  }) async {
    if (!(await LocalSetting().instance()).clipboard ||
        !await LocalSetting().clipboardAutoSync()) {
      return RemoteClipboardPasteResult.notAvailable;
    }
    return _remoteClipboardTransfer.preparePaste(
      peerId: peerId,
      sessionId: sessionId,
    );
  }

  void markLocalWorkspaceClipboard() {
    _workspaceClipboardRevision++;
    _workspaceClipboardOrigin = null;
  }

  Future<RemoteClipboardPasteResult> prepareLatestWorkspaceClipboardPaste() {
    final origin = _workspaceClipboardOrigin;
    if (origin == null) {
      return Future<RemoteClipboardPasteResult>.value(
        RemoteClipboardPasteResult.notAvailable,
      );
    }
    final offer = _remoteClipboardTransfer.remoteOffer(
      peerId: origin.peerId,
      sessionId: origin.sessionId,
    );
    if (offer == null || offer.offerId != origin.offerId) {
      _workspaceClipboardOrigin = null;
      return Future<RemoteClipboardPasteResult>.value(
        RemoteClipboardPasteResult.notAvailable,
      );
    }
    return prepareRemoteClipboardPaste(
      peerId: origin.peerId,
      sessionId: origin.sessionId,
    );
  }

  /// The paste shortcut pressed on this device for files copied on the one
  /// it controls. True: press it again now. Files still on their way are
  /// waited for on screen, without holding up the shortcut's caller.
  Future<bool> pasteLatestWorkspaceClipboard() async {
    final origin = _workspaceClipboardOrigin;
    final front = foregroundWindowToken();
    final folder = foregroundFolder();
    final pending = prepareLatestWorkspaceClipboardPaste();
    final early = await pending
        .then<RemoteClipboardPasteResult?>((result) => result)
        .timeout(remoteClipboardPasteHoldLimit, onTimeout: () => null);
    if (early != null) {
      return early != RemoteClipboardPasteResult.failed;
    }
    if (origin == null) {
      return false;
    }
    return remoteClipboardPasteWatch.follow(
      sessionId: origin.sessionId,
      pending: pending,
      front: front,
      folder: folder,
    );
  }

  Future<void> clearRemoteClipboardSession({
    required String peerId,
    required String sessionId,
    bool notifyPeer = false,
    bool endsPaste = false,
  }) {
    return _remoteClipboardTransfer.clearSession(
      sessionId,
      notifyPeer: notifyPeer,
      peerId: peerId,
      endsPaste: endsPaste,
    );
  }

  /// Whether [transferId] brings files for a paste, which the floating
  /// island shows instead of the window's.
  bool carriesRemoteClipboardTransfer(String transferId) =>
      _remoteClipboardTransfer.carriesTransfer(transferId);

  bool remoteClipboardOwnsPaths({
    required String sessionId,
    required List<String> paths,
  }) {
    return _remoteClipboardTransfer.ownsClipboardPaths(sessionId, paths);
  }

  bool _validateRemoteClipboardSession({
    required String peerId,
    required String sessionId,
    required bool sourceIsLocal,
  }) {
    final inputSession = _remoteInputManager.session(sessionId);
    final socketSession = _peers.sessionForPeer(peerId);
    if (inputSession?.state != RemoteInputSessionState.connected ||
        inputSession?.remoteClipboardV1 != true ||
        socketSession == null ||
        !socketSession.isAuthenticated ||
        _peers.currentBinding(peerId)?.generation !=
            socketSession.connectionGeneration) {
      return false;
    }
    final localPeerId = socketSession.localProfile.uid;
    return (inputSession!.sourcePeerId == localPeerId &&
            inputSession.sinkPeerId == peerId) ||
        (inputSession.sourcePeerId == peerId &&
            inputSession.sinkPeerId == localPeerId);
  }

  Future<void> _handleWorkspaceClipboardOffer({
    required String peerId,
    required String sessionId,
  }) {
    return _serializeWorkspaceClipboard(() async {
      final offer = _remoteClipboardTransfer.remoteOffer(
        peerId: peerId,
        sessionId: sessionId,
      );
      if (offer == null) return;
      final workspace = RemoteInputWorkspaceCoordinator.shared.snapshot;
      final originTarget = workspace.targets[peerId];
      final legacy = RemoteInputCoordinator.shared.state;
      final isWorkspaceOrigin =
          workspace.isControllerLive &&
          originTarget?.isConnected == true &&
          originTarget?.sessionId == sessionId;
      final isLegacyOrigin =
          legacy.role == RemoteInputRuntimeRole.source &&
          legacy.peerId == peerId &&
          legacy.sessionId == sessionId;
      if (!isWorkspaceOrigin && !isLegacyOrigin) return;
      final revision = ++_workspaceClipboardRevision;
      _workspaceClipboardOrigin = _WorkspaceClipboardOrigin(
        revision: revision,
        peerId: peerId,
        sessionId: sessionId,
        offerId: offer.offerId,
      );
      if (!isWorkspaceOrigin) return;
      for (final target in workspace.targets.values) {
        if (!target.isConnected || target.peerId == peerId) continue;
        if (_workspaceClipboardOrigin?.revision != revision) return;
        await _remoteClipboardTransfer.relayRemoteOffer(
          originPeerId: peerId,
          originSessionId: sessionId,
          targetPeerId: target.peerId,
          targetSessionId: target.sessionId,
        );
      }
    });
  }

  Future<void> _handleWorkspaceClipboardClear({
    required String peerId,
    required String sessionId,
  }) {
    return _serializeWorkspaceClipboard(() async {
      final origin = _workspaceClipboardOrigin;
      if (origin == null ||
          origin.peerId != peerId ||
          origin.sessionId != sessionId) {
        return;
      }
      _workspaceClipboardRevision++;
      _workspaceClipboardOrigin = null;
      final workspace = RemoteInputWorkspaceCoordinator.shared.snapshot;
      if (!workspace.isControllerLive) return;
      for (final target in workspace.targets.values) {
        if (!target.isConnected || target.peerId == peerId) continue;
        await _remoteClipboardTransfer.clearSession(
          target.sessionId,
          notifyPeer: true,
          peerId: target.peerId,
        );
      }
    });
  }

  Future<void> _relayWorkspaceClipboardText(
    MessageData message, {
    required String sourcePeerId,
  }) async {
    final workspace = RemoteInputWorkspaceCoordinator.shared.snapshot;
    final source = workspace.targets[sourcePeerId];
    if (!workspace.isControllerLive || source?.isConnected != true) return;
    markLocalWorkspaceClipboard();
    for (final target in workspace.targets.values) {
      if (!target.isConnected || target.peerId == sourcePeerId) continue;
      await _remoteClipboardTransfer.clearSession(
        target.sessionId,
        notifyPeer: true,
        peerId: target.peerId,
      );
      await sendMessageTo(
        target.peerId,
        message.content ?? '',
        clipboard: true,
      );
    }
  }

  Future<void> _serializeWorkspaceClipboard(Future<void> Function() action) {
    final next = _workspaceClipboardSerial.then((_) => action());
    _workspaceClipboardSerial = next.catchError((_) {});
    return next;
  }
}
