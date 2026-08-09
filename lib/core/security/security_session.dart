import 'package:cryptography/cryptography.dart';

class SecuritySession {
  final String peerId;
  final String endpointId;
  final String sessionId;
  final List<int> sessionSalt;
  final SecretKey sendKey;
  final SecretKey receiveKey;
  final String remoteIdentityPublicKey;
  final String remoteFingerprint;
  int sendSequence;
  int receiveSequence;

  SecuritySession({
    required this.peerId,
    required this.endpointId,
    required this.sessionId,
    required this.sessionSalt,
    required this.sendKey,
    required this.receiveKey,
    required this.remoteIdentityPublicKey,
    required this.remoteFingerprint,
    this.sendSequence = 1,
    this.receiveSequence = 0,
  });

  /// Increments and returns the next sequence number for outbound message encryption
  int nextSendSequence() {
    final current = sendSequence;
    sendSequence++;
    return current;
  }

  /// Verifies inbound sequence monotonicity
  bool isValidInboundSequence(int seq, String incomingSessionId) {
    if (incomingSessionId != sessionId) {
      return false;
    }
    if (seq <= receiveSequence) {
      return false;
    }
    return true;
  }

  /// Updates receive sequence counter after successful decryption
  void updateReceiveSequence(int seq) {
    if (seq > receiveSequence) {
      receiveSequence = seq;
    }
  }
}
