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
  final Set<int> _receivedSequences = {};

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

  /// Verifies inbound sequence using a 64-packet sliding window replay protection
  bool isValidInboundSequence(int seq, String incomingSessionId) {
    if (incomingSessionId != sessionId) {
      return false;
    }
    if (seq <= receiveSequence - 64) {
      return false;
    }
    if (seq == receiveSequence || _receivedSequences.contains(seq)) {
      return false;
    }
    return true;
  }

  /// Updates receive sequence counter and trims sliding window cache
  void updateReceiveSequence(int seq) {
    _receivedSequences.add(seq);
    if (seq > receiveSequence) {
      receiveSequence = seq;
    }
    _receivedSequences.removeWhere((s) => s <= receiveSequence - 64);
  }
}
