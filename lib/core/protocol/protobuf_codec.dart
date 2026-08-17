import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:vantra/generated/vantra_message.pb.dart';
import 'protocol_codec.dart';
import 'protocol_exception.dart';
import 'protocol_message.dart';
import 'protocol_version.dart';

Capability _mapToProtoCapability(VantraCapability cap) {
  switch (cap) {
    case VantraCapability.text:
      return Capability.CAPABILITY_TEXT;
    case VantraCapability.image:
      return Capability.CAPABILITY_IMAGE;
    case VantraCapability.audio:
      return Capability.CAPABILITY_AUDIO;
    case VantraCapability.video:
      return Capability.CAPABILITY_VIDEO;
    case VantraCapability.file:
      return Capability.CAPABILITY_FILE;
    case VantraCapability.group:
      return Capability.CAPABILITY_GROUP;
  }
}

VantraCapability? _mapToDomainCapability(Capability cap) {
  switch (cap) {
    case Capability.CAPABILITY_TEXT:
      return VantraCapability.text;
    case Capability.CAPABILITY_IMAGE:
      return VantraCapability.image;
    case Capability.CAPABILITY_AUDIO:
      return VantraCapability.audio;
    case Capability.CAPABILITY_VIDEO:
      return VantraCapability.video;
    case Capability.CAPABILITY_FILE:
      return VantraCapability.file;
    case Capability.CAPABILITY_GROUP:
      return VantraCapability.group;
    default:
      return null;
  }
}

MediaControl_Type _mapToProtoMediaControlType(DomainMediaControlType type) {
  switch (type) {
    case DomainMediaControlType.unspecified:
      return MediaControl_Type.TYPE_UNSPECIFIED;
    case DomainMediaControlType.offer:
      return MediaControl_Type.OFFER;
    case DomainMediaControlType.accept:
      return MediaControl_Type.ACCEPT;
    case DomainMediaControlType.reject:
      return MediaControl_Type.REJECT;
    case DomainMediaControlType.cancel:
      return MediaControl_Type.CANCEL;
  }
}

DomainMediaControlType _mapToDomainMediaControlType(MediaControl_Type type) {
  switch (type) {
    case MediaControl_Type.TYPE_UNSPECIFIED:
      return DomainMediaControlType.unspecified;
    case MediaControl_Type.OFFER:
      return DomainMediaControlType.offer;
    case MediaControl_Type.ACCEPT:
      return DomainMediaControlType.accept;
    case MediaControl_Type.REJECT:
      return DomainMediaControlType.reject;
    case MediaControl_Type.CANCEL:
      return DomainMediaControlType.cancel;
    default:
      return DomainMediaControlType.unspecified;
  }
}

class ProtobufCodec implements ProtocolCodec {
  const ProtobufCodec();

  @override
  Uint8List encodeWireEnvelope(DomainWireEnvelope envelope) {
    final pbEnvelope = VantraWireEnvelope(
      protocolVersion: envelope.protocolVersion,
    );

    switch (envelope) {
      case DomainHandshakePayload handshake:
        pbEnvelope.handshake = IdentitySecurePayload(
          peerId: handshake.peerId,
          displayName: handshake.displayName,
          identityPublicKey: handshake.identityPublicKey,
          ephemeralPublicKey: handshake.ephemeralPublicKey,
          signature: handshake.signature,
          minSupportedVersion: handshake.minSupportedVersion ?? 0,
          maxSupportedVersion: handshake.maxSupportedVersion ?? 0,
          supportedCapabilities: handshake.supportedCapabilities
              ?.map(_mapToProtoCapability)
              .toList(),
        );
      case DomainEncryptedEnvelope encrypted:
        pbEnvelope.encryptedMessage = EncryptedEnvelope(
          messageId: encrypted.messageId,
          sessionId: encrypted.sessionId,
          sequence: Int64(encrypted.sequence),
          nonce: encrypted.nonce,
          ciphertext: encrypted.ciphertext,
          mac: encrypted.mac,
        );
      case DomainProtocolError error:
        pbEnvelope.error = ProtocolErrorPayload(
          errorCode: error.errorCode,
          errorMessage: error.errorMessage,
          relatedMessageId: error.relatedMessageId,
        );
      case DomainRouteEnvelope routed:
        pbEnvelope.routedMessage = RouteEnvelope(
          packetId: routed.packetId,
          sourcePeerId: routed.sourcePeerId,
          destinationPeerId: routed.destinationPeerId,
          hopCount: routed.hopCount,
          maxHops: routed.maxHops,
          encryptedPayload: routed.encryptedPayload,
        );
      case DomainRouteRequest rreq:
        pbEnvelope.routeRequest = RouteRequest(
          requestId: rreq.requestId,
          sourcePeerId: rreq.sourcePeerId,
          destinationPeerId: rreq.destinationPeerId,
          hopCount: rreq.hopCount,
          maxHops: rreq.maxHops,
        );
      case DomainRouteReply rrep:
        pbEnvelope.routeReply = RouteReply(
          requestId: rrep.requestId,
          sourcePeerId: rrep.sourcePeerId,
          destinationPeerId: rrep.destinationPeerId,
          hopCount: rrep.hopCount,
          maxHops: rrep.maxHops,
          signature: rrep.signature,
        );
    }

    return pbEnvelope.writeToBuffer();
  }


