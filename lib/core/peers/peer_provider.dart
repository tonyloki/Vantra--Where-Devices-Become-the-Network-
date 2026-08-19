import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/conversation_summary.dart';
import 'package:vantra/core/models/peer_profile.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'peer_discovery_service.dart';

final peerDiscoveryServiceProvider = Provider<PeerDiscoveryService>((ref) {
  final transport = ref.watch(transportProvider);
  final service = PeerDiscoveryService(transport);
  ref.onDispose(() => service.dispose());
  return service;
});

final isDiscoveringProvider = StreamProvider<bool>((ref) {
  final service = ref.watch(peerDiscoveryServiceProvider);
  return service.isDiscoveringStream;
});

final discoveredNearbyPeersProvider = StreamProvider<List<DiscoveredNearbyPeer>>((ref) {
  final service = ref.watch(peerDiscoveryServiceProvider);
  return service.discoveredPeersStream;
});

/// Streams all known persistent peers from Drift and merges with active session states
final allPeersStreamProvider = StreamProvider<List<PeerProfile>>((ref) {
  final repo = ref.watch(messagingRepositoryProvider);
  final messagingState = ref.watch(messagingStateProvider);

  return repo.watchPeers().map((peers) {
    return peers.map((p) {
      final session = messagingState.sessions[p.peerId];
      return PeerProfile(
        peerId: p.peerId,
        displayName: p.displayName,
        nickname: p.nickname,
        lastKnownEndpointId: p.lastKnownEndpointId,
        publicKey: p.publicKey,
        fingerprint: p.fingerprint,
        verifiedPublicKey: p.verifiedPublicKey,
        trustState: p.trustState,
        protocolVersion: p.protocolVersion,
        lastSeen: p.lastSeen,
        createdAt: p.createdAt,
        updatedAt: p.updatedAt,
        sessionStatus: session?.status ?? SessionStatus.disconnected,
        isSecure: session?.isSecure ?? false,
      );
    }).toList();
  });
});

/// Streams only trusted peers
final trustedPeersStreamProvider = StreamProvider<List<PeerProfile>>((ref) {
  final repo = ref.watch(messagingRepositoryProvider);
  final messagingState = ref.watch(messagingStateProvider);

  return repo.watchTrustedPeers().map((peers) {
    return peers.map((p) {
      final session = messagingState.sessions[p.peerId];
      return PeerProfile(
        peerId: p.peerId,
        displayName: p.displayName,
        nickname: p.nickname,
        lastKnownEndpointId: p.lastKnownEndpointId,
        publicKey: p.publicKey,
        fingerprint: p.fingerprint,
        verifiedPublicKey: p.verifiedPublicKey,
        trustState: p.trustState,
        protocolVersion: p.protocolVersion,
        lastSeen: p.lastSeen,
        createdAt: p.createdAt,
        updatedAt: p.updatedAt,
        sessionStatus: session?.status ?? SessionStatus.disconnected,
        isSecure: session?.isSecure ?? false,
      );
    }).toList();
  });
});

/// Streams only blocked peers
final blockedPeersStreamProvider = StreamProvider<List<PeerProfile>>((ref) {
  final repo = ref.watch(messagingRepositoryProvider);
  final messagingState = ref.watch(messagingStateProvider);

  return repo.watchBlockedPeers().map((peers) {
    return peers.map((p) {
      final session = messagingState.sessions[p.peerId];
      return PeerProfile(
        peerId: p.peerId,
        displayName: p.displayName,
        nickname: p.nickname,
        lastKnownEndpointId: p.lastKnownEndpointId,
        publicKey: p.publicKey,
        fingerprint: p.fingerprint,
        verifiedPublicKey: p.verifiedPublicKey,
        trustState: p.trustState,
        protocolVersion: p.protocolVersion,
        lastSeen: p.lastSeen,
        createdAt: p.createdAt,
        updatedAt: p.updatedAt,
        sessionStatus: session?.status ?? SessionStatus.disconnected,
        isSecure: session?.isSecure ?? false,
      );
    }).toList();
  });
});

/// Streams a specific PeerProfile by peerId
final peerProfileStreamProvider = StreamProvider.family<PeerProfile?, String>((ref, peerId) {
  final repo = ref.watch(messagingRepositoryProvider);
  final messagingState = ref.watch(messagingStateProvider);

  return repo.watchPeer(peerId).map((p) {
    if (p == null) return null;
    final session = messagingState.sessions[p.peerId];
    return PeerProfile(
      peerId: p.peerId,
      displayName: p.displayName,
      nickname: p.nickname,
      lastKnownEndpointId: p.lastKnownEndpointId,
      publicKey: p.publicKey,
      fingerprint: p.fingerprint,
      verifiedPublicKey: p.verifiedPublicKey,
      trustState: p.trustState,
      protocolVersion: p.protocolVersion,
      lastSeen: p.lastSeen,
      createdAt: p.createdAt,
      updatedAt: p.updatedAt,
      sessionStatus: session?.status ?? SessionStatus.disconnected,
      isSecure: session?.isSecure ?? false,
    );
  });
});

/// Streams conversation previews with unread counts
final conversationSummariesStreamProvider = StreamProvider<List<ConversationSummary>>((ref) {
  final repo = ref.watch(messagingRepositoryProvider);
  final localIdentity = ref.watch(localIdentityStateProvider);
  final messagingState = ref.watch(messagingStateProvider);

  return repo.watchConversationSummaries(localIdentity.peerId, messagingState.sessions);
});
