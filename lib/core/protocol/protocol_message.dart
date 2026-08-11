import 'dart:typed_data';

enum DomainDeliveryStatus {
  unspecified,
  delivered,
}

/// Abstract base class for wire envelopes.
sealed class DomainWireEnvelope {
  final int protocolVersion;

  const DomainWireEnvelope({required this.protocolVersion});
}

/// Handshake wire payload (unencrypted during connection setup).
class DomainHandshakePayload extends DomainWireEnvelope {
  final String peerId;
  final String displayName;
  final Uint8List identityPublicKey;
  final Uint8List ephemeralPublicKey;
  final Uint8List signature;
  final int? minSupportedVersion;
  final int? maxSupportedVersion;
  final List<VantraCapability>? supportedCapabilities;

  const DomainHandshakePayload({
    required super.protocolVersion,
    required this.peerId,
    required this.displayName,
    required this.identityPublicKey,
    required this.ephemeralPublicKey,
    required this.signature,
    this.minSupportedVersion,
    this.maxSupportedVersion,
    this.supportedCapabilities,
  });
}

/// Encrypted envelope wire payload.
class DomainEncryptedEnvelope extends DomainWireEnvelope {
  final String messageId;
  final String sessionId;
  final int sequence;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List mac;

  const DomainEncryptedEnvelope({
    required super.protocolVersion,
    required this.messageId,
    required this.sessionId,
    required this.sequence,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });
}

/// Pre-session outer protocol error payload.
class DomainProtocolError extends DomainWireEnvelope {
  final int errorCode;
  final String errorMessage;
  final String relatedMessageId;

  const DomainProtocolError({
    required super.protocolVersion,
    required this.errorCode,
    required this.errorMessage,
    required this.relatedMessageId,
  });
}

/// Abstract base class for authenticated, decrypted plaintext payloads.
sealed class DomainPlaintext {
  final String messageId;
  final String sessionId;
  final int sequence;
  final int timestampMs;
  final String senderId;
  final String receiverId;

  const DomainPlaintext({
    required this.messageId,
    required this.sessionId,
    required this.sequence,
    required this.timestampMs,
    required this.senderId,
    required this.receiverId,
  });
}

/// Plaintext text message.
class DomainTextMessage extends DomainPlaintext {
  final String content;

  const DomainTextMessage({
    required super.messageId,
    required super.sessionId,
    required super.sequence,
    required super.timestampMs,
    required super.senderId,
    required super.receiverId,
    required this.content,
  });
}

/// Plaintext acknowledgment message.
class DomainAckMessage extends DomainPlaintext {
  final String originalMessageId;
  final DomainDeliveryStatus status;

  const DomainAckMessage({
    required super.messageId,
    required super.sessionId,
    required super.sequence,
    required super.timestampMs,
    required super.senderId,
    required super.receiverId,
    required this.originalMessageId,
    required this.status,
  });
}

enum VantraCapability {
  text,
  image,
  audio,
  video,
  file,
  group,
}

class DomainCapabilitiesExchange extends DomainPlaintext {
  final int minSupportedVersion;
  final int maxSupportedVersion;
  final List<VantraCapability> supportedCapabilities;

  const DomainCapabilitiesExchange({
    required super.messageId,
    required super.sessionId,
    required super.sequence,
    required super.timestampMs,
    required super.senderId,
    required super.receiverId,
    required this.minSupportedVersion,
    required this.maxSupportedVersion,
    required this.supportedCapabilities,
  });
}
