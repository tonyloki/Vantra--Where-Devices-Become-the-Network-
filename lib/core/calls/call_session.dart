enum CallStatus {
  idle,
  outgoing,
  incoming,
  active,
  ended,
}

class CallSession {
  final String callId;
  final String peerId;
  final CallStatus status;
  final bool isMuted;
  final bool isSpeaker;
  final DateTime? startedAt;
  final Duration duration;
  final String? error;

  const CallSession({
    required this.callId,
    required this.peerId,
    required this.status,
    this.isMuted = false,
    this.isSpeaker = false,
    this.startedAt,
    this.duration = Duration.zero,
    this.error,
  });

  CallSession copyWith({
    String? callId,
    String? peerId,
    CallStatus? status,
    bool? isMuted,
    bool? isSpeaker,
    DateTime? startedAt,
    Duration? duration,
    String? error,
  }) {
    return CallSession(
      callId: callId ?? this.callId,
      peerId: peerId ?? this.peerId,
      status: status ?? this.status,
      isMuted: isMuted ?? this.isMuted,
      isSpeaker: isSpeaker ?? this.isSpeaker,
      startedAt: startedAt ?? this.startedAt,
      duration: duration ?? this.duration,
      error: error ?? this.error,
    );
  }
}
