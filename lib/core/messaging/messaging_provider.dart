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
import 'package:vantra/core/errors/vantra_exceptions.dart';
import 'package:vantra/core/utils/logger.dart';
import 'package:cryptography/cryptography.dart';
import 'message.dart';
import 'messaging_repository.dart';
import 'messaging_service.dart';

class MessagingState {
  final Map<String, PeerSession> sessions;
  final Map<String, String> endpointToPeerId;
  final String? activeEndpointId;
  final String? activeEndpointName;
  final ConnectionStatus connectionStatus;

  const MessagingState({
    required this.sessions,
    required this.endpointToPeerId,
    this.activeEndpointId,
    this.activeEndpointName,
    this.connectionStatus = ConnectionStatus.disconnected,
  });

  factory MessagingState.initial() => const MessagingState(
        sessions: {},
        endpointToPeerId: {},
      );

  MessagingState copyWith({
    Map<String, PeerSession>? sessions,
    Map<String, String>? endpointToPeerId,
    String? activeEndpointId,
    String? activeEndpointName,
    ConnectionStatus? connectionStatus,
  }) {
    return MessagingState(
      sessions: sessions ?? this.sessions,
      endpointToPeerId: endpointToPeerId ?? this.endpointToPeerId,
      activeEndpointId: activeEndpointId ?? this.activeEndpointId,
      activeEndpointName: activeEndpointName ?? this.activeEndpointName,
      connectionStatus: connectionStatus ?? this.connectionStatus,
    );
  }
}

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() {
    db.close();
  });
  return db;
});

final messagingRepositoryProvider = Provider<MessagingRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return MessagingRepository(db);
});

final conversationStreamProvider = StreamProvider.family<List<VantraMessage>, String>((ref, remotePeerId) {
  final repository = ref.watch(messagingRepositoryProvider);
  final localIdentity = ref.watch(localIdentityStateProvider);
  return repository.watchConversation(localIdentity.peerId, remotePeerId);
});

final messagingServiceProvider = Provider<MessagingService>((ref) {
  final transport = ref.watch(transportProvider);
  final service = MessagingService(transport, codec: const ProtobufCodec());
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});

final messagingStateProvider = NotifierProvider<MessagingNotifier, MessagingState>(() {
  return MessagingNotifier();
});

class MessagingNotifier extends Notifier<MessagingState> {
  late final MessagingService _service;
  late final CryptoService _cryptoService;

  StreamSubscription? _connectionSub;
  StreamSubscription? _encryptedMessageSub;
  StreamSubscription? _secureIdentitySub;

