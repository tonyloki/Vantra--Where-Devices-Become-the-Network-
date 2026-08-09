import 'peer_session.dart';
import 'peer_trust_state.dart';

class PeerProfile {
  final String peerId;
  final String displayName;
  final String? nickname;
  final String? lastKnownEndpointId;
  final String? publicKey;
  final String? fingerprint;
  final PeerTrustState trustState;
  final int? protocolVersion;
  final int lastSeen;
  final int createdAt;
  final int updatedAt;
  final SessionStatus sessionStatus;
  final bool isSecure;

  const PeerProfile({
    required this.peerId,
    required this.displayName,
    this.nickname,
    this.lastKnownEndpointId,
    this.publicKey,
    this.fingerprint,
    this.trustState = PeerTrustState.untrusted,
    this.protocolVersion,
    required this.lastSeen,
    required this.createdAt,
    required this.updatedAt,
    this.sessionStatus = SessionStatus.disconnected,
    this.isSecure = false,
  });

  /// Returns nickname if set, otherwise original authenticated displayName
  String get effectiveName {
    if (nickname != null && nickname!.trim().isNotEmpty) {
      return nickname!.trim();
    }
    return displayName;
  }

  bool get isOnline => sessionStatus == SessionStatus.connected;
  bool get isBlocked => trustState == PeerTrustState.distrusted;
  bool get isTrusted => trustState == PeerTrustState.trusted;

  PeerProfile copyWith({
    String? peerId,
    String? displayName,
    String? nickname,
    String? lastKnownEndpointId,
    String? publicKey,
    String? fingerprint,
    PeerTrustState? trustState,
    int? protocolVersion,
    int? lastSeen,
    int? createdAt,
    int? updatedAt,
    SessionStatus? sessionStatus,
    bool? isSecure,
  }) {
    return PeerProfile(
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      nickname: nickname ?? this.nickname,
      lastKnownEndpointId: lastKnownEndpointId ?? this.lastKnownEndpointId,
      publicKey: publicKey ?? this.publicKey,
      fingerprint: fingerprint ?? this.fingerprint,
      trustState: trustState ?? this.trustState,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      lastSeen: lastSeen ?? this.lastSeen,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sessionStatus: sessionStatus ?? this.sessionStatus,
      isSecure: isSecure ?? this.isSecure,
    );
  }
}