  @override
  DomainWireEnvelope decodeWireEnvelope(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const ProtocolValidationException('Empty wire payload received');
    }

    VantraWireEnvelope pbEnvelope;
    try {
      pbEnvelope = VantraWireEnvelope.fromBuffer(bytes);
    } catch (e) {
      throw ProtocolValidationException('Malformed Protobuf wire envelope: $e');
    }

    // 1. Version validation
    if (pbEnvelope.protocolVersion < kMinSupportedProtocolVersion ||
        pbEnvelope.protocolVersion > kCurrentProtocolVersion) {
      throw ProtocolValidationException(
        'Unsupported protocol version: ${pbEnvelope.protocolVersion}',
        errorCode: 1001,
      );
    }

    // 2. Payload variant validation
    switch (pbEnvelope.whichPayload()) {
      case VantraWireEnvelope_Payload.handshake:
        final h = pbEnvelope.handshake;
        if (h.peerId.trim().isEmpty) {
          throw const ProtocolValidationException('Handshake peerId cannot be empty');
        }
        if (h.displayName.trim().isEmpty) {
          throw const ProtocolValidationException('Handshake displayName cannot be empty');
        }
        if (h.identityPublicKey.length != 32) {
          throw ProtocolValidationException('Invalid identityPublicKey length: ${h.identityPublicKey.length} (expected 32)');
        }
        if (h.ephemeralPublicKey.length != 32) {
          throw ProtocolValidationException('Invalid ephemeralPublicKey length: ${h.ephemeralPublicKey.length} (expected 32)');
        }
        if (h.signature.length != 64) {
          throw ProtocolValidationException('Invalid signature length: ${h.signature.length} (expected 64)');
        }

        return DomainHandshakePayload(
          protocolVersion: pbEnvelope.protocolVersion,
          peerId: h.peerId,
          displayName: h.displayName,
          identityPublicKey: Uint8List.fromList(h.identityPublicKey),
          ephemeralPublicKey: Uint8List.fromList(h.ephemeralPublicKey),
          signature: Uint8List.fromList(h.signature),
          minSupportedVersion: h.minSupportedVersion != 0 ? h.minSupportedVersion : null,
          maxSupportedVersion: h.maxSupportedVersion != 0 ? h.maxSupportedVersion : null,
          supportedCapabilities: h.supportedCapabilities.isNotEmpty
              ? h.supportedCapabilities
                  .map(_mapToDomainCapability)
                  .whereType<VantraCapability>()
                  .toList()
              : null,
        );

      case VantraWireEnvelope_Payload.encryptedMessage:
        final enc = pbEnvelope.encryptedMessage;
        if (enc.messageId.trim().isEmpty) {
          throw const ProtocolValidationException('EncryptedEnvelope messageId cannot be empty');
        }
        if (enc.sessionId.trim().isEmpty) {
          throw const ProtocolValidationException('EncryptedEnvelope sessionId cannot be empty');
        }
        final seqInt = enc.sequence.toInt();
        if (seqInt <= 0) {
          throw ProtocolValidationException('Invalid EncryptedEnvelope sequence: $seqInt (must be > 0)');
        }
        if (enc.nonce.length != 12) {
          throw ProtocolValidationException('Invalid nonce length: ${enc.nonce.length} (expected 12)');
        }
        if (enc.mac.length != 16) {
          throw ProtocolValidationException('Invalid MAC length: ${enc.mac.length} (expected 16)');
        }
        if (enc.ciphertext.isEmpty) {
          throw const ProtocolValidationException('EncryptedEnvelope ciphertext cannot be empty');
        }

        return DomainEncryptedEnvelope(
          protocolVersion: pbEnvelope.protocolVersion,
          messageId: enc.messageId,
          sessionId: enc.sessionId,
          sequence: seqInt,
          nonce: Uint8List.fromList(enc.nonce),
          ciphertext: Uint8List.fromList(enc.ciphertext),
          mac: Uint8List.fromList(enc.mac),
        );

      case VantraWireEnvelope_Payload.error:
        final err = pbEnvelope.error;
        return DomainProtocolError(
          protocolVersion: pbEnvelope.protocolVersion,
          errorCode: err.errorCode,
          errorMessage: err.errorMessage,
          relatedMessageId: err.relatedMessageId,
        );

      case VantraWireEnvelope_Payload.routedMessage:
        final r = pbEnvelope.routedMessage;
        if (r.packetId.trim().isEmpty) {
          throw const ProtocolValidationException('RouteEnvelope packetId cannot be empty');
        }
        if (r.sourcePeerId.trim().isEmpty) {
          throw const ProtocolValidationException('RouteEnvelope sourcePeerId cannot be empty');
        }
        if (r.destinationPeerId.trim().isEmpty) {
          throw const ProtocolValidationException('RouteEnvelope destinationPeerId cannot be empty');
        }
        if (r.encryptedPayload.isEmpty) {
          throw const ProtocolValidationException('RouteEnvelope encryptedPayload cannot be empty');
        }
        return DomainRouteEnvelope(
          protocolVersion: pbEnvelope.protocolVersion,
          packetId: r.packetId,
          sourcePeerId: r.sourcePeerId,
          destinationPeerId: r.destinationPeerId,
          hopCount: r.hopCount,
          maxHops: r.maxHops,
          encryptedPayload: Uint8List.fromList(r.encryptedPayload),
        );

      case VantraWireEnvelope_Payload.routeRequest:
        final req = pbEnvelope.routeRequest;
        if (req.requestId.trim().isEmpty) {
          throw const ProtocolValidationException('RouteRequest requestId cannot be empty');
        }
        if (req.sourcePeerId.trim().isEmpty) {
          throw const ProtocolValidationException('RouteRequest sourcePeerId cannot be empty');
        }
        if (req.destinationPeerId.trim().isEmpty) {
          throw const ProtocolValidationException('RouteRequest destinationPeerId cannot be empty');
        }
        return DomainRouteRequest(
          protocolVersion: pbEnvelope.protocolVersion,
          requestId: req.requestId,
          sourcePeerId: req.sourcePeerId,
          destinationPeerId: req.destinationPeerId,
          hopCount: req.hopCount,
          maxHops: req.maxHops,
        );

      case VantraWireEnvelope_Payload.routeReply:
        final rep = pbEnvelope.routeReply;
        if (rep.requestId.trim().isEmpty) {
          throw const ProtocolValidationException('RouteReply requestId cannot be empty');
        }
        if (rep.sourcePeerId.trim().isEmpty) {
          throw const ProtocolValidationException('RouteReply sourcePeerId cannot be empty');
        }
        if (rep.destinationPeerId.trim().isEmpty) {
          throw const ProtocolValidationException('RouteReply destinationPeerId cannot be empty');
        }
        if (rep.signature.length != 64) {
          throw ProtocolValidationException('Invalid RouteReply signature length: ${rep.signature.length} (expected 64)');
        }
        return DomainRouteReply(
          protocolVersion: pbEnvelope.protocolVersion,
          requestId: rep.requestId,
          sourcePeerId: rep.sourcePeerId,
          destinationPeerId: rep.destinationPeerId,
          hopCount: rep.hopCount,
          maxHops: rep.maxHops,
          signature: Uint8List.fromList(rep.signature),
        );

      case VantraWireEnvelope_Payload.notSet:
        throw const ProtocolValidationException('Missing required payload in VantraWireEnvelope');
    }
  }

  @override
  Uint8List encodePlaintext(DomainPlaintext plaintext) {
    final pbPlaintext = VantraPlaintext(
      messageId: plaintext.messageId,
      sessionId: plaintext.sessionId,
      sequence: Int64(plaintext.sequence),
      timestampMs: Int64(plaintext.timestampMs),
      senderId: plaintext.senderId,
      receiverId: plaintext.receiverId,
    );

    switch (plaintext) {
      case DomainTextMessage textMsg:
        pbPlaintext.text = TextBody(content: textMsg.content);
      case DomainAckMessage ackMsg:
        pbPlaintext.ack = AckBody(
          originalMessageId: ackMsg.originalMessageId,
          status: ackMsg.status == DomainDeliveryStatus.delivered
              ? DeliveryStatus.DELIVERY_DELIVERED
              : DeliveryStatus.DELIVERY_UNSPECIFIED,
        );
      case DomainCapabilitiesExchange capMsg:
        pbPlaintext.capabilitiesExchange = CapabilitiesExchange(
          minSupportedVersion: capMsg.minSupportedVersion,
          maxSupportedVersion: capMsg.maxSupportedVersion,
          supportedCapabilities: capMsg.supportedCapabilities
              .map(_mapToProtoCapability)
              .toList(),
        );
      case DomainMediaControl mediaCtrl:
        pbPlaintext.mediaControl = MediaControl(
          type: _mapToProtoMediaControlType(mediaCtrl.type),
          transferId: mediaCtrl.transferId,
          fileName: mediaCtrl.fileName ?? '',
          fileSize: Int64(mediaCtrl.fileSize ?? 0),
          mimeType: mediaCtrl.mimeType ?? '',
          totalChunks: mediaCtrl.totalChunks ?? 0,
          chunkSize: mediaCtrl.chunkSize ?? 0,
          width: mediaCtrl.width ?? 0,
          height: mediaCtrl.height ?? 0,
          caption: mediaCtrl.caption ?? '',
          nextExpectedChunk: mediaCtrl.nextExpectedChunk ?? 0,
          sha256: mediaCtrl.sha256 ?? '',
        );
      case DomainMediaChunk mediaChunk:
        pbPlaintext.mediaChunk = MediaChunk(
          transferId: mediaChunk.transferId,
          chunkIndex: mediaChunk.chunkIndex,
          totalChunks: mediaChunk.totalChunks,
          data: mediaChunk.data,
        );
    }

    return pbPlaintext.writeToBuffer();
  }

  @override
  DomainPlaintext decodePlaintext(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const ProtocolValidationException('Empty plaintext payload received');
    }

    VantraPlaintext pbPlaintext;
    try {
      pbPlaintext = VantraPlaintext.fromBuffer(bytes);
    } catch (e) {
      throw ProtocolValidationException('Malformed Protobuf plaintext payload: $e');
    }

    if (pbPlaintext.messageId.trim().isEmpty) {
      throw const ProtocolValidationException('Plaintext messageId cannot be empty');
    }
    if (pbPlaintext.sessionId.trim().isEmpty) {
      throw const ProtocolValidationException('Plaintext sessionId cannot be empty');
    }
    final seqInt = pbPlaintext.sequence.toInt();
    if (seqInt <= 0) {
      throw ProtocolValidationException('Invalid Plaintext sequence: $seqInt (must be > 0)');
    }
    if (pbPlaintext.senderId.trim().isEmpty) {
      throw const ProtocolValidationException('Plaintext senderId cannot be empty');
    }
    if (pbPlaintext.receiverId.trim().isEmpty) {
      throw const ProtocolValidationException('Plaintext receiverId cannot be empty');
    }

    switch (pbPlaintext.whichBody()) {
      case VantraPlaintext_Body.text:
        return DomainTextMessage(
          messageId: pbPlaintext.messageId,
          sessionId: pbPlaintext.sessionId,
          sequence: seqInt,
          timestampMs: pbPlaintext.timestampMs.toInt(),
          senderId: pbPlaintext.senderId,
          receiverId: pbPlaintext.receiverId,
          content: pbPlaintext.text.content,
        );

      case VantraPlaintext_Body.ack:
        final ack = pbPlaintext.ack;
        if (ack.originalMessageId.trim().isEmpty) {
          throw const ProtocolValidationException('AckBody originalMessageId cannot be empty');
        }
        return DomainAckMessage(
          messageId: pbPlaintext.messageId,
          sessionId: pbPlaintext.sessionId,
          sequence: seqInt,
          timestampMs: pbPlaintext.timestampMs.toInt(),
          senderId: pbPlaintext.senderId,
          receiverId: pbPlaintext.receiverId,
          originalMessageId: ack.originalMessageId,
          status: ack.status == DeliveryStatus.DELIVERY_DELIVERED
              ? DomainDeliveryStatus.delivered
              : DomainDeliveryStatus.unspecified,
        );

      case VantraPlaintext_Body.capabilitiesExchange:
        final cap = pbPlaintext.capabilitiesExchange;
        return DomainCapabilitiesExchange(
          messageId: pbPlaintext.messageId,
          sessionId: pbPlaintext.sessionId,
          sequence: seqInt,
          timestampMs: pbPlaintext.timestampMs.toInt(),
          senderId: pbPlaintext.senderId,
          receiverId: pbPlaintext.receiverId,
          minSupportedVersion: cap.minSupportedVersion,
          maxSupportedVersion: cap.maxSupportedVersion,
          supportedCapabilities: cap.supportedCapabilities
              .map(_mapToDomainCapability)
              .whereType<VantraCapability>()
              .toList(),
        );

      case VantraPlaintext_Body.mediaControl:
        final ctrl = pbPlaintext.mediaControl;
        return DomainMediaControl(
          messageId: pbPlaintext.messageId,
          sessionId: pbPlaintext.sessionId,
          sequence: seqInt,
          timestampMs: pbPlaintext.timestampMs.toInt(),
          senderId: pbPlaintext.senderId,
          receiverId: pbPlaintext.receiverId,
          type: _mapToDomainMediaControlType(ctrl.type),
          transferId: ctrl.transferId,
          fileName: ctrl.fileName.isNotEmpty ? ctrl.fileName : null,
          fileSize: ctrl.fileSize != Int64.ZERO ? ctrl.fileSize.toInt() : null,
          mimeType: ctrl.mimeType.isNotEmpty ? ctrl.mimeType : null,
          totalChunks: ctrl.totalChunks != 0 ? ctrl.totalChunks : null,
          chunkSize: ctrl.chunkSize != 0 ? ctrl.chunkSize : null,
          width: ctrl.width != 0 ? ctrl.width : null,
          height: ctrl.height != 0 ? ctrl.height : null,
          caption: ctrl.caption.isNotEmpty ? ctrl.caption : null,
          nextExpectedChunk: ctrl.nextExpectedChunk != 0 ? ctrl.nextExpectedChunk : null,
          sha256: ctrl.sha256.isNotEmpty ? ctrl.sha256 : null,
        );

      case VantraPlaintext_Body.mediaChunk:
        final chunk = pbPlaintext.mediaChunk;
        return DomainMediaChunk(
          messageId: pbPlaintext.messageId,
          sessionId: pbPlaintext.sessionId,
          sequence: seqInt,
          timestampMs: pbPlaintext.timestampMs.toInt(),
          senderId: pbPlaintext.senderId,
          receiverId: pbPlaintext.receiverId,
          transferId: chunk.transferId,
          chunkIndex: chunk.chunkIndex,
          totalChunks: chunk.totalChunks,
          data: Uint8List.fromList(chunk.data),
        );

      case VantraPlaintext_Body.notSet:
        throw const ProtocolValidationException('Missing required body in VantraPlaintext');
    }
  }
}
