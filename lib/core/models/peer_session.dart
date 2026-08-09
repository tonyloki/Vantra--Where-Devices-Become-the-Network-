import 'peer_trust_state.dart';

enum SessionStatus {
  connecting,
  handshaking,
  connected,
  disconnected,
  failed,
}

class PeerSession {
  final String peerId;
  final String displayName;
  final String endpointId;
  final SessionStatus status;
  final String? publicKey;
  final String? fingerprint;
  final PeerTrustState trustState;
  final bool isSecure;

  const PeerSession({
    required this.peerId,
    required this.displayName,
    required this.endpointId,
    required this.status,
    this.publicKey,
    this.fingerprint,
    this.trustState = PeerTrustState.untrusted,
    this.isSecure = false,
  });

  PeerSession copyWith({
    String? peerId,
    String? displayName,
    String? endpointId,
    SessionStatus? status,
    String? publicKey,
    String? fingerprint,
    PeerTrustState? trustState,
    bool? isSecure,
  }) {
    return PeerSession(
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      endpointId: endpointId ?? this.endpointId,
      status: status ?? this.status,
      publicKey: publicKey ?? this.publicKey,
      fingerprint: fingerprint ?? this.fingerprint,
      trustState: trustState ?? this.trustState,
      isSecure: isSecure ?? this.isSecure,
    );
  }
}
