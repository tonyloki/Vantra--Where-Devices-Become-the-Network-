enum SessionStatus {
  connecting,
  connected,
  disconnected,
}

class PeerSession {
  final String peerId;
  final String displayName;
  final String endpointId;
  final SessionStatus status;

  const PeerSession({
    required this.peerId,
    required this.displayName,
    required this.endpointId,
    required this.status,
  });

  PeerSession copyWith({
    String? peerId,
    String? displayName,
    String? endpointId,
    SessionStatus? status,
  }) {
    return PeerSession(
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      endpointId: endpointId ?? this.endpointId,
      status: status ?? this.status,
    );
  }
}
