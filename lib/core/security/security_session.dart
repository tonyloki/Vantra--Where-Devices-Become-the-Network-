import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

class SecuritySession {
  final String peerId;
  final String endpointId;
  final String sessionId;
  final List<int> sessionSalt;
  final String remoteIdentityPublicKey;
  final String remoteFingerprint;

  // Legacy/Compatibility fields
  final SecretKey? _sendKey;
  final SecretKey? _receiveKey;

  // Double Ratchet State
  SimpleKeyPair? localDhKeyPair;
  SimplePublicKey? remoteDhPublicKey;
  SecretKey? rootKey;
  SecretKey? sendingChainKey;
  SecretKey? receivingChainKey;
  int ns; // Number of messages sent in current sending chain
  int nr; // Number of messages received in current receiving chain
  int pn; // Number of messages sent in previous sending chain

  // Cache of skipped message keys: maps "remoteDhPublicKeyHex:sequenceNumber" -> SecretKey
  final Map<String, SecretKey> skippedMessageKeys = {};
  // Track creation timestamps of skipped keys for TTL eviction
  final Map<String, DateTime> skippedMessageKeysTimestamps = {};

  bool isDeviceA;

  SecuritySession({
    required this.peerId,
    required this.endpointId,
    required this.sessionId,
    required this.sessionSalt,
    required this.remoteIdentityPublicKey,
    required this.remoteFingerprint,
    SecretKey? sendKey,
    SecretKey? receiveKey,
    int sendSequence = 1,
    int receiveSequence = 0,
    this.localDhKeyPair,
    this.remoteDhPublicKey,
    this.rootKey,
    this.sendingChainKey,
    this.receivingChainKey,
    this.isDeviceA = false,
  }) : _sendKey = sendKey,
       _receiveKey = receiveKey,
       ns = sendSequence,
       nr = receiveSequence,
       pn = 0;

  /// Getters to maintain perfect backward compatibility
  SecretKey get sendKey => sendingChainKey ?? _sendKey ?? SecretKey([]);
  SecretKey get receiveKey => receivingChainKey ?? _receiveKey ?? SecretKey([]);
  int get sendSequence => ns;
  int get receiveSequence => nr;
  int nextSendSequence() => ns;

  final Map<String, SecretKey> sentMessageKeys = {};

  SecretKey getSendKeyForMessage(String messageId) {
    return sentMessageKeys[messageId] ?? sendKey;
  }

  Future<Uint8List> getLocalDhPublicKeyBytes() async {
    if (localDhKeyPair == null) return Uint8List(0);
    final pubKey = await localDhKeyPair!.extractPublicKey();
    return Uint8List.fromList(pubKey.bytes);
  }

  final Set<int> _receivedSequences = {};

  bool isValidInboundSequence(int seq, String targetSessionId) {
    if (targetSessionId != sessionId) return false;
    if (_receivedSequences.contains(seq)) return false;
    final lowerBound = nr - 64;
    if (seq <= lowerBound) return false;
    return true;
  }

  void updateReceiveSequence(int seq) {
    _receivedSequences.add(seq);
    if (seq > nr) {
      nr = seq;
    }
    final lowerBound = nr - 64;
    _receivedSequences.removeWhere((s) => s <= lowerBound);
  }

  /// Helper to get remote public key as a hex string for cache indexing
  String getRemotePublicKeyHex() {
    if (remoteDhPublicKey == null) return 'none';
    return remoteDhPublicKey!.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Clean up expired skipped keys (older than 1 hour) or when capacity exceeds 100
  void evictExpiredSkippedKeys() {
    final now = DateTime.now();
    skippedMessageKeysTimestamps.removeWhere((key, timestamp) {
      if (now.difference(timestamp).inHours >= 1) {
        skippedMessageKeys.remove(key);
        return true;
      }
      return false;
    });

    // Bounded capacity: if still > 100, remove the oldest keys
    if (skippedMessageKeys.length > 100) {
      final sortedKeys = skippedMessageKeysTimestamps.keys.toList()
        ..sort((a, b) => skippedMessageKeysTimestamps[a]!.compareTo(skippedMessageKeysTimestamps[b]!));
      while (skippedMessageKeys.length > 100 && sortedKeys.isNotEmpty) {
        final oldestKey = sortedKeys.removeAt(0);
        skippedMessageKeys.remove(oldestKey);
        skippedMessageKeysTimestamps.remove(oldestKey);
      }
    }
  }

  /// Adds a skipped key to the cache with bounded safety check
  void addSkippedKey(String key, SecretKey secretKey) {
    evictExpiredSkippedKeys();
    if (skippedMessageKeys.length >= 100) {
      // Evict oldest first to make room
      final sortedKeys = skippedMessageKeysTimestamps.keys.toList()
        ..sort((a, b) => skippedMessageKeysTimestamps[a]!.compareTo(skippedMessageKeysTimestamps[b]!));
      if (sortedKeys.isNotEmpty) {
        final oldestKey = sortedKeys.first;
        skippedMessageKeys.remove(oldestKey);
        skippedMessageKeysTimestamps.remove(oldestKey);
      }
    }
    skippedMessageKeys[key] = secretKey;
    skippedMessageKeysTimestamps[key] = DateTime.now();
  }
}
