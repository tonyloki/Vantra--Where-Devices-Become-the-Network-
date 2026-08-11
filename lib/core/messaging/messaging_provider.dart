// ignore_for_file: avoid_print

import 'dart:async';
import 'package:flutter/foundation.dart';
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
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/peers/peer_discovery_service.dart';
import 'message.dart';
import 'messaging_repository.dart';
import 'messaging_service.dart';

class ConnectionRequestInfo {
  final String endpointId;
  final String endpointName;
  final String? authenticationToken;
  final bool isIncoming;

  const ConnectionRequestInfo({
    required this.endpointId,
    required this.endpointName,
    this.authenticationToken,
    required this.isIncoming,
  });
}

class IdentityMismatchRequest {
  final String peerId;
  final String endpointId;
  final String oldPublicKey;
  final String newPublicKey;

  const IdentityMismatchRequest({
    required this.peerId,
    required this.endpointId,
    required this.oldPublicKey,
    required this.newPublicKey,
  });
}

class MessagingState {
  final Map<String, PeerSession> sessions;
  final Map<String, String> endpointToPeerId;
  final ConnectionStatus connectionStatus;
  final String? activeEndpointId;
  final String? activeEndpointName;
  final String? activeConversationPeerId;
  final ConnectionRequestInfo? activeConnectionRequest;
  final IdentityMismatchRequest? identityMismatchRequest;

