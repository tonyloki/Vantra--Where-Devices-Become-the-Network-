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

enum DomainMediaControlType {
  unspecified,
  offer,
  accept,
  reject,
  cancel,
}

class DomainMediaControl extends DomainPlaintext {
  final DomainMediaControlType type;
  final String transferId;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final int? totalChunks;
  final int? chunkSize;
  final int? width;
  final int? height;
  final String? caption;
  final int? nextExpectedChunk;
  final String? sha256;

  const DomainMediaControl({
    required super.messageId,
    required super.sessionId,
    required super.sequence,
    required super.timestampMs,
    required super.senderId,
    required super.receiverId,
    required this.type,
    required this.transferId,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.totalChunks,
    this.chunkSize,
    this.width,
    this.height,
    this.caption,
    this.nextExpectedChunk,
    this.sha256,
  });
}

class DomainMediaChunk extends DomainPlaintext {
  final String transferId;
  final int chunkIndex;
  final int totalChunks;
  final Uint8List data;

  const DomainMediaChunk({
    required super.messageId,
    required super.sessionId,
    required super.sequence,
    required super.timestampMs,
    required super.senderId,
    required super.receiverId,
    required this.transferId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.data,
  });
}

/// Route envelope wire payload (Phase 16).
class DomainRouteEnvelope extends DomainWireEnvelope {
  final String packetId;
  final String sourcePeerId;
  final String destinationPeerId;
  final int hopCount;
  final int maxHops;
  final Uint8List encryptedPayload;

  const DomainRouteEnvelope({
    required super.protocolVersion,
    required this.packetId,
    required this.sourcePeerId,
    required this.destinationPeerId,
    required this.hopCount,
    required this.maxHops,
    required this.encryptedPayload,
  });
}

/// Route discovery request payload (Phase 16).
class DomainRouteRequest extends DomainWireEnvelope {
  final String requestId;
  final String sourcePeerId;
  final String destinationPeerId;
  final int hopCount;
  final int maxHops;

  const DomainRouteRequest({
    required super.protocolVersion,
    required this.requestId,
    required this.sourcePeerId,
    required this.destinationPeerId,
    required this.hopCount,
    required this.maxHops,
  });
}

/// Route discovery reply payload (Phase 16).
class DomainRouteReply extends DomainWireEnvelope {
  final String requestId;
  final String sourcePeerId;
  final String destinationPeerId;
  final int hopCount;
  final int maxHops;
  final Uint8List signature;

  const DomainRouteReply({
    required super.protocolVersion,
    required this.requestId,
    required this.sourcePeerId,
    required this.destinationPeerId,
    required this.hopCount,
    required this.maxHops,
    required this.signature,
  });
}

/// Route error control message (Phase 17).
class DomainRouteError extends DomainWireEnvelope {
  final String errorId;
  final String brokenPeerId;
  final String reporterId;
  final int hopCount;
  final int maxHops;

  const DomainRouteError({
    required super.protocolVersion,
    required this.errorId,
    required this.brokenPeerId,
    required this.reporterId,
    required this.hopCount,
    required this.maxHops,
  });
}


