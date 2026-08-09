import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/utils/logger.dart';
import 'package:vantra/core/errors/vantra_exceptions.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/messaging/messaging_repository.dart';
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
  StreamSubscription? _msgSub;
  StreamSubscription? _idSub;
  StreamSubscription? _connSub;

  @override
  MessagingState build() {
    _service = ref.watch(messagingServiceProvider);

    _msgSub?.cancel();
    _idSub?.cancel();
    _connSub?.cancel();

    _msgSub = _service.messageStream.listen(_handleIncomingMessage);
    _idSub = _service.identityStream.listen(_handleIdentityReceived);
    _connSub = ref.read(transportProvider).connectionUpdateStream.listen(_handleConnectionUpdate);

    ref.onDispose(() {
      _msgSub?.cancel();
      _idSub?.cancel();
      _connSub?.cancel();
    });

    return MessagingState.initial();
  }

  void _handleIncomingMessage(VantraMessage msg) {
    VantraLogger.log('[VANTRA][MESSAGE] Message received, displaying for peer ${msg.senderId}');
    ref.read(messagingRepositoryProvider).saveIncomingMessage(msg);
  }

  void _handleIdentityReceived(SessionIdentity identity) {
    final localId = ref.read(localIdentityStateProvider);

    if (identity.peerId == localId.peerId) return;

    final existingSession = state.sessions[identity.peerId];

    PeerSession updatedSession;
    if (existingSession != null) {
      VantraLogger.log('[VANTRA][CONNECTION] Reconnecting peer ${identity.peerId} with new endpoint ${identity.endpointId}');
      updatedSession = existingSession.copyWith(
        endpointId: identity.endpointId,
        displayName: identity.displayName,
        status: SessionStatus.connected,
      );
    } else {
      VantraLogger.log('[VANTRA][CONNECTION] New peer session established for ${identity.peerId} (${identity.displayName})');
      updatedSession = PeerSession(
        peerId: identity.peerId,
        displayName: identity.displayName,
        endpointId: identity.endpointId,
        status: SessionStatus.connected,
      );
    }

    // Persist peer update to database
    ref.read(messagingRepositoryProvider).upsertPeer(
      identity.peerId,
      identity.displayName,
      endpointId: identity.endpointId,
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
  }

  void _handleConnectionUpdate(ConnectionUpdate update) {
    final localIdentity = ref.read(localIdentityStateProvider);

    if (update.status == ConnectionStatus.connected) {
      _service.sendIdentity(update.endpointId, localIdentity);
      state = state.copyWith(
        connectionStatus: ConnectionStatus.connected,
        activeEndpointId: update.endpointId,
        activeEndpointName: update.endpointName,
      );
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
        VantraLogger.log('[VANTRA][CONNECTION] Peer $peerId disconnected from endpoint ${update.endpointId}');
        final session = state.sessions[peerId];
        if (session != null) {
          state = state.copyWith(
            sessions: {
              ...state.sessions,
              peerId: session.copyWith(status: SessionStatus.disconnected),
            },
          );
        }
      }
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

  Future<void> sendTextMessage(String peerId, String text) async {
    final session = state.sessions[peerId];
    if (session == null || session.status != SessionStatus.connected) {
      throw const VantraException('Cannot send message: Peer is not connected');
    }

    final localIdentity = ref.read(localIdentityStateProvider);
    final repository = ref.read(messagingRepositoryProvider);

    // 1. Create message model with pending status
    final messageId = const Uuid().v4();
    final msg = VantraMessage(
      messageId: messageId,
      senderId: localIdentity.peerId,
      receiverId: peerId,
      text: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      status: MessageStatus.pending,
    );

    // 2. Persist locally first
    await repository.saveOutgoingMessage(msg);

    try {
      // 3. Attempt transmission
      await _service.sendTextMessage(
        session.endpointId,
        localIdentity.peerId,
        peerId,
        text,
        messageId: messageId,
        timestamp: msg.timestamp,
      );

      // 4. Update status to sent on success
      await repository.updateMessageStatus(messageId, MessageStatus.sent);
    } catch (e) {
      // 5. Update status to failed on error
      await repository.updateMessageStatus(messageId, MessageStatus.failed);
      rethrow;
    }
  }
}
