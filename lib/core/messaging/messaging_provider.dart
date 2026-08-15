// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
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
    bool clearActiveEndpoint = false,
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
      activeEndpointId: clearActiveEndpoint
          ? null
          : (activeEndpointId ?? this.activeEndpointId),
      activeEndpointName: clearActiveEndpoint
          ? null
          : (activeEndpointName ?? this.activeEndpointName),
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
  final Map<String, Completer<DomainMediaControl>> _mediaCompleters = {};
  final Map<String, double> _transferProgress = {};
  final Set<String> _inflightSends = {};

  double getTransferProgress(String transferId) => _transferProgress[transferId] ?? 0.0;

  bool hasActiveSecureTransport(String peerId) {
    final session = state.sessions[peerId];
    final secSession = _securitySessions[peerId];

    if (session == null || secSession == null) return false;
    if (!session.isSecure) return false;
    if (state.activeEndpointId == null) return false;
    if (state.connectionStatus != ConnectionStatus.connected) return false;
    if (session.endpointId != state.activeEndpointId) return false;
    if (secSession.endpointId != state.activeEndpointId) return false;

    return true;
  }

  // Connection Request Idempotency Tracking
  final Set<String> _acceptedEndpoints = {};
  final Set<String> _rejectedEndpoints = {};
  final Set<String> _activeConnectLocks = {};
  final Map<String, Timer> _handshakeTimers = {};

  StreamSubscription? _discoveredPeersSub;
  final Map<String, DateTime> _lastConnectAttempt = {};
  final Map<String, Duration> _reconnectBackoff = {};
  List<DiscoveredNearbyPeer> _lastDiscoveredList = [];
  Timer? _reconnectTimer;

  Future<void>? _incomingProcessingChain;

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
    _reconnectTimer?.cancel();
    _incomingProcessingChain = null;

    _connectionSub = transport.connectionUpdateStream.listen(_handleConnectionUpdate);
    _encryptedMessageSub = _service.encryptedMessageStream.listen((event) {
      final completer = Completer<void>();
      final previous = _incomingProcessingChain;
      _incomingProcessingChain = completer.future;

      Future<void> process() async {
        if (previous != null) {
          try {
            await previous;
          } catch (_) {}
        }
        try {
          await _handleIncomingEncryptedMessage(event);
        } catch (e, stack) {
          print('[VANTRA][MESSAGING] Error handling incoming encrypted message: $e');
          VantraLogger.log('[VANTRA][MESSAGING] Error handling incoming encrypted message: $e', e, stack);
        } finally {
          completer.complete();
        }
      }

      process();
    });
    _secureIdentitySub = _service.secureIdentityStream.listen(_handleSecureIdentityReceived);
    _discoveredPeersSub = discoveryService.discoveredPeersStream.listen(_handleDiscoveredPeersUpdate);

    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _handleDiscoveredPeersUpdate(_lastDiscoveredList);
    });

    ref.onDispose(() {
      _connectionSub?.cancel();
      _encryptedMessageSub?.cancel();
      _secureIdentitySub?.cancel();
      _discoveredPeersSub?.cancel();
      _reconnectTimer?.cancel();
      for (final session in _securitySessions.values) {
        print('[VANTRA][SESSION] SESSION_INVALIDATED peerId=${session.peerId} reason=Provider disposed');
        print('[VANTRA][PIPELINE] STATE_INVALIDATION source=onDispose endpoint=${session.endpointId} peerId=${session.peerId} reason=Provider disposed');
        VantraLogger.log('[VANTRA][CRYPTO] SESSION DESTROYED endpointId=${session.endpointId}');
      }
      _securitySessions.clear();
      _pendingEphemeralKeys.clear();
      _activePeerFlushes.clear();
      _acceptedEndpoints.clear();
      _rejectedEndpoints.clear();
      _activeConnectLocks.clear();
      for (final t in _handshakeTimers.values) {
        t.cancel();
      }
      _handshakeTimers.clear();
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

  @visibleForTesting
  Set<String> get activeConnectLocks => _activeConnectLocks;

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
        print('[VANTRA][SESSION] state=${state.sessions[peerId]?.status.name}');
        print('[VANTRA][SESSION] sendCounter=${session.sendSequence}');
        print('[VANTRA][SESSION] receiveCounter=${session.receiveSequence}');
        print('[VANTRA][SESSION] endpoint=${session.endpointId}');
        print('[VANTRA][SESSION] keyAvailable=true');
        decryptedBytes = await _cryptoService.decryptBytes(
          secretKey: session.receiveKey,
          nonce: event.nonce,
          ciphertext: event.ciphertext,
          mac: event.mac,
          messageId: event.messageId,
        );
        print('[VANTRA][MESSAGE] DECRYPT_SUCCESS messageId=${event.messageId}');
        print('[VANTRA][CRYPTO] DECRYPT_SUCCESS messageId=${event.messageId}');
        VantraLogger.log('[VANTRA][CRYPTO] DECRYPT SUCCESS messageId=${event.messageId} plaintextLength=${decryptedBytes.length}');
      } catch (e) {
        VantraLogger.log('[VANTRA][CRYPTO] DECRYPT FAILED messageId=${event.messageId} errorType=${e.runtimeType}');
        rethrow;
      }

      // 2. Decode authenticated plaintext protobuf
      final plaintext = _service.codec.decodePlaintext(decryptedBytes);
      VantraLogger.log('[VANTRA][MESSAGING] MESSAGE RECONSTRUCTED messageId=${plaintext.messageId} senderId=${plaintext.senderId} receiverId=${plaintext.receiverId} timestamp=${plaintext.timestampMs}');

      String transferIdVal = 'none';
      if (plaintext is DomainMediaControl) {
        transferIdVal = plaintext.transferId;
      } else if (plaintext is DomainMediaChunk) {
        transferIdVal = plaintext.transferId;
      }
      print('[VANTRA][MEDIA][ENVELOPE]\n'
            'messageId=${plaintext.messageId}\n'
            'payloadType=${plaintext.runtimeType}\n'
            'transferId=$transferIdVal');

      // 3. Replay Protection: verify sequence > lastSeenReceiveSequence & matching session ID
      if (plaintext.sessionId != session.sessionId || plaintext.sequence <= session.receiveSequence) {
        VantraLogger.log('[VANTRA][SECURITY] REPLAY / INVALID SEQUENCE: messageId=${plaintext.messageId}, seq=${plaintext.sequence} <= receiveSequence=${session.receiveSequence} or sessionId mismatch. Discarded.');
        return;
      }
      session.updateReceiveSequence(plaintext.sequence);
      print('[VANTRA][PIPELINE] MESSAGE_RECEIVED endpoint=${event.endpointId} peerId=$peerId');

      final currentSession = state.sessions[peerId];
      if (plaintext is! DomainCapabilitiesExchange &&
          currentSession != null &&
          session.endpointId == event.endpointId &&
          currentSession.endpointId == event.endpointId &&
          (currentSession.status != SessionStatus.connected || !currentSession.isSecure)) {
        print('[VANTRA][SESSION][RECOVERY]\n'
              'Valid encrypted message received for peer $peerId on endpoint ${event.endpointId}.\n'
              'Restoring session status to connected.');
        _stateUpdateSource = '_handleIncomingEncryptedMessage_recovery';
        state = state.copyWith(
          sessions: {
            ...state.sessions,
            peerId: currentSession.copyWith(
              status: SessionStatus.connected,
              isSecure: true,
            ),
          },
        );
      }

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
          print('[VANTRA][MESSAGE] STORED messageId=${incomingMsg.messageId}');
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
        _inflightSends.remove(plaintext.originalMessageId);

        final dbMsg = await repository.getMessageById(plaintext.originalMessageId);

        if (dbMsg != null && (dbMsg.type == 'IMAGE' || dbMsg.type == 'FILE')) {
          print('[VANTRA][MEDIA][ACK_RECEIVED]\n'
                'messageId=${plaintext.originalMessageId}\n'
                'transferId=${dbMsg.transferId ?? "none"}');
        } else {
          VantraLogger.log('[VANTRA][RECEIVE] ACK matched=${dbMsg != null} ackPacketId=${plaintext.messageId} targetMessageId=${plaintext.originalMessageId}');
        }

        VantraLogger.log('[VANTRA][DB] MESSAGE STATUS UPDATE messageId=${plaintext.originalMessageId} status=delivered');
        await repository.updateMessageStatus(plaintext.originalMessageId, MessageStatus.delivered);
        // Flush queue to process next FIFO message
        _flushQueue(peerId, 'DomainAckMessage');
      } else if (plaintext is DomainCapabilitiesExchange) {
        print('[VANTRA][SESSION][HANDSHAKE] stage=CAPABILITIES_RECEIVED peerId=$peerId endpoint=${event.endpointId}');
        print('[VANTRA][SECURITY] Received CapabilitiesExchange from ${event.endpointId}');
        
        final secSession = _securitySessions[peerId];
        if (secSession == null) {
          VantraLogger.log('[VANTRA][SECURITY] Dropping capabilities: No active security session for peer $peerId');
          return;
        }

        final activeSession = state.sessions[peerId];

        // Enforce SessionStatus.connected and keep state synchronized with the authoritative secure session
        final localCapabilities = const [
          VantraCapability.text,
          VantraCapability.image,
          VantraCapability.file,
        ];
        final negotiatedCapabilities = localCapabilities
            .where((c) => plaintext.supportedCapabilities.contains(c))
            .toList();

        print('[VANTRA][SECURITY] Negotiated capabilities for peer $peerId: '
            'localCapabilities=${localCapabilities.map((c) => c.name).toList()}, '
            'remoteCapabilities=${plaintext.supportedCapabilities.map((c) => c.name).toList()}, '
            'negotiatedCapabilities=${negotiatedCapabilities.map((c) => c.name).toList()}');

        final baseSession = activeSession ?? PeerSession(
          peerId: peerId,
          displayName: secSession.peerId, // best effort fallback
          endpointId: event.endpointId,
          status: SessionStatus.connected,
          publicKey: secSession.remoteIdentityPublicKey,
          fingerprint: secSession.remoteFingerprint,
          isSecure: true,
        );

        if (activeSession != null) {
          print('[VANTRA][SECURITY] Checking early return: '
              'activeSession.status=${activeSession.status.name}, '
              'activeSession.endpointId=${activeSession.endpointId}, '
              'activeSession.enabledCapabilities=${activeSession.enabledCapabilities?.map((c) => c.name).toList()}, '
              'event.endpointId=${event.endpointId}');

          if (activeSession.status == SessionStatus.connected &&
              activeSession.enabledCapabilities != null &&
              activeSession.endpointId == event.endpointId) {
            print('[VANTRA][SECURITY] CapabilitiesExchange early return: already connected with capabilities! Discarding capabilities payload.');
            // Already negotiated. Just reply with ACK to clear remote queue.
            await _sendAck(event.endpointId, secSession, plaintext.messageId);
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
        }

        final readySession = baseSession.copyWith(
          status: SessionStatus.connected,
          endpointId: event.endpointId,
          isSecure: true,
          enabledCapabilities: negotiatedCapabilities,
          remoteMinVersion: plaintext.minSupportedVersion,
          remoteMaxVersion: plaintext.maxSupportedVersion,
          remoteCapabilities: plaintext.supportedCapabilities,
        );

        state = state.copyWith(
          sessions: {
            ...state.sessions,
            peerId: readySession,
          },
          endpointToPeerId: {
            ...state.endpointToPeerId,
            event.endpointId: peerId,
          },
          activeEndpointId: event.endpointId,
          connectionStatus: ConnectionStatus.connected,
        );

        print('[VANTRA][SESSION][HANDSHAKE] stage=PEER_READY peerId=$peerId endpoint=${event.endpointId}');
        print('[VANTRA][SESSION][SECURE] Capability negotiation complete. Peer $peerId is now ready for communication.');
        print('[VANTRA][SECURITY] CAPABILITY_NEGOTIATION_SUCCESS for peer $peerId. Enabled capabilities: $negotiatedCapabilities');

        await _sendAck(event.endpointId, secSession, plaintext.messageId);
        _flushQueue(peerId, 'DomainCapabilitiesExchange');
      } else if (plaintext is DomainMediaControl) {
        if (plaintext.type == DomainMediaControlType.offer) {
          print('[VANTRA][MEDIA][OFFER_RECEIVED]\n'
                'messageId=${plaintext.messageId}\n'
                'transferId=${plaintext.transferId}\n'
                'fileSize=${plaintext.fileSize}\n'
                'mimeType=${plaintext.mimeType}');
          final mime = plaintext.mimeType;
          final isImage = mime != null &&
              (mime.startsWith('image/jpeg') ||
               mime.startsWith('image/png') ||
               mime.startsWith('image/webp')) &&
              (plaintext.width != null && plaintext.width! > 0);
          final capability = isImage ? VantraCapability.image : VantraCapability.file;
          final isSupported = activeSession?.enabledCapabilities?.contains(capability) ?? false;
          if (!isSupported) {
            VantraLogger.log('[VANTRA][MESSAGING] Received OFFER for $capability, but capability not enabled.');
            if (activeSession != null) {
              await _sendMediaReject(event.endpointId, session, plaintext.transferId);
            }
            return;
          }
          final sizeLimit = isImage ? 10 * 1024 * 1024 : 200 * 1024 * 1024;
          if (plaintext.fileSize != null && plaintext.fileSize! > sizeLimit) {
            VantraLogger.log('[VANTRA][MESSAGING] Media OFFER exceeds size limit: ${plaintext.fileSize}');
            if (activeSession != null) {
              await _sendMediaReject(event.endpointId, session, plaintext.transferId);
            }
            return;
          }

          final existingMsg = await repository.getMessageById(plaintext.messageId);
          if (existingMsg != null) {
            if (activeSession != null) {
              await _sendAck(event.endpointId, session, plaintext.messageId);
            }
            return;
          }

          final type = isImage ? 'IMAGE' : 'FILE';
          final dirPrefix = isImage ? 'media' : 'files';

          final appDir = await getApplicationDocumentsDirectory();
          final tempDir = Directory(path.join(appDir.path, dirPrefix, 'temp', plaintext.transferId));
          int nextExpectedChunk = 0;
          if (await tempDir.exists()) {
            while (true) {
              final chunkFile = File(path.join(tempDir.path, 'chunk_$nextExpectedChunk'));
              if (await chunkFile.exists()) {
                nextExpectedChunk++;
              } else {
                break;
              }
            }
          } else {
            await tempDir.create(recursive: true);
          }

          final incomingMsg = VantraMessage(
            messageId: plaintext.messageId,
            senderId: plaintext.senderId,
            receiverId: plaintext.receiverId,
            text: plaintext.caption ?? '',
            timestamp: plaintext.timestampMs,
            status: MessageStatus.sending,
            type: type,
            fileName: plaintext.fileName,
            fileSize: plaintext.fileSize,
            width: plaintext.width,
            height: plaintext.height,
            transferId: plaintext.transferId,
            sha256: plaintext.sha256,
          );
          await repository.saveIncomingMessage(incomingMsg);

          if (activeSession != null) {
            await _sendMediaAccept(event.endpointId, session, plaintext.transferId, nextExpectedChunk);
          }
        } else if (plaintext.type == DomainMediaControlType.accept || plaintext.type == DomainMediaControlType.reject) {
          final completer = _mediaCompleters[plaintext.transferId];
          if (completer != null && !completer.isCompleted) {
            completer.complete(plaintext);
          }
        }
      } else if (plaintext is DomainMediaChunk) {
        final msg = await repository.getMessageByTransferId(plaintext.transferId);
        print('[VANTRA][MEDIA][CHUNK_RECEIVED]\n'
              'messageId=${msg?.messageId ?? "unknown"}\n'
              'transferId=${plaintext.transferId}\n'
              'chunkIndex=${plaintext.chunkIndex}\n'
              'totalChunks=${plaintext.totalChunks}');
        final isImage = msg == null || msg.type == 'IMAGE';
        final dirPrefix = isImage ? 'media' : 'files';

        final appDir = await getApplicationDocumentsDirectory();
        final tempDir = Directory(path.join(appDir.path, dirPrefix, 'temp', plaintext.transferId));
        if (!await tempDir.exists()) {
          await tempDir.create(recursive: true);
        }
        final chunkFile = File(path.join(tempDir.path, 'chunk_${plaintext.chunkIndex}'));
        await chunkFile.writeAsBytes(plaintext.data);

        _transferProgress[plaintext.transferId] = (plaintext.chunkIndex + 1) / plaintext.totalChunks;
        state = state.copyWith();

        bool allReceived = true;
        for (var i = 0; i < plaintext.totalChunks; i++) {
          final file = File(path.join(tempDir.path, 'chunk_$i'));
          if (!await file.exists()) {
            allReceived = false;
            break;
          }
        }

        if (allReceived) {
          VantraLogger.log('[VANTRA][MESSAGING] All chunks received for transferId=${plaintext.transferId}. Reassembling...');
          final incomingDir = Directory(path.join(appDir.path, dirPrefix, 'incoming'));
          if (!await incomingDir.exists()) {
            await incomingDir.create(recursive: true);
          }

          if (msg == null) {
            VantraLogger.log('[VANTRA][MESSAGING] Error: Message metadata missing for transferId=${plaintext.transferId}');
            return;
          }

          final ext = path.extension(msg.fileName ?? (isImage ? '.jpg' : '.bin'));
          final finalPath = path.join(incomingDir.path, '${msg.messageId}$ext');

          final outFile = File(finalPath);
          try {
            final ios = await outFile.open(mode: FileMode.write);
            try {
              for (var i = 0; i < plaintext.totalChunks; i++) {
                final chunkF = File(path.join(tempDir.path, 'chunk_$i'));
                final data = await chunkF.readAsBytes();
                await ios.writeFrom(data);
              }
            } finally {
              await ios.close();
            }

            final fileSizeVal = await outFile.length();
            print('[VANTRA][MEDIA][REASSEMBLY_COMPLETE]\n'
                  'messageId=${msg.messageId}\n'
                  'transferId=${msg.transferId}\n'
                  'chunksReceived=${plaintext.totalChunks}\n'
                  'expectedChunks=${plaintext.totalChunks}\n'
                  'fileSize=$fileSizeVal');
          } catch (writeErr) {
            print('[VANTRA][MEDIA][REASSEMBLY_FAILED]\n'
                  'messageId=${msg.messageId}\n'
                  'transferId=${msg.transferId}\n'
                  'reason=File reassembly write error: $writeErr');
            await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
            return;
          }

          // Verify SHA-256 integrity hash if provided
          if (msg.sha256 != null && msg.sha256!.isNotEmpty) {
            try {
              final fileStream = outFile.openRead();
              final hashVal = await sha256.bind(fileStream).first;
              final computedHash = hashVal.toString();
              if (computedHash != msg.sha256) {
                VantraLogger.log('[VANTRA][MESSAGING] Hash verification failed for transferId=${plaintext.transferId}. Expected: ${msg.sha256}, Computed: $computedHash');
                print('[VANTRA][MEDIA][REASSEMBLY_FAILED]\n'
                      'messageId=${msg.messageId}\n'
                      'transferId=${msg.transferId}\n'
                      'reason=Hash verification failed. Expected: ${msg.sha256}, Computed: $computedHash');
                await outFile.delete();
                await tempDir.delete(recursive: true);
                await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
                return;
              }
              VantraLogger.log('[VANTRA][MESSAGING] Hash verified successfully for transferId=${plaintext.transferId}');
            } catch (hashErr) {
              VantraLogger.log('[VANTRA][MESSAGING] Error during hash verification: $hashErr');
              print('[VANTRA][MEDIA][REASSEMBLY_FAILED]\n'
                    'messageId=${msg.messageId}\n'
                    'transferId=${msg.transferId}\n'
                    'reason=Hash verification error: $hashErr');
              await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
              return;
            }
          }

          await tempDir.delete(recursive: true);
          await repository.updateIncomingMediaDetails(msg.messageId, finalPath, MessageStatus.received);

          final finalSize = await File(finalPath).length();
          print('[VANTRA][MEDIA][FILE_STORED]\n'
                'messageId=${msg.messageId}\n'
                'transferId=${msg.transferId}\n'
                'path=$finalPath\n'
                'bytes=$finalSize');

          print('[VANTRA][MEDIA][REMOTE_RECEIVED]\n'
                'messageId=${msg.messageId}\n'
                'peerId=${activeSession?.peerId ?? "none"}\n'
                'messageType=${msg.type}\n'
                'currentStatus=received\n'
                'attemptCount=${msg.retryCount}\n'
                'endpointId=${event.endpointId}\n'
                'session state=${activeSession?.status.name ?? "none"}');

          if (activeSession != null) {
            print('[VANTRA][MEDIA][ACK_SEND]\n'
                  'messageId=${msg.messageId}\n'
                  'transferId=${msg.transferId}');
            await _sendAck(event.endpointId, session, msg.messageId);
          }
        }
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
    final activeSession = state.sessions[identity.peerId];
    if (activeSession != null &&
        activeSession.status == SessionStatus.connected &&
        activeSession.endpointId == identity.endpointId) {
      print('[VANTRA][SESSION][HANDSHAKE] stage=HANDSHAKE_RECEIVED peerId=${identity.peerId} endpoint=${identity.endpointId} info=Duplicate handshake ignored on active connection');
      return;
    }

    print('[VANTRA][SESSION][HANDSHAKE] stage=HANDSHAKE_RECEIVED peerId=${identity.peerId} endpoint=${identity.endpointId}');
    print('[VANTRA][PIPELINE] HANDSHAKE_RECEIVED endpoint=${identity.endpointId} peerId=${identity.peerId}');
    print('[VANTRA][SESSION][IDENTITY] Handshake packet received from displayName=${identity.displayName} peerId=${identity.peerId}');
    print('[VANTRA][SECURITY] INBOUND HANDSHAKE: peerId=${identity.peerId}, displayName=${identity.displayName}, endpointId=${identity.endpointId}, v=${identity.protocolVersion}');

    // Reject unsupported protocol versions
    if (identity.protocolVersion < kMinSupportedProtocolVersion || identity.protocolVersion > kCurrentProtocolVersion) {
      print('[VANTRA][SESSION][HANDSHAKE] stage=HANDSHAKE_DECODED peerId=${identity.peerId} endpoint=${identity.endpointId} error=Unsupported protocol version');
      print('[VANTRA][SECURITY] Unsupported protocol version: ${identity.protocolVersion}');
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);
      return;
    }

    final idKeyBytes = _hexDecode(identity.identityPublicKeyHex);
    final ephKeyBytes = _hexDecode(identity.ephemeralPublicKeyHex);
    final sigBytes = _hexDecode(identity.signatureHex);

    print('[VANTRA][SESSION][HANDSHAKE] stage=HANDSHAKE_DECODED peerId=${identity.peerId} endpoint=${identity.endpointId}');

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
      print('[VANTRA][SESSION][HANDSHAKE] stage=IDENTITY_VERIFIED peerId=${identity.peerId} endpoint=${identity.endpointId} error=Signature verification failed');
      print('[VANTRA][SESSION][IDENTITY] Signature verification failed for peer ${identity.peerId}');
      print('[VANTRA][SECURITY] SIGNATURE VERIFICATION: result=FAILED! Disconnecting untrusted peer.');
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);
      return;
    }

    print('[VANTRA][SESSION][HANDSHAKE] stage=IDENTITY_VERIFIED peerId=${identity.peerId} endpoint=${identity.endpointId}');
    print('[VANTRA][SESSION][IDENTITY] Signature verification succeeded for peer ${identity.peerId}');
    print('[VANTRA][SECURITY] SIGNATURE VERIFICATION: result=SUCCESS');
    print('[VANTRA][SECURITY] STATE: IDENTITY_VERIFIED');
    print('[VANTRA][CONNECTION] IDENTITY_RECEIVED: peerId=${identity.peerId}, endpointId=${identity.endpointId}');

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

    DerivedSessionKeys derivedKeys;
    try {
      derivedKeys = await _cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: localEphKeyPair,
        remoteEphemeralPublicKeyBytes: ephKeyBytes,
      );
      print('[VANTRA][SESSION][HANDSHAKE] stage=SESSION_DERIVED peerId=${identity.peerId} endpoint=${identity.endpointId}');
      print('[VANTRA][SESSION][CRYPTO] Session keys derived successfully for peer ${identity.peerId}');
    } catch (e) {
      print('[VANTRA][SESSION][HANDSHAKE] stage=SESSION_DERIVED peerId=${identity.peerId} endpoint=${identity.endpointId} error=Key derivation failed: $e');
      print('[VANTRA][SESSION][CRYPTO] Key derivation failed for peer ${identity.peerId}: $e');
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);
      return;
    }

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
    _handshakeTimers[identity.endpointId]?.cancel();
    _activeConnectLocks.remove(identity.peerId);
    _reconnectBackoff.remove(identity.peerId);
    _lastConnectAttempt.remove(identity.peerId);

    print('[VANTRA][SESSION][HANDSHAKE] stage=SECURE_SESSION_READY peerId=${identity.peerId} endpoint=${identity.endpointId}');
    print('[VANTRA][PIPELINE] SECURE_SESSION_READY endpoint=${identity.endpointId} peerId=${identity.peerId}');
    print('[VANTRA][SESSION][SECURE] Cryptographic session ready for peer ${identity.peerId}');
    print('[VANTRA][CRYPTO] SESSION READY endpointId=${identity.endpointId} sessionId=${derivedKeys.sessionId} securityState=SECURE');
    print('[VANTRA][CONNECTION] SESSION_READY: peerId=${identity.peerId}, endpointId=${identity.endpointId}, sessionId=${derivedKeys.sessionId}');
    print('[VANTRA][SESSION] peer=${identity.peerId} state=SECURE');

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

    final localCapabilities = const [
      VantraCapability.text,
      VantraCapability.image,
      VantraCapability.file,
    ];
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

    if (isV1) {
      print('[VANTRA][SESSION][HANDSHAKE] stage=PEER_READY peerId=${identity.peerId} endpoint=${identity.endpointId}');
    }

    if (!isV1) {
      print('[VANTRA][SECURITY] Initiating V2 CapabilitiesExchange with peer ${identity.peerId}');
      await _sendCapabilitiesExchange(identity.peerId);
    } else {
      // Reconnection: Flush queue upon secure session establishment
      print('[VANTRA][MESSAGE] peer=${identity.peerId} queue_flush_started');
      _flushQueue(identity.peerId, '_handleSecureIdentityReceived');
    }
  }

  void _handleDiscoveredPeersUpdate(List<DiscoveredNearbyPeer> discoveredList) {
    _lastDiscoveredList = discoveredList;
    if (discoveredList.isEmpty) return;
    final localIdentity = ref.read(localIdentityStateProvider);
    if (localIdentity.peerId.isEmpty) return;

    final repo = ref.read(messagingRepositoryProvider);

    for (final peer in discoveredList) {
      final peerId = peer.resolvedPeerId;
      if (peerId == null || peerId.isEmpty) continue;

      if (_activeConnectLocks.contains(peerId)) {
        continue;
      }

      final session = state.sessions[peerId];
      if (session != null &&
          (session.status == SessionStatus.connected ||
           session.status == SessionStatus.connecting ||
           session.status == SessionStatus.handshaking)) {
        continue;
      }

      final lastAttempt = _lastConnectAttempt[peerId];
      final backoff = _reconnectBackoff[peerId] ?? const Duration(seconds: 1);
      if (lastAttempt != null && DateTime.now().difference(lastAttempt) < backoff) {
        continue;
      }

      // DETERMINISTIC INITIATOR DECISION
      final localPeerId = localIdentity.peerId;
      final remotePeerId = peerId;
      final comparison = localPeerId.compareTo(remotePeerId);
      final role = comparison < 0 ? 'INITIATOR' : 'RESPONDER';

      print('[VANTRA][CONNECTION] ROLE_DECISION localPeerId=$localPeerId remotePeerId=$remotePeerId role=$role');

      if (comparison >= 0) {
        continue;
      }

      repo.getPeer(peerId).then((dbPeer) {
        if (dbPeer != null && dbPeer.trustState == PeerTrustState.trusted) {
          if (_activeConnectLocks.contains(peerId)) return;
          final currentSession = state.sessions[peerId];
          if (currentSession != null &&
              (currentSession.status == SessionStatus.connected ||
               currentSession.status == SessionStatus.connecting ||
               currentSession.status == SessionStatus.handshaking)) {
             return;
          }

          print('[VANTRA][RECONNECT] Auto-reconnect triggered for peerId=$peerId, endpointId=${peer.endpointId}, backoff=${backoff.inSeconds}s');
          print('[VANTRA][NEARBY] TRUSTED_PEER_DISCOVERED peerId=$peerId name=${peer.effectiveName}');
          print('[VANTRA][NEARBY] AUTO_RECONNECT peerId=$peerId endpointId=${peer.endpointId}');

          _activeConnectLocks.add(peerId);
          _lastConnectAttempt[peerId] = DateTime.now();
          _reconnectBackoff[peerId] = Duration(seconds: (backoff.inSeconds * 2).clamp(1, 60));

          print('[VANTRA][RETRY] peer=$peerId retry_in=${_reconnectBackoff[peerId]!.inSeconds}s');
          print('[VANTRA][CONNECTION] REQUEST_START: endpointId=${peer.endpointId}, localName=${localIdentity.displayName}:${localIdentity.peerId}, mode=AUTO_CONNECT');
          print('[VANTRA][NEARBY] CONNECT_ATTEMPT endpointId=${peer.endpointId}');
          ref.read(peerDiscoveryServiceProvider).connect(
            peer.endpointId,
            localName: '${localIdentity.displayName}:${localIdentity.peerId}',
          ).then((_) {
            print('[VANTRA][CONNECTION] REQUEST_SUCCESS: endpointId=${peer.endpointId}');
          }).catchError((e) {
            _activeConnectLocks.remove(peerId);
            print('[VANTRA][CONNECTION] REQUEST_ERROR: endpointId=${peer.endpointId}, error=$e');
            print('[VANTRA][NEARBY] Auto-connect failed to connect for endpointId=${peer.endpointId}: $e');
          });
        }
      });
    }
  }

  void _handleConnectionUpdate(ConnectionUpdate update) {
    print('[VANTRA][CONNECTION] CONNECTION_STATUS_CHANGED: endpointId=${update.endpointId}, status=${update.status.name}');
    // Unconditional standard prints for diagnostic logging
    print('[VANTRA][SECURITY] CONNECTION UPDATE: endpointId=${update.endpointId}, status=${update.status.name}');

    final index = update.endpointName.indexOf(':');
    final candidateName = index != -1 ? update.endpointName.substring(0, index) : update.endpointName;
    final candidatePeerId = index != -1 ? update.endpointName.substring(index + 1) : null;

    if (update.status == ConnectionStatus.connected) {
      print('[VANTRA][SESSION][HANDSHAKE] stage=CONNECTED peerId=$candidatePeerId endpoint=${update.endpointId}');
      print('[VANTRA][CHAT-BRIDGE] Mapping endpointId=${update.endpointId} to peerId=$candidatePeerId');
      print('[VANTRA][CONNECTION] CONNECTION_CONNECTED: endpointId=${update.endpointId}');
      _acceptedEndpoints.remove(update.endpointId);
      _rejectedEndpoints.remove(update.endpointId);
      print('[VANTRA][NEARBY] CONNECTION_ESTABLISHED endpoint=${update.endpointId}');

      // Arm 15-second handshake watchdog timer
      _handshakeTimers[update.endpointId]?.cancel();
      _handshakeTimers[update.endpointId] = Timer(const Duration(seconds: 15), () async {
        print('[VANTRA][CONNECTION] HANDSHAKE_TIMEOUT endpointId=${update.endpointId}');
        final pId = state.endpointToPeerId[update.endpointId];
        if (pId != null) {
          final sess = state.sessions[pId];
          final currentSecSession = _securitySessions[pId];
          print('[VANTRA][PIPELINE] ENDPOINT_STATE endpoint=${update.endpointId} peerId=$pId activeEndpoint=${state.activeEndpointId} sessionEndpoint=${sess?.endpointId} secSessionEndpoint=${currentSecSession?.endpointId}');
          if ((sess != null && sess.endpointId != update.endpointId) ||
              (currentSecSession != null && currentSecSession.endpointId != update.endpointId)) {
            print('[VANTRA][PIPELINE] Ignoring stale handshake timeout for endpoint ${update.endpointId} because active session is on endpoint ${sess?.endpointId ?? currentSecSession?.endpointId}');
            return;
          }
          _activeConnectLocks.remove(pId);
          print('[VANTRA][PIPELINE] STATE_INVALIDATION source=watchdog_timer_lock endpoint=${update.endpointId} peerId=$pId reason=Cleared active connect lock');
          if (sess != null && !sess.isSecure) {
            print('[VANTRA][SECURITY] Handshake timed out for peer $pId. Destroying session and disconnecting.');
            print('[VANTRA][SESSION] SESSION_INVALIDATED peerId=$pId reason=Handshake timeout');
            print('[VANTRA][PIPELINE] STATE_INVALIDATION source=watchdog_timer endpoint=${update.endpointId} peerId=$pId reason=Handshake timeout');
            _securitySessions.remove(pId);
            _pendingEphemeralKeys.remove(update.endpointId);
            try {
              await ref.read(transportProvider).disconnect(update.endpointId);
            } catch (_) {}
          }
        }
      });

      if (candidatePeerId != null) {
        final existingSession = state.sessions[candidatePeerId];
        final initialSession = PeerSession(
          peerId: candidatePeerId,
          displayName: candidateName,
          endpointId: update.endpointId,
          status: SessionStatus.handshaking,
          trustState: existingSession?.trustState ?? PeerTrustState.untrusted,
          publicKey: existingSession?.publicKey,
          fingerprint: existingSession?.fingerprint,
          isSecure: false,
        );
        state = state.copyWith(
          connectionStatus: ConnectionStatus.connected,
          activeEndpointId: update.endpointId,
          activeEndpointName: candidateName,
          clearActiveConnectionRequest: true,
          sessions: {
            ...state.sessions,
            candidatePeerId: initialSession,
          },
          endpointToPeerId: {
            ...state.endpointToPeerId,
            update.endpointId: candidatePeerId,
          },
        );
        final repo = ref.read(messagingRepositoryProvider);
        repo.getPeer(candidatePeerId).then((dbPeer) {
          if (dbPeer != null) {
            final currentSession = state.sessions[candidatePeerId];
            if (currentSession != null && currentSession.endpointId == update.endpointId) {
              state = state.copyWith(
                sessions: {
                  ...state.sessions,
                  candidatePeerId: currentSession.copyWith(
                    trustState: dbPeer.trustState,
                    publicKey: dbPeer.publicKey,
                    fingerprint: dbPeer.fingerprint,
                  ),
                },
              );
            }
          }
        });
      } else {
        state = state.copyWith(
          connectionStatus: ConnectionStatus.connected,
          activeEndpointId: update.endpointId,
          activeEndpointName: candidateName,
          clearActiveConnectionRequest: true,
        );
      }
      print('[VANTRA][PIPELINE] CONNECTION_CONNECTED endpoint=${update.endpointId} peerId=$candidatePeerId');

      final transport = ref.read(transportProvider);
      final isFake = transport.runtimeType.toString().contains('Fake');
      if (isFake) {
        print('[VANTRA][SECURITY] STATE: CONNECTED (endpointId=${update.endpointId}). Initiating handshake immediately (test environment).');
        print('[VANTRA][CONNECTION] HANDSHAKE_STARTED: endpointId=${update.endpointId}');
        _initiateSecureHandshake(update.endpointId);
      } else {
        print('[VANTRA][SECURITY] STATE: CONNECTED (endpointId=${update.endpointId}). Handshake will start in 500ms.');
        print('[VANTRA][CONNECTION] HANDSHAKE_SCHEDULED: endpointId=${update.endpointId}');
        Future.delayed(const Duration(milliseconds: 500), () {
          print('[VANTRA][SECURITY] Handshake delay complete for ${update.endpointId}. Initiating secure handshake.');
          print('[VANTRA][CONNECTION] HANDSHAKE_STARTED: endpointId=${update.endpointId}');
          _initiateSecureHandshake(update.endpointId);
        });
      }
    } else if (update.status == ConnectionStatus.connecting) {
      print('[VANTRA][PIPELINE] CONNECTION_CONNECTING endpoint=${update.endpointId} peerId=$candidatePeerId');
      print('[VANTRA][CONNECTION] REQUEST_RECEIVED: endpointId=${update.endpointId}, peerName=$candidateName, direction=${update.isIncoming ? "incoming" : "outgoing"}');
      print('[VANTRA][SECURITY] STATE: CONNECTING (endpointId=${update.endpointId}, isIncoming=${update.isIncoming}, token=${update.authenticationToken})');
      print('[VANTRA][NEARBY] GLOBAL_REQUEST_RECEIVED endpoint=${update.endpointId}');

      final localIdentity = ref.read(localIdentityStateProvider);

      if (candidatePeerId != null && candidatePeerId.isNotEmpty) {
        final localPeerId = localIdentity.peerId;
        final remotePeerId = candidatePeerId;
        final role = localPeerId.compareTo(remotePeerId) < 0 ? 'INITIATOR' : 'RESPONDER';
        print('[VANTRA][CONNECTION] ROLE_DECISION localPeerId=$localPeerId remotePeerId=$remotePeerId role=$role');
      }

      // SIMULTANEOUS CONNECTION REQUEST SAFETY CHECK:
      if (update.isIncoming == true && state.activeEndpointId != null && state.activeEndpointId != update.endpointId) {
        final pendingOutgoingPeerId = state.endpointToPeerId[state.activeEndpointId];
        if (candidatePeerId != null && candidatePeerId == pendingOutgoingPeerId) {
          final localPeerId = localIdentity.peerId;
          final remotePeerId = candidatePeerId;
          final isInitiator = localPeerId.compareTo(remotePeerId) < 0;

          if (isInitiator) {
            print('[VANTRA][CONNECTION] DUPLICATE_REQUEST_IGNORED localPeerId=$localPeerId remotePeerId=$remotePeerId');
            rejectConnectionRequest(update.endpointId);
            return;
          } else {
            print('[VANTRA][CONNECTION] Outgoing request abandoned due to simultaneous incoming request from initiator $remotePeerId');
            // Cancel/abandon outgoing attempt by calling disconnect() at transport layer
            final outgoingEndpointId = state.activeEndpointId!;
            try {
              ref.read(transportProvider).disconnect(outgoingEndpointId);
            } catch (_) {}
            
            // Clean up the outgoing session local state to prepare for accepting the incoming request
            final newEndpointToPeerId = Map<String, String>.from(state.endpointToPeerId);
            newEndpointToPeerId.remove(outgoingEndpointId);
            state = state.copyWith(
              endpointToPeerId: newEndpointToPeerId,
            );
          }
        }
      }

      // Set activeEndpointId immediately to avoid race conditions during async database queries
      state = state.copyWith(
        connectionStatus: ConnectionStatus.connecting,
        activeEndpointId: update.endpointId,
        activeEndpointName: candidateName,
      );

      if (update.isIncoming == false) {
        print('[VANTRA][CONNECTION] Outgoing request auto-accepting in background: endpointId=${update.endpointId}');
        acceptConnectionRequest(update.endpointId);
        return;
      }

      if (candidatePeerId != null && candidatePeerId.isNotEmpty) {
        print('[VANTRA][NEARBY] ENDPOINT_RESOLVED endpointId=${update.endpointId} peerId=$candidatePeerId');
        final repo = ref.read(messagingRepositoryProvider);
        repo.getPeer(candidatePeerId).then((dbPeer) async {
          // Guard against race conditions where connection failed/disconnected while database lookup was running
          if (state.activeEndpointId != update.endpointId) {
            print('[VANTRA][NEARBY] Connection was aborted before database lookup finished for endpointId=${update.endpointId}');
            return;
          }

          if (dbPeer != null && dbPeer.trustState == PeerTrustState.trusted && state.identityMismatchRequest?.peerId != candidatePeerId) {
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
          if (state.activeEndpointId == update.endpointId) {
            _showManualPairingOverlay(update, candidateName, candidatePeerId);
          }
        });
      } else {
        _showManualPairingOverlay(update, candidateName, null);
      }
    } else if (update.status == ConnectionStatus.disconnected ||
        update.status == ConnectionStatus.rejected ||
        update.status == ConnectionStatus.error) {
      print('[VANTRA][CONNECTION] DISCONNECTED endpoint=${update.endpointId} reason=${update.status.name}');
      if (update.status == ConnectionStatus.disconnected) {
        print('[VANTRA][CONNECTION] CONNECTION_DISCONNECTED: endpointId=${update.endpointId}');
      } else if (update.status == ConnectionStatus.rejected) {
        print('[VANTRA][CONNECTION] CONNECTION_REJECTED: endpointId=${update.endpointId}');
      } else if (update.status == ConnectionStatus.error) {
        print('[VANTRA][CONNECTION] CONNECTION_ERROR: endpointId=${update.endpointId}, error=${update.errorMessage}');
      }
      print('[VANTRA][SECURITY] STATE: DISCONNECTED/REJECTED/ERROR (endpointId=${update.endpointId}, status=${update.status.name})');
      _acceptedEndpoints.remove(update.endpointId);
      _rejectedEndpoints.remove(update.endpointId);
      _handshakeTimers.remove(update.endpointId)?.cancel();

      final peerId = state.endpointToPeerId[update.endpointId] ?? candidatePeerId;
      if (peerId != null) {
        final currentSecSession = _securitySessions[peerId];
        final currentPeerSession = state.sessions[peerId];

        print('[VANTRA][PIPELINE] ENDPOINT_STATE endpoint=${update.endpointId} peerId=$peerId activeEndpoint=${state.activeEndpointId} sessionEndpoint=${currentPeerSession?.endpointId} secSessionEndpoint=${currentSecSession?.endpointId}');

        final bool isStale = (currentPeerSession != null && currentPeerSession.endpointId != update.endpointId) ||
                              (currentSecSession != null && currentSecSession.endpointId != update.endpointId);

        if (isStale) {
          print('[VANTRA][PIPELINE] Ignoring stale disconnect callback: endpoint=${update.endpointId} mismatch activeEndpoint=${currentPeerSession?.endpointId} or secSessionEndpoint=${currentSecSession?.endpointId}. DO NOT invalidate EP_NEW.');
        } else {
          print('[VANTRA][SESSION] SESSION_INVALIDATED peerId=$peerId reason=Connection status: ${update.status.name}');
          print('[VANTRA][PIPELINE] STATE_INVALIDATION source=_handleConnectionUpdate endpoint=${update.endpointId} peerId=$peerId reason=Connection status ${update.status.name}');
          print('[VANTRA][CRYPTO] SESSION DESTROYED endpointId=${update.endpointId}');
          _activeConnectLocks.remove(peerId);
          print('[VANTRA][PIPELINE] STATE_INVALIDATION source=_handleConnectionUpdate_lock endpoint=${update.endpointId} peerId=$peerId reason=Cleared active connect lock');
          _securitySessions.remove(peerId);
          _backoffTimers[peerId]?.cancel();
          _backoffTimers.remove(peerId);
          print('[VANTRA][PIPELINE] STATE_INVALIDATION source=_handleConnectionUpdate_backoff endpoint=${update.endpointId} peerId=$peerId reason=Connection update disconnected - cleared backoff timer');
          if (currentPeerSession != null) {
            _stateUpdateSource = '_handleConnectionUpdate';
            state = state.copyWith(
              sessions: {
                ...state.sessions,
                peerId: currentPeerSession.copyWith(status: SessionStatus.disconnected, isSecure: false),
              },
            );
          }
        }
      }
      _pendingEphemeralKeys.remove(update.endpointId);

      final newEndpointToPeerId = Map<String, String>.from(state.endpointToPeerId);
      newEndpointToPeerId.remove(update.endpointId);

      final bool isCurrentEndpoint = (state.activeEndpointId == update.endpointId);
      _stateUpdateSource = '_handleConnectionUpdate';
      state = state.copyWith(
        connectionStatus: isCurrentEndpoint ? update.status : state.connectionStatus,
        clearActiveEndpoint: isCurrentEndpoint,
        endpointToPeerId: newEndpointToPeerId,
        clearActiveConnectionRequest: isCurrentEndpoint,
      );
    } else {
      _stateUpdateSource = '_handleConnectionUpdate';
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
    print('[VANTRA][CONNECTION] REQUEST_ACCEPT_CLICKED: endpointId=$endpointId');
    print('[VANTRA][CONNECTION] ACCEPT_BUTTON_PRESSED: endpointId=$endpointId');
    print('[VANTRA][NEARBY] ACCEPT_PRESSED endpoint=$endpointId');
    if (_acceptedEndpoints.contains(endpointId)) {
      print('[VANTRA][NEARBY] Already accepted endpoint $endpointId, skipping duplicate accept call');
      return;
    }
    _acceptedEndpoints.add(endpointId);
    
    // Transition to accepting status but do NOT clear activeConnectionRequest yet
    state = state.copyWith(connectionStatus: ConnectionStatus.accepting);

    print('[VANTRA][CONNECTION] ACCEPT_START: endpointId=$endpointId');
    print('[VANTRA][CONNECTION] ACCEPT_CALL_START: endpointId=$endpointId');
    try {
      final transport = ref.read(transportProvider);
      await transport.acceptConnection(endpointId);
      print('[VANTRA][CONNECTION] ACCEPT_SUCCESS: endpointId=$endpointId');
      print('[VANTRA][CONNECTION] ACCEPT_CALL_SUCCESS: endpointId=$endpointId');
    } catch (e) {
      print('[VANTRA][CONNECTION] ACCEPT_ERROR: endpointId=$endpointId, error=$e');
      print('[VANTRA][CONNECTION] ACCEPT_CALL_ERROR: endpointId=$endpointId, error=$e');
      print('[VANTRA][NEARBY] Error calling acceptConnection on transport: $e');
    }
  }

  Future<void> rejectConnectionRequest(String endpointId) async {
    print('[VANTRA][CONNECTION] REQUEST_REJECT_CLICKED: endpointId=$endpointId');
    print('[VANTRA][NEARBY] REJECT_PRESSED endpoint=$endpointId');
    if (_rejectedEndpoints.contains(endpointId) ||
        _acceptedEndpoints.contains(endpointId) ||
        state.connectionStatus == ConnectionStatus.accepting ||
        state.connectionStatus == ConnectionStatus.connected) {
      print('[VANTRA][NEARBY] Already accepted, accepting, connected, or processed endpoint $endpointId, skipping reject call');
      return;
    }
    _rejectedEndpoints.add(endpointId);

    // Clear activeConnectionRequest from state so overlay dismisses immediately
    state = state.copyWith(clearActiveConnectionRequest: true);

    print('[VANTRA][CONNECTION] REJECT_CALL_START: endpointId=$endpointId');
    try {
      final transport = ref.read(transportProvider);
      await transport.rejectConnection(endpointId);
      print('[VANTRA][CONNECTION] REJECT_CALL_SUCCESS: endpointId=$endpointId');
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
    final peerId = state.endpointToPeerId[endpointId];
    print('[VANTRA][CONNECTION] HANDSHAKE_STARTED: endpointId=$endpointId');
    print('[VANTRA][PIPELINE] HANDSHAKE_STARTED endpoint=$endpointId peerId=$peerId');
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

    // 3. Transmit IDENTITY_SECURE protobuf packet
    await _service.sendSecureIdentity(
      endpointId: endpointId,
      peerId: localId.peerId,
      displayName: localId.displayName,
      identityPublicKey: Uint8List.fromList(idPubBytes),
      ephemeralPublicKey: Uint8List.fromList(ephPub.bytes),
      signature: Uint8List.fromList(signatureBytes),
      protocolVersion: kCurrentProtocolVersion,
      minSupportedVersion: kMinSupportedProtocolVersion,
      maxSupportedVersion: kCurrentProtocolVersion,
      supportedCapabilities: const [
        VantraCapability.text,
        VantraCapability.image,
        VantraCapability.file,
      ],
    );
    print('[VANTRA][SECURITY] HANDSHAKE PACKET SENT to $endpointId');
    print('[VANTRA][CONNECTION] HANDSHAKE_SENT: endpointId=$endpointId');
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
      supportedCapabilities: const [
        VantraCapability.text,
        VantraCapability.image,
        VantraCapability.file,
      ],
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
    print('[VANTRA][SESSION][HANDSHAKE] stage=CAPABILITIES_SENT peerId=$peerId endpoint=${session.endpointId}');
    print('[VANTRA][SECURITY] Sent CapabilitiesExchange to ${session.endpointId}');
  }

  // Phase 7: Persistent Queue Flusher
  Future<void> _flushQueue(String peerId, [String? triggerSource]) async {
    final caller = triggerSource ?? _getCallingMethodName();
    print('[VANTRA][QUEUE][FLUSH_TRIGGER]\nsource=$caller');

    if (_activePeerFlushes.contains(peerId)) return;
    _activePeerFlushes.add(peerId);

    final flusherInstanceId = const Uuid().v4().substring(0, 8);

    try {
      final repository = ref.read(messagingRepositoryProvider);
      while (true) {
        final session = state.sessions[peerId];
        final secSession = _securitySessions[peerId];

        // Fetch pending messages in FIFO order
        final pending = await repository.getPendingOrFailedMessages(peerId);
        
        print('[VANTRA][QUEUE][FLUSH_START] flushId=$flusherInstanceId\n'
              'peerId=$peerId\n'
              'pendingCount=${pending.length}\n'
              'messageIds=${pending.map((m) => m.messageId).toList()}\n'
              'flusherInstanceId=$flusherInstanceId');

        if (pending.isEmpty) {
          print('[VANTRA][QUEUE][FLUSH_END]\n'
                'peerId=$peerId\n'
                'pendingCount=${pending.length}\n'
                'messageIds=${pending.map((m) => m.messageId).toList()}\n'
                'flusherInstanceId=$flusherInstanceId');
          break;
        }

        final msg = pending.first;
        final isConnected = session?.status == SessionStatus.connected || hasActiveSecureTransport(peerId);
        final isSecure = session?.isSecure == true;
        final secSessionExists = secSession != null;

        print('[VANTRA][QUEUE][SELECT]\n'
              'flushId=$flusherInstanceId\n'
              'messageId=${msg.messageId}\n'
              'status=${msg.status.name}');

        if (msg.type == 'IMAGE' || msg.type == 'FILE') {
          print('[VANTRA][MEDIA][QUEUE]\n'
                'messageId=${msg.messageId}\n'
                'status=${msg.status.name}\n'
                'flushId=$flusherInstanceId\n'
                'trigger=${triggerSource ?? "none"}');
        }

        print('[VANTRA][MESSAGE] SEND_DECISION messageId=${msg.messageId} transportConnected=$isConnected sessionExists=$secSessionExists sessionSecure=$isSecure endpoint=${session?.endpointId}');

        // Break if session is not secure or disconnected
        if (session == null || !isConnected || !isSecure || !secSessionExists) {
          String reason = 'unknown';
          if (session == null) {
            reason = 'no active session';
          } else if (!isConnected) {
            reason = 'transport disconnected';
          } else if (!isSecure) {
            reason = 'session not secure';
          } else if (!secSessionExists) {
            reason = 'missing security keys';
          }
          print('[VANTRA][MESSAGE] QUEUED messageId=${msg.messageId} reason=$reason');
          print('[VANTRA][QUEUE][FLUSH_END]\n'
                'peerId=$peerId\n'
                'pendingCount=${pending.length}\n'
                'messageIds=${pending.map((m) => m.messageId).toList()}\n'
                'flusherInstanceId=$flusherInstanceId');
          break;
        }

        final success = await _sendSingleMessage(secSession, session, msg);

        if (msg.type == 'IMAGE' || msg.type == 'FILE') {
          print('[VANTRA][MEDIA][QUEUE_RECHECK]\n'
                'messageId=${msg.messageId}\n'
                'peerId=$peerId\n'
                'messageType=${msg.type}\n'
                'currentStatus=${msg.status.name}\n'
                'attemptCount=${msg.retryCount}\n'
                'endpointId=${session.endpointId}\n'
                'session state=${session.status.name}');
        }

        if (!success) {
          print('[VANTRA][QUEUE][FLUSH_END]\n'
                'peerId=$peerId\n'
                'pendingCount=${pending.length}\n'
                'messageIds=${pending.map((m) => m.messageId).toList()}\n'
                'flusherInstanceId=$flusherInstanceId');
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
    print('[VANTRA][PIPELINE] MESSAGE_SEND_ATTEMPT peerId=${session.peerId}');
    final repository = ref.read(messagingRepositoryProvider);
    final localIdentity = ref.read(localIdentityStateProvider);

    if (msg.type == 'IMAGE' || msg.type == 'FILE') {
      if (_inflightSends.contains(msg.messageId)) {
        print('[VANTRA][MEDIA][DUPLICATE_GUARD]\n'
              'messageId=${msg.messageId}\n'
              'peerId=${session.peerId}\n'
              'messageType=${msg.type}\n'
              'currentStatus=${msg.status.name}\n'
              'attemptCount=${msg.retryCount}\n'
              'endpointId=${session.endpointId}\n'
              'session state=${session.status.name}');
        return false;
      }
      _inflightSends.add(msg.messageId);

      final capability = msg.type == 'IMAGE' ? VantraCapability.image : VantraCapability.file;
      final isSupported = session.enabledCapabilities?.contains(capability) ?? false;
      if (!isSupported) {
        VantraLogger.log('[VANTRA][MESSAGING] Sharing type ${msg.type} not supported by peer ${msg.receiverId}. '
            'session.status=${session.status.name}, '
            'session.isSecure=${session.isSecure}, '
            'session.enabledCapabilities=${session.enabledCapabilities?.map((c) => c.name).toList()}');
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        _inflightSends.remove(msg.messageId);
        return false;
      }

      final file = File(msg.mediaPath!);
      if (!await file.exists()) {
        VantraLogger.log('[VANTRA][MESSAGING] Outgoing file missing: ${msg.mediaPath}');
        print('[VANTRA][MEDIA][CHUNK_PIPELINE_STOPPED]\n'
              'messageId=${msg.messageId}\n'
              'transferId=${msg.transferId}\n'
              'reason=Outgoing file missing: ${msg.mediaPath}');
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        _inflightSends.remove(msg.messageId);
        return false;
      }

      final chunkSize = 16384;
      final totalChunks = (msg.fileSize! / chunkSize).ceil();

      print('[VANTRA][MEDIA][SEND_ATTEMPT]\n'
            'messageId=${msg.messageId}\n'
            'type=${msg.type}\n'
            'endpoint=${session.endpointId}\n'
            'transferId=${msg.transferId}');

      final completer = Completer<DomainMediaControl>();
      _mediaCompleters[msg.transferId!] = completer;

      await repository.updateMessageStatus(msg.messageId, MessageStatus.sending);

      final offerMsgId = msg.messageId; // Reuse messageId to link offer, receiver saving, and final ACK matching
      final offerSeq = secSession.nextSendSequence();

      print('[VANTRA][MEDIA][OFFER]\n'
            'messageId=${msg.messageId}\n'
            'offerMessageId=$offerMsgId\n'
            'transferId=${msg.transferId}');
      
      final offerDomainMsg = DomainMediaControl(
        messageId: offerMsgId,
        sessionId: secSession.sessionId,
        sequence: offerSeq,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: localIdentity.peerId,
        receiverId: msg.receiverId,
        type: DomainMediaControlType.offer,
        transferId: msg.transferId!,
        fileName: msg.fileName,
        fileSize: msg.fileSize,
        mimeType: msg.mimeType,
        totalChunks: totalChunks,
        chunkSize: chunkSize,
        width: msg.width,
        height: msg.height,
        caption: msg.text,
        sha256: msg.sha256,
      );

      final offerBytes = _service.codec.encodePlaintext(offerDomainMsg);

      final encryptedOffer = await _cryptoService.encryptBytes(
        secretKey: secSession.sendKey,
        sessionSalt: secSession.sessionSalt,
        sequence: offerSeq,
        messageId: offerMsgId,
        plaintextBytes: offerBytes,
      );

      print('[VANTRA][MEDIA][OFFER_ENCRYPT]\n'
            'messageId=${msg.messageId}\n'
            'transferId=${msg.transferId}\n'
            'encryptedBytes=${encryptedOffer.ciphertext.length}');

      VantraLogger.log('[VANTRA][MESSAGING] Media/File transfer offering transferId=${msg.transferId}');

      print('[VANTRA][MEDIA][OFFER_SEND]\n'
            'messageId=${msg.messageId}\n'
            'endpoint=${session.endpointId}\n'
            'bytes=${encryptedOffer.ciphertext.length}');

      await _service.sendEncryptedMessage(
        endpointId: session.endpointId,
        messageId: offerMsgId,
        sessionId: secSession.sessionId,
        sequence: offerSeq,
        nonce: Uint8List.fromList(encryptedOffer.nonce),
        ciphertext: Uint8List.fromList(encryptedOffer.ciphertext),
        mac: Uint8List.fromList(encryptedOffer.mac),
        protocolVersion: kCurrentProtocolVersion,
      );

      print('[VANTRA][MEDIA][OFFER_SEND_SUCCESS]\n'
            'messageId=${msg.messageId}\n'
            'endpoint=${session.endpointId}');

      DomainMediaControl response;
      try {
        response = await completer.future.timeout(const Duration(seconds: 15));
      } catch (e) {
        VantraLogger.log('[VANTRA][MESSAGING] OFFER timeout or rejected for transferId=${msg.transferId}');
        print('[VANTRA][MEDIA][CHUNK_PIPELINE_STOPPED]\n'
              'messageId=${msg.messageId}\n'
              'transferId=${msg.transferId}\n'
              'reason=Offer timeout or error: $e');
        _mediaCompleters.remove(msg.transferId);
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        _inflightSends.remove(msg.messageId);
        return false;
      } finally {
        _mediaCompleters.remove(msg.transferId);
      }

      if (response.type == DomainMediaControlType.reject) {
        VantraLogger.log('[VANTRA][MESSAGING] Receiver rejected transferId=${msg.transferId}');
        print('[VANTRA][MEDIA][CHUNK_PIPELINE_STOPPED]\n'
              'messageId=${msg.messageId}\n'
              'transferId=${msg.transferId}\n'
              'reason=Receiver rejected transfer');
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        _inflightSends.remove(msg.messageId);
        return false;
      }

      final startIndex = response.nextExpectedChunk ?? 0;
      VantraLogger.log('[VANTRA][MESSAGING] Transfer ACCEPTED. Starting from chunk index $startIndex of $totalChunks');

      final accessFile = await file.open(mode: FileMode.read);
      try {
        for (var i = startIndex; i < totalChunks; i++) {
          final activeSession = state.sessions[msg.receiverId];
          if (activeSession == null || activeSession.status != SessionStatus.connected) {
            throw Exception('Disconnected during chunk stream');
          }

          await accessFile.setPosition(i * chunkSize);
          final chunkData = await accessFile.read(chunkSize);

          final chunkMsgId = const Uuid().v4();
          final chunkSeq = secSession.nextSendSequence();

          final chunkDomainMsg = DomainMediaChunk(
            messageId: chunkMsgId,
            sessionId: secSession.sessionId,
            sequence: chunkSeq,
            timestampMs: DateTime.now().millisecondsSinceEpoch,
            senderId: localIdentity.peerId,
            receiverId: msg.receiverId,
            transferId: msg.transferId!,
            chunkIndex: i,
            totalChunks: totalChunks,
            data: Uint8List.fromList(chunkData),
          );

          final chunkBytes = _service.codec.encodePlaintext(chunkDomainMsg);
          final encryptedChunk = await _cryptoService.encryptBytes(
            secretKey: secSession.sendKey,
            sessionSalt: secSession.sessionSalt,
            sequence: chunkSeq,
            messageId: chunkMsgId,
            plaintextBytes: chunkBytes,
          );

          print('[VANTRA][MEDIA][CHUNK_SEND]\n'
                'messageId=${msg.messageId}\n'
                'transferId=${msg.transferId}\n'
                'chunkIndex=$i\n'
                'totalChunks=$totalChunks');

          await _service.sendEncryptedMessage(
            endpointId: session.endpointId,
            messageId: chunkMsgId,
            sessionId: secSession.sessionId,
            sequence: chunkSeq,
            nonce: Uint8List.fromList(encryptedChunk.nonce),
            ciphertext: Uint8List.fromList(encryptedChunk.ciphertext),
            mac: Uint8List.fromList(encryptedChunk.mac),
            protocolVersion: kCurrentProtocolVersion,
          );

          print('[VANTRA][MEDIA][CHUNK_SEND_SUCCESS]\n'
                'messageId=${msg.messageId}\n'
                'chunkIndex=$i');

          _transferProgress[msg.transferId!] = (i + 1) / totalChunks;
          state = state.copyWith();
        }
      } catch (e) {
        VantraLogger.log('[VANTRA][MESSAGING] Chunk streaming interrupted for transferId=${msg.transferId}: $e');
        print('[VANTRA][MEDIA][CHUNK_PIPELINE_STOPPED]\n'
              'messageId=${msg.messageId}\n'
              'transferId=${msg.transferId}\n'
              'reason=Chunk stream interrupted: $e');
        await repository.updateMessageStatus(msg.messageId, MessageStatus.pending);
        _inflightSends.remove(msg.messageId);
        return false;
      } finally {
        await accessFile.close();
      }

      VantraLogger.log('[VANTRA][MESSAGING] Chunks stream completed for transferId=${msg.transferId}. Waiting for ACK...');

      print('[VANTRA][MEDIA][TRANSPORT_SUCCESS]\n'
            'messageId=${msg.messageId}\n'
            'peerId=${session.peerId}\n'
            'messageType=${msg.type}\n'
            'currentStatus=${msg.status.name}\n'
            'attemptCount=${msg.retryCount}\n'
            'endpointId=${session.endpointId}\n'
            'session state=${session.status.name}');

      await repository.updateMessageStatus(msg.messageId, MessageStatus.sent);
      _scheduleAckTimeout(msg.messageId, msg.receiverId);
      return true;
    }

    if (_inflightSends.contains(msg.messageId)) {
      return false;
    }
    _inflightSends.add(msg.messageId);

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
      print('[VANTRA][SESSION] state=${session.status.name}');
      print('[VANTRA][SESSION] sendCounter=${secSession.sendSequence}');
      print('[VANTRA][SESSION] receiveCounter=${secSession.receiveSequence}');
      print('[VANTRA][SESSION] endpoint=${session.endpointId}');
      print('[VANTRA][SESSION] keyAvailable=true');
      final encrypted = await _cryptoService.encryptBytes(
        secretKey: secSession.sendKey,
        sessionSalt: secSession.sessionSalt,
        sequence: seq,
        messageId: msg.messageId,
        plaintextBytes: plaintextBytes,
      );
      print('[VANTRA][MESSAGE] ENCRYPTED messageId=${msg.messageId} bytes=${encrypted.ciphertext.length}');
      VantraLogger.log('[VANTRA][CRYPTO] ENCRYPT SUCCESS messageId=${msg.messageId} nonceLength=12 ciphertextLength=${encrypted.ciphertext.length} macLength=16');

      print('[VANTRA][PIPELINE] MESSAGE_TRANSPORT_SEND endpoint=${session.endpointId}');
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
      print('[VANTRA][PIPELINE] MESSAGE_TRANSPORT_SEND_SUCCESS endpoint=${session.endpointId}');

      await repository.updateMessageStatus(msg.messageId, MessageStatus.sent);

      // Start persistent ACK timer
      _scheduleAckTimeout(msg.messageId, msg.receiverId);
      return true;
    } catch (e, stack) {
      _inflightSends.remove(msg.messageId);
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
      _inflightSends.remove(messageId);
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
      _flushQueue(peerId, '_scheduleBackoffRetry');
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
    print('[VANTRA][MESSAGE] SEND_REQUEST messageId=$messageId peerId=$peerId');
    print('[VANTRA][PIPELINE] MESSAGE_SEND_ATTEMPT peerId=$peerId');
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
    await _flushQueue(peerId, 'sendTextMessage');
  }

  Future<void> retryMessage(String messageId, String peerId) async {
    VantraLogger.log('[VANTRA][SECURITY] Manual retry triggered for messageId=$messageId');
    _inflightSends.remove(messageId);
    final repository = ref.read(messagingRepositoryProvider);
    final dbMsg = await repository.getMessageById(messageId);
    if (dbMsg != null && (dbMsg.type == 'IMAGE' || dbMsg.type == 'FILE')) {
      print('[VANTRA][MEDIA][RESEND]\n'
            'messageId=$messageId\n'
            'peerId=$peerId\n'
            'messageType=${dbMsg.type}\n'
            'currentStatus=pending\n'
            'attemptCount=0\n'
            'endpointId=none\n'
            'session state=none');
    }

    final db = ref.read(appDatabaseProvider);
    
    await (db.update(db.messages)..where((t) => t.messageId.equals(messageId)))
        .write(MessagesCompanion(
      status: Value(MessageStatus.pending),
      retryCount: Value(0),
    ));

    await _flushQueue(peerId, 'retryMessage');
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
      print('[VANTRA][SESSION] SESSION_INVALIDATED peerId=$peerId reason=Peer blocked');
      print('[VANTRA][PIPELINE] STATE_INVALIDATION source=blockPeer endpoint=${session.endpointId} peerId=$peerId reason=Peer blocked');
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

  @visibleForTesting
  Future<void> flushQueue(String peerId, [String? triggerSource]) => _flushQueue(peerId, triggerSource);

  @visibleForTesting
  Future<bool> sendSingleMessage(SecuritySession secSession, PeerSession session, VantraMessage msg) =>
      _sendSingleMessage(secSession, session, msg);

  Future<void> sendImageMessage(String peerId, String filePath, {String? caption}) async {
    VantraLogger.log('[VANTRA][MESSAGING] sendImageMessage: peerId=$peerId, filePath=$filePath, caption=$caption');
    final localIdentity = ref.read(localIdentityStateProvider);
    final repository = ref.read(messagingRepositoryProvider);

    final messageId = const Uuid().v4();
    final transferId = const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    print('[VANTRA][MEDIA][SEND_CALLER]\n'
          'messageId=$messageId\n'
          'source=${_getCallingMethodName()}');

    final file = File(filePath);
    if (!await file.exists()) {
      VantraLogger.log('[VANTRA][MESSAGING] File does not exist: $filePath');
      return;
    }

    final fileSize = await file.length();
    final ext = path.extension(filePath);
    
    final appDir = await getApplicationDocumentsDirectory();
    final outgoingDir = Directory(path.join(appDir.path, 'media', 'outgoing'));
    if (!await outgoingDir.exists()) {
      await outgoingDir.create(recursive: true);
    }
    final localPath = path.join(outgoingDir.path, '$messageId$ext');
    await file.copy(localPath);

    int width = 0;
    int height = 0;
    try {
      final bytes = await File(localPath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      width = frameInfo.image.width;
      height = frameInfo.image.height;
    } catch (e) {
      VantraLogger.log('[VANTRA][MESSAGING] Failed to decode image dimensions: $e');
    }

    String mimeType = 'image/jpeg';
    if (ext.toLowerCase() == '.png') {
      mimeType = 'image/png';
    } else if (ext.toLowerCase() == '.webp') {
      mimeType = 'image/webp';
    }

    // Compute complete-file SHA-256 hash using streaming
    String sha256Hex = '';
    try {
      final fileStream = File(localPath).openRead();
      final hashVal = await sha256.bind(fileStream).first;
      sha256Hex = hashVal.toString();
      VantraLogger.log('[VANTRA][MESSAGING] Computed SHA-256 for outgoing image: $sha256Hex');
    } catch (e) {
      VantraLogger.log('[VANTRA][MESSAGING] Failed to compute image hash: $e');
    }

    print('[VANTRA][MEDIA][MESSAGE_IDENTITY]\n'
          'messageId=$messageId\n'
          'attachmentId=$transferId\n'
          'fileHash=$sha256Hex\n'
          'createdAt=$timestamp');

    print('[VANTRA][MEDIA][CREATE]\n'
          'messageId=$messageId\n'
          'peerId=$peerId\n'
          'filePath=$filePath\n'
          'mimeType=$mimeType\n'
          'fileSize=$fileSize');

    final msg = VantraMessage(
      messageId: messageId,
      senderId: localIdentity.peerId,
      receiverId: peerId,
      text: caption ?? '',
      timestamp: timestamp,
      status: MessageStatus.pending,
      type: 'IMAGE',
      mediaPath: localPath,
      mimeType: mimeType,
      fileName: path.basename(filePath),
      fileSize: fileSize,
      width: width,
      height: height,
      transferId: transferId,
      sha256: sha256Hex,
    );

    await repository.saveOutgoingMessage(msg);

    print('[VANTRA][MEDIA][PERSIST]\n'
          'messageId=$messageId\n'
          'status=${msg.status.name}\n'
          'mediaType=${msg.type}');

    _flushQueue(peerId, 'sendImageMessage');
  }

  Future<void> sendFileMessage(String peerId, String filePath, {String? caption}) async {
    VantraLogger.log('[VANTRA][MESSAGING] sendFileMessage: peerId=$peerId, filePath=$filePath, caption=$caption');
    final localIdentity = ref.read(localIdentityStateProvider);
    final repository = ref.read(messagingRepositoryProvider);

    final messageId = const Uuid().v4();
    final transferId = const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    print('[VANTRA][MEDIA][SEND_CALLER]\n'
          'messageId=$messageId\n'
          'source=${_getCallingMethodName()}');

    final file = File(filePath);
    if (!await file.exists()) {
      VantraLogger.log('[VANTRA][MESSAGING] File does not exist: $filePath');
      return;
    }

    final fileSize = await file.length();
    final ext = path.extension(filePath);
    
    final appDir = await getApplicationDocumentsDirectory();
    final outgoingDir = Directory(path.join(appDir.path, 'files', 'outgoing'));
    if (!await outgoingDir.exists()) {
      await outgoingDir.create(recursive: true);
    }
    final localPath = path.join(outgoingDir.path, '$messageId$ext');
    await file.copy(localPath);

    // Compute complete-file SHA-256 hash using streaming
    String sha256Hex = '';
    try {
      final fileStream = File(localPath).openRead();
      final hashVal = await sha256.bind(fileStream).first;
      sha256Hex = hashVal.toString();
      VantraLogger.log('[VANTRA][MESSAGING] Computed SHA-256 for outgoing file: $sha256Hex');
    } catch (e) {
      VantraLogger.log('[VANTRA][MESSAGING] Failed to compute file hash: $e');
    }

    // Determine mime-type based on extension
    String mimeType = 'application/octet-stream';
    if (ext.toLowerCase() == '.pdf') {
      mimeType = 'application/pdf';
    } else if (ext.toLowerCase() == '.txt') {
      mimeType = 'text/plain';
    } else if (ext.toLowerCase() == '.zip') {
      mimeType = 'application/zip';
    } else if (ext.toLowerCase() == '.json') {
      mimeType = 'application/json';
    } else if (ext.toLowerCase() == '.csv') {
      mimeType = 'text/csv';
    }

    print('[VANTRA][MEDIA][MESSAGE_IDENTITY]\n'
          'messageId=$messageId\n'
          'attachmentId=$transferId\n'
          'fileHash=$sha256Hex\n'
          'createdAt=$timestamp');

    print('[VANTRA][MEDIA][CREATE]\n'
          'messageId=$messageId\n'
          'peerId=$peerId\n'
          'filePath=$filePath\n'
          'mimeType=$mimeType\n'
          'fileSize=$fileSize');

    final msg = VantraMessage(
      messageId: messageId,
      senderId: localIdentity.peerId,
      receiverId: peerId,
      text: caption ?? '',
      timestamp: timestamp,
      status: MessageStatus.pending,
      type: 'FILE',
      mediaPath: localPath,
      mimeType: mimeType,
      fileName: path.basename(filePath),
      fileSize: fileSize,
      transferId: transferId,
      sha256: sha256Hex,
    );

    await repository.saveOutgoingMessage(msg);

    print('[VANTRA][MEDIA][PERSIST]\n'
          'messageId=$messageId\n'
          'status=${msg.status.name}\n'
          'mediaType=${msg.type}');

    _flushQueue(peerId, 'sendFileMessage');
  }

  Future<void> _sendMediaReject(String endpointId, SecuritySession session, String transferId) async {
    final msgId = const Uuid().v4();
    final seq = session.nextSendSequence();

    final rejectDomainMsg = DomainMediaControl(
      messageId: msgId,
      sessionId: session.sessionId,
      sequence: seq,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      senderId: session.peerId,
      receiverId: session.peerId,
      type: DomainMediaControlType.reject,
      transferId: transferId,
    );

    final bytes = _service.codec.encodePlaintext(rejectDomainMsg);
    final encrypted = await _cryptoService.encryptBytes(
      secretKey: session.sendKey,
      sessionSalt: session.sessionSalt,
      sequence: seq,
      messageId: msgId,
      plaintextBytes: bytes,
    );

    await _service.sendEncryptedMessage(
      endpointId: endpointId,
      messageId: msgId,
      sessionId: session.sessionId,
      sequence: seq,
      nonce: Uint8List.fromList(encrypted.nonce),
      ciphertext: Uint8List.fromList(encrypted.ciphertext),
      mac: Uint8List.fromList(encrypted.mac),
      protocolVersion: kCurrentProtocolVersion,
    );
  }

  Future<void> _sendMediaAccept(String endpointId, SecuritySession session, String transferId, int nextExpectedChunk) async {
    final msgId = const Uuid().v4();
    final seq = session.nextSendSequence();

    final acceptDomainMsg = DomainMediaControl(
      messageId: msgId,
      sessionId: session.sessionId,
      sequence: seq,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      senderId: session.peerId,
      receiverId: session.peerId,
      type: DomainMediaControlType.accept,
      transferId: transferId,
      nextExpectedChunk: nextExpectedChunk,
    );

    final bytes = _service.codec.encodePlaintext(acceptDomainMsg);
    final encrypted = await _cryptoService.encryptBytes(
      secretKey: session.sendKey,
      sessionSalt: session.sessionSalt,
      sequence: seq,
      messageId: msgId,
      plaintextBytes: bytes,
    );

    await _service.sendEncryptedMessage(
      endpointId: endpointId,
      messageId: msgId,
      sessionId: session.sessionId,
      sequence: seq,
      nonce: Uint8List.fromList(encrypted.nonce),
      ciphertext: Uint8List.fromList(encrypted.ciphertext),
      mac: Uint8List.fromList(encrypted.mac),
      protocolVersion: kCurrentProtocolVersion,
    );
  }

  String _stateUpdateSource = 'unknown';

  @override
  set state(MessagingState value) {
    final oldState = super.state;
    super.state = value;
    final source = _stateUpdateSource != 'unknown' ? _stateUpdateSource : _getCallingMethodName();
    _logStateTransition(oldState, value, source);
    _stateUpdateSource = 'unknown';
  }

  String _getCallingMethodName() {
    final trace = StackTrace.current.toString();
    final lines = trace.split('\n');
    for (final line in lines) {
      if (line.contains('state=') || line.contains('_getCallingMethodName') || line.contains('_logStateTransition')) {
        continue;
      }
      final match = RegExp(r'MessagingNotifier\.([a-zA-Z0-9_]+)').firstMatch(line);
      if (match != null) {
        return match.group(1) ?? 'unknown';
      }
    }
    return 'unknown';
  }

  void _logStateTransition(MessagingState oldState, MessagingState newState, String source) {
    final allPeerIds = {...oldState.sessions.keys, ...newState.sessions.keys};
    for (final peerId in allPeerIds) {
      final oldSession = oldState.sessions[peerId];
      final newSession = newState.sessions[peerId];

      final oldTransport = oldSession?.status == SessionStatus.connected ||
          (oldSession != null && oldSession.isSecure && oldState.activeEndpointId == oldSession.endpointId);
      final newTransport = newSession?.status == SessionStatus.connected ||
          (newSession != null && newSession.isSecure && newState.activeEndpointId == newSession.endpointId);

      final oldOnline = oldSession?.status == SessionStatus.connected;
      final newOnline = newSession?.status == SessionStatus.connected;

      if (oldTransport != newTransport || 
          oldOnline != newOnline || 
          oldSession?.endpointId != newSession?.endpointId ||
          oldSession?.status != newSession?.status) {
        
        print('[VANTRA][STATE][WRITE]');
        print('source=$source');
        print('peerId=$peerId');
        print('endpoint=${newSession?.endpointId ?? oldSession?.endpointId ?? "none"}');
        print('oldTransport=$oldTransport');
        print('newTransport=$newTransport');
        print('oldOnline=$oldOnline');
        print('newOnline=$newOnline');
        print('sessionEndpoint=${newSession?.endpointId ?? oldSession?.endpointId ?? "none"}');
        print('activeEndpoint=${newState.activeEndpointId ?? "none"}');
        print('connectionCallbackStatus=${newState.connectionStatus.name}');
      }
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
