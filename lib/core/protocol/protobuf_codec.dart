import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:vantra/generated/vantra_message.pb.dart';
import 'protocol_codec.dart';
import 'protocol_exception.dart';
import 'protocol_message.dart';
import 'protocol_version.dart';

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

      case VantraPlaintext_Body.notSet:
        throw const ProtocolValidationException('Missing required body in VantraPlaintext');
    }
  }
}
