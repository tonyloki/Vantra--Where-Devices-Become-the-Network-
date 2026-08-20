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
import 'package:vantra/core/calls/call_session.dart';
import 'package:vantra/core/calls/call_provider.dart';
import 'package:drift/drift.dart' show Value;
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/peers/peer_discovery_service.dart';
import 'message.dart';
import 'messaging_repository.dart';
import 'messaging_service.dart';
import 'transfer_speed_tracker.dart';

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

class PendingIncomingOffer {
  final String peerId;
  final String endpointId;
  final SecuritySession session;
  final DomainMediaControl offer;
  final Timer timeoutTimer;

  PendingIncomingOffer({
    required this.peerId,
    required this.endpointId,
    required this.session,
    required this.offer,
    required this.timeoutTimer,
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

final groupConversationStreamProvider = StreamProvider.family<List<VantraMessage>, String>((ref, groupId) {
  final repository = ref.watch(messagingRepositoryProvider);
  return repository.watchGroupConversation(groupId);
});

final groupsStreamProvider = StreamProvider<List<Group>>((ref) {
  final repository = ref.watch(messagingRepositoryProvider);
  return repository.watchGroups();
});

final groupMembersProvider = FutureProvider.family<List<GroupMember>, String>((ref, groupId) {
  final repository = ref.watch(messagingRepositoryProvider);
  return repository.getGroupMembers(groupId);
});

class TransferProgressState {
  final double progress;
  final String speed;
  final String eta;

  const TransferProgressState({
    this.progress = 0.0,
    this.speed = '',
    this.eta = '',
  });
}

class TransferProgressMapNotifier extends Notifier<Map<String, TransferProgressState>> {
  @override
  Map<String, TransferProgressState> build() {
    return const {};
  }

  void updateProgress(String transferId, TransferProgressState progressState) {
    state = {
      ...state,
      transferId: progressState,
    };
  }

  void removeProgress(String transferId) {
    if (state.containsKey(transferId)) {
      final copy = Map<String, TransferProgressState>.from(state);
      copy.remove(transferId);
      state = copy;
    }
  }
}

final transferProgressMapProvider = NotifierProvider<TransferProgressMapNotifier, Map<String, TransferProgressState>>(() {
  return TransferProgressMapNotifier();
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
  StreamSubscription? _routedEnvelopeSub;
  StreamSubscription? _routeRequestSub;
  StreamSubscription? _routeReplySub;
  StreamSubscription? _routeErrorSub;

  // Phase 16 Mesh Routing Table and caches
  final Map<String, RouteEntry> _routingTable = {};
  final Set<String> _recentlyForwardedPackets = {};
  final Set<String> _recentlyProcessedRouteRequests = {};
  final Set<String> _recentlyProcessedRouteErrors = {};
  final List<Timer> _cacheTimers = [];
  final Map<String, List<Completer<DomainRouteReply>>> _pendingRreqs = {};

  final Map<String, SecuritySession> _securitySessions = {};
  final Map<String, SimpleKeyPair> _pendingEphemeralKeys = {};

  // Phase 7 Queue, ACK-Timeout, and Backoff structures
  final Set<String> _activePeerFlushes = {};
  final Map<String, Timer> _ackTimers = {};
  final Map<String, Timer> _backoffTimers = {};
  final Map<String, Completer<DomainMediaControl>> _mediaCompleters = {};
  final Map<String, double> _transferProgress = {};
  final Set<String> _inflightSends = {};
  final Map<String, PendingIncomingOffer> _pendingIncomingOffers = {};
  
  // Phase 19 Transfer UX structures
  final Set<String> _cancelledTransfers = {};
  final Map<String, TransferSpeedTracker> _speedTrackers = {};
  
  // Phase 18 Large Media Streaming structures
  final Map<String, RandomAccessFile> _activeReceiveFiles = {};
  final Map<String, Set<int>> _receivedChunkIndices = {};
  final Map<String, Timer> _receiveTimeoutTimers = {};
  final Map<String, int> _receiveChunkSizes = {};

  double getTransferProgress(String transferId) => _transferProgress[transferId] ?? 0.0;
  String getTransferSpeed(String transferId) => _speedTrackers[transferId]?.speedLabel ?? '';
  String getTransferEta(String transferId) => _speedTrackers[transferId]?.etaLabel ?? '';

  Future<void> _cleanupReceiveTransfer(String transferId, {bool deleteTempFile = false, String? tempFilePath}) async {
    final raf = _activeReceiveFiles.remove(transferId);
    if (raf != null) {
      try {
        await raf.close();
      } catch (_) {}
    }
    _receivedChunkIndices.remove(transferId);
    final timer = _receiveTimeoutTimers.remove(transferId);
    timer?.cancel();
    _receiveChunkSizes.remove(transferId);
    _speedTrackers.remove(transferId);
    _cancelledTransfers.remove(transferId);
    ref.read(transferProgressMapProvider.notifier).removeProgress(transferId);

    if (deleteTempFile && tempFilePath != null) {
      try {
        final f = File(tempFilePath);
        if (await f.exists()) {
          await f.delete();
          VantraLogger.log('[VANTRA][MESSAGING] Deleted temporary file for transferId=$transferId path=$tempFilePath');
        }
      } catch (_) {}
    }
  }

  Future<void> _cleanupTempDir(String transferId, bool isImage) async {
    try {
      _speedTrackers.remove(transferId);
      _cancelledTransfers.remove(transferId);
      _transferProgress.remove(transferId);
      ref.read(transferProgressMapProvider.notifier).removeProgress(transferId);

      final appDir = await getApplicationDocumentsDirectory();
      final dirPrefix = isImage ? 'media' : 'files';
      final tempFilePath = path.join(appDir.path, dirPrefix, 'temp', '$transferId.tmp');
      await _cleanupReceiveTransfer(transferId, deleteTempFile: true, tempFilePath: tempFilePath);
      
      // Also check and delete legacy chunk directory if it exists
      final legacyDir = Directory(path.join(appDir.path, dirPrefix, 'temp', transferId));
      if (await legacyDir.exists()) {
        await legacyDir.delete(recursive: true);
      }
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][MESSAGING] Failed to clean up temporary resources: $e', e, stack);
    }
  }

  bool hasActiveSecureTransport(String peerId) {
    final session = state.sessions[peerId];
    final secSession = _securitySessions[peerId];

    if (session == null || secSession == null) return false;
    if (!session.isSecure) return false;
    if (session.status != SessionStatus.connected) return false;
    if (session.endpointId != secSession.endpointId) return false;
    if (!_aliveEndpoints.contains(session.endpointId)) return false;

    return true;
  }

  // Connection Request Idempotency Tracking
  final Set<String> _acceptedEndpoints = {};
  final Set<String> _rejectedEndpoints = {};
  final Set<String> _activeConnectLocks = {};
  final Set<String> _aliveEndpoints = {};
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
          } catch (e, stack) {
            VantraLogger.log('[VANTRA][MESSAGING] Error in previous chain step: $e', e, stack);
          }
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

    _routedEnvelopeSub?.cancel();
    _routeRequestSub?.cancel();
    _routeReplySub?.cancel();
    _routeErrorSub?.cancel();

    _routedEnvelopeSub = _service.routedEnvelopeStream.listen(_handleIncomingRoutedEnvelope);
    _routeRequestSub = _service.routeRequestStream.listen(_handleIncomingRouteRequest);
    _routeReplySub = _service.routeReplyStream.listen(_handleIncomingRouteReply);
    _routeErrorSub = _service.routeErrorStream.listen(_handleIncomingRouteError);

    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _handleDiscoveredPeersUpdate(_lastDiscoveredList);
    });

    ref.onDispose(() {
      _connectionSub?.cancel();
      _encryptedMessageSub?.cancel();
      _secureIdentitySub?.cancel();
      _discoveredPeersSub?.cancel();
      _routedEnvelopeSub?.cancel();
      _routeRequestSub?.cancel();
      _routeReplySub?.cancel();
      _routeErrorSub?.cancel();
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
      for (final pending in _pendingIncomingOffers.values) {
        pending.timeoutTimer.cancel();
      }
      _pendingIncomingOffers.clear();
      for (final t in _cacheTimers) {
        t.cancel();
      }
      _cacheTimers.clear();
      for (final raf in _activeReceiveFiles.values) {
        try {
          raf.closeSync();
        } catch (_) {}
      }
      _activeReceiveFiles.clear();
      _receivedChunkIndices.clear();
      for (final t in _receiveTimeoutTimers.values) {
        t.cancel();
      }
      _receiveTimeoutTimers.clear();
      _receiveChunkSizes.clear();
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
        print('[VANTRA][SESSION] sendCounter=${session.ns}');
        print('[VANTRA][SESSION] receiveCounter=${session.nr}');
        print('[VANTRA][SESSION] endpoint=${session.endpointId}');
        print('[VANTRA][SESSION] keyAvailable=true');
        decryptedBytes = await _cryptoService.decryptWithDoubleRatchet(
          session: session,
          incomingDhPublicKeyBytes: event.dhPublicKey,
          incomingSequence: event.sequence,
          incomingPreviousChainLength: event.previousChainLength ?? 0,
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

      // 3. Verify session ID
      if (plaintext.sessionId != session.sessionId) {
        VantraLogger.log('[VANTRA][SECURITY] SESSION ID MISMATCH: messageId=${plaintext.messageId}, expected=${session.sessionId}, actual=${plaintext.sessionId}. Discarded.');
        return;
      }
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

      await _processDecryptedPlaintext(
        peerId,
        event.endpointId,
        session,
        plaintext,
        isMesh: false,
      );
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][SECURITY] DECRYPT / INTEGRITY CHECK FAILED for message ${event.messageId}: $e', e, stack);
    }
  }

