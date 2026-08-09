import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/security/security_session.dart';
import 'package:vantra/core/utils/logger.dart';
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Value;
import 'message.dart';
import 'messaging_repository.dart';
import 'messaging_service.dart';

class MessagingState {
  final Map<String, PeerSession> sessions;
  final Map<String, String> endpointToPeerId;
  final ConnectionStatus connectionStatus;
  final String? activeEndpointId;
  final String? activeEndpointName;
  final String? activeConversationPeerId;

  const MessagingState({
    required this.sessions,
    required this.endpointToPeerId,
    required this.connectionStatus,
    this.activeEndpointId,
    this.activeEndpointName,
    this.activeConversationPeerId,
  });

  factory MessagingState.initial() => const MessagingState(
        sessions: {},
        endpointToPeerId: {},
        connectionStatus: ConnectionStatus.idle,
      );

  MessagingState copyWith({
    Map<String, PeerSession>? sessions,
    Map<String, String>? endpointToPeerId,
    ConnectionStatus? connectionStatus,
    String? activeEndpointId,
    String? activeEndpointName,
    String? activeConversationPeerId,
    bool clearActiveConversation = false,
  }) {
    return MessagingState(
      sessions: sessions ?? this.sessions,
      endpointToPeerId: endpointToPeerId ?? this.endpointToPeerId,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      activeEndpointId: activeEndpointId ?? this.activeEndpointId,
      activeEndpointName: activeEndpointName ?? this.activeEndpointName,
      activeConversationPeerId: clearActiveConversation
          ? null
          : (activeConversationPeerId ?? this.activeConversationPeerId),
    );
  }
}

final messagingRepositoryProvider = Provider<MessagingRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return MessagingRepository(db);
});

final messagingServiceProvider = Provider<MessagingService>((ref) {
  final transport = ref.watch(transportProvider);
  final service = MessagingService(transport, codec: const ProtobufCodec());
  ref.onDispose(() => service.dispose());
  return service;
});

final conversationStreamProvider = StreamProvider.family<List<VantraMessage>, String>((ref, remotePeerId) {
  final localIdentity = ref.watch(localIdentityStateProvider);
  final repository = ref.watch(messagingRepositoryProvider);
  return repository.watchConversation(localIdentity.peerId, remotePeerId);
});

final messagingStateProvider = NotifierProvider<MessagingNotifier, MessagingState>(() {
  return MessagingNotifier();
});

class MessagingNotifier extends Notifier<MessagingState> {
  late MessagingService _service;
  late CryptoService _cryptoService;

  StreamSubscription? _connectionSub;
  StreamSubscription? _encryptedMessageSub;
  StreamSubscription? _secureIdentitySub;

  final Map<String, SecuritySession> _securitySessions = {};
  final Map<String, SimpleKeyPair> _pendingEphemeralKeys = {};

  // Phase 7 Queue, ACK-Timeout, and Backoff structures
  final Set<String> _activePeerFlushes = {};
  final Map<String, Timer> _ackTimers = {};
  final Map<String, Timer> _backoffTimers = {};

  @override
  MessagingState build() {
    _service = ref.watch(messagingServiceProvider);
    _cryptoService = ref.watch(cryptoServiceProvider);

    final transport = ref.watch(transportProvider);

    _connectionSub?.cancel();
    _encryptedMessageSub?.cancel();
    _secureIdentitySub?.cancel();

    _connectionSub = transport.connectionUpdateStream.listen(_handleConnectionUpdate);
    _encryptedMessageSub = _service.encryptedMessageStream.listen(_handleIncomingEncryptedMessage);
    _secureIdentitySub = _service.secureIdentityStream.listen(_handleSecureIdentityReceived);

    ref.onDispose(() {
      _connectionSub?.cancel();
      _encryptedMessageSub?.cancel();
      _secureIdentitySub?.cancel();
      _securitySessions.clear();
      _pendingEphemeralKeys.clear();
      _activePeerFlushes.clear();
      for (final t in _ackTimers.values) {
        t.cancel();
      }
      _ackTimers.clear();
      for (final t in _backoffTimers.values) {
        t.cancel();
      }
      _backoffTimers.clear();
    });

    // Persistent Recovery on App Boot
    Future.microtask(() async {
      final repository = ref.read(messagingRepositoryProvider);
      await repository.recoverSentMessages();
    });

    return MessagingState.initial();
  }