  const MessagingState({
    required this.sessions,
    required this.endpointToPeerId,
    required this.connectionStatus,
    this.activeEndpointId,
    this.activeEndpointName,
    this.activeConversationPeerId,
    this.activeConnectionRequest,
    this.identityMismatchRequest,
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
    ConnectionRequestInfo? activeConnectionRequest,
    bool clearActiveConnectionRequest = false,
    IdentityMismatchRequest? identityMismatchRequest,
    bool clearIdentityMismatchRequest = false,
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
      activeConnectionRequest: clearActiveConnectionRequest
          ? null
          : (activeConnectionRequest ?? this.activeConnectionRequest),
      identityMismatchRequest: clearIdentityMismatchRequest
          ? null
          : (identityMismatchRequest ?? this.identityMismatchRequest),
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

  // Connection Request Idempotency Tracking
  final Set<String> _acceptedEndpoints = {};
  final Set<String> _rejectedEndpoints = {};

  StreamSubscription? _discoveredPeersSub;
  final Map<String, DateTime> _lastConnectAttempt = {};
  final Map<String, Duration> _reconnectBackoff = {};

  @override
  MessagingState build() {
    _service = ref.watch(messagingServiceProvider);
    _cryptoService = ref.watch(cryptoServiceProvider);

    final transport = ref.watch(transportProvider);
    final discoveryService = ref.watch(peerDiscoveryServiceProvider);

    _connectionSub?.cancel();
    _encryptedMessageSub?.cancel();
    _secureIdentitySub?.cancel();
    _discoveredPeersSub?.cancel();

    _connectionSub = transport.connectionUpdateStream.listen(_handleConnectionUpdate);
    _encryptedMessageSub = _service.encryptedMessageStream.listen(_handleIncomingEncryptedMessage);
    _secureIdentitySub = _service.secureIdentityStream.listen(_handleSecureIdentityReceived);
    _discoveredPeersSub = discoveryService.discoveredPeersStream.listen(_handleDiscoveredPeersUpdate);

    ref.onDispose(() {
      _connectionSub?.cancel();
      _encryptedMessageSub?.cancel();
      _secureIdentitySub?.cancel();
      _discoveredPeersSub?.cancel();
      for (final session in _securitySessions.values) {
        VantraLogger.log('[VANTRA][CRYPTO] SESSION DESTROYED endpointId=${session.endpointId}');
      }
      _securitySessions.clear();
      _pendingEphemeralKeys.clear();
      _activePeerFlushes.clear();
      _acceptedEndpoints.clear();
      _rejectedEndpoints.clear();
      _lastConnectAttempt.clear();
      _reconnectBackoff.clear();
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
      VantraLogger.log('[VANTRA][CRYPTO] DECRYPT START messageId=${event.messageId} sequence=${event.sequence}');

      // 1. Decrypt and verify Poly1305 authentication tag & Associated Data
      Uint8List decryptedBytes;
      try {
        decryptedBytes = await _cryptoService.decryptBytes(
          secretKey: session.receiveKey,
          nonce: event.nonce,
          ciphertext: event.ciphertext,
          mac: event.mac,
          messageId: event.messageId,
        );
        VantraLogger.log('[VANTRA][CRYPTO] DECRYPT SUCCESS messageId=${event.messageId} plaintextLength=${decryptedBytes.length}');
      } catch (e) {
        VantraLogger.log('[VANTRA][CRYPTO] DECRYPT FAILED messageId=${event.messageId} errorType=${e.runtimeType}');
        rethrow;
      }

      // 2. Decode authenticated plaintext protobuf
      final plaintext = _service.codec.decodePlaintext(decryptedBytes);
      VantraLogger.log('[VANTRA][MESSAGING] MESSAGE RECONSTRUCTED messageId=${plaintext.messageId} senderId=${plaintext.senderId} receiverId=${plaintext.receiverId} timestamp=${plaintext.timestampMs}');

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
        VantraLogger.log('[VANTRA][DB] DUPLICATE MESSAGE messageId=${plaintext.messageId}');
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

        VantraLogger.log('[VANTRA][DB] INBOUND INSERT START messageId=${incomingMsg.messageId} status=received');
        try {
          // Persist message to SQLite
          await repository.saveIncomingMessage(incomingMsg, isRead: isCurrentlyViewing);
          VantraLogger.log('[VANTRA][DB] INBOUND INSERT SUCCESS messageId=${incomingMsg.messageId}');
        } catch (e) {
          VantraLogger.log('[VANTRA][DB] INBOUND INSERT FAILED messageId=${incomingMsg.messageId} errorType=${e.runtimeType}');
          rethrow;
        }

        // Transmit Encrypted Delivery ACK
        if (activeSession != null) {
          await _sendAck(event.endpointId, session, plaintext.messageId);
        }
      } else if (plaintext is DomainAckMessage) {
        VantraLogger.log('[VANTRA][RECEIVE] ACK RECEIVED ackPacketId=${plaintext.messageId}');
        VantraLogger.log('[VANTRA][CRYPTO] ACK DECRYPT SUCCESS ackPacketId=${plaintext.messageId}');

        _ackTimers[plaintext.originalMessageId]?.cancel();
        _ackTimers.remove(plaintext.originalMessageId);

        VantraLogger.log('[VANTRA][DB] MESSAGE STATUS UPDATE messageId=${plaintext.originalMessageId} status=delivered');
        await repository.updateMessageStatus(plaintext.originalMessageId, MessageStatus.delivered);
        // Flush queue to process next FIFO message
        _flushQueue(peerId);
      } else if (plaintext is DomainCapabilitiesExchange) {
        print('[VANTRA][SECURITY] Received CapabilitiesExchange from ${event.endpointId}');
        final activeSession = state.sessions[peerId];
        if (activeSession == null) return;

        if (activeSession.status == SessionStatus.connected) {
          // Already negotiated. Just reply with ACK to clear remote queue.
          await _sendAck(event.endpointId, session, plaintext.messageId);
          return;
        }

        // Downgrade protection and spoof check
        if (plaintext.minSupportedVersion != activeSession.remoteMinVersion ||
            plaintext.maxSupportedVersion != activeSession.remoteMaxVersion) {
          print('[VANTRA][SECURITY] Version range mismatch! Handshake advertised [${activeSession.remoteMinVersion}..${activeSession.remoteMaxVersion}], exchange claimed [${plaintext.minSupportedVersion}..${plaintext.maxSupportedVersion}]. Terminating connection.');
          final transport = ref.read(transportProvider);
          await transport.disconnect(event.endpointId);
          return;
        }

        final remoteCaps = activeSession.remoteCapabilities ?? const [];
        final listsMatch = plaintext.supportedCapabilities.length == remoteCaps.length &&
            plaintext.supportedCapabilities.every((c) => remoteCaps.contains(c));

        if (!listsMatch) {
          print('[VANTRA][SECURITY] Capability advertisement mismatch! Terminating connection.');
          final transport = ref.read(transportProvider);
          await transport.disconnect(event.endpointId);
          return;
        }

        final localCapabilities = const [VantraCapability.text];
        final negotiatedCapabilities = localCapabilities
            .where((c) => plaintext.supportedCapabilities.contains(c))
            .toList();

        final readySession = activeSession.copyWith(
          status: SessionStatus.connected,
          enabledCapabilities: negotiatedCapabilities,
        );

        state = state.copyWith(
          sessions: {
            ...state.sessions,
            peerId: readySession,
          },
        );

        print('[VANTRA][SECURITY] CAPABILITY_NEGOTIATION_SUCCESS for peer $peerId. Enabled capabilities: $negotiatedCapabilities');

        await _sendAck(event.endpointId, session, plaintext.messageId);
        _flushQueue(peerId);
      }
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] DECRYPT / INTEGRITY CHECK FAILED for message ${event.messageId}: $e', e, stack);
    }
  }

  Future<void> _sendAck(String endpointId, SecuritySession session, String originalMessageId) async {
    final ackPacketId = const Uuid().v4();
    final ackSeq = session.nextSendSequence();

    VantraLogger.log('[VANTRA][MESSAGING] ACK CREATE originalMessageId=$originalMessageId');

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

    VantraLogger.log('[VANTRA][CRYPTO] ACK ENCRYPT SUCCESS ackPacketId=$ackPacketId');

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

    VantraLogger.log('[VANTRA][TRANSPORT] ACK SEND SUCCESS ackPacketId=$ackPacketId');
  }

  Future<void> _handleSecureIdentityReceived(SessionSecureIdentity identity) async {
    print('[VANTRA][SECURITY] INBOUND HANDSHAKE: peerId=${identity.peerId}, displayName=${identity.displayName}, endpointId=${identity.endpointId}, v=${identity.protocolVersion}');

    // Reject unsupported protocol versions
    if (identity.protocolVersion < kMinSupportedProtocolVersion || identity.protocolVersion > kCurrentProtocolVersion) {
      print('[VANTRA][SECURITY] Unsupported protocol version: ${identity.protocolVersion}');
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);
      return;
    }

    final idKeyBytes = _hexDecode(identity.identityPublicKeyHex);
    final ephKeyBytes = _hexDecode(identity.ephemeralPublicKeyHex);
    final sigBytes = _hexDecode(identity.signatureHex);

    final remoteFingerprint = await _cryptoService.computeFingerprint(idKeyBytes);
    print('[VANTRA][SECURITY] REMOTE ID FINGERPRINT: $remoteFingerprint, ephemeralPubLen=${ephKeyBytes.length}, sigLen=${sigBytes.length}');

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
      print('[VANTRA][SECURITY] SIGNATURE VERIFICATION: result=FAILED! Disconnecting untrusted peer.');
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);
      return;
    }

    print('[VANTRA][SECURITY] SIGNATURE VERIFICATION: result=SUCCESS');
    print('[VANTRA][SECURITY] STATE: IDENTITY_VERIFIED');

    // BLOCKING SECURITY INVARIANT CHECK
    final repo = ref.read(messagingRepositoryProvider);
    final existingPeer = await repo.getPeer(identity.peerId);
    final trustState = existingPeer?.trustState ?? PeerTrustState.untrusted;

    if (trustState == PeerTrustState.distrusted) {
      print('[VANTRA][SECURITY] BLOCKED PEER CONNECTION REJECTED: peerId=${identity.peerId}, endpointId=${identity.endpointId}');
      _pendingEphemeralKeys.remove(identity.endpointId);
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);
      return;
    }

    if (trustState == PeerTrustState.trusted &&
        existingPeer?.publicKey != null &&
        existingPeer!.publicKey != identity.identityPublicKeyHex) {
      print('[VANTRA][NEARBY] IDENTITY_MISMATCH peerId=${identity.peerId} oldKey=${existingPeer.publicKey} newKey=${identity.identityPublicKeyHex}');
      _pendingEphemeralKeys.remove(identity.endpointId);
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);

      final session = state.sessions[identity.peerId];
      state = state.copyWith(
        identityMismatchRequest: IdentityMismatchRequest(
          peerId: identity.peerId,
          endpointId: identity.endpointId,
          oldPublicKey: existingPeer.publicKey!,
          newPublicKey: identity.identityPublicKeyHex,
        ),
        sessions: {
          ...state.sessions,
          if (session != null)
            identity.peerId: session.copyWith(
              status: SessionStatus.disconnected,
              isSecure: false,
            ),
        },
      );
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

    print('[VANTRA][SECURITY] STATE: KEY_DERIVED');
    print('[VANTRA][SECURITY] KEY DERIVATION DETAILS: sharedSecretFingerprint=${derivedKeys.sharedSecretFingerprint}, sessionId=${derivedKeys.sessionId}');

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
    _reconnectBackoff.remove(identity.peerId);
    _lastConnectAttempt.remove(identity.peerId);

    print('[VANTRA][CRYPTO] SESSION READY endpointId=${identity.endpointId} sessionId=${derivedKeys.sessionId} securityState=SECURE');

    // Version range negotiation
    final localMin = kMinSupportedProtocolVersion;
    final localMax = kCurrentProtocolVersion;
    final remoteMin = identity.minSupportedVersion ?? 1;
    final remoteMax = identity.maxSupportedVersion ?? 1;

    final start = localMin > remoteMin ? localMin : remoteMin;
    final end = localMax < remoteMax ? localMax : remoteMax;

    if (start > end) {
      print('[VANTRA][SECURITY] Incompatible version range: local [$localMin..$localMax], remote [$remoteMin..$remoteMax]. Disconnecting.');
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);
      return;
    }
    final negotiatedVersion = end;
    final isV1 = negotiatedVersion == 1;

    final localCapabilities = const [VantraCapability.text];
    final remoteCapabilities = identity.supportedCapabilities ?? const [VantraCapability.text];
    final negotiatedCapabilities = localCapabilities
        .where((c) => remoteCapabilities.contains(c))
        .toList();

    // 4. Update database peer record
    await repo.upsertPeer(
      identity.peerId,
      identity.displayName,
      endpointId: identity.endpointId,
      publicKey: identity.identityPublicKeyHex,
      fingerprint: remoteFingerprint,
      trustState: trustState,
      protocolVersion: negotiatedVersion,
    );

    final updatedSession = PeerSession(
      peerId: identity.peerId,
      displayName: identity.displayName,
      endpointId: identity.endpointId,
      status: isV1 ? SessionStatus.connected : SessionStatus.handshaking,
      publicKey: identity.identityPublicKeyHex,
      fingerprint: remoteFingerprint,
      trustState: trustState,
      isSecure: true,
      negotiatedVersion: negotiatedVersion,
      enabledCapabilities: isV1 ? negotiatedCapabilities : null,
      remoteMinVersion: remoteMin,
      remoteMaxVersion: remoteMax,
      remoteCapabilities: remoteCapabilities,
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

    print('[VANTRA][SECURITY] STATE: SECURE with peer ${identity.peerId} (SessionId: ${derivedKeys.sessionId}, NegotiatedVersion: $negotiatedVersion)');

    if (!isV1) {
      print('[VANTRA][SECURITY] Initiating V2 CapabilitiesExchange with peer ${identity.peerId}');
      await _sendCapabilitiesExchange(identity.peerId);
    } else {
      // Reconnection: Flush queue upon secure session establishment
      _flushQueue(identity.peerId);
    }
  }

  void _handleDiscoveredPeersUpdate(List<DiscoveredNearbyPeer> discoveredList) {
    final localIdentity = ref.read(localIdentityStateProvider);
    if (localIdentity.peerId.isEmpty) return;

    final repo = ref.read(messagingRepositoryProvider);

    for (final peer in discoveredList) {
      final peerId = peer.resolvedPeerId;
      if (peerId == null || peerId.isEmpty) continue;

      final session = state.sessions[peerId];
      if (session != null &&
          (session.status == SessionStatus.connected ||
           session.status == SessionStatus.connecting ||
           session.status == SessionStatus.handshaking)) {
        continue;
      }

      final lastAttempt = _lastConnectAttempt[peerId];
      final backoff = _reconnectBackoff[peerId] ?? const Duration(seconds: 5);
      if (lastAttempt != null && DateTime.now().difference(lastAttempt) < backoff) {
        continue;
      }

      repo.getPeer(peerId).then((dbPeer) {
        if (dbPeer != null && dbPeer.trustState == PeerTrustState.trusted) {
          final currentSession = state.sessions[peerId];
          if (currentSession != null &&
              (currentSession.status == SessionStatus.connected ||
               currentSession.status == SessionStatus.connecting ||
               currentSession.status == SessionStatus.handshaking)) {
            return;
          }

          print('[VANTRA][NEARBY] TRUSTED_PEER_DISCOVERED peerId=$peerId name=${peer.effectiveName}');
          print('[VANTRA][NEARBY] AUTO_RECONNECT peerId=$peerId endpointId=${peer.endpointId}');

          _lastConnectAttempt[peerId] = DateTime.now();
          _reconnectBackoff[peerId] = Duration(seconds: (backoff.inSeconds * 2).clamp(5, 60));

          print('[VANTRA][NEARBY] CONNECT_ATTEMPT endpointId=${peer.endpointId}');
          ref.read(peerDiscoveryServiceProvider).connect(
            peer.endpointId,
            localName: '${localIdentity.displayName}:${localIdentity.peerId}',
          ).catchError((e) {
            print('[VANTRA][NEARBY] Auto-connect failed to connect for endpointId=${peer.endpointId}: $e');
          });
        }
      });
    }
  }

  void _handleConnectionUpdate(ConnectionUpdate update) {
    // Unconditional standard prints for diagnostic logging
    print('[VANTRA][SECURITY] CONNECTION UPDATE: endpointId=${update.endpointId}, status=${update.status.name}');

    final index = update.endpointName.indexOf(':');
    final candidateName = index != -1 ? update.endpointName.substring(0, index) : update.endpointName;
    final candidatePeerId = index != -1 ? update.endpointName.substring(index + 1) : null;

    if (update.status == ConnectionStatus.connected) {
      _acceptedEndpoints.remove(update.endpointId);
      _rejectedEndpoints.remove(update.endpointId);
      print('[VANTRA][NEARBY] CONNECTION_ESTABLISHED endpoint=${update.endpointId}');

      state = state.copyWith(
        connectionStatus: ConnectionStatus.connected,
        activeEndpointId: update.endpointId,
        activeEndpointName: candidateName,
        clearActiveConnectionRequest: true,
      );

      final transport = ref.read(transportProvider);
      final isFake = transport.runtimeType.toString().contains('Fake');
      if (isFake) {
        print('[VANTRA][SECURITY] STATE: CONNECTED (endpointId=${update.endpointId}). Initiating handshake immediately (test environment).');
        _initiateSecureHandshake(update.endpointId);
      } else {
        print('[VANTRA][SECURITY] STATE: CONNECTED (endpointId=${update.endpointId}). Handshake will start in 500ms.');
        Future.delayed(const Duration(milliseconds: 500), () {
          print('[VANTRA][SECURITY] Handshake delay complete for ${update.endpointId}. Initiating secure handshake.');
          _initiateSecureHandshake(update.endpointId);
        });
      }
    } else if (update.status == ConnectionStatus.connecting) {
      print('[VANTRA][SECURITY] STATE: CONNECTING (endpointId=${update.endpointId}, isIncoming=${update.isIncoming}, token=${update.authenticationToken})');
      print('[VANTRA][NEARBY] GLOBAL_REQUEST_RECEIVED endpoint=${update.endpointId}');

      if (candidatePeerId != null && candidatePeerId.isNotEmpty) {
        print('[VANTRA][NEARBY] ENDPOINT_RESOLVED endpointId=${update.endpointId} peerId=$candidatePeerId');
        final repo = ref.read(messagingRepositoryProvider);
        repo.getPeer(candidatePeerId).then((dbPeer) async {
          if (dbPeer != null && dbPeer.trustState == PeerTrustState.trusted) {
            print('[VANTRA][NEARBY] Auto-accepting trusted peer candidate in background endpointId=${update.endpointId}');
            
            final updatedSession = PeerSession(
              peerId: candidatePeerId,
              displayName: candidateName,
              endpointId: update.endpointId,
              status: SessionStatus.handshaking,
              trustState: PeerTrustState.trusted,
              publicKey: dbPeer.publicKey,
              fingerprint: dbPeer.fingerprint,
              isSecure: false,
            );

            state = state.copyWith(
              connectionStatus: ConnectionStatus.connecting,
              activeEndpointId: update.endpointId,
              activeEndpointName: candidateName,
              sessions: {
                ...state.sessions,
                candidatePeerId: updatedSession,
              },
              endpointToPeerId: {
                ...state.endpointToPeerId,
                update.endpointId: candidatePeerId,
              },
            );

            await acceptConnectionRequest(update.endpointId);
          } else if (dbPeer != null && dbPeer.trustState == PeerTrustState.distrusted) {
            print('[VANTRA][SECURITY] BLOCKED PEER CONNECTION REJECTED: peerId=$candidatePeerId, endpointId=${update.endpointId}');
            await rejectConnectionRequest(update.endpointId);
          } else {
            _showManualPairingOverlay(update, candidateName, candidatePeerId);
          }
        }).catchError((_) {
          _showManualPairingOverlay(update, candidateName, candidatePeerId);
        });
      } else {
        _showManualPairingOverlay(update, candidateName, null);
      }
    } else if (update.status == ConnectionStatus.disconnected ||
        update.status == ConnectionStatus.rejected ||
        update.status == ConnectionStatus.error) {
      print('[VANTRA][SECURITY] STATE: DISCONNECTED/REJECTED/ERROR (endpointId=${update.endpointId}, status=${update.status.name})');
      _acceptedEndpoints.remove(update.endpointId);
      _rejectedEndpoints.remove(update.endpointId);

      final peerId = state.endpointToPeerId[update.endpointId];
      if (peerId != null) {
        print('[VANTRA][CRYPTO] SESSION DESTROYED endpointId=${update.endpointId}');
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
        clearActiveConnectionRequest: true,
      );
    } else {
      state = state.copyWith(
        connectionStatus: update.status,
      );
    }
  }

  void _showManualPairingOverlay(ConnectionUpdate update, String displayName, String? candidatePeerId) {
    state = state.copyWith(
      connectionStatus: ConnectionStatus.connecting,
      activeEndpointId: update.endpointId,
      activeEndpointName: displayName,
      activeConnectionRequest: ConnectionRequestInfo(
        endpointId: update.endpointId,
        endpointName: displayName,
        authenticationToken: update.authenticationToken,
        isIncoming: update.isIncoming,
      ),
    );
    if (candidatePeerId != null) {
      state = state.copyWith(
        endpointToPeerId: {
          ...state.endpointToPeerId,
          update.endpointId: candidatePeerId,
        },
      );
    }
  }

  Future<void> acceptConnectionRequest(String endpointId) async {
    print('[VANTRA][NEARBY] ACCEPT_PRESSED endpoint=$endpointId');
    if (_acceptedEndpoints.contains(endpointId)) {
      print('[VANTRA][NEARBY] Already accepted endpoint $endpointId, skipping duplicate accept call');
      return;
    }
    _acceptedEndpoints.add(endpointId);
    
    // Clear activeConnectionRequest from state so overlay dismisses immediately
    state = state.copyWith(clearActiveConnectionRequest: true);

    try {
      final transport = ref.read(transportProvider);
      await transport.acceptConnection(endpointId);
    } catch (e) {
      print('[VANTRA][NEARBY] Error calling acceptConnection on transport: $e');
    }
  }

  Future<void> rejectConnectionRequest(String endpointId) async {
    print('[VANTRA][NEARBY] REJECT_PRESSED endpoint=$endpointId');
    if (_rejectedEndpoints.contains(endpointId) || _acceptedEndpoints.contains(endpointId)) {
      print('[VANTRA][NEARBY] Already processed endpoint $endpointId, skipping reject call');
      return;
    }
    _rejectedEndpoints.add(endpointId);

    // Clear activeConnectionRequest from state so overlay dismisses immediately
    state = state.copyWith(clearActiveConnectionRequest: true);

    try {
      final transport = ref.read(transportProvider);
      await transport.rejectConnection(endpointId);
    } catch (e) {
      print('[VANTRA][NEARBY] Error calling rejectConnection on transport: $e');
    }
  }

  Future<void> acceptIdentityChange(String peerId, String newPublicKey) async {
    print('[VANTRA][NEARBY] USER_ACCEPTED_IDENTITY_CHANGE peerId=$peerId');
    final repo = ref.read(messagingRepositoryProvider);
    final existingPeer = await repo.getPeer(peerId);
    if (existingPeer != null) {
      final fingerprint = await _cryptoService.computeFingerprint(_hexDecode(newPublicKey));
      await repo.upsertPeer(
        peerId,
        existingPeer.displayName,
        publicKey: newPublicKey,
        fingerprint: fingerprint,
        trustState: PeerTrustState.untrusted,
        protocolVersion: existingPeer.protocolVersion,
      );
    }
    state = state.copyWith(clearIdentityMismatchRequest: true);
  }

  Future<void> rejectIdentityChange(String peerId) async {
    print('[VANTRA][NEARBY] USER_REJECTED_IDENTITY_CHANGE peerId=$peerId');
    final repo = ref.read(messagingRepositoryProvider);
    await repo.updatePeerTrustState(peerId, PeerTrustState.distrusted);
    state = state.copyWith(clearIdentityMismatchRequest: true);
  }

  Future<void> _initiateSecureHandshake(String endpointId) async {
    print('[VANTRA][SECURITY] INITIATING HANDSHAKE: outbound to $endpointId');
    print('[VANTRA][NEARBY] HANDSHAKE_START endpoint=$endpointId');
    final localNotifier = ref.read(localIdentityStateProvider.notifier);
    await localNotifier.ensureKeysLoaded();
    final localId = ref.read(localIdentityStateProvider);

    if (localId.keyPair == null) {
      print('[VANTRA][SECURITY] Cannot initiate handshake: Local keypair not ready');
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

    print('[VANTRA][SECURITY] OUTBOUND HANDSHAKE DETAILS: localPeerId=${localId.peerId}, localFingerprint=${localId.fingerprint}, ephPubLen=${ephPub.bytes.length}, sigLen=${signatureBytes.length}');

    // 3. Transmit IDENTITY_SECURE protobuf packet (using V1 wire version for compatibility)
    await _service.sendSecureIdentity(
      endpointId: endpointId,
      peerId: localId.peerId,
      displayName: localId.displayName,
      identityPublicKey: Uint8List.fromList(idPubBytes),
      ephemeralPublicKey: Uint8List.fromList(ephPub.bytes),
      signature: Uint8List.fromList(signatureBytes),
      protocolVersion: 1, // V1 wire compatibility
      minSupportedVersion: kMinSupportedProtocolVersion,
      maxSupportedVersion: kCurrentProtocolVersion,
      supportedCapabilities: const [VantraCapability.text],
    );
    print('[VANTRA][SECURITY] HANDSHAKE PACKET SENT to $endpointId');
  }

  Future<void> _sendCapabilitiesExchange(String peerId) async {
    final session = state.sessions[peerId];
    final secSession = _securitySessions[peerId];
    if (session == null || secSession == null) return;

    final msgId = const Uuid().v4();
    final seq = secSession.nextSendSequence();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    final domainPlaintext = DomainCapabilitiesExchange(
      messageId: msgId,
      sessionId: secSession.sessionId,
      sequence: seq,
      timestampMs: timestamp,
      senderId: ref.read(localIdentityStateProvider).peerId,
      receiverId: peerId,
      minSupportedVersion: kMinSupportedProtocolVersion,
      maxSupportedVersion: kCurrentProtocolVersion,
      supportedCapabilities: const [VantraCapability.text],
    );

    final bytes = _service.codec.encodePlaintext(domainPlaintext);

    final encrypted = await _cryptoService.encryptBytes(
      secretKey: secSession.sendKey,
      sessionSalt: secSession.sessionSalt,
      sequence: seq,
      messageId: msgId,
      plaintextBytes: bytes,
    );

    await _service.sendEncryptedMessage(
      endpointId: session.endpointId,
      messageId: msgId,
      sessionId: secSession.sessionId,
      sequence: seq,
      nonce: Uint8List.fromList(encrypted.nonce),
      ciphertext: Uint8List.fromList(encrypted.ciphertext),
      mac: Uint8List.fromList(encrypted.mac),
      protocolVersion: session.negotiatedVersion ?? kCurrentProtocolVersion,
    );
    print('[VANTRA][SECURITY] Sent CapabilitiesExchange to ${session.endpointId}');
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

    VantraLogger.log('[VANTRA][PROTO] PLAINTEXT BUILD START messageId=${msg.messageId} sequence=$seq sessionIdPresent=${secSession.sessionId.isNotEmpty}');
    try {
      Uint8List plaintextBytes;
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

        plaintextBytes = _service.codec.encodePlaintext(domainPlaintext);
        VantraLogger.log('[VANTRA][PROTO] PLAINTEXT ENCODE SUCCESS messageId=${msg.messageId} byteLength=${plaintextBytes.length}');
      } catch (e) {
        VantraLogger.log('[VANTRA][PROTO] PLAINTEXT ENCODE FAILED messageId=${msg.messageId}');
        rethrow;
      }

      VantraLogger.log('[VANTRA][CRYPTO] ENCRYPT START messageId=${msg.messageId} sequence=$seq');
      final encrypted = await _cryptoService.encryptBytes(
        secretKey: secSession.sendKey,
        sessionSalt: secSession.sessionSalt,
        sequence: seq,
        messageId: msg.messageId,
        plaintextBytes: plaintextBytes,
      );
      VantraLogger.log('[VANTRA][CRYPTO] ENCRYPT SUCCESS messageId=${msg.messageId} nonceLength=12 ciphertextLength=${encrypted.ciphertext.length} macLength=16');

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
    VantraLogger.log('[VANTRA][MESSAGING] SEND START peerId=$peerId textLength=${text.length}');
    final session = state.sessions[peerId];
    final endpointId = session?.endpointId ?? 'none';
    final connectionStatus = session?.status.name ?? 'none';
    final securityState = session?.isSecure == true ? 'SECURE' : 'unsecure';
    final hasSessionKeys = _securitySessions[peerId] != null;
    VantraLogger.log('[VANTRA][MESSAGING] SESSION CHECK peerId=$peerId endpointId=$endpointId connectionStatus=$connectionStatus securityState=$securityState hasSessionKeys=$hasSessionKeys');

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
    VantraLogger.log('[VANTRA][DB] OUTBOUND INSERT START messageId=$messageId status=pending');
    try {
      await repository.saveOutgoingMessage(msg);
      VantraLogger.log('[VANTRA][DB] OUTBOUND INSERT SUCCESS messageId=$messageId');
    } catch (e) {
      VantraLogger.log('[VANTRA][DB] OUTBOUND INSERT FAILED messageId=$messageId errorType=${e.runtimeType}');
      rethrow;
    }

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
      VantraLogger.log('[VANTRA][CRYPTO] SESSION DESTROYED endpointId=${session.endpointId}');
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

  @visibleForTesting
  Map<String, SecuritySession> get securitySessions => _securitySessions;

  List<int> _hexDecode(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}