  Future<void> _processDecryptedPlaintext(
    String peerId,
    String endpointId,
    SecuritySession session,
    DomainPlaintext plaintext, {
    required bool isMesh,
  }) async {
    final repository = ref.read(messagingRepositoryProvider);

    // 4. Update peer lastSeen timestamp in SQLite
    await repository.updatePeerLastSeen(peerId, plaintext.timestampMs);

    // 5. Handle Text Message vs Delivery ACK
    if (plaintext is DomainTextMessage) {
      // Lost-ACK + Duplicate-Message ACK Recovery for Text Messages
      final existingMsg = await repository.getMessageById(plaintext.messageId);
      final activeSession = state.sessions[peerId];
      if (existingMsg != null) {
        VantraLogger.log('[VANTRA][DB] DUPLICATE MESSAGE messageId=${plaintext.messageId}');
        VantraLogger.log('[VANTRA][SECURITY] DUPLICATE DETECTED: messageId=${plaintext.messageId}. Discarding duplicate payload, but immediately re-acknowledging.');
        if (activeSession != null) {
          await _sendAckOrRoutedAck(peerId, endpointId, session, plaintext.messageId, plaintext.sequence, isMesh: isMesh);
        }
        return;
      }

      final isCurrentlyViewing = state.activeConversationPeerId == peerId;

      final group = await repository.getGroup(plaintext.receiverId);
      final isGroup = group != null;

      final incomingMsg = VantraMessage(
        messageId: plaintext.messageId,
        senderId: plaintext.senderId,
        receiverId: plaintext.receiverId,
        text: plaintext.content,
        timestamp: plaintext.timestampMs,
        status: MessageStatus.received,
        groupId: isGroup ? plaintext.receiverId : null,
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
        await _sendAckOrRoutedAck(peerId, endpointId, session, plaintext.messageId, plaintext.sequence, isMesh: isMesh);
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
      print('[VANTRA][SESSION][HANDSHAKE] stage=CAPABILITIES_RECEIVED peerId=$peerId endpoint=$endpointId');
      print('[VANTRA][SECURITY] Received CapabilitiesExchange from $endpointId');
      print('[VANTRA][CAPABILITY][REMOTE_RECEIVED]\n'
            'peerId=$peerId\n'
            'endpointId=$endpointId\n'
            'minVersion=${plaintext.minSupportedVersion}\n'
            'maxVersion=${plaintext.maxSupportedVersion}\n'
            'remoteCapabilities=${plaintext.supportedCapabilities.map((c) => c.name).toList()}');
      
      final secSession = _securitySessions[peerId];
      if (secSession == null) {
        VantraLogger.log('[VANTRA][SECURITY] Dropping capabilities: No active security session for peer $peerId');
        return;
      }

      final activeSession = state.sessions[peerId];
      final isHandshaking = activeSession == null || activeSession.status == SessionStatus.handshaking;

      // Enforce SessionStatus.connected and keep state synchronized with the authoritative secure session
      final localCapabilities = const [
        VantraCapability.text,
        VantraCapability.image,
        VantraCapability.file,
        VantraCapability.audio,
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
        endpointId: endpointId,
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
            'endpointId=$endpointId');

        if (activeSession.status == SessionStatus.connected &&
            activeSession.enabledCapabilities != null &&
            activeSession.endpointId == endpointId) {
          print('[VANTRA][SECURITY] CapabilitiesExchange early return: already connected with capabilities! Discarding capabilities payload.');
          // Already negotiated. Just reply with ACK to clear remote queue.
          await _sendAckOrRoutedAck(peerId, endpointId, secSession, plaintext.messageId, plaintext.sequence, isMesh: isMesh);
          return;
        }

        // Downgrade protection and spoof check
        if (plaintext.minSupportedVersion != activeSession.remoteMinVersion ||
            plaintext.maxSupportedVersion != activeSession.remoteMaxVersion) {
          print('[VANTRA][SECURITY] Version range mismatch! Handshake advertised [${activeSession.remoteMinVersion}..${activeSession.remoteMaxVersion}], exchange claimed [${plaintext.minSupportedVersion}..${plaintext.maxSupportedVersion}]. Terminating connection.');
          final transport = ref.read(transportProvider);
          await transport.disconnect(endpointId);
          return;
        }

        final remoteCaps = activeSession.remoteCapabilities ?? const [];
        final listsMatch = plaintext.supportedCapabilities.length == remoteCaps.length &&
            plaintext.supportedCapabilities.every((c) => remoteCaps.contains(c));

        if (!listsMatch) {
          print('[VANTRA][SECURITY] Capability advertisement mismatch! Terminating connection.');
          final transport = ref.read(transportProvider);
          await transport.disconnect(endpointId);
          return;
        }
      }

      final readySession = baseSession.copyWith(
        status: SessionStatus.connected,
        endpointId: endpointId,
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
          endpointId: peerId,
        },
        activeEndpointId: endpointId,
        connectionStatus: ConnectionStatus.connected,
      );

      print('[VANTRA][SESSION][HANDSHAKE] stage=PEER_READY peerId=$peerId endpoint=$endpointId');
      print('[VANTRA][SESSION][SECURE] Capability negotiation complete. Peer $peerId is now ready for communication.');
      print('[VANTRA][SECURITY] CAPABILITY_NEGOTIATION_SUCCESS for peer $peerId. Enabled capabilities: $negotiatedCapabilities');
      print('[VANTRA][CAPABILITY][NEGOTIATED]\n'
            'peerId=$peerId\n'
            'endpointId=$endpointId\n'
            'negotiatedCapabilities=${negotiatedCapabilities.map((c) => c.name).toList()}');

      await _sendAckOrRoutedAck(peerId, endpointId, secSession, plaintext.messageId, plaintext.sequence, isMesh: isMesh);

      if (!secSession.isDeviceA && isHandshaking) {
        print('[VANTRA][SECURITY] Responder replying with CapabilitiesExchange to $peerId');
        await _sendCapabilitiesExchange(peerId);
      }

      _flushQueue(peerId, 'DomainCapabilitiesExchange');
      await _replayPendingOffersForPeer(peerId, endpointId);
    } else if (plaintext is DomainMediaControl) {
      if (plaintext.mimeType == 'application/vantra-group-invite') {
        final groupId = plaintext.transferId;
        final groupName = plaintext.fileName ?? 'Unnamed Group';
        final memberIds = (plaintext.caption ?? '').split(',');

        await repository.createGroup(groupId, groupName, plaintext.senderId, memberIds);
        await _sendAckOrRoutedAck(peerId, endpointId, session, plaintext.messageId, plaintext.sequence, isMesh: isMesh);
        return;
      }

      if (plaintext.mimeType == 'audio/call') {
        final callNotifier = ref.read(callStateProvider.notifier);
        if (plaintext.type == DomainMediaControlType.offer) {
          callNotifier.handleIncomingOffer(peerId, plaintext.transferId);
        } else if (plaintext.type == DomainMediaControlType.accept) {
          callNotifier.handleIncomingAccept(plaintext.transferId);
        } else if (plaintext.type == DomainMediaControlType.reject) {
          callNotifier.handleIncomingReject(plaintext.transferId);
        } else if (plaintext.type == DomainMediaControlType.cancel) {
          callNotifier.handleIncomingCancel(plaintext.transferId);
        }
        await _sendAckOrRoutedAck(peerId, endpointId, session, plaintext.messageId, plaintext.sequence, isMesh: isMesh);
        return;
      }

      if (plaintext.type == DomainMediaControlType.offer) {
        await _handleIncomingOffer(peerId, endpointId, session, plaintext);
      } else if (plaintext.type == DomainMediaControlType.accept ||
          plaintext.type == DomainMediaControlType.reject ||
          plaintext.type == DomainMediaControlType.cancel) {
        final completer = _mediaCompleters[plaintext.transferId];
        if (completer != null && !completer.isCompleted) {
          completer.complete(plaintext);
        }
        if (plaintext.type == DomainMediaControlType.cancel) {
          VantraLogger.log('[VANTRA][MESSAGING] Received CANCEL control message for transferId=${plaintext.transferId}');
          final msg = await repository.getMessageByTransferId(plaintext.transferId);
          if (msg != null) {
            final isImage = msg.type == 'IMAGE';
            await _cleanupTempDir(plaintext.transferId, isImage);
            await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
          }
          _cancelledTransfers.add(plaintext.transferId);
          _speedTrackers.remove(plaintext.transferId);
          _transferProgress.remove(plaintext.transferId);
          ref.read(transferProgressMapProvider.notifier).removeProgress(plaintext.transferId);
        }
      }
    } else if (plaintext is DomainMediaChunk) {
      final activeCall = ref.read(callStateProvider);
      if (plaintext.totalChunks == -1 || (activeCall != null && activeCall.callId == plaintext.transferId)) {
        ref.read(callStateProvider.notifier).handleIncomingAudioFrame(
          plaintext.transferId,
          plaintext.chunkIndex,
          plaintext.data,
        );
        return;
      }

      final msg = await repository.getMessageByTransferId(plaintext.transferId);
      if (msg == null) {
        VantraLogger.log('[VANTRA][MESSAGING] Error: Message metadata missing for transferId=${plaintext.transferId}');
        return;
      }

      if (msg.status == MessageStatus.failed) {
        VantraLogger.log('[VANTRA][MESSAGING] Discarding chunk for cancelled/failed transferId=${plaintext.transferId}');
        return;
      }

      final advertisedSize = msg.fileSize ?? 0;
      final totalChunks = plaintext.totalChunks;
      final chunkIndex = plaintext.chunkIndex;
      final chunkLength = plaintext.data.length;
      final isImage = msg.type == 'IMAGE';
      final isVoice = msg.type == 'VOICE';
      final dirPrefix = (isImage || isVoice) ? 'media' : 'files';

      // Bounded application-level buffer tracking and size computation
      final defaultChunkSize = (advertisedSize < 131072 && totalChunks > 0)
          ? (advertisedSize / totalChunks).ceil()
          : 131072;
      final chunkSize = _receiveChunkSizes[plaintext.transferId] ?? (totalChunks > 1 ? defaultChunkSize : advertisedSize);
      final offset = chunkIndex * chunkSize;

      // 1. Chunk validation checks
      if (chunkIndex < 0 || chunkIndex >= totalChunks) {
        VantraLogger.log('[VANTRA][MESSAGING] Rejected chunk: invalid chunkIndex=$chunkIndex totalChunks=$totalChunks');
        final appDir = await getApplicationDocumentsDirectory();
        final tempFilePath = path.join(appDir.path, dirPrefix, 'temp', '${plaintext.transferId}.tmp');
        await _cleanupReceiveTransfer(plaintext.transferId, deleteTempFile: true, tempFilePath: tempFilePath);
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        return;
      }

      if (offset < 0 || offset + chunkLength > advertisedSize) {
        VantraLogger.log('[VANTRA][MESSAGING] Rejected chunk: boundary overflow. offset=$offset chunkLength=$chunkLength advertisedSize=$advertisedSize');
        final appDir = await getApplicationDocumentsDirectory();
        final tempFilePath = path.join(appDir.path, dirPrefix, 'temp', '${plaintext.transferId}.tmp');
        await _cleanupReceiveTransfer(plaintext.transferId, deleteTempFile: true, tempFilePath: tempFilePath);
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        return;
      }

      if (kDebugMode) {
        print('[VANTRA][MEDIA][CHUNK_RECEIVED]\n'
              'messageId=${msg.messageId}\n'
              'transferId=${plaintext.transferId}\n'
              'chunkIndex=${plaintext.chunkIndex}\n'
              'totalChunks=${plaintext.totalChunks}');
      }

      final appDir = await getApplicationDocumentsDirectory();
      final tempFilePath = path.join(appDir.path, dirPrefix, 'temp', '${plaintext.transferId}.tmp');

      // Reset the timeout timer for this transfer
      final oldTimer = _receiveTimeoutTimers.remove(plaintext.transferId);
      oldTimer?.cancel();
      _receiveTimeoutTimers[plaintext.transferId] = Timer(const Duration(seconds: 30), () async {
        VantraLogger.log('[VANTRA][MESSAGING] Transfer timed out: transferId=${plaintext.transferId}');
        await _cleanupReceiveTransfer(plaintext.transferId, deleteTempFile: true, tempFilePath: tempFilePath);
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
      });

      // 2. Open and pre-allocate the temporary file if not already open
      RandomAccessFile raf;
      try {
        if (!_activeReceiveFiles.containsKey(plaintext.transferId)) {
          final tempParentDir = Directory(path.join(appDir.path, dirPrefix, 'temp'));
          if (!await tempParentDir.exists()) {
            await tempParentDir.create(recursive: true);
          }
          final file = File(tempFilePath);
          raf = await file.open(mode: FileMode.write);
          await raf.truncate(advertisedSize);
          _activeReceiveFiles[plaintext.transferId] = raf;
        } else {
          raf = _activeReceiveFiles[plaintext.transferId]!;
        }
      } catch (fileErr) {
        VantraLogger.log('[VANTRA][MESSAGING] File initialization error: $fileErr');
        await _cleanupReceiveTransfer(plaintext.transferId, deleteTempFile: true, tempFilePath: tempFilePath);
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        return;
      }

      // 3. Write data to the random access file at correct offset
      final receivedIndices = _receivedChunkIndices.putIfAbsent(plaintext.transferId, () => {});
      final isDuplicate = receivedIndices.contains(chunkIndex);

      try {
        await raf.setPosition(offset);
        await raf.writeFrom(plaintext.data);
      } catch (writeErr) {
        VantraLogger.log('[VANTRA][MESSAGING] Write error: $writeErr');
        await _cleanupReceiveTransfer(plaintext.transferId, deleteTempFile: true, tempFilePath: tempFilePath);
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        return;
      }

      if (!isDuplicate) {
        receivedIndices.add(chunkIndex);
      }

      // 4. Update progress metrics
      final double lastProgress = _transferProgress[plaintext.transferId] ?? 0.0;
      final double currentProgress = receivedIndices.length / totalChunks;
      final tracker = _speedTrackers.putIfAbsent(plaintext.transferId, () => TransferSpeedTracker(totalBytes: advertisedSize));
      int receivedBytes = 0;
      for (final idx in receivedIndices) {
        if (idx == totalChunks - 1) {
          receivedBytes += advertisedSize - (totalChunks - 1) * chunkSize;
        } else {
          receivedBytes += chunkSize;
        }
      }
      tracker.record(receivedBytes);

      final bool isFirstOrLast = receivedIndices.length == 1 || receivedIndices.length == totalChunks;
      if (isFirstOrLast || (currentProgress - lastProgress).abs() >= 0.02) {
        _transferProgress[plaintext.transferId] = currentProgress;
        ref.read(transferProgressMapProvider.notifier).updateProgress(
          plaintext.transferId,
          TransferProgressState(
            progress: currentProgress,
            speed: tracker.speedLabel,
            eta: tracker.etaLabel,
          ),
        );
      }

      // 5. Completion Check
      if (receivedIndices.length == totalChunks) {
        VantraLogger.log('[VANTRA][MESSAGING] All chunks received for transferId=${plaintext.transferId}. Finalizing...');
        
        // Close the file handle atomically
        await _cleanupReceiveTransfer(plaintext.transferId);

        final incomingDir = Directory(path.join(appDir.path, dirPrefix, 'incoming'));
        if (!await incomingDir.exists()) {
          await incomingDir.create(recursive: true);
        }

        final ext = path.extension(msg.fileName ?? (isImage ? '.jpg' : (isVoice ? '.aac' : '.bin')));
        final finalPath = path.join(incomingDir.path, '${msg.messageId}$ext');
        final outFile = File(finalPath);
        final tmpFile = File(tempFilePath);

        // Verify file size matches advertised size
        if (!await tmpFile.exists()) {
          VantraLogger.log('[VANTRA][MESSAGING] Error: Temp file missing on finalization');
          await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
          return;
        }
        final finalSize = await tmpFile.length();
        if (finalSize != advertisedSize) {
          VantraLogger.log('[VANTRA][MESSAGING] Final size mismatch: got $finalSize, expected $advertisedSize');
          await tmpFile.delete();
          await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
          return;
        }

        // Verify SHA-256 integrity hash if provided
        if (msg.sha256 != null && msg.sha256!.isNotEmpty) {
          try {
            final fileStream = tmpFile.openRead();
            final hashVal = await sha256.bind(fileStream).first;
            final computedHash = hashVal.toString();
            if (computedHash != msg.sha256) {
              VantraLogger.log('[VANTRA][MESSAGING] Hash verification failed for transferId=${plaintext.transferId}. Expected: ${msg.sha256}, Computed: $computedHash');
              print('[VANTRA][MEDIA][REASSEMBLY_FAILED]\n'
                    'messageId=${msg.messageId}\n'
                    'transferId=${msg.transferId}\n'
                    'reason=Hash verification failed. Expected: ${msg.sha256}, Computed: $computedHash');
              await tmpFile.delete();
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
            await tmpFile.delete();
            await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
            return;
          }
        }

        // Atomically move the file to final destination
        try {
          if (await outFile.exists()) {
            await outFile.delete();
          }
          await tmpFile.rename(finalPath);
        } catch (renameErr) {
          VantraLogger.log('[VANTRA][MESSAGING] Error moving completed file: $renameErr. Falling back to copy-delete.');
          try {
            await tmpFile.copy(finalPath);
            await tmpFile.delete();
          } catch (copyErr) {
            VantraLogger.log('[VANTRA][MESSAGING] Copy-delete fallback failed: $copyErr');
            await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
            return;
          }
        }

        await repository.updateIncomingMediaDetails(msg.messageId, finalPath, MessageStatus.received);

        print('[VANTRA][MEDIA][FILE_STORED]\n'
              'messageId=${msg.messageId}\n'
              'transferId=${msg.transferId}\n'
              'path=$finalPath\n'
              'bytes=$finalSize');

        final activeSession = state.sessions[peerId];
        print('[VANTRA][MEDIA][REMOTE_RECEIVED]\n'
              'messageId=${msg.messageId}\n'
              'peerId=${activeSession?.peerId ?? "none"}\n'
              'messageType=${msg.type}\n'
              'currentStatus=received\n'
              'attemptCount=${msg.retryCount}\n'
              'endpointId=$endpointId\n'
              'session state=${activeSession?.status.name ?? "none"}');

        if (activeSession != null) {
          print('[VANTRA][MEDIA][ACK_SEND]\n'
                'messageId=${msg.messageId}\n'
                'transferId=${msg.transferId}');
          await _sendAckOrRoutedAck(peerId, endpointId, session, msg.messageId, plaintext.sequence, isMesh: isMesh);
        }
      }
    }
  }