  final Map<String, SecuritySession> _securitySessions = {};
  final Map<String, SimpleKeyPair> _pendingEphemeralKeys = {};

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
    });

    return MessagingState.initial();
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

      // 3. Monotonic sequence & session ID replay check
      if (!session.isValidInboundSequence(plaintext.sequence, plaintext.sessionId)) {
        VantraLogger.log('[VANTRA][SECURITY] REPLAY / INVALID SEQUENCE: messageId=${plaintext.messageId}, seq=${plaintext.sequence} <= receiveSequence=${session.receiveSequence} or sessionId mismatch. Discarded.');
        return;
      }

      session.updateReceiveSequence(plaintext.sequence);

      // 4. Handle plaintext body variant
      switch (plaintext) {
        case DomainTextMessage textMsg:
          final msg = VantraMessage(
            messageId: textMsg.messageId,
            senderId: textMsg.senderId,
            receiverId: textMsg.receiverId,
            text: textMsg.content,
            timestamp: textMsg.timestampMs,
            status: MessageStatus.received,
          );

          VantraLogger.log('[VANTRA][SECURITY] MESSAGE RECONSTRUCTED = YES (messageId=${msg.messageId}, senderId=${msg.senderId}, receiverId=${msg.receiverId})');
          await ref.read(messagingRepositoryProvider).saveIncomingMessage(msg);
          VantraLogger.log('[VANTRA][SECURITY] REPOSITORY: messageId=${msg.messageId} saved, conversationStream notified');

          // Send authenticated encrypted delivery ACK back to sender
          await _sendEncryptedDeliveryAck(
            endpointId: event.endpointId,
            recipientPeerId: textMsg.senderId,
            originalMessageId: textMsg.messageId,
            session: session,
          );

        case DomainAckMessage ackMsg:
          if (ackMsg.status == DomainDeliveryStatus.delivered) {
            VantraLogger.log('[VANTRA][SECURITY] ACK RECEIVED: originalMessageId=${ackMsg.originalMessageId}, updating local status to DELIVERED');
            await ref.read(messagingRepositoryProvider).updateMessageStatus(
                  ackMsg.originalMessageId,
                  MessageStatus.delivered,
                );
          }
      }
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] DECRYPT/PROCESSING FAIL: messageId=${event.messageId}, error=$e', e, stack);
    }
  }

  Future<void> _sendEncryptedDeliveryAck({
    required String endpointId,
    required String recipientPeerId,
    required String originalMessageId,
    required SecuritySession session,
  }) async {
    final localId = ref.read(localIdentityStateProvider);
    // Invariant: unique ACK packet ID distinct from original message ID
    final ackPacketId = const Uuid().v4();
    final ackSeq = session.nextSendSequence();
    final now = DateTime.now().millisecondsSinceEpoch;

    VantraLogger.log('[VANTRA][SECURITY] GENERATING ACK: ackPacketId=$ackPacketId, originalMessageId=$originalMessageId, seq=$ackSeq');

    final ackPlaintext = DomainAckMessage(
      messageId: ackPacketId,
      sessionId: session.sessionId,
      sequence: ackSeq,
      timestampMs: now,
      senderId: localId.peerId,
      receiverId: recipientPeerId,
      originalMessageId: originalMessageId,
      status: DomainDeliveryStatus.delivered,
    );

    final plaintextBytes = _service.codec.encodePlaintext(ackPlaintext);

    final encryptedAck = await _cryptoService.encryptBytes(
      secretKey: session.sendKey,
      sessionSalt: session.sessionSalt,
      sequence: ackSeq,
      messageId: ackPacketId,
      plaintextBytes: plaintextBytes,
    );

    await _service.sendEncryptedMessage(
      endpointId: endpointId,
      messageId: ackPacketId,
      sessionId: session.sessionId,
      sequence: ackSeq,
      nonce: Uint8List.fromList(encryptedAck.nonce),
      ciphertext: Uint8List.fromList(encryptedAck.ciphertext),
      mac: Uint8List.fromList(encryptedAck.mac),
      protocolVersion: kCurrentProtocolVersion,
    );

    VantraLogger.log('[VANTRA][SECURITY] ACK SENT: ackPacketId=$ackPacketId for originalMessageId=$originalMessageId to $endpointId');
  }

  Future<void> _handleSecureIdentityReceived(SessionSecureIdentity identity) async {
    final localId = ref.read(localIdentityStateProvider);
    if (identity.peerId == localId.peerId) return;

    VantraLogger.log('[VANTRA][SECURITY] STATE: SECURITY_HANDSHAKE (inbound from ${identity.endpointId})');
    VantraLogger.log('[VANTRA][SECURITY] INBOUND HANDSHAKE: peerId=${identity.peerId}, displayName=${identity.displayName}, v=${identity.protocolVersion}');

    final ephemeralKeyPair = _pendingEphemeralKeys[identity.endpointId];
    if (ephemeralKeyPair == null) {
      VantraLogger.log('[VANTRA][SECURITY] HANDSHAKE DROP: No local ephemeral key found for ${identity.endpointId}');
      return;
    }

    final idKeyBytes = identity.identityPublicKey;
    final ephKeyBytes = identity.ephemeralPublicKey;
    final sigBytes = identity.signature;

    final remoteFingerprint = await _cryptoService.computeFingerprint(idKeyBytes);
    VantraLogger.log('[VANTRA][SECURITY] REMOTE ID FINGERPRINT: $remoteFingerprint, ephemeralPubLen=${ephKeyBytes.length}, sigLen=${sigBytes.length}');

    // 1. Verify remote peer's signature over the canonical handshake transcript
    final isValidSignature = await _cryptoService.verifyHandshake(
      signatureBytes: sigBytes,
      identityPublicKeyBytes: idKeyBytes,
      protocolVersion: identity.protocolVersion,
      peerId: identity.peerId,
      displayName: identity.displayName,
      ephemeralPublicKeyBytes: ephKeyBytes,
    );

    VantraLogger.log('[VANTRA][SECURITY] SIGNATURE VERIFICATION: result=${isValidSignature ? "SUCCESS" : "FAILED"}');

    if (!isValidSignature) {
      VantraLogger.log('[VANTRA][SECURITY] STATE: HANDSHAKE_FAILED. Disconnecting ${identity.endpointId}.');
      await ref.read(transportProvider).disconnect(identity.endpointId);
      return;
    }

    VantraLogger.log('[VANTRA][SECURITY] STATE: IDENTITY_VERIFIED');

    // 2. Perform ECDH key agreement and derive directional keys
    final derivedKeys = await _cryptoService.deriveSessionKeys(
      localEphemeralKeyPair: ephemeralKeyPair,
      remoteEphemeralPublicKeyBytes: ephKeyBytes,
    );

    VantraLogger.log('[VANTRA][SECURITY] STATE: KEY_DERIVED');
    VantraLogger.log('[VANTRA][SECURITY] KEY DERIVATION DETAILS: isDeviceA=${derivedKeys.isDeviceA}, sharedSecretFingerprint=${derivedKeys.sharedSecretFingerprint}, keyAtoBFingerprint=${derivedKeys.keyAtoBFingerprint}, keyBtoAFingerprint=${derivedKeys.keyBtoAFingerprint}, localSendKeyFingerprint=${derivedKeys.localSendKeyFingerprint}, localReceiveKeyFingerprint=${derivedKeys.localReceiveKeyFingerprint}, sessionId=${derivedKeys.sessionId}');

    final repo = ref.read(messagingRepositoryProvider);
    final existingPeer = await repo.getPeer(identity.peerId);
    final trustState = existingPeer?.trustState ?? PeerTrustState.untrusted;

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

  Future<void> sendTextMessage(String peerId, String text) async {
    final session = state.sessions[peerId];
    final secSession = _securitySessions[peerId];

    if (session == null || session.status != SessionStatus.connected || secSession == null) {
      VantraLogger.log('[VANTRA][SECURITY] SEND FAILED: Secure session is not established for peer $peerId');
      throw const VantraException('Cannot send message: Secure session is not established');
    }

    final localIdentity = ref.read(localIdentityStateProvider);
    final repository = ref.read(messagingRepositoryProvider);

    // 1. Create message model with pending status
    final messageId = const Uuid().v4();
    final seq = secSession.nextSendSequence();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    final msg = VantraMessage(
      messageId: messageId,
      senderId: localIdentity.peerId,
      receiverId: peerId,
      text: text,
      timestamp: timestamp,
      status: MessageStatus.pending,
    );

    // 2. Persist locally in SQLite
    await repository.saveOutgoingMessage(msg);

    try {
      // 3. Encode domain plaintext to Protobuf binary
      final domainPlaintext = DomainTextMessage(
        messageId: messageId,
        sessionId: secSession.sessionId,
        sequence: seq,
        timestampMs: timestamp,
        senderId: localIdentity.peerId,
        receiverId: peerId,
        content: text,
      );

      final plaintextBytes = _service.codec.encodePlaintext(domainPlaintext);

      // 4. Encrypt with ChaCha20-Poly1305 and AAD = UTF-8(messageId)
      final encrypted = await _cryptoService.encryptBytes(
        secretKey: secSession.sendKey,
        sessionSalt: secSession.sessionSalt,
        sequence: seq,
        messageId: messageId,
        plaintextBytes: plaintextBytes,
      );

      VantraLogger.log('[VANTRA][SECURITY] OUTBOUND: type=ENCRYPTED_TEXT, messageId=$messageId, sequence=$seq, nonceLength=${encrypted.nonce.length}, ciphertextLength=${encrypted.ciphertext.length}, AAD/messageId=$messageId, encryption=SUCCESS');

      // 5. Transmit Encrypted Protobuf Envelope
      await _service.sendEncryptedMessage(
        endpointId: session.endpointId,
        messageId: messageId,
        sessionId: secSession.sessionId,
        sequence: seq,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
        protocolVersion: kCurrentProtocolVersion,
      );

      VantraLogger.log('[VANTRA][SECURITY] Transport.send(): endpointId=${session.endpointId}, messageId=$messageId, result=SUCCESS');

      // 6. Update status to sent on transport success
      await repository.updateMessageStatus(messageId, MessageStatus.sent);
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] SEND FAILED: messageId=$messageId, error=$e', e, stack);
      await repository.updateMessageStatus(messageId, MessageStatus.failed);
      rethrow;
    }
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

  List<int> _hexDecode(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}