  void setActiveConversation(String? peerId) {
    if (peerId != null) {
      state = state.copyWith(activeConversationPeerId: peerId);
      final localIdentity = ref.read(localIdentityStateProvider);
      ref.read(messagingRepositoryProvider).markConversationAsRead(localIdentity.peerId, peerId);
    } else {
      state = state.copyWith(clearActiveConversation: true);
    }
  }

  Future<void> _handleIncomingEncryptedMessage(EncryptedMessageEvent event) async {
    final peerId = state.endpointToPeerId[event.endpointId];
    if (peerId == null) {
      VantraLogger.log('[VANTRA][SECURITY] INBOUND DROP: Unknown endpoint ${event.endpointId}');
      return;
    }

    final session = _securitySessions[peerId];
    if (session == null) {
      VantraLogger.log('[VANTRA][SECURITY] INBOUND DROP: No active secure session for peer $peerId');
      return;
    }

    VantraLogger.log('[VANTRA][SECURITY] INBOUND: endpointId=${event.endpointId}, messageId=${event.messageId}, type=ENCRYPTED_ENVELOPE, v=${event.protocolVersion}');

    try {
      VantraLogger.log('[VANTRA][SECURITY] DECRYPT: messageId=${event.messageId}, AAD/messageId=${event.messageId}, nonceLength=${event.nonce.length}, ciphertextLength=${event.ciphertext.length}, keyDirection=RECEIVE');

      // 1. Decrypt and verify Poly1305 authentication tag & Associated Data
      final decryptedBytes = await _cryptoService.decryptBytes(
        secretKey: session.receiveKey,
        nonce: event.nonce,
        ciphertext: event.ciphertext,
        mac: event.mac,
        messageId: event.messageId,
      );

      // 2. Decode authenticated plaintext protobuf
      final plaintext = _service.codec.decodePlaintext(decryptedBytes);

      VantraLogger.log('[VANTRA][SECURITY] DECRYPT SUCCESS: messageId=${plaintext.messageId}, senderId=${plaintext.senderId}, receiverId=${plaintext.receiverId}, timestamp=${plaintext.timestampMs}');

      // 3. Replay Protection: verify sequence > lastSeenReceiveSequence & matching session ID
      if (plaintext.sessionId != session.sessionId || plaintext.sequence <= session.receiveSequence) {
        VantraLogger.log('[VANTRA][SECURITY] REPLAY / INVALID SEQUENCE: messageId=${plaintext.messageId}, seq=${plaintext.sequence} <= receiveSequence=${session.receiveSequence} or sessionId mismatch. Discarded.');
        return;
      }
      session.updateReceiveSequence(plaintext.sequence);

      final repository = ref.read(messagingRepositoryProvider);

      // 4. Update peer lastSeen timestamp in SQLite
      await repository.updatePeerLastSeen(peerId, plaintext.timestampMs);

      // Lost-ACK + Duplicate-Message ACK Recovery
      final existingMsg = await repository.getMessageById(plaintext.messageId);
      final activeSession = state.sessions[peerId];
      if (existingMsg != null) {
        VantraLogger.log('[VANTRA][SECURITY] DUPLICATE DETECTED: messageId=${plaintext.messageId}. Discarding duplicate payload, but immediately re-acknowledging.');
        if (activeSession != null) {
          await _sendAck(event.endpointId, session, plaintext.messageId);
        }
        return;
      }

      // 5. Handle Text Message vs Delivery ACK
      if (plaintext is DomainTextMessage) {
        final isCurrentlyViewing = state.activeConversationPeerId == peerId;

        final incomingMsg = VantraMessage(
          messageId: plaintext.messageId,
          senderId: plaintext.senderId,
          receiverId: plaintext.receiverId,
          text: plaintext.content,
          timestamp: plaintext.timestampMs,
          status: MessageStatus.received,
        );

        VantraLogger.log('[VANTRA][SECURITY] MESSAGE RECONSTRUCTED = YES (messageId=${incomingMsg.messageId}, senderId=${incomingMsg.senderId}, receiverId=${incomingMsg.receiverId})');

        // Persist message to SQLite
        await repository.saveIncomingMessage(incomingMsg, isRead: isCurrentlyViewing);
        VantraLogger.log('[VANTRA][SECURITY] REPOSITORY: messageId=${incomingMsg.messageId} saved, conversationStream notified');

        // Transmit Encrypted Delivery ACK
        if (activeSession != null) {
          await _sendAck(event.endpointId, session, plaintext.messageId);
        }
      } else if (plaintext is DomainAckMessage) {
        VantraLogger.log('[VANTRA][SECURITY] ACK RECEIVED: originalMessageId=${plaintext.originalMessageId}, updating local status to DELIVERED');
        _ackTimers[plaintext.originalMessageId]?.cancel();
        _ackTimers.remove(plaintext.originalMessageId);
        await repository.updateMessageStatus(plaintext.originalMessageId, MessageStatus.delivered);
        // Flush queue to process next FIFO message
        _flushQueue(peerId);
      }
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] DECRYPT / INTEGRITY CHECK FAILED for message ${event.messageId}: $e', e, stack);
    }
  }

  Future<void> _sendAck(String endpointId, SecuritySession session, String originalMessageId) async {
    final ackPacketId = const Uuid().v4();
    final ackSeq = session.nextSendSequence();

    VantraLogger.log('[VANTRA][SECURITY] GENERATING ACK: ackPacketId=$ackPacketId, originalMessageId=$originalMessageId, seq=$ackSeq');

    final ackDomainMessage = DomainAckMessage(
      messageId: ackPacketId,
      sessionId: session.sessionId,
      sequence: ackSeq,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      senderId: session.peerId, // local recipient is the sender of the ACK
      receiverId: session.peerId,
      originalMessageId: originalMessageId,
      status: DomainDeliveryStatus.delivered,
    );

    final ackPlaintextBytes = _service.codec.encodePlaintext(ackDomainMessage);

    final encAck = await _cryptoService.encryptBytes(
      secretKey: session.sendKey,
      sessionSalt: session.sessionSalt,
      sequence: ackSeq,
      messageId: ackPacketId,
      plaintextBytes: ackPlaintextBytes,
    );

    await _service.sendEncryptedMessage(
      endpointId: endpointId,
      messageId: ackPacketId,
      sessionId: session.sessionId,
      sequence: ackSeq,
      nonce: Uint8List.fromList(encAck.nonce),
      ciphertext: Uint8List.fromList(encAck.ciphertext),
      mac: Uint8List.fromList(encAck.mac),
      protocolVersion: kCurrentProtocolVersion,
    );

    VantraLogger.log('[VANTRA][SECURITY] ACK SENT: ackPacketId=$ackPacketId for originalMessageId=$originalMessageId to $endpointId');
  }

  Future<void> _handleSecureIdentityReceived(SessionSecureIdentity identity) async {
    VantraLogger.log('[VANTRA][SECURITY] STATE: SECURITY_HANDSHAKE (inbound from ${identity.endpointId})');
    VantraLogger.log('[VANTRA][SECURITY] INBOUND HANDSHAKE: peerId=${identity.peerId}, displayName=${identity.displayName}, v=${identity.protocolVersion}');

    // Reject unsupported protocol versions
    if (identity.protocolVersion < kMinSupportedProtocolVersion || identity.protocolVersion > kCurrentProtocolVersion) {
      VantraLogger.log('[VANTRA][SECURITY] Unsupported protocol version: ${identity.protocolVersion}');
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);
      return;
    }

    final idKeyBytes = _hexDecode(identity.identityPublicKeyHex);
    final ephKeyBytes = _hexDecode(identity.ephemeralPublicKeyHex);
    final sigBytes = _hexDecode(identity.signatureHex);

    final remoteFingerprint = await _cryptoService.computeFingerprint(idKeyBytes);
    VantraLogger.log('[VANTRA][SECURITY] REMOTE ID FINGERPRINT: $remoteFingerprint, ephemeralPubLen=${ephKeyBytes.length}, sigLen=${sigBytes.length}');

    // 1. Verify Ed25519 canonical signature
    final isValid = await _cryptoService.verifyHandshake(
      signatureBytes: sigBytes,
      identityPublicKeyBytes: idKeyBytes,
      protocolVersion: identity.protocolVersion,
      peerId: identity.peerId,
      displayName: identity.displayName,
      ephemeralPublicKeyBytes: ephKeyBytes,
    );

    if (!isValid) {
      VantraLogger.log('[VANTRA][SECURITY] SIGNATURE VERIFICATION: result=FAILED! Disconnecting untrusted peer.');
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);
      return;
    }

    VantraLogger.log('[VANTRA][SECURITY] SIGNATURE VERIFICATION: result=SUCCESS');
    VantraLogger.log('[VANTRA][SECURITY] STATE: IDENTITY_VERIFIED');

    // BLOCKING SECURITY INVARIANT CHECK
    final repo = ref.read(messagingRepositoryProvider);
    final existingPeer = await repo.getPeer(identity.peerId);
    final trustState = existingPeer?.trustState ?? PeerTrustState.untrusted;

    if (trustState == PeerTrustState.distrusted) {
      VantraLogger.log('[VANTRA][SECURITY] BLOCKED PEER CONNECTION REJECTED: peerId=${identity.peerId}, endpointId=${identity.endpointId}');
      _pendingEphemeralKeys.remove(identity.endpointId);
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);
      return;
    }

    // 2. Perform ECDH & HKDF key derivation
    var localEphKeyPair = _pendingEphemeralKeys[identity.endpointId];
    if (localEphKeyPair == null) {
      localEphKeyPair = await _cryptoService.generateEphemeralKeyPair();
      _pendingEphemeralKeys[identity.endpointId] = localEphKeyPair;
    }

    final derivedKeys = await _cryptoService.deriveSessionKeys(
      localEphemeralKeyPair: localEphKeyPair,
      remoteEphemeralPublicKeyBytes: ephKeyBytes,
    );

    VantraLogger.log('[VANTRA][SECURITY] STATE: KEY_DERIVED');
    VantraLogger.log('[VANTRA][SECURITY] KEY DERIVATION DETAILS: isDeviceA=${derivedKeys.isDeviceA}, sharedSecretFingerprint=${derivedKeys.sharedSecretFingerprint}, keyAtoBFingerprint=${derivedKeys.keyAtoBFingerprint}, keyBtoAFingerprint=${derivedKeys.keyBtoAFingerprint}, localSendKeyFingerprint=${derivedKeys.localSendKeyFingerprint}, localReceiveKeyFingerprint=${derivedKeys.localReceiveKeyFingerprint}, sessionId=${derivedKeys.sessionId}');

    // 3. Establish secure session in memory
    final secSession = SecuritySession(
      peerId: identity.peerId,
      endpointId: identity.endpointId,
      sessionId: derivedKeys.sessionId,
      sessionSalt: derivedKeys.sessionSalt,
      sendKey: derivedKeys.sendKey,
      receiveKey: derivedKeys.receiveKey,
      remoteIdentityPublicKey: identity.identityPublicKeyHex,
      remoteFingerprint: remoteFingerprint,
    );

    _securitySessions[identity.peerId] = secSession;

    // 4. Update database peer record
    await repo.upsertPeer(
      identity.peerId,
      identity.displayName,
      endpointId: identity.endpointId,
      publicKey: identity.identityPublicKeyHex,
      fingerprint: remoteFingerprint,
      trustState: trustState,
      protocolVersion: identity.protocolVersion,
    );

    final updatedSession = PeerSession(
      peerId: identity.peerId,
      displayName: identity.displayName,
      endpointId: identity.endpointId,
      status: SessionStatus.connected,
      publicKey: identity.identityPublicKeyHex,
      fingerprint: remoteFingerprint,
      trustState: trustState,
      isSecure: true,
    );

    state = state.copyWith(
      sessions: {
        ...state.sessions,
        identity.peerId: updatedSession,
      },
      endpointToPeerId: {
        ...state.endpointToPeerId,
        identity.endpointId: identity.peerId,
      },
    );

    VantraLogger.log('[VANTRA][SECURITY] STATE: SECURE with peer ${identity.peerId} (Fingerprint: $remoteFingerprint, SessionId: ${derivedKeys.sessionId})');

    // Reconnection: Flush queue upon secure session establishment
    _flushQueue(identity.peerId);
  }

  void _handleConnectionUpdate(ConnectionUpdate update) {
    VantraLogger.log('[VANTRA][SECURITY] CONNECTION UPDATE: endpointId=${update.endpointId}, status=${update.status.name}');
    if (update.status == ConnectionStatus.connected) {
      VantraLogger.log('[VANTRA][SECURITY] STATE: CONNECTED (endpointId=${update.endpointId})');
      state = state.copyWith(
        connectionStatus: ConnectionStatus.connected,
        activeEndpointId: update.endpointId,
        activeEndpointName: update.endpointName,
      );
      _initiateSecureHandshake(update.endpointId);
    } else if (update.status == ConnectionStatus.connecting) {
      state = state.copyWith(
        connectionStatus: ConnectionStatus.connecting,
        activeEndpointId: update.endpointId,
        activeEndpointName: update.endpointName,
      );
    } else if (update.status == ConnectionStatus.disconnected ||
        update.status == ConnectionStatus.rejected ||
        update.status == ConnectionStatus.error) {

      final peerId = state.endpointToPeerId[update.endpointId];
      if (peerId != null) {
        VantraLogger.log('[VANTRA][SECURITY] Destroying secure session keys for disconnected peer $peerId');
        _securitySessions.remove(peerId);
        _backoffTimers[peerId]?.cancel();
        _backoffTimers.remove(peerId);
        final session = state.sessions[peerId];
        if (session != null) {
          state = state.copyWith(
            sessions: {
              ...state.sessions,
              peerId: session.copyWith(status: SessionStatus.disconnected, isSecure: false),
            },
          );
        }
      }
      _pendingEphemeralKeys.remove(update.endpointId);

      state = state.copyWith(
        connectionStatus: update.status,
        activeEndpointId: null,
        activeEndpointName: null,
      );
    } else {
      state = state.copyWith(
        connectionStatus: update.status,
      );
    }
  }

  Future<void> _initiateSecureHandshake(String endpointId) async {
    VantraLogger.log('[VANTRA][SECURITY] STATE: SECURITY_HANDSHAKE (outbound to $endpointId)');
    final localNotifier = ref.read(localIdentityStateProvider.notifier);
    await localNotifier.ensureKeysLoaded();
    final localId = ref.read(localIdentityStateProvider);

    if (localId.keyPair == null) {
      VantraLogger.log('[VANTRA][SECURITY] Cannot initiate handshake: Local keypair not ready');
      return;
    }

    // 1. Generate fresh ephemeral X25519 keypair
    final ephemeralKeyPair = await _cryptoService.generateEphemeralKeyPair();
    _pendingEphemeralKeys[endpointId] = ephemeralKeyPair;

    final ephPub = await ephemeralKeyPair.extractPublicKey();
    final idPubBytes = _hexDecode(localId.identityPublicKey);

    // 2. Sign canonical handshake transcript (using CanonicalEncoder)
    final signatureBytes = await _cryptoService.signHandshake(
      identityKeyPair: localId.keyPair!,
      protocolVersion: kCurrentProtocolVersion,
      peerId: localId.peerId,
      displayName: localId.displayName,
      identityPublicKeyBytes: idPubBytes,
      ephemeralPublicKeyBytes: ephPub.bytes,
    );

    VantraLogger.log('[VANTRA][SECURITY] OUTBOUND HANDSHAKE: localPeerId=${localId.peerId}, localFingerprint=${localId.fingerprint}, ephPubLen=${ephPub.bytes.length}, sigLen=${signatureBytes.length}');

    // 3. Transmit IDENTITY_SECURE protobuf packet
    await _service.sendSecureIdentity(
      endpointId: endpointId,
      peerId: localId.peerId,
      displayName: localId.displayName,
      identityPublicKey: Uint8List.fromList(idPubBytes),
      ephemeralPublicKey: Uint8List.fromList(ephPub.bytes),
      signature: Uint8List.fromList(signatureBytes),
      protocolVersion: kCurrentProtocolVersion,
    );
  }

  // Phase 7: Persistent Queue Flusher
  Future<void> _flushQueue(String peerId) async {
    if (_activePeerFlushes.contains(peerId)) return;
    _activePeerFlushes.add(peerId);

    try {
      final repository = ref.read(messagingRepositoryProvider);
      while (true) {
        final session = state.sessions[peerId];
        final secSession = _securitySessions[peerId];

        // Break if session is not secure or disconnected
        if (session == null || session.status != SessionStatus.connected || secSession == null) {
          break;
        }

        // Fetch pending messages in FIFO order
        final pending = await repository.getPendingOrFailedMessages(peerId);
        if (pending.isEmpty) break;

        final msg = pending.first;
        final success = await _sendSingleMessage(secSession, session, msg);
        if (!success) {
          // Break flusher to await scheduled retry backoff timer
          break;
        }
      }
    } finally {
      _activePeerFlushes.remove(peerId);
    }
  }

  Future<bool> _sendSingleMessage(
    SecuritySession secSession,
    PeerSession session,
    VantraMessage msg,
  ) async {
    final repository = ref.read(messagingRepositoryProvider);
    final localIdentity = ref.read(localIdentityStateProvider);

    final seq = secSession.nextSendSequence();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    try {
      // Encode original messageId under fresh session and sequence counters
      final domainPlaintext = DomainTextMessage(
        messageId: msg.messageId,
        sessionId: secSession.sessionId,
        sequence: seq,
        timestampMs: timestamp,
        senderId: localIdentity.peerId,
        receiverId: msg.receiverId,
        content: msg.text,
      );

      final plaintextBytes = _service.codec.encodePlaintext(domainPlaintext);

      final encrypted = await _cryptoService.encryptBytes(
        secretKey: secSession.sendKey,
        sessionSalt: secSession.sessionSalt,
        sequence: seq,
        messageId: msg.messageId,
        plaintextBytes: plaintextBytes,
      );

      VantraLogger.log('[VANTRA][SECURITY] Transmitting ENCRYPTED_TEXT protobuf packet for ${msg.messageId} to ${session.displayName}');

      await _service.sendEncryptedMessage(
        endpointId: session.endpointId,
        messageId: msg.messageId,
        sessionId: secSession.sessionId,
        sequence: seq,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
        protocolVersion: kCurrentProtocolVersion,
      );

      VantraLogger.log('[VANTRA][SECURITY] Transport.send(): endpointId=${session.endpointId}, messageId=${msg.messageId}, result=SUCCESS');

      await repository.updateMessageStatus(msg.messageId, MessageStatus.sent);

      // Start persistent ACK timer
      _scheduleAckTimeout(msg.messageId, msg.receiverId);
      return true;
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] Queue transmit failed for messageId=${msg.messageId}: $e', e, stack);
      await repository.incrementRetryCount(msg.messageId, maxAttempts: 5);

      final updated = await repository.getMessageById(msg.messageId);
      if (updated != null && updated.status != MessageStatus.failed) {
        _scheduleBackoffRetry(msg.receiverId, updated.retryCount);
      }
      return false;
    }
  }

  void _scheduleAckTimeout(String messageId, String peerId) {
    _ackTimers[messageId]?.cancel();
    _ackTimers[messageId] = Timer(const Duration(seconds: 10), () async {
      final repository = ref.read(messagingRepositoryProvider);
      final msg = await repository.getMessageById(messageId);
      if (msg != null && msg.status == MessageStatus.sent) {
        VantraLogger.log('[VANTRA][SECURITY] ACK Timeout for messageId=$messageId. Reverting to pending for retry.');
        await repository.updateMessageStatus(messageId, MessageStatus.pending);
        await repository.incrementRetryCount(messageId, maxAttempts: 5);

        final updated = await repository.getMessageById(messageId);
        if (updated != null && updated.status != MessageStatus.failed) {
          _scheduleBackoffRetry(peerId, updated.retryCount);
        }
      }
    });
  }

  void _scheduleBackoffRetry(String peerId, int retryCount) {
    _backoffTimers[peerId]?.cancel();
    final seconds = (1 << retryCount) * 2; // 2s, 4s, 8s, 16s, 32s
    final jitter = (seconds * 0.1 * (2 * (DateTime.now().millisecond / 1000.0) - 1)).toInt();
    final delay = Duration(seconds: seconds) + Duration(milliseconds: jitter * 1000);

    VantraLogger.log('[VANTRA][SECURITY] Scheduling retry backoff for peer $peerId in ${delay.inSeconds}s (attempt $retryCount)');
    _backoffTimers[peerId] = Timer(delay, () {
      _flushQueue(peerId);
    });
  }

  // Phase 7: Composing messages when offline is supported without exceptions
  Future<void> sendTextMessage(String peerId, String text) async {
    final localIdentity = ref.read(localIdentityStateProvider);
    final repository = ref.read(messagingRepositoryProvider);

    final messageId = const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    final msg = VantraMessage(
      messageId: messageId,
      senderId: localIdentity.peerId,
      receiverId: peerId,
      text: text,
      timestamp: timestamp,
      status: MessageStatus.pending,
    );

    // Save locally
    await repository.saveOutgoingMessage(msg);

    // Trigger queue flush
    await _flushQueue(peerId);
  }

  Future<void> retryMessage(String messageId, String peerId) async {
    VantraLogger.log('[VANTRA][SECURITY] Manual retry triggered for messageId=$messageId');
    final db = ref.read(appDatabaseProvider);
    
    await (db.update(db.messages)..where((t) => t.messageId.equals(messageId)))
        .write(MessagesCompanion(
      status: Value(MessageStatus.pending),
      retryCount: Value(0),
    ));

    await _flushQueue(peerId);
  }

  Future<void> setPeerTrustState(String peerId, PeerTrustState newState) async {
    final repo = ref.read(messagingRepositoryProvider);
    await repo.updatePeerTrustState(peerId, newState);

    final session = state.sessions[peerId];
    if (session != null) {
      state = state.copyWith(
        sessions: {
          ...state.sessions,
          peerId: session.copyWith(trustState: newState),
        },
      );
    }
  }

  Future<void> blockPeer(String peerId) async {
    VantraLogger.log('[VANTRA][SECURITY] Blocking peer $peerId');
    final repo = ref.read(messagingRepositoryProvider);
    await repo.updatePeerTrustState(peerId, PeerTrustState.distrusted);

    // Terminate active transport and session if connected
    final session = state.sessions[peerId];
    if (session != null) {
      final transport = ref.read(transportProvider);
      try {
        await transport.disconnect(session.endpointId);
      } catch (_) {}
      _securitySessions.remove(peerId);
      _backoffTimers[peerId]?.cancel();
      _backoffTimers.remove(peerId);
      state = state.copyWith(
        sessions: {
          ...state.sessions,
          peerId: session.copyWith(
            status: SessionStatus.disconnected,
            isSecure: false,
            trustState: PeerTrustState.distrusted,
          ),
        },
      );
    }
  }

  Future<void> unblockPeer(String peerId) async {
    VantraLogger.log('[VANTRA][SECURITY] Unblocking peer $peerId');
    final repo = ref.read(messagingRepositoryProvider);
    await repo.updatePeerTrustState(peerId, PeerTrustState.untrusted);

    final session = state.sessions[peerId];
    if (session != null) {
      state = state.copyWith(
        sessions: {
          ...state.sessions,
          peerId: session.copyWith(trustState: PeerTrustState.untrusted),
        },
      );
    }
  }

  Future<void> updatePeerNickname(String peerId, String? nickname) async {
    final repo = ref.read(messagingRepositoryProvider);
    await repo.updatePeerNickname(peerId, nickname);
  }

  List<int> _hexDecode(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}