  Future<void> _sendAckOrRoutedAck(
    String peerId,
    String directEndpointId,
    SecuritySession session,
    String originalMessageId,
    int sequence, {
    required bool isMesh,
  }) async {
    if (isMesh) {
      await _sendRoutedAck(peerId, originalMessageId, sequence);
    } else {
      await _sendAck(directEndpointId, session, originalMessageId);
    }
  }

  Future<void> _sendEncryptedEnvelope({
    required String peerId,
    required String messageId,
    required String sessionId,
    required int sequence,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List mac,
    required Uint8List dhPublicKey,
    required int? previousChainLength,
    int? protocolVersion,
  }) async {
    final session = state.sessions[peerId];
    final actualProtocolVersion = protocolVersion ?? session?.negotiatedVersion ?? kCurrentProtocolVersion;

    final secSession = _securitySessions[peerId];
    final isDirect = hasActiveSecureTransport(peerId) ||
        (session != null &&
         (session.status == SessionStatus.connected || session.status == SessionStatus.handshaking) &&
         session.endpointId == secSession?.endpointId &&
         _aliveEndpoints.contains(session.endpointId));
    if (!isDirect) {
      final innerEnvelope = DomainEncryptedEnvelope(
        protocolVersion: actualProtocolVersion,
        messageId: messageId,
        sessionId: sessionId,
        sequence: sequence,
        nonce: nonce,
        ciphertext: ciphertext,
        mac: mac,
        dhPublicKey: dhPublicKey,
        previousChainLength: previousChainLength,
      );
      await _sendRoutedPayload(peerId, innerEnvelope);
    } else {
      if (session != null) {
        await _service.sendEncryptedMessage(
          endpointId: session.endpointId,
          messageId: messageId,
          sessionId: sessionId,
          sequence: sequence,
          nonce: nonce,
          ciphertext: ciphertext,
          mac: mac,
          dhPublicKey: dhPublicKey,
          previousChainLength: previousChainLength,
          protocolVersion: actualProtocolVersion,
        );
      } else {
        print('[VANTRA][MESSAGING] Error: direct transport requested but session is null for peerId=$peerId');
      }
    }
  }

