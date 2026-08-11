import 'package:vantra/core/protocol/protocol_message.dart';
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
  final int? negotiatedVersion;
  final List<VantraCapability>? enabledCapabilities;
  final int? remoteMinVersion;
  final int? remoteMaxVersion;
  final List<VantraCapability>? remoteCapabilities;

  const PeerSession({
    required this.peerId,
    required this.displayName,
    required this.endpointId,
    required this.status,
    this.publicKey,
    this.fingerprint,
    this.trustState = PeerTrustState.untrusted,
    this.isSecure = false,
    this.negotiatedVersion,
    this.enabledCapabilities,
    this.remoteMinVersion,
    this.remoteMaxVersion,
    this.remoteCapabilities,
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
    int? negotiatedVersion,
    List<VantraCapability>? enabledCapabilities,
    int? remoteMinVersion,
    int? remoteMaxVersion,
    List<VantraCapability>? remoteCapabilities,
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
      negotiatedVersion: negotiatedVersion ?? this.negotiatedVersion,
      enabledCapabilities: enabledCapabilities ?? this.enabledCapabilities,
      remoteMinVersion: remoteMinVersion ?? this.remoteMinVersion,
      remoteMaxVersion: remoteMaxVersion ?? this.remoteMaxVersion,
      remoteCapabilities: remoteCapabilities ?? this.remoteCapabilities,
    );
  }
}
