import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/utils/logger.dart';
import 'package:vantra/core/errors/vantra_exceptions.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/messaging/messaging_repository.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/security/security_session.dart';
import 'messaging_service.dart';
import 'message.dart';

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
    required this.connectionStatus,
  });

  MessagingState.initial()
      : sessions = const {},
        endpointToPeerId = const {},
        activeEndpointId = null,
        activeEndpointName = null,
        connectionStatus = ConnectionStatus.idle;

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
  final service = MessagingService(transport);
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

  final Map<String, SecuritySession> _securitySessions = {};
  final Map<String, SimpleKeyPair> _pendingEphemeralKeys = {};

  StreamSubscription? _msgSub;
  StreamSubscription? _idSub;
  StreamSubscription? _connSub;

  @override
  MessagingState build() {
    _service = ref.watch(messagingServiceProvider);
    _cryptoService = ref.watch(cryptoServiceProvider);

    _msgSub?.cancel();
    _idSub?.cancel();
    _connSub?.cancel();

    _msgSub = _service.encryptedMessageStream.listen(_handleIncomingEncryptedMessage);
    _idSub = _service.secureIdentityStream.listen(_handleSecureIdentityReceived);
    _connSub = ref.read(transportProvider).connectionUpdateStream.listen(_handleConnectionUpdate);

    ref.onDispose(() {
      _msgSub?.cancel();
      _idSub?.cancel();
      _connSub?.cancel();
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

    VantraLogger.log('[VANTRA][SECURITY] INBOUND: endpointId=${event.endpointId}, messageId=${event.messageId}, type=ENCRYPTED_TEXT, v=${event.protocolVersion}');

    try {
      final nonceBytes = _hexDecode(event.nonceHex);
      final ciphertextBytes = _hexDecode(event.ciphertextHex);
      final macBytes = _hexDecode(event.macHex);

      VantraLogger.log('[VANTRA][SECURITY] DECRYPT: messageId=${event.messageId}, AAD/messageId=${event.messageId}, nonceLength=${nonceBytes.length}, ciphertextLength=${ciphertextBytes.length}, keyDirection=RECEIVE');

      // Decrypt and verify Poly1305 authentication tag & Associated Data
      final decryptedJsonString = await _cryptoService.decryptPayload(
        secretKey: session.receiveKey,
        nonce: nonceBytes,
        ciphertext: ciphertextBytes,
        mac: macBytes,
        messageId: event.messageId,
      );

      final cleartextJson = jsonDecode(decryptedJsonString) as Map<String, dynamic>;
      final seq = cleartextJson['seq'] as int? ?? 0;
      final incomingSessionId = cleartextJson['sessionId'] as String? ?? '';

      final textContent = cleartextJson['text'] as String? ?? '';
      final senderId = cleartextJson['senderId'] as String? ?? '';
      final receiverId = cleartextJson['receiverId'] as String? ?? '';
      final timestamp = cleartextJson['timestamp'] as int? ?? 0;

      VantraLogger.log('[VANTRA][SECURITY] DECRYPT SUCCESS: messageId=${event.messageId}, senderId=$senderId, receiverId=$receiverId, timestamp=$timestamp, textLength=${textContent.length}');

      // Replay & Monotonic sequence check
      if (!session.isValidInboundSequence(seq, incomingSessionId)) {
        VantraLogger.log('[VANTRA][SECURITY] REPLAY / INVALID SEQUENCE: messageId=${event.messageId}, seq=$seq <= receiveSequence=${session.receiveSequence} or sessionId mismatch. Discarded.');
        return;
      }

      session.updateReceiveSequence(seq);

      final msg = VantraMessage(
        messageId: event.messageId,
        senderId: senderId,
        receiverId: receiverId,
        text: textContent,
        timestamp: timestamp,
        status: MessageStatus.received,
      );

      VantraLogger.log('[VANTRA][SECURITY] MESSAGE RECONSTRUCTED = YES (messageId=${msg.messageId}, senderId=${msg.senderId}, receiverId=${msg.receiverId})');
      await ref.read(messagingRepositoryProvider).saveIncomingMessage(msg);
      VantraLogger.log('[VANTRA][SECURITY] REPOSITORY: messageId=${msg.messageId} saved, conversationStream notified');
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] DECRYPT FAIL: messageId=${event.messageId}, error=$e', e, stack);
    }
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

    final idKeyBytes = _hexDecode(identity.identityPublicKeyHex);
    final ephKeyBytes = _hexDecode(identity.ephemeralPublicKeyHex);
    final sigBytes = _hexDecode(identity.signatureHex);

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

    // 2. Sign canonical handshake transcript
    final signatureBytes = await _cryptoService.signHandshake(
      identityKeyPair: localId.keyPair!,
      protocolVersion: 1,
      peerId: localId.peerId,
      displayName: localId.displayName,
      identityPublicKeyBytes: idPubBytes,
      ephemeralPublicKeyBytes: ephPub.bytes,
    );

    VantraLogger.log('[VANTRA][SECURITY] OUTBOUND HANDSHAKE: localPeerId=${localId.peerId}, localFingerprint=${localId.fingerprint}, ephPubLen=${ephPub.bytes.length}, sigLen=${signatureBytes.length}');

    // 3. Transmit IDENTITY_SECURE packet
    await _service.sendSecureIdentity(
      endpointId: endpointId,
      peerId: localId.peerId,
      displayName: localId.displayName,
      identityPublicKeyHex: localId.identityPublicKey,
      ephemeralPublicKeyHex: _hexEncode(ephPub.bytes),
      signatureHex: _hexEncode(signatureBytes),
      protocolVersion: 1,
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
      // 3. Encrypt payload
      final cleartextJson = jsonEncode({
        'senderId': localIdentity.peerId,
        'receiverId': peerId,
        'text': text,
        'timestamp': timestamp,
        'seq': seq,
        'sessionId': secSession.sessionId,
      });

      final encrypted = await _cryptoService.encryptPayload(
        secretKey: secSession.sendKey,
        sessionSalt: secSession.sessionSalt,
        sequence: seq,
        messageId: messageId,
        plaintextJson: cleartextJson,
      );

      VantraLogger.log('[VANTRA][SECURITY] OUTBOUND: type=ENCRYPTED_TEXT, messageId=$messageId, sequence=$seq, nonceLength=${encrypted.nonce.length}, ciphertextLength=${encrypted.ciphertext.length}, AAD/messageId=$messageId, encryption=SUCCESS');

      // 4. Transmit ENCRYPTED_TEXT wrapper
      await _service.sendEncryptedMessage(
        endpointId: session.endpointId,
        messageId: messageId,
        nonceHex: _hexEncode(encrypted.nonce),
        ciphertextHex: _hexEncode(encrypted.ciphertext),
        macHex: _hexEncode(encrypted.mac),
        protocolVersion: 1,
      );

      VantraLogger.log('[VANTRA][SECURITY] Transport.send(): endpointId=${session.endpointId}, messageId=$messageId, result=SUCCESS');

      // 5. Update status to sent on success
      await repository.updateMessageStatus(messageId, MessageStatus.sent);
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] SEND ENCRYPTION/TRANSPORT FAIL: messageId=$messageId, error=$e', e, stack);
      await repository.updateMessageStatus(messageId, MessageStatus.failed);
      rethrow;
    }
  }

  Future<void> setPeerTrustState(String peerId, PeerTrustState trustState) async {
    await ref.read(messagingRepositoryProvider).updatePeerTrustState(peerId, trustState);
    final session = state.sessions[peerId];
    if (session != null) {
      state = state.copyWith(
        sessions: {
          ...state.sessions,
          peerId: session.copyWith(trustState: trustState),
        },
      );
    }
  }

  List<int> _hexDecode(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  String _hexEncode(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