  Future<void> _sendAck(String endpointId, SecuritySession session, String originalMessageId) async {
    final ackPacketId = const Uuid().v4();
    final ackSeq = session.ns;

    VantraLogger.log('[VANTRA][MESSAGING] ACK CREATE originalMessageId=$originalMessageId');

    final localId = ref.read(localIdentityStateProvider);
    final ackDomainMessage = DomainAckMessage(
      messageId: ackPacketId,
      sessionId: session.sessionId,
      sequence: ackSeq,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      senderId: localId.peerId,
      receiverId: session.peerId,
      originalMessageId: originalMessageId,
      status: DomainDeliveryStatus.delivered,
    );

    final ackPlaintextBytes = _service.codec.encodePlaintext(ackDomainMessage);

    final encAck = await _cryptoService.encryptWithDoubleRatchet(
      session: session,
      messageId: ackPacketId,
      plaintextBytes: ackPlaintextBytes,
    );

    final dhPubBytes = await session.getLocalDhPublicKeyBytes();
    final prevChainLen = session.pn;

    VantraLogger.log('[VANTRA][CRYPTO] ACK ENCRYPT SUCCESS ackPacketId=$ackPacketId');

    await _service.sendEncryptedMessage(
      endpointId: endpointId,
      messageId: ackPacketId,
      sessionId: session.sessionId,
      sequence: ackSeq,
      nonce: Uint8List.fromList(encAck.nonce),
      ciphertext: Uint8List.fromList(encAck.ciphertext),
      mac: Uint8List.fromList(encAck.mac),
      dhPublicKey: dhPubBytes,
      previousChainLength: prevChainLen,
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

    if (trustState == PeerTrustState.verified &&
        existingPeer?.verifiedPublicKey != null &&
        existingPeer!.verifiedPublicKey != identity.identityPublicKeyHex) {
      print('[VANTRA][NEARBY] IDENTITY_MISMATCH (VERIFIED) peerId=${identity.peerId} verifiedKey=${existingPeer.verifiedPublicKey} newKey=${identity.identityPublicKeyHex}');
      _pendingEphemeralKeys.remove(identity.endpointId);
      final transport = ref.read(transportProvider);
      await transport.disconnect(identity.endpointId);

      final session = state.sessions[identity.peerId];
      state = state.copyWith(
        identityMismatchRequest: IdentityMismatchRequest(
          peerId: identity.peerId,
          endpointId: identity.endpointId,
          oldPublicKey: existingPeer.verifiedPublicKey!,
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
      remoteIdentityPublicKey: identity.identityPublicKeyHex,
      remoteFingerprint: remoteFingerprint,
      sendKey: derivedKeys.sendKey,
      receiveKey: derivedKeys.receiveKey,
    );

    await _cryptoService.initializeDoubleRatchet(
      session: secSession,
      handshakeLocalKeyPair: localEphKeyPair,
      handshakeRemotePublicKeyBytes: ephKeyBytes,
      isDeviceA: derivedKeys.isDeviceA,
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
      VantraCapability.audio,
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
      if (derivedKeys.isDeviceA) {
        print('[VANTRA][SECURITY] Initiating V2 CapabilitiesExchange with peer ${identity.peerId}');
        await _sendCapabilitiesExchange(identity.peerId);
      } else {
        print('[VANTRA][SECURITY] Responder waiting for initiator CapabilitiesExchange from ${identity.peerId}');
      }
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

    final index = update.endpointName.lastIndexOf(':');
    final candidateName = index != -1 ? update.endpointName.substring(0, index) : update.endpointName;
    final candidatePeerId = index != -1 ? update.endpointName.substring(index + 1) : null;

    if (update.status == ConnectionStatus.connected) {
      _aliveEndpoints.add(update.endpointId);
      print('[VANTRA][SESSION][HANDSHAKE] stage=CONNECTED peerId=$candidatePeerId endpoint=${update.endpointId}');
      print('[VANTRA][CHAT-BRIDGE] Mapping endpointId=${update.endpointId} to peerId=$candidatePeerId');
      print('[VANTRA][CONNECTION] CONNECTION_CONNECTED: endpointId=${update.endpointId}');
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
      _aliveEndpoints.add(update.endpointId);
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
      final existingEndpointForPeer = state.endpointToPeerId.entries
          .where((e) => e.value == candidatePeerId && e.key != update.endpointId)
          .map((e) => e.key)
          .firstOrNull;

      if (update.isIncoming == true && existingEndpointForPeer != null) {
        if (candidatePeerId != null) {
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
            final outgoingEndpointId = existingEndpointForPeer;
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
          if (!_aliveEndpoints.contains(update.endpointId)) {
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
          if (_aliveEndpoints.contains(update.endpointId)) {
            _showManualPairingOverlay(update, candidateName, candidatePeerId);
          }
        });
      } else {
        _showManualPairingOverlay(update, candidateName, null);
      }
    } else if (update.status == ConnectionStatus.disconnected ||
        update.status == ConnectionStatus.rejected ||
        update.status == ConnectionStatus.error) {
      _aliveEndpoints.remove(update.endpointId);
      _invalidateRoutesViaEndpoint(update.endpointId);
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

      final pendingToRemove = _pendingIncomingOffers.entries
          .where((e) => e.value.endpointId == update.endpointId)
          .toList();
      for (final entry in pendingToRemove) {
        entry.value.timeoutTimer.cancel();
        _pendingIncomingOffers.remove(entry.key);
        final offer = entry.value.offer;
        final isImage = offer.mimeType != null &&
            (offer.mimeType!.startsWith('image/jpeg') ||
             offer.mimeType!.startsWith('image/png') ||
             offer.mimeType!.startsWith('image/webp')) &&
            (offer.width != null && offer.width! > 0);
        _cleanupTempDir(entry.key, isImage);
      }

      final newEndpointToPeerId = Map<String, String>.from(state.endpointToPeerId);
      newEndpointToPeerId.remove(update.endpointId);

      final bool isCurrentEndpoint = (state.activeEndpointId == update.endpointId);
      final bool anyPeerStillConnected = state.sessions.values
          .any((s) => s.endpointId != update.endpointId && s.status == SessionStatus.connected);
      _stateUpdateSource = '_handleConnectionUpdate';
      state = state.copyWith(
        connectionStatus: isCurrentEndpoint
            ? (anyPeerStillConnected ? ConnectionStatus.connected : update.status)
            : state.connectionStatus,
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
        state.connectionStatus == ConnectionStatus.accepting) {
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
        VantraCapability.audio,
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
    final seq = secSession.ns;
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
        VantraCapability.audio,
      ],
    );

    final bytes = _service.codec.encodePlaintext(domainPlaintext);

    final encrypted = await _cryptoService.encryptWithDoubleRatchet(
      session: secSession,
      messageId: msgId,
      plaintextBytes: bytes,
    );

    final dhPubBytes = await secSession.getLocalDhPublicKeyBytes();
    final prevChainLen = secSession.pn;

    await _sendEncryptedEnvelope(
      peerId: peerId,
      messageId: msgId,
      sessionId: secSession.sessionId,
      sequence: seq,
      nonce: Uint8List.fromList(encrypted.nonce),
      ciphertext: Uint8List.fromList(encrypted.ciphertext),
      mac: Uint8List.fromList(encrypted.mac),
      dhPublicKey: dhPubBytes,
      previousChainLength: prevChainLen,
      protocolVersion: session.negotiatedVersion ?? kCurrentProtocolVersion,
    );
    print('[VANTRA][CAPABILITY][LOCAL_ADVERTISE]\n'
          'peerId=$peerId\n'
          'endpointId=${session.endpointId}\n'
          'minVersion=$kMinSupportedProtocolVersion\n'
          'maxVersion=$kCurrentProtocolVersion\n'
          'capabilities=[text, image, file]');
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
        var session = state.sessions[peerId];
        final secSession = _securitySessions[peerId];
        final hasRoute = _routingTable[peerId]?.isActive == true;

        if (session == null && hasRoute) {
          session = PeerSession(
            peerId: peerId,
            displayName: 'Mesh Peer',
            endpointId: _routingTable[peerId]!.nextHopEndpointId,
            status: SessionStatus.connecting,
          );
          state = state.copyWith(
            sessions: {
              ...state.sessions,
              peerId: session,
            },
          );
        }

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
        final isConnected = session?.status == SessionStatus.connected || hasActiveSecureTransport(peerId) || hasRoute;
        final isSecure = session?.isSecure == true || hasRoute;
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
          if (session == null) {
            _getOrDiscoverRoute(peerId).then((discoveredRoute) {
              if (discoveredRoute != null) {
                _flushQueue(peerId, 'routeDiscovered');
              }
            });
          } else if (!secSessionExists) {
            final route = _routingTable[peerId];
            if (route != null && route.isActive) {
              _initiateEndToEndHandshake(peerId);
            } else {
              _getOrDiscoverRoute(peerId).then((discoveredRoute) {
                if (discoveredRoute != null) {
                  _flushQueue(peerId, 'routeDiscovered');
                }
              });
            }
          }
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

    if (msg.type == 'IMAGE' || msg.type == 'FILE' || msg.type == 'VOICE') {
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

      final capability = msg.type == 'IMAGE'
          ? VantraCapability.image
          : (msg.type == 'VOICE' ? VantraCapability.audio : VantraCapability.file);

      if (session.enabledCapabilities == null) {
        print('[VANTRA][CAPABILITY][CHECK]\n'
              'peerId=${session.peerId}\n'
              'messageType=${msg.type}\n'
              'enabledCapabilities=null\n'
              'state=WAITING');
        print('[VANTRA][CAPABILITY][WAIT]\n'
              'peerId=${session.peerId}\n'
              'messageId=${msg.messageId}');
        _inflightSends.remove(msg.messageId);
        return false;
      }

      final isSupported = session.enabledCapabilities!.contains(capability);
      if (!isSupported) {
        print('[VANTRA][CAPABILITY][REJECT]\n'
              'peerId=${session.peerId}\n'
              'requested=${capability.name}\n'
              'enabledCapabilities=${session.enabledCapabilities?.map((c) => c.name).toList()}\n'
              'reason=UNSUPPORTED_CAPABILITY');
        VantraLogger.log('[VANTRA][MESSAGING] Sharing type ${msg.type} not supported by peer ${msg.receiverId}. '
            'session.status=${session.status.name}, '
            'session.isSecure=${session.isSecure}, '
            'session.enabledCapabilities=${session.enabledCapabilities?.map((c) => c.name).toList()}');
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        _inflightSends.remove(msg.messageId);
        return false;
      }

      print('[VANTRA][CAPABILITY][READY]\n'
            'peerId=${session.peerId}\n'
            'enabledCapabilities=${session.enabledCapabilities?.map((c) => c.name).toList()}\n'
            'endpointId=${session.endpointId}');

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

      final fileSize = await file.length();
      const int mediaSizeLimit = 500 * 1024 * 1024;
      if (fileSize > mediaSizeLimit) {
        print('REJECT_REASON=SIZE_LIMIT');
        print('[VANTRA][MEDIA][REJECT]\n'
              'peerId=${session.peerId}\n'
              'endpointId=${session.endpointId}\n'
              'transferId=${msg.transferId}\n'
              'reason=SIZE_LIMIT');
        VantraLogger.log('[VANTRA][MESSAGING] Media size $fileSize exceeds 500 MB limit');
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        _inflightSends.remove(msg.messageId);
        return false;
      }

      final chunkSize = 131072;
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
      final offerSeq = secSession.ns;

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
        duration: msg.duration,
      );

      final offerBytes = _service.codec.encodePlaintext(offerDomainMsg);

      final encryptedOffer = await _cryptoService.encryptWithDoubleRatchet(
        session: secSession,
        messageId: offerMsgId,
        plaintextBytes: offerBytes,
      );

      final dhPubBytes = await secSession.getLocalDhPublicKeyBytes();
      final prevChainLen = secSession.pn;

      print('[VANTRA][MEDIA][OFFER_ENCRYPT]\n'
            'messageId=${msg.messageId}\n'
            'transferId=${msg.transferId}\n'
            'encryptedBytes=${encryptedOffer.ciphertext.length}');

      VantraLogger.log('[VANTRA][MESSAGING] Media/File transfer offering transferId=${msg.transferId}');

      print('[VANTRA][MEDIA][OFFER_SEND]\n'
            'messageId=${msg.messageId}\n'
            'endpoint=${session.endpointId}\n'
            'bytes=${encryptedOffer.ciphertext.length}');

      await _sendEncryptedEnvelope(
        peerId: session.peerId,
        messageId: offerMsgId,
        sessionId: secSession.sessionId,
        sequence: offerSeq,
        nonce: Uint8List.fromList(encryptedOffer.nonce),
        ciphertext: Uint8List.fromList(encryptedOffer.ciphertext),
        mac: Uint8List.fromList(encryptedOffer.mac),
        dhPublicKey: dhPubBytes,
        previousChainLength: prevChainLen,
        protocolVersion: kCurrentProtocolVersion,
      );

      print('[VANTRA][MEDIA][OFFER_SEND_SUCCESS]\n'
            'messageId=${msg.messageId}\n'
            'endpoint=${session.endpointId}');
      print('[VANTRA][MEDIA][OFFER_SENT]\n'
            'peerId=${session.peerId}\n'
            'endpointId=${session.endpointId}\n'
            'messageId=${msg.messageId}\n'
            'transferId=${msg.transferId}');

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

      if (response.type == DomainMediaControlType.reject || response.type == DomainMediaControlType.cancel) {
        final isCancel = response.type == DomainMediaControlType.cancel;
        VantraLogger.log('[VANTRA][MESSAGING] Transfer failed or cancelled: transferId=${msg.transferId}');
        print('[VANTRA][MEDIA][CHUNK_PIPELINE_STOPPED]\n'
              'messageId=${msg.messageId}\n'
              'transferId=${msg.transferId}\n'
              'reason=${isCancel ? 'Cancelled by receiver' : 'Receiver rejected transfer'}');
        await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
        _inflightSends.remove(msg.messageId);
        return false;
      }

      final startIndex = response.nextExpectedChunk ?? 0;
      VantraLogger.log('[VANTRA][MESSAGING] Transfer ACCEPTED. Starting from chunk index $startIndex of $totalChunks');

      final accessFile = await file.open(mode: FileMode.read);
      try {
        for (var i = startIndex; i < totalChunks; i++) {
          if (_cancelledTransfers.contains(msg.transferId)) {
            VantraLogger.log('[VANTRA][MESSAGING] Chunk streaming aborted for transferId=${msg.transferId} because it was cancelled');
            print('[VANTRA][MEDIA][CHUNK_PIPELINE_STOPPED]\n'
                  'messageId=${msg.messageId}\n'
                  'transferId=${msg.transferId}\n'
                  'reason=Cancelled by user');
            await repository.updateMessageStatus(msg.messageId, MessageStatus.failed);
            _inflightSends.remove(msg.messageId);
            return false;
          }

          final activeSession = state.sessions[msg.receiverId];
          if (activeSession == null || activeSession.status != SessionStatus.connected) {
            throw Exception('Disconnected during chunk stream');
          }

          await accessFile.setPosition(i * chunkSize);
          final chunkData = await accessFile.read(chunkSize);

          final chunkMsgId = const Uuid().v4();
          final chunkSeq = secSession.ns;

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
          final encryptedChunk = await _cryptoService.encryptWithDoubleRatchet(
            session: secSession,
            messageId: chunkMsgId,
            plaintextBytes: chunkBytes,
          );

          final dhPubBytes = await secSession.getLocalDhPublicKeyBytes();
          final prevChainLen = secSession.pn;

          if (kDebugMode) {
            print('[VANTRA][MEDIA][CHUNK_SEND]\n'
                  'messageId=${msg.messageId}\n'
                  'transferId=${msg.transferId}\n'
                  'chunkIndex=$i\n'
                  'totalChunks=$totalChunks');
          }

          await _sendEncryptedEnvelope(
            peerId: session.peerId,
            messageId: chunkMsgId,
            sessionId: secSession.sessionId,
            sequence: chunkSeq,
            nonce: Uint8List.fromList(encryptedChunk.nonce),
            ciphertext: Uint8List.fromList(encryptedChunk.ciphertext),
            mac: Uint8List.fromList(encryptedChunk.mac),
            dhPublicKey: dhPubBytes,
            previousChainLength: prevChainLen,
            protocolVersion: kCurrentProtocolVersion,
          );

          if (kDebugMode) {
            print('[VANTRA][MEDIA][CHUNK_SEND_SUCCESS]\n'
                  'messageId=${msg.messageId}\n'
                  'chunkIndex=$i');
          }

          final double lastProgress = _transferProgress[msg.transferId!] ?? 0.0;
          final double currentProgress = (i + 1) / totalChunks;
          final tracker = _speedTrackers.putIfAbsent(msg.transferId!, () => TransferSpeedTracker(totalBytes: msg.fileSize ?? 0));
          final bytesSentTotal = (i * chunkSize) + chunkData.length;
          tracker.record(bytesSentTotal);

          final bool isFirstOrLast = i == startIndex || i == totalChunks - 1;
          if (isFirstOrLast || (currentProgress - lastProgress).abs() >= 0.02) {
            _transferProgress[msg.transferId!] = currentProgress;
            ref.read(transferProgressMapProvider.notifier).updateProgress(
              msg.transferId!,
              TransferProgressState(
                progress: currentProgress,
                speed: tracker.speedLabel,
                eta: tracker.etaLabel,
              ),
            );
          }

          await Future.delayed(const Duration(milliseconds: 5));
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

    final seq = secSession.ns;
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
      print('[VANTRA][SESSION] sendCounter=${secSession.ns}');
      print('[VANTRA][SESSION] receiveCounter=${secSession.nr}');
      print('[VANTRA][SESSION] endpoint=${session.endpointId}');
      print('[VANTRA][SESSION] keyAvailable=true');
      final encrypted = await _cryptoService.encryptWithDoubleRatchet(
        session: secSession,
        messageId: msg.messageId,
        plaintextBytes: plaintextBytes,
      );

      final dhPubBytes = await secSession.getLocalDhPublicKeyBytes();
      final prevChainLen = secSession.pn;

      print('[VANTRA][MESSAGE] ENCRYPTED messageId=${msg.messageId} bytes=${encrypted.ciphertext.length}');
      VantraLogger.log('[VANTRA][CRYPTO] ENCRYPT SUCCESS messageId=${msg.messageId} nonceLength=12 ciphertextLength=${encrypted.ciphertext.length} macLength=16');

      await _sendEncryptedEnvelope(
        peerId: session.peerId,
        messageId: msg.messageId,
        sessionId: secSession.sessionId,
        sequence: seq,
        nonce: Uint8List.fromList(encrypted.nonce),
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        mac: Uint8List.fromList(encrypted.mac),
        dhPublicKey: dhPubBytes,
        previousChainLength: prevChainLen,
        protocolVersion: kCurrentProtocolVersion,
      );

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

  Future<void> sendGroupMessage(String groupId, String text) async {
    final localIdentity = ref.read(localIdentityStateProvider);
    final repository = ref.read(messagingRepositoryProvider);

    final messageId = const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Create VantraMessage with groupId populated
    final msg = VantraMessage(
      messageId: messageId,
      senderId: localIdentity.peerId,
      receiverId: groupId, // Addressed to the group
      text: text,
      timestamp: timestamp,
      status: MessageStatus.pending,
      groupId: groupId,
    );

    // Save locally under the group chat
    await repository.saveOutgoingMessage(msg);

    // Fetch all members of the group
    final members = await repository.getGroupMembers(groupId);
    
    // Perform E2E fan-out encryption and delivery for each member (except self)
    int sendCount = 0;
    for (final member in members) {
      if (member.peerId == localIdentity.peerId) continue;

      final peerId = member.peerId;
      final session = state.sessions[peerId];
      final secSession = _securitySessions[peerId];

      if (session != null && secSession != null && session.status == SessionStatus.connected) {
        // Encrypt and transmit pairwise
        final seq = secSession.ns;
        final domainPlaintext = DomainTextMessage(
          messageId: messageId,
          sessionId: secSession.sessionId,
          sequence: seq,
          timestampMs: timestamp,
          senderId: localIdentity.peerId,
          receiverId: groupId, // GroupId is transmitted as the receiverId
          content: text,
        );

        try {
          final plaintextBytes = _service.codec.encodePlaintext(domainPlaintext);
          final encrypted = await _cryptoService.encryptWithDoubleRatchet(
            session: secSession,
            messageId: messageId,
            plaintextBytes: plaintextBytes,
          );

          final dhPubBytes = await secSession.getLocalDhPublicKeyBytes();
          final prevChainLen = secSession.pn;

          await _sendEncryptedEnvelope(
            peerId: peerId,
            messageId: messageId,
            sessionId: secSession.sessionId,
            sequence: seq,
            nonce: Uint8List.fromList(encrypted.nonce),
            ciphertext: Uint8List.fromList(encrypted.ciphertext),
            mac: Uint8List.fromList(encrypted.mac),
            dhPublicKey: dhPubBytes,
            previousChainLength: prevChainLen,
            protocolVersion: kCurrentProtocolVersion,
          );
          sendCount++;
        } catch (e, stack) {
          VantraLogger.log('[VANTRA][MESSAGING] Failed to send group message to member $peerId: $e', e, stack);
        }
      }
    }

    if (sendCount > 0) {
      await repository.updateMessageStatus(messageId, MessageStatus.sent);
    } else {
      // If no members are currently connected, we can keep it pending
      await repository.updateMessageStatus(messageId, MessageStatus.failed);
    }
  }

  Future<void> createAndInviteGroup(String name, List<String> memberIds) async {
    final localIdentity = ref.read(localIdentityStateProvider);
    final repository = ref.read(messagingRepositoryProvider);
    final groupId = const Uuid().v4();

    // Ensure local user is included in membership list
    final allMembers = {localIdentity.peerId, ...memberIds}.toList();
    await repository.createGroup(groupId, name, localIdentity.peerId, allMembers);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final captionMembers = allMembers.join(',');

    for (final peerId in memberIds) {
      if (peerId == localIdentity.peerId) continue;

      final session = state.sessions[peerId];
      final secSession = _securitySessions[peerId];

      if (session != null && secSession != null && session.status == SessionStatus.connected) {
        final inviteMsgId = const Uuid().v4();
        final inviteSeq = secSession.ns;

        final inviteDomainMsg = DomainMediaControl(
          messageId: inviteMsgId,
          sessionId: secSession.sessionId,
          sequence: inviteSeq,
          timestampMs: timestamp,
          senderId: localIdentity.peerId,
          receiverId: peerId,
          type: DomainMediaControlType.offer,
          transferId: groupId,
          fileName: name,
          mimeType: 'application/vantra-group-invite',
          caption: captionMembers,
        );

        try {
          final inviteBytes = _service.codec.encodePlaintext(inviteDomainMsg);
          final encrypted = await _cryptoService.encryptWithDoubleRatchet(
            session: secSession,
            messageId: inviteMsgId,
            plaintextBytes: inviteBytes,
          );

          final dhPubBytes = await secSession.getLocalDhPublicKeyBytes();
          final prevChainLen = secSession.pn;

          await _sendEncryptedEnvelope(
            peerId: peerId,
            messageId: inviteMsgId,
            sessionId: secSession.sessionId,
            sequence: inviteSeq,
            nonce: Uint8List.fromList(encrypted.nonce),
            ciphertext: Uint8List.fromList(encrypted.ciphertext),
            mac: Uint8List.fromList(encrypted.mac),
            dhPublicKey: dhPubBytes,
            previousChainLength: prevChainLen,
            protocolVersion: kCurrentProtocolVersion,
          );
        } catch (e, stack) {
          VantraLogger.log('[VANTRA][MESSAGING] Failed to send group invite to $peerId: $e', e, stack);
        }
      }
    }
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

  Future<void> cancelTransfer(String messageId, String peerId) async {
    VantraLogger.log('[VANTRA][MESSAGING] cancelTransfer: messageId=$messageId, peerId=$peerId');
    final repository = ref.read(messagingRepositoryProvider);
    final msg = await repository.getMessageById(messageId);
    if (msg == null) return;

    final transferId = msg.transferId;
    if (transferId == null) return;

    _cancelledTransfers.add(transferId);
    _speedTrackers.remove(transferId);
    _transferProgress.remove(transferId);

    // Clean up our local state/files if we were receiving
    final isImage = msg.type == 'IMAGE';
    await _cleanupTempDir(transferId, isImage);

    // Update state provider to clear progress
    ref.read(transferProgressMapProvider.notifier).removeProgress(transferId);

    // Update database status
    await repository.updateMessageStatus(messageId, MessageStatus.failed);

    // Send cancel message if active transport exists
    final activeSession = state.sessions[peerId];
    final secSession = _securitySessions[peerId];
    if (activeSession != null && activeSession.status == SessionStatus.connected && secSession != null) {
      await _sendMediaCancel(activeSession.endpointId, secSession, transferId);
    }

    // Also resolve any completer we might be waiting on
    final completer = _mediaCompleters[transferId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(DomainMediaControl(
        messageId: const Uuid().v4(),
        sessionId: secSession?.sessionId ?? '',
        sequence: 0,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: msg.senderId,
        receiverId: msg.receiverId,
        type: DomainMediaControlType.cancel,
        transferId: transferId,
      ));
    }
  }

  Future<void> _sendMediaCancel(String endpointId, SecuritySession session, String transferId) async {
    final msgId = const Uuid().v4();
    final seq = session.ns;

    final localId = ref.read(localIdentityStateProvider);
    final cancelDomainMsg = DomainMediaControl(
      messageId: msgId,
      sessionId: session.sessionId,
      sequence: seq,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      senderId: localId.peerId,
      receiverId: session.peerId,
      type: DomainMediaControlType.cancel,
      transferId: transferId,
    );

    final bytes = _service.codec.encodePlaintext(cancelDomainMsg);
    final encrypted = await _cryptoService.encryptWithDoubleRatchet(
      session: session,
      messageId: msgId,
      plaintextBytes: bytes,
    );

    final dhPubBytes = await session.getLocalDhPublicKeyBytes();
    final prevChainLen = session.pn;

    await _sendEncryptedEnvelope(
      peerId: session.peerId,
      messageId: msgId,
      sessionId: session.sessionId,
      sequence: seq,
      nonce: Uint8List.fromList(encrypted.nonce),
      ciphertext: Uint8List.fromList(encrypted.ciphertext),
      mac: Uint8List.fromList(encrypted.mac),
      dhPublicKey: dhPubBytes,
      previousChainLength: prevChainLen,
      protocolVersion: kCurrentProtocolVersion,
    );
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

  Future<void> verifyPeer(String peerId, String verifiedPublicKey) async {
    final repo = ref.read(messagingRepositoryProvider);
    await repo.updatePeerVerification(peerId, verifiedPublicKey);

    final session = state.sessions[peerId];
    if (session != null) {
      state = state.copyWith(
        sessions: {
          ...state.sessions,
          peerId: session.copyWith(trustState: PeerTrustState.verified),
        },
      );
    }
  }

  void clearIdentityMismatchRequest() {
    state = state.copyWith(clearIdentityMismatchRequest: true);
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
  Set<String> get aliveEndpoints => _aliveEndpoints;

  @visibleForTesting
  Map<String, PendingIncomingOffer> get pendingIncomingOffers => _pendingIncomingOffers;

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

  Future<void> sendVoiceMessage(String peerId, String filePath, int durationMs) async {
    VantraLogger.log('[VANTRA][MESSAGING] sendVoiceMessage: peerId=$peerId, filePath=$filePath, durationMs=$durationMs');
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

    String mimeType = 'audio/aac';
    if (ext.toLowerCase() == '.m4a') {
      mimeType = 'audio/mp4';
    } else if (ext.toLowerCase() == '.ogg') {
      mimeType = 'audio/ogg';
    }

    // Compute complete-file SHA-256 hash using streaming
    String sha256Hex = '';
    try {
      final fileStream = File(localPath).openRead();
      final hashVal = await sha256.bind(fileStream).first;
      sha256Hex = hashVal.toString();
      VantraLogger.log('[VANTRA][MESSAGING] Computed SHA-256 for outgoing voice message: $sha256Hex');
    } catch (e) {
      VantraLogger.log('[VANTRA][MESSAGING] Failed to compute voice message hash: $e');
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
      text: '',
      timestamp: timestamp,
      status: MessageStatus.pending,
      type: 'VOICE',
      mediaPath: localPath,
      mimeType: mimeType,
      fileName: path.basename(filePath),
      fileSize: fileSize,
      transferId: transferId,
      sha256: sha256Hex,
      duration: durationMs,
    );

    await repository.saveOutgoingMessage(msg);

    print('[VANTRA][MEDIA][PERSIST]\n'
          'messageId=$messageId\n'
          'status=${msg.status.name}\n'
          'mediaType=${msg.type}');

    _flushQueue(peerId, 'sendVoiceMessage');
  }

  Future<void> sendCallPlaintext(String peerId, DomainPlaintext plaintext) async {
    final session = state.sessions[peerId];
    final secSession = _securitySessions[peerId];
    if (session == null || secSession == null || session.status != SessionStatus.connected) {
      VantraLogger.log('[VANTRA][MESSAGING] sendCallPlaintext failed: no connected session for $peerId');
      return;
    }

    final bytes = _service.codec.encodePlaintext(plaintext);
    final encrypted = await _cryptoService.encryptWithDoubleRatchet(
      session: secSession,
      messageId: plaintext.messageId,
      plaintextBytes: bytes,
    );

    final dhPubBytes = await secSession.getLocalDhPublicKeyBytes();
    final prevChainLen = secSession.pn;

    await _sendEncryptedEnvelope(
      peerId: peerId,
      messageId: plaintext.messageId,
      sessionId: secSession.sessionId,
      sequence: plaintext.sequence,
      nonce: Uint8List.fromList(encrypted.nonce),
      ciphertext: Uint8List.fromList(encrypted.ciphertext),
      mac: Uint8List.fromList(encrypted.mac),
      dhPublicKey: dhPubBytes,
      previousChainLength: prevChainLen,
      protocolVersion: kCurrentProtocolVersion,
    );
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
    final seq = session.ns;

    final localId = ref.read(localIdentityStateProvider);
    final rejectDomainMsg = DomainMediaControl(
      messageId: msgId,
      sessionId: session.sessionId,
      sequence: seq,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      senderId: localId.peerId,
      receiverId: session.peerId,
      type: DomainMediaControlType.reject,
      transferId: transferId,
    );

    final bytes = _service.codec.encodePlaintext(rejectDomainMsg);
    final encrypted = await _cryptoService.encryptWithDoubleRatchet(
      session: session,
      messageId: msgId,
      plaintextBytes: bytes,
    );

    final dhPubBytes = await session.getLocalDhPublicKeyBytes();
    final prevChainLen = session.pn;

    await _sendEncryptedEnvelope(
      peerId: session.peerId,
      messageId: msgId,
      sessionId: session.sessionId,
      sequence: seq,
      nonce: Uint8List.fromList(encrypted.nonce),
      ciphertext: Uint8List.fromList(encrypted.ciphertext),
      mac: Uint8List.fromList(encrypted.mac),
      dhPublicKey: dhPubBytes,
      previousChainLength: prevChainLen,
      protocolVersion: kCurrentProtocolVersion,
    );
  }

  Future<void> _sendMediaAccept(String endpointId, SecuritySession session, String transferId, int nextExpectedChunk) async {
    final msgId = const Uuid().v4();
    final seq = session.ns;

    final localId = ref.read(localIdentityStateProvider);
    final acceptDomainMsg = DomainMediaControl(
      messageId: msgId,
      sessionId: session.sessionId,
      sequence: seq,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      senderId: localId.peerId,
      receiverId: session.peerId,
      type: DomainMediaControlType.accept,
      transferId: transferId,
      nextExpectedChunk: nextExpectedChunk,
    );

    final bytes = _service.codec.encodePlaintext(acceptDomainMsg);
    final encrypted = await _cryptoService.encryptWithDoubleRatchet(
      session: session,
      messageId: msgId,
      plaintextBytes: bytes,
    );

    final dhPubBytes = await session.getLocalDhPublicKeyBytes();
    final prevChainLen = session.pn;

    await _sendEncryptedEnvelope(
      peerId: session.peerId,
      messageId: msgId,
      sessionId: session.sessionId,
      sequence: seq,
      nonce: Uint8List.fromList(encrypted.nonce),
      ciphertext: Uint8List.fromList(encrypted.ciphertext),
      mac: Uint8List.fromList(encrypted.mac),
      dhPublicKey: dhPubBytes,
      previousChainLength: prevChainLen,
      protocolVersion: kCurrentProtocolVersion,
    );
  }

  Future<void> _handleIncomingOffer(
    String peerId,
    String endpointId,
    SecuritySession session,
    DomainMediaControl offer,
  ) async {
    final activeSession = state.sessions[peerId];
    final repository = ref.read(messagingRepositoryProvider);

    final mime = offer.mimeType;
    final isImage = mime != null &&
        (mime.startsWith('image/jpeg') ||
         mime.startsWith('image/png') ||
         mime.startsWith('image/webp')) &&
        (offer.width != null && offer.width! > 0);
    final isAudio = mime != null && mime.startsWith('audio/');
    final capability = isImage
        ? VantraCapability.image
        : (isAudio ? VantraCapability.audio : VantraCapability.file);
    final isSupported = activeSession?.enabledCapabilities?.contains(capability) ?? false;
    const int mediaSizeLimit = 500 * 1024 * 1024;

    print('OFFER_RECEIVED\n'
          'mimeType=$mime\n'
          'width=${offer.width}\n'
          'height=${offer.height}\n'
          'isImage=$isImage\n'
          'capability=${capability.name}\n'
          'activeSession=${activeSession == null ? "null" : "not_null"}\n'
          'sessionStatus=${activeSession?.status.name}\n'
          'enabledCapabilities=${activeSession?.enabledCapabilities?.map((c) => c.name).toList()}\n'
          'isSupported=$isSupported\n'
          'fileSize=${offer.fileSize}\n'
          'sizeLimit=$mediaSizeLimit');

    print('[VANTRA][MEDIA][OFFER_RECEIVED]\n'
          'peerId=$peerId\n'
          'endpointId=$endpointId\n'
          'transferId=${offer.transferId}\n'
          'mimeType=$mime\n'
          'fileSize=${offer.fileSize}\n'
          'capability=${capability.name}');

    if (activeSession == null) {
      print('REJECT_REASON=CAPABILITY');
      print('[VANTRA][MEDIA][REJECT]\n'
            'peerId=$peerId\n'
            'endpointId=$endpointId\n'
            'transferId=${offer.transferId}\n'
            'reason=NO_ACTIVE_SESSION');
      await _cleanupTempDir(offer.transferId, isImage || isAudio);
      await _sendMediaReject(endpointId, session, offer.transferId);
      return;
    }

    if (activeSession.enabledCapabilities == null) {
      print('[VANTRA][MEDIA][OFFER_WAIT_CAPABILITY]\n'
            'peerId=$peerId\n'
            'endpointId=$endpointId\n'
            'transferId=${offer.transferId}\n'
            'reason=enabledCapabilities==null');

      _pendingIncomingOffers[offer.transferId]?.timeoutTimer.cancel();
      final timer = Timer(const Duration(seconds: 15), () async {
        final pending = _pendingIncomingOffers.remove(offer.transferId);
        if (pending != null) {
          print('[VANTRA][MEDIA][OFFER_WAIT_TIMEOUT]\n'
                'peerId=$peerId\n'
                'endpointId=$endpointId\n'
                'transferId=${offer.transferId}');
          print('REJECT_REASON=CAPABILITY');
          print('[VANTRA][MEDIA][REJECT]\n'
                'peerId=$peerId\n'
                'endpointId=$endpointId\n'
                'transferId=${offer.transferId}\n'
                'reason=CAPABILITY_NEGOTIATION_TIMEOUT');
          await _cleanupTempDir(offer.transferId, isImage || isAudio);
          final curSec = _securitySessions[peerId];
          if (curSec != null && (curSec.endpointId == endpointId || curSec.endpointId.startsWith('mesh:'))) {
            await _sendMediaReject(endpointId, pending.session, offer.transferId);
          }
        }
      });

      _pendingIncomingOffers[offer.transferId] = PendingIncomingOffer(
        peerId: peerId,
        endpointId: endpointId,
        session: session,
        offer: offer,
        timeoutTimer: timer,
      );
      return;
    }

    final isCapSupported = activeSession.enabledCapabilities!.contains(capability);
    if (!isCapSupported) {
      print('REJECT_REASON=CAPABILITY');
      print('[VANTRA][MEDIA][REJECT]\n'
            'peerId=$peerId\n'
            'endpointId=$endpointId\n'
            'transferId=${offer.transferId}\n'
            'reason=UNSUPPORTED_CAPABILITY');
      VantraLogger.log('[VANTRA][MESSAGING] Received OFFER for $capability, but capability not enabled. activeSessionCapabilities=${activeSession.enabledCapabilities?.map((c) => c.name).toList()}');
      await _cleanupTempDir(offer.transferId, isImage || isAudio);
      await _sendMediaReject(endpointId, session, offer.transferId);
      return;
    }

    if (offer.fileSize != null && offer.fileSize! > mediaSizeLimit) {
      print('REJECT_REASON=SIZE_LIMIT');
      print('[VANTRA][MEDIA][REJECT]\n'
            'peerId=$peerId\n'
            'endpointId=$endpointId\n'
            'transferId=${offer.transferId}\n'
            'reason=SIZE_LIMIT');
      VantraLogger.log('[VANTRA][MESSAGING] Media OFFER exceeds size limit: ${offer.fileSize}');
      await _cleanupTempDir(offer.transferId, isImage || isAudio);
      await _sendMediaReject(endpointId, session, offer.transferId);
      return;
    }

    final type = isImage ? 'IMAGE' : (isAudio ? 'VOICE' : 'FILE');
    final dirPrefix = (isImage || isAudio) ? 'media' : 'files';

    final appDir = await getApplicationDocumentsDirectory();
    final tempDir = Directory(path.join(appDir.path, dirPrefix, 'temp', offer.transferId));
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

    final existingMsg = await repository.getMessageById(offer.messageId);
    if (existingMsg != null) {
      if (existingMsg.status == MessageStatus.received) {
        // Transfer already fully completed and verified
        await _sendAck(endpointId, session, offer.messageId);
      } else {
        // In progress or retry: send ACCEPT to resume chunk transfer
        print('[VANTRA][MEDIA][OFFER_ACCEPT]\n'
              'peerId=$peerId\n'
              'endpointId=$endpointId\n'
              'transferId=${offer.transferId}\n'
              'nextExpectedChunk=$nextExpectedChunk\n'
              'resume=true');
        await _sendMediaAccept(endpointId, session, offer.transferId, nextExpectedChunk);
      }
      return;
    }

    final incomingMsg = VantraMessage(
      messageId: offer.messageId,
      senderId: offer.senderId,
      receiverId: offer.receiverId,
      text: offer.caption ?? '',
      timestamp: offer.timestampMs,
      status: MessageStatus.sending,
      type: type,
      fileName: offer.fileName,
      fileSize: offer.fileSize,
      width: offer.width,
      height: offer.height,
      transferId: offer.transferId,
      sha256: offer.sha256,
      duration: offer.duration,
    );
    _receiveChunkSizes[offer.transferId] = offer.chunkSize ?? 131072;
    await repository.saveIncomingMessage(incomingMsg);

    print('[VANTRA][MEDIA][OFFER_ACCEPT]\n'
          'peerId=$peerId\n'
          'endpointId=$endpointId\n'
          'transferId=${offer.transferId}\n'
          'nextExpectedChunk=$nextExpectedChunk');

    await _sendMediaAccept(endpointId, session, offer.transferId, nextExpectedChunk);
  }

  Future<void> _replayPendingOffersForPeer(String peerId, String endpointId) async {
    final toReplay = _pendingIncomingOffers.entries
        .where((e) => e.value.peerId == peerId && e.value.endpointId == endpointId)
        .map((e) => e.value)
        .toList();

    for (final pending in toReplay) {
      _pendingIncomingOffers.remove(pending.offer.transferId);
      pending.timeoutTimer.cancel();
      print('[VANTRA][MEDIA][OFFER_REPLAY]\n'
            'peerId=$peerId\n'
            'endpointId=$endpointId\n'
            'transferId=${pending.offer.transferId}');
      await _handleIncomingOffer(pending.peerId, pending.endpointId, pending.session, pending.offer);
    }
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

      final oldTransport = oldSession?.status == SessionStatus.connected && oldSession?.isSecure == true;
      final newTransport = newSession?.status == SessionStatus.connected && newSession?.isSecure == true;

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

  // --- Phase 16 Mesh Routing Methods & Handlers ---

  @visibleForTesting
  Map<String, RouteEntry> get routingTable => _routingTable;

  String _getRouteRequestCacheKey(String sourcePeerId, String requestId) {
    return '$sourcePeerId:$requestId';
  }

  void _addToDuplicateCache(String key, Set<String> cache, {Duration duration = const Duration(minutes: 5)}) {
    cache.add(key);
    final timer = Timer(duration, () {
      cache.remove(key);
    });
    _cacheTimers.add(timer);
  }

  String _hexEncode(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _updateRoute({
    required String destinationPeerId,
    required String nextHopPeerId,
    required String nextHopEndpointId,
    required int hopCount,
  }) {
    final existing = _routingTable[destinationPeerId];
    if (existing == null || existing.hopCount > hopCount || !existing.isActive) {
      _routingTable[destinationPeerId] = RouteEntry(
        destinationPeerId: destinationPeerId,
        nextHopPeerId: nextHopPeerId,
        nextHopEndpointId: nextHopEndpointId,
        hopCount: hopCount,
        lastSeen: DateTime.now(),
        isActive: true,
      );
      print('[VANTRA][MESH][ROUTE_CREATED] destination=$destinationPeerId nextHop=$nextHopPeerId hopCount=$hopCount');
    }
  }

  Future<RouteEntry?> _getOrDiscoverRoute(String destinationPeerId) async {
    final existing = _routingTable[destinationPeerId];
    if (existing != null && existing.isActive) {
      return existing;
    }

    final requestId = const Uuid().v4();
    final completer = Completer<DomainRouteReply>();
    _pendingRreqs.putIfAbsent(requestId, () => []).add(completer);

    final localIdentity = ref.read(localIdentityStateProvider);

    final rreq = DomainRouteRequest(
      protocolVersion: kCurrentProtocolVersion,
      requestId: requestId,
      sourcePeerId: localIdentity.peerId,
      destinationPeerId: destinationPeerId,
      hopCount: 0,
      maxHops: 8,
    );

    bool sentToAny = false;
    for (final entry in state.sessions.entries) {
      final session = entry.value;
      if (session.status == SessionStatus.connected) {
        print('[A][MESH][RREQ_SENT] requestId=$requestId source=${localIdentity.peerId} destination=$destinationPeerId currentPeer=${localIdentity.peerId} nextHop=${session.peerId} hopCount=0 TTL=8');
        _service.sendRouteRequest(session.endpointId, rreq);
        sentToAny = true;
      }
    }

    if (!sentToAny) {
      _pendingRreqs.remove(requestId);
      return null;
    }

    try {
      await completer.future.timeout(const Duration(seconds: 5));
      return _routingTable[destinationPeerId];
    } catch (_) {
      _pendingRreqs.remove(requestId);
      return null;
    }
  }

  Future<void> _initiateEndToEndHandshake(String peerId) async {
    final route = await _getOrDiscoverRoute(peerId);
    if (route == null) {
      print('[VANTRA][MESH][HANDSHAKE_FAILED] No route to $peerId');
      return;
    }

    final localId = ref.read(localIdentityStateProvider);
    final ephemeralKeyPair = await _cryptoService.generateEphemeralKeyPair();
    _pendingEphemeralKeys[peerId] = ephemeralKeyPair;

    final ephPub = await ephemeralKeyPair.extractPublicKey();
    final idPubBytes = _hexDecode(localId.identityPublicKey);

    final signatureBytes = await _cryptoService.signHandshake(
      identityKeyPair: localId.keyPair!,
      protocolVersion: kCurrentProtocolVersion,
      peerId: localId.peerId,
      displayName: localId.displayName,
      identityPublicKeyBytes: idPubBytes,
      ephemeralPublicKeyBytes: ephPub.bytes,
    );

    final handshake = DomainHandshakePayload(
      protocolVersion: kCurrentProtocolVersion,
      peerId: localId.peerId,
      displayName: localId.displayName,
      identityPublicKey: Uint8List.fromList(idPubBytes),
      ephemeralPublicKey: Uint8List.fromList(ephPub.bytes),
      signature: Uint8List.fromList(signatureBytes),
      minSupportedVersion: kMinSupportedProtocolVersion,
      maxSupportedVersion: kCurrentProtocolVersion,
      supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
    );

    await _sendRoutedPayload(peerId, handshake);
  }

  Future<void> _sendRoutedPayload(String destinationPeerId, DomainWireEnvelope innerEnvelope) async {
    final route = _routingTable[destinationPeerId];
    if (route == null || !route.isActive) {
      print('[VANTRA][MESH][ROUTE_ERROR] Cannot send routed payload, no route to $destinationPeerId');
      return;
    }

    final innerBytes = _service.codec.encodeWireEnvelope(innerEnvelope);
    final packetId = const Uuid().v4();

    final routeEnvelope = DomainRouteEnvelope(
      protocolVersion: kCurrentProtocolVersion,
      packetId: packetId,
      sourcePeerId: ref.read(localIdentityStateProvider).peerId,
      destinationPeerId: destinationPeerId,
      hopCount: 0,
      maxHops: 8,
      encryptedPayload: innerBytes,
    );

    print('[VANTRA][MESH][FORWARD] packetId=$packetId source=${routeEnvelope.sourcePeerId} destination=$destinationPeerId currentPeer=${ref.read(localIdentityStateProvider).peerId} nextHop=${route.nextHopPeerId} hopCount=0 TTL=8');
    await _sendWithHopRetry(route.nextHopEndpointId, routeEnvelope);
  }

  Future<void> _sendRoutedAck(String recipientPeerId, String originalMessageId, int sequence) async {
    final session = _securitySessions[recipientPeerId];
    if (session == null) return;

    final ackSeq = session.ns;
    final ackMsgId = const Uuid().v4();

    final ackDomainMessage = DomainAckMessage(
      messageId: ackMsgId,
      sessionId: session.sessionId,
      sequence: ackSeq,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      senderId: ref.read(localIdentityStateProvider).peerId,
      receiverId: recipientPeerId,
      originalMessageId: originalMessageId,
      status: DomainDeliveryStatus.delivered,
    );

    final ackPlaintextBytes = _service.codec.encodePlaintext(ackDomainMessage);
    final encAck = await _cryptoService.encryptWithDoubleRatchet(
      session: session,
      messageId: ackMsgId,
      plaintextBytes: ackPlaintextBytes,
    );

    final dhPubBytes = await session.getLocalDhPublicKeyBytes();
    final prevChainLen = session.pn;

    final routeEnvelope = DomainEncryptedEnvelope(
      protocolVersion: kCurrentProtocolVersion,
      messageId: ackMsgId,
      sessionId: session.sessionId,
      sequence: ackSeq,
      nonce: Uint8List.fromList(encAck.nonce),
      ciphertext: Uint8List.fromList(encAck.ciphertext),
      mac: Uint8List.fromList(encAck.mac),
      dhPublicKey: dhPubBytes,
      previousChainLength: prevChainLen,
    );

    await _sendRoutedPayload(recipientPeerId, routeEnvelope);
  }

  Future<void> _handleIncomingRouteRequest(RouteRequestEvent event) async {
    final localIdentity = ref.read(localIdentityStateProvider);
    if (event.request.sourcePeerId == localIdentity.peerId) {
      return;
    }

    final cacheKey = _getRouteRequestCacheKey(event.request.sourcePeerId, event.request.requestId);
    if (_recentlyProcessedRouteRequests.contains(cacheKey)) {
      print('[VANTRA][MESH][DUPLICATE_DROP] RREQ duplicate drop requestId=${event.request.requestId}');
      return;
    }
    _addToDuplicateCache(cacheKey, _recentlyProcessedRouteRequests);

    print('[B][MESH][RREQ_RECEIVED] requestId=${event.request.requestId} source=${event.request.sourcePeerId} destination=${event.request.destinationPeerId} currentPeer=${localIdentity.peerId}');

    final senderPeerId = state.endpointToPeerId[event.endpointId];
    if (senderPeerId != null) {
      _updateRoute(
        destinationPeerId: event.request.sourcePeerId,
        nextHopPeerId: senderPeerId,
        nextHopEndpointId: event.endpointId,
        hopCount: event.request.hopCount + 1,
      );
    }

    if (event.request.destinationPeerId == localIdentity.peerId) {
      final signatureBytes = await _cryptoService.signRouteReply(
        identityKeyPair: localIdentity.keyPair!,
        requestId: event.request.requestId,
        sourcePeerId: event.request.sourcePeerId,
        destinationPeerId: event.request.destinationPeerId,
      );

      final rrep = DomainRouteReply(
        protocolVersion: kCurrentProtocolVersion,
        requestId: event.request.requestId,
        sourcePeerId: event.request.sourcePeerId,
        destinationPeerId: event.request.destinationPeerId,
        hopCount: 0,
        maxHops: 8,
        signature: Uint8List.fromList(signatureBytes),
      );

      final reverseRoute = _routingTable[event.request.sourcePeerId];
      if (reverseRoute != null && reverseRoute.isActive) {
        print('[C][MESH][RREP_SENT] requestId=${event.request.requestId} source=${event.request.sourcePeerId} destination=${event.request.destinationPeerId} currentPeer=${localIdentity.peerId} nextHop=${reverseRoute.nextHopPeerId} hopCount=0 TTL=8');
        await _service.sendRouteReply(reverseRoute.nextHopEndpointId, rrep);
      }
    } else {
      final newHopCount = event.request.hopCount + 1;
      if (newHopCount >= event.request.maxHops) {
        print('[VANTRA][MESH][TTL_DROP] RREQ TTL drop requestId=${event.request.requestId}');
        return;
      }

      final forwardedRreq = DomainRouteRequest(
        protocolVersion: kCurrentProtocolVersion,
        requestId: event.request.requestId,
        sourcePeerId: event.request.sourcePeerId,
        destinationPeerId: event.request.destinationPeerId,
        hopCount: newHopCount,
        maxHops: event.request.maxHops,
      );

      for (final entry in state.sessions.entries) {
        final session = entry.value;
        if (session.status == SessionStatus.connected && session.endpointId != event.endpointId) {
          print('[B][MESH][RREQ_FORWARDED] requestId=${event.request.requestId} source=${event.request.sourcePeerId} destination=${event.request.destinationPeerId} currentPeer=${localIdentity.peerId} nextHop=${session.peerId} hopCount=$newHopCount TTL=${event.request.maxHops - 1}');
          await _service.sendRouteRequest(session.endpointId, forwardedRreq);
        }
      }
    }
  }

  Future<void> _handleIncomingRouteReply(RouteReplyEvent event) async {
    final localIdentity = ref.read(localIdentityStateProvider);

    print('[B][MESH][RREP_RECEIVED] requestId=${event.reply.requestId} source=${event.reply.sourcePeerId} destination=${event.reply.destinationPeerId} currentPeer=${localIdentity.peerId}');

    final repository = ref.read(messagingRepositoryProvider);
    final dbPeer = await repository.getPeer(event.reply.destinationPeerId);
    if (dbPeer == null || dbPeer.publicKey == null) {
      print('[VANTRA][MESH][RREP_DROP] Destination peer public key not found in database for ${event.reply.destinationPeerId}');
      return;
    }
    final pubKeyBytes = _hexDecode(dbPeer.publicKey!);

    final isSignatureValid = await _cryptoService.verifyRouteReply(
      signatureBytes: event.reply.signature,
      identityPublicKeyBytes: pubKeyBytes,
      requestId: event.reply.requestId,
      sourcePeerId: event.reply.sourcePeerId,
      destinationPeerId: event.reply.destinationPeerId,
    );

    if (!isSignatureValid) {
      print('[VANTRA][MESH][RREP_DROP] Invalid RREP signature from ${event.reply.destinationPeerId}');
      return;
    }

    final senderPeerId = state.endpointToPeerId[event.endpointId];
    if (senderPeerId != null) {
      _updateRoute(
        destinationPeerId: event.reply.destinationPeerId,
        nextHopPeerId: senderPeerId,
        nextHopEndpointId: event.endpointId,
        hopCount: event.reply.hopCount + 1,
      );
    }

    if (event.reply.sourcePeerId == localIdentity.peerId) {
      print('[A][MESH][RREP_RECEIVED] requestId=${event.reply.requestId} source=${event.reply.sourcePeerId} destination=${event.reply.destinationPeerId} currentPeer=${localIdentity.peerId}');
      final completers = _pendingRreqs[event.reply.requestId];
      if (completers != null) {
        for (final c in completers) {
          if (!c.isCompleted) {
            c.complete(event.reply);
          }
        }
        _pendingRreqs.remove(event.reply.requestId);
      }
    } else {
      final reverseRoute = _routingTable[event.reply.sourcePeerId];
      if (reverseRoute != null && reverseRoute.isActive) {
        final forwardedRrep = DomainRouteReply(
          protocolVersion: kCurrentProtocolVersion,
          requestId: event.reply.requestId,
          sourcePeerId: event.reply.sourcePeerId,
          destinationPeerId: event.reply.destinationPeerId,
          hopCount: event.reply.hopCount + 1,
          maxHops: event.reply.maxHops,
          signature: event.reply.signature,
        );
        print('[B][MESH][RREP_FORWARDED] requestId=${event.reply.requestId} source=${event.reply.sourcePeerId} destination=${event.reply.destinationPeerId} currentPeer=${localIdentity.peerId} nextHop=${reverseRoute.nextHopPeerId} hopCount=${event.reply.hopCount + 1}');
        await _service.sendRouteReply(reverseRoute.nextHopEndpointId, forwardedRrep);
      } else {
        print('[VANTRA][MESH][RREP_DROP] No reverse route found for source ${event.reply.sourcePeerId}');
      }
    }
  }

  Future<void> _handleIncomingRoutedEnvelope(RoutedEnvelopeEvent event) async {
    final localIdentity = ref.read(localIdentityStateProvider);

    if (_recentlyForwardedPackets.contains(event.envelope.packetId)) {
      print('[VANTRA][MESH][DUPLICATE_DROP] Routed envelope duplicate drop packetId=${event.envelope.packetId}');
      return;
    }
    _addToDuplicateCache(event.envelope.packetId, _recentlyForwardedPackets);

    final senderPeerId = state.endpointToPeerId[event.endpointId];
    if (senderPeerId != null) {
      _updateRoute(
        destinationPeerId: event.envelope.sourcePeerId,
        nextHopPeerId: senderPeerId,
        nextHopEndpointId: event.endpointId,
        hopCount: event.envelope.hopCount + 1,
      );
    }

    if (event.envelope.destinationPeerId == localIdentity.peerId) {
      print('[VANTRA][MESH][RECEIVED] packetId=${event.envelope.packetId} source=${event.envelope.sourcePeerId} destination=${event.envelope.destinationPeerId} currentPeer=${localIdentity.peerId} hopCount=${event.envelope.hopCount}');
      try {
        final innerEnvelope = _service.codec.decodeWireEnvelope(event.envelope.encryptedPayload);
        if (innerEnvelope is DomainHandshakePayload) {
          await _handleIncomingHandshakeOverMesh(event.envelope.sourcePeerId, event.endpointId, innerEnvelope);
        } else if (innerEnvelope is DomainEncryptedEnvelope) {
          await _handleIncomingEncryptedMessageOverMesh(event.envelope.sourcePeerId, event.endpointId, innerEnvelope);
        }
      } catch (e, stack) {
        VantraLogger.log('[VANTRA][MESH] Failed to decode inner wire envelope: $e', e, stack);
      }
    } else {
      final newHopCount = event.envelope.hopCount + 1;
      if (newHopCount >= event.envelope.maxHops) {
        print('[VANTRA][MESH][TTL_DROP] Packet TTL drop packetId=${event.envelope.packetId}');
        return;
      }

      final route = _routingTable[event.envelope.destinationPeerId];
      if (route != null && route.isActive) {
        final forwardedEnvelope = DomainRouteEnvelope(
          protocolVersion: event.envelope.protocolVersion,
          packetId: event.envelope.packetId,
          sourcePeerId: event.envelope.sourcePeerId,
          destinationPeerId: event.envelope.destinationPeerId,
          hopCount: newHopCount,
          maxHops: event.envelope.maxHops,
          encryptedPayload: event.envelope.encryptedPayload,
        );
        print('[B][MESH][FORWARD] packetId=${event.envelope.packetId} source=${event.envelope.sourcePeerId} destination=${event.envelope.destinationPeerId} currentPeer=${localIdentity.peerId} nextHop=${route.nextHopPeerId} hopCount=$newHopCount TTL=${event.envelope.maxHops - 1}');
        await _sendWithHopRetry(route.nextHopEndpointId, forwardedEnvelope);
      } else {
        print('[VANTRA][MESH][DROP] No route found for destination ${event.envelope.destinationPeerId}, dropping packetId=${event.envelope.packetId}');
      }
    }
  }

  Future<void> _handleIncomingHandshakeOverMesh(
    String senderPeerId,
    String directEndpointId,
    DomainHandshakePayload handshake,
  ) async {
    final isValid = await _cryptoService.verifyHandshake(
      signatureBytes: handshake.signature,
      identityPublicKeyBytes: handshake.identityPublicKey,
      protocolVersion: handshake.protocolVersion,
      peerId: handshake.peerId,
      displayName: handshake.displayName,
      ephemeralPublicKeyBytes: handshake.ephemeralPublicKey,
    );

    if (!isValid) {
      print('[VANTRA][MESH][HANDSHAKE_ERROR] Signature verification failed for $senderPeerId');
      return;
    }

    final repo = ref.read(messagingRepositoryProvider);
    final existingPeer = await repo.getPeer(senderPeerId);
    final trustState = existingPeer?.trustState ?? PeerTrustState.untrusted;

    if (trustState == PeerTrustState.distrusted) {
      print('[VANTRA][SECURITY][MESH] BLOCKED PEER CONNECTION REJECTED: peerId=$senderPeerId');
      _pendingEphemeralKeys.remove(senderPeerId);
      return;
    }

    if (trustState == PeerTrustState.verified &&
        existingPeer?.verifiedPublicKey != null &&
        existingPeer!.verifiedPublicKey != _hexEncode(handshake.identityPublicKey)) {
      print('[VANTRA][MESH] IDENTITY_MISMATCH (VERIFIED) peerId=$senderPeerId verifiedKey=${existingPeer.verifiedPublicKey} newKey=${_hexEncode(handshake.identityPublicKey)}');
      _pendingEphemeralKeys.remove(senderPeerId);

      final session = state.sessions[senderPeerId];
      state = state.copyWith(
        identityMismatchRequest: IdentityMismatchRequest(
          peerId: senderPeerId,
          endpointId: 'mesh:$senderPeerId',
          oldPublicKey: existingPeer.verifiedPublicKey!,
          newPublicKey: _hexEncode(handshake.identityPublicKey),
        ),
        sessions: {
          ...state.sessions,
          if (session != null)
            senderPeerId: session.copyWith(
              status: SessionStatus.disconnected,
              isSecure: false,
            ),
        },
      );
      return;
    }

    if (trustState == PeerTrustState.trusted &&
        existingPeer?.publicKey != null &&
        existingPeer!.publicKey != _hexEncode(handshake.identityPublicKey)) {
      print('[VANTRA][MESH] IDENTITY_MISMATCH peerId=$senderPeerId oldKey=${existingPeer.publicKey} newKey=${_hexEncode(handshake.identityPublicKey)}');
      _pendingEphemeralKeys.remove(senderPeerId);

      final session = state.sessions[senderPeerId];
      state = state.copyWith(
        identityMismatchRequest: IdentityMismatchRequest(
          peerId: senderPeerId,
          endpointId: 'mesh:$senderPeerId',
          oldPublicKey: existingPeer.publicKey!,
          newPublicKey: _hexEncode(handshake.identityPublicKey),
        ),
        sessions: {
          ...state.sessions,
          if (session != null)
            senderPeerId: session.copyWith(
              status: SessionStatus.disconnected,
              isSecure: false,
            ),
        },
      );
      return;
    }

    var localEphKeyPair = _pendingEphemeralKeys[senderPeerId];
    bool wasInitiator = localEphKeyPair != null;
    if (localEphKeyPair == null) {
      localEphKeyPair = await _cryptoService.generateEphemeralKeyPair();
      _pendingEphemeralKeys[senderPeerId] = localEphKeyPair;
    }

    final derivedKeys = await _cryptoService.deriveSessionKeys(
      localEphemeralKeyPair: localEphKeyPair,
      remoteEphemeralPublicKeyBytes: handshake.ephemeralPublicKey,
    );

    final remoteFingerprint = await _cryptoService.computeFingerprint(handshake.identityPublicKey);
    final secSession = SecuritySession(
      peerId: senderPeerId,
      endpointId: 'mesh:$senderPeerId',
      sessionId: derivedKeys.sessionId,
      sessionSalt: derivedKeys.sessionSalt,
      remoteIdentityPublicKey: _hexEncode(handshake.identityPublicKey),
      remoteFingerprint: remoteFingerprint,
      sendKey: derivedKeys.sendKey,
      receiveKey: derivedKeys.receiveKey,
    );

    await _cryptoService.initializeDoubleRatchet(
      session: secSession,
      handshakeLocalKeyPair: localEphKeyPair,
      handshakeRemotePublicKeyBytes: handshake.ephemeralPublicKey,
      isDeviceA: derivedKeys.isDeviceA,
    );

    _securitySessions[senderPeerId] = secSession;

    await repo.upsertPeer(
      senderPeerId,
      handshake.displayName,
      publicKey: _hexEncode(handshake.identityPublicKey),
      fingerprint: remoteFingerprint,
      trustState: PeerTrustState.untrusted,
    );

    final route = _routingTable[senderPeerId]!;
    state = state.copyWith(
      sessions: {
        ...state.sessions,
        senderPeerId: PeerSession(
          peerId: senderPeerId,
          displayName: handshake.displayName,
          endpointId: route.nextHopEndpointId,
          status: SessionStatus.connected,
          isSecure: true,
          publicKey: _hexEncode(handshake.identityPublicKey),
        ),
      },
    );

    print('[VANTRA][MESH][SESSION_READY] E2E secure session established with $senderPeerId');

    if (!wasInitiator) {
      final localId = ref.read(localIdentityStateProvider);
      final ephPub = await localEphKeyPair.extractPublicKey();
      final idPubBytes = _hexDecode(localId.identityPublicKey);

      final signatureBytes = await _cryptoService.signHandshake(
        identityKeyPair: localId.keyPair!,
        protocolVersion: kCurrentProtocolVersion,
        peerId: localId.peerId,
        displayName: localId.displayName,
        identityPublicKeyBytes: idPubBytes,
        ephemeralPublicKeyBytes: ephPub.bytes,
      );

      final replyHandshake = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: localId.peerId,
        displayName: localId.displayName,
        identityPublicKey: Uint8List.fromList(idPubBytes),
        ephemeralPublicKey: Uint8List.fromList(ephPub.bytes),
        signature: Uint8List.fromList(signatureBytes),
        minSupportedVersion: kMinSupportedProtocolVersion,
        maxSupportedVersion: kCurrentProtocolVersion,
        supportedCapabilities: const [VantraCapability.text, VantraCapability.image],
      );

      await _sendRoutedPayload(senderPeerId, replyHandshake);
    }

    _pendingEphemeralKeys.remove(senderPeerId);
    _flushQueue(senderPeerId, '_handleIncomingHandshakeOverMesh');
  }

  Future<void> _handleIncomingEncryptedMessageOverMesh(
    String senderPeerId,
    String directEndpointId,
    DomainEncryptedEnvelope event,
  ) async {
    final session = _securitySessions[senderPeerId];
    if (session == null) {
      VantraLogger.log('[VANTRA][SECURITY] INBOUND DROP: No active secure session for peer $senderPeerId');
      return;
    }

    try {
      final decryptedBytes = await _cryptoService.decryptWithDoubleRatchet(
        session: session,
        incomingDhPublicKeyBytes: event.dhPublicKey,
        incomingSequence: event.sequence,
        incomingPreviousChainLength: event.previousChainLength ?? 0,
        nonce: event.nonce,
        ciphertext: event.ciphertext,
        mac: event.mac,
        messageId: event.messageId,
      );

      final plaintext = _service.codec.decodePlaintext(decryptedBytes);
      VantraLogger.log('[VANTRA][MESSAGING] MESSAGE RECONSTRUCTED messageId=${plaintext.messageId} senderId=${plaintext.senderId} receiverId=${plaintext.receiverId} timestamp=${plaintext.timestampMs}');

      if (plaintext.sessionId != session.sessionId) {
        VantraLogger.log('[VANTRA][SECURITY] SESSION ID MISMATCH: messageId=${plaintext.messageId}, expected=${session.sessionId}, actual=${plaintext.sessionId}. Discarded.');
        return;
      }

      await _processDecryptedPlaintext(
        senderPeerId,
        directEndpointId,
        session,
        plaintext,
        isMesh: true,
      );
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][MESH] Failed to decrypt routed message: $e', e, stack);
    }
  }

  // --- Phase 17 Mesh Reliability Methods ---

  void _invalidateRoutesViaEndpoint(String deadEndpointId) {
    final invalidatedDestinations = <String>[];
    _routingTable.forEach((dest, entry) {
      if (entry.nextHopEndpointId == deadEndpointId && entry.isActive) {
        _routingTable[dest] = entry.copyWith(isActive: false);
        invalidatedDestinations.add(dest);
        print('[VANTRA][MESH][ROUTE_INVALIDATED] destination=$dest nextHop=${entry.nextHopPeerId} reason=Local Link Failure');
        _conditionallyResetE2eSession(dest, failedEndpointId: deadEndpointId);
      }
    });

    if (invalidatedDestinations.isNotEmpty) {
      _broadcastRouteError(invalidatedDestinations, excludeEndpointId: deadEndpointId);
    }
  }

  void _broadcastRouteError(List<String> brokenPeerIds, {String? excludeEndpointId}) {
    final localIdentity = ref.read(localIdentityStateProvider);
    for (final brokenPeerId in brokenPeerIds) {
      final errorId = const Uuid().v4();
      final rerr = DomainRouteError(
        protocolVersion: kCurrentProtocolVersion,
        errorId: errorId,
        brokenPeerId: brokenPeerId,
        reporterId: localIdentity.peerId,
        hopCount: 0,
        maxHops: 8,
      );

      print('[VANTRA][MESH][RERR_SENT] errorId=$errorId brokenPeerId=$brokenPeerId');
      
      for (final entry in state.sessions.entries) {
        final session = entry.value;
        if (session.status == SessionStatus.connected && session.endpointId != excludeEndpointId) {
          _service.sendRouteError(session.endpointId, rerr);
        }
      }
    }
  }

  Future<void> _handleIncomingRouteError(RouteErrorEvent event) async {
    if (_recentlyProcessedRouteErrors.contains(event.error.errorId)) {
      print('[VANTRA][MESH][RERR_DUPLICATE_DROP] errorId=${event.error.errorId}');
      return;
    }
    _addToDuplicateCache(event.error.errorId, _recentlyProcessedRouteErrors);

    print('[VANTRA][MESH][RERR_RECEIVED] errorId=${event.error.errorId} brokenPeerId=${event.error.brokenPeerId} reporter=${event.error.reporterId}');

    final brokenPeerId = event.error.brokenPeerId;
    final senderEndpointId = event.endpointId;

    final route = _routingTable[brokenPeerId];
    final routeIsAffected = (
      route != null &&
      route.isActive &&
      route.nextHopEndpointId == senderEndpointId
    );

    if (routeIsAffected) {
      _routingTable[brokenPeerId] = route.copyWith(isActive: false);
      print('[VANTRA][MESH][ROUTE_INVALIDATED] destination=$brokenPeerId reason=RERR errorId=${event.error.errorId}');

      // Step 2: Conditionally reset E2E session
      _conditionallyResetE2eSession(brokenPeerId, failedEndpointId: senderEndpointId);

      // Step 3: Conditionally rediscover
      _conditionallyRediscover(brokenPeerId);
    }

    // Step 4: TTL check and forward
    final newHopCount = event.error.hopCount + 1;
    if (newHopCount >= event.error.maxHops) {
      print('[VANTRA][MESH][RERR_TTL_DROP] errorId=${event.error.errorId} hopCount=$newHopCount');
      return;
    }

    final forwardedRerr = DomainRouteError(
      protocolVersion: event.error.protocolVersion,
      errorId: event.error.errorId,
      brokenPeerId: event.error.brokenPeerId,
      reporterId: event.error.reporterId,
      hopCount: newHopCount,
      maxHops: event.error.maxHops,
    );

    for (final entry in state.sessions.entries) {
      final session = entry.value;
      if (session.status == SessionStatus.connected && session.endpointId != senderEndpointId) {
        await _service.sendRouteError(session.endpointId, forwardedRerr);
        print('[VANTRA][MESH][RERR_FORWARDED] errorId=${event.error.errorId} nextHop=${session.peerId} hopCount=$newHopCount');
      }
    }
  }

  void _conditionallyResetE2eSession(String brokenPeerId, {required String failedEndpointId}) {
    final secSession = _securitySessions[brokenPeerId];
    if (secSession == null) return;

    final route = _routingTable[brokenPeerId];
    if (route == null || route.nextHopEndpointId != failedEndpointId) {
      // The session did not use the broken path, so do not reset it.
      return;
    }

    _securitySessions.remove(brokenPeerId);
    print('[VANTRA][MESH][SESSION_RESET] peerId=$brokenPeerId reason=route_invalidated');

    final currentPeerSession = state.sessions[brokenPeerId];
    if (currentPeerSession != null) {
      state = state.copyWith(
        sessions: {
          ...state.sessions,
          brokenPeerId: currentPeerSession.copyWith(status: SessionStatus.disconnected, isSecure: false),
        },
      );
    }
  }

  Future<void> _conditionallyRediscover(String brokenPeerId) async {
    // Check if there is any pending/failed message in the database queue for brokenPeerId
    final repository = ref.read(messagingRepositoryProvider);
    final pending = await repository.getPendingOrFailedMessages(brokenPeerId);
    if (pending.isEmpty) {
      print('[VANTRA][MESH][RERR_NO_REDISCOVERY] peerId=$brokenPeerId reason=no_queued_traffic');
      return;
    }

    print('[VANTRA][MESH][RERR_REDISCOVERY] peerId=$brokenPeerId reason=queued_traffic');
    final route = await _getOrDiscoverRoute(brokenPeerId);
    if (route != null && route.isActive) {
      _flushQueue(brokenPeerId, 'routeRediscovery');
    }
  }

  Future<bool> _sendWithHopRetry(
    String endpointId,
    DomainRouteEnvelope envelope, {
    int maxAttempts = 3,
    Duration retryDelay = const Duration(milliseconds: 300),
  }) async {
    int attempt = 0;
    while (attempt < maxAttempts) {
      try {
        await _service.sendRoutedEnvelope(endpointId, envelope);
        print('[VANTRA][MESH][HOP_SEND] packetId=${envelope.packetId} attempt=$attempt');
        return true;
      } catch (e) {
        attempt++;
        print('[VANTRA][MESH][HOP_RETRY] packetId=${envelope.packetId} attempt=$attempt error=$e');
        if (attempt < maxAttempts) {
          await Future.delayed(retryDelay);
        }
      }
    }

    print('[VANTRA][MESH][HOP_FAILED] packetId=${envelope.packetId} endpoint=$endpointId');
    _invalidateRoutesViaEndpoint(endpointId);
    return false;
  }

  // --- Phase 17 Contacts & Chat Management Methods ---

  Future<void> deleteMessage(String messageId) async {
    await ref.read(messagingRepositoryProvider).deleteMessage(messageId);
  }

  Future<void> clearChat(String peerId) async {
    final localId = ref.read(localIdentityStateProvider).peerId;
    await ref.read(messagingRepositoryProvider).clearConversation(localId, peerId);
  }

  Future<void> deleteContact(String peerId) async {
    final localId = ref.read(localIdentityStateProvider).peerId;
    await ref.read(messagingRepositoryProvider).deletePeerAndHistory(peerId, localId);

    // Clean up routing table entry
    _routingTable.remove(peerId);

    // Clean up session state if it exists
    final session = state.sessions[peerId];
    if (session != null) {
      _securitySessions.remove(peerId);
      final newSessions = Map<String, PeerSession>.from(state.sessions)..remove(peerId);
      state = state.copyWith(sessions: newSessions);
    }
  }

  @visibleForTesting
  Map<String, Timer> get receiveTimeoutTimers => _receiveTimeoutTimers;

  @visibleForTesting
  Future<void> cleanupReceiveTransfer(String transferId, {bool deleteTempFile = false, String? tempFilePath}) =>
      _cleanupReceiveTransfer(transferId, deleteTempFile: deleteTempFile, tempFilePath: tempFilePath);
}

class RouteEntry {
  final String destinationPeerId;
  final String nextHopPeerId;
  final String nextHopEndpointId;
  final int hopCount;
  final DateTime lastSeen;
  final bool isActive;

  const RouteEntry({
    required this.destinationPeerId,
    required this.nextHopPeerId,
    required this.nextHopEndpointId,
    required this.hopCount,
    required this.lastSeen,
    this.isActive = true,
  });

  RouteEntry copyWith({
    String? destinationPeerId,
    String? nextHopPeerId,
    String? nextHopEndpointId,
    int? hopCount,
    DateTime? lastSeen,
    bool? isActive,
  }) {
    return RouteEntry(
      destinationPeerId: destinationPeerId ?? this.destinationPeerId,
      nextHopPeerId: nextHopPeerId ?? this.nextHopPeerId,
      nextHopEndpointId: nextHopEndpointId ?? this.nextHopEndpointId,
      hopCount: hopCount ?? this.hopCount,
      lastSeen: lastSeen ?? this.lastSeen,
      isActive: isActive ?? this.isActive,
    );
  }
}
