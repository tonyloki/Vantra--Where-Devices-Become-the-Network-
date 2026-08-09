import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:vantra/core/security/crypto_service.dart';

void main() {
  late CryptoService cryptoService;
  const codec = ProtobufCodec();

  setUp(() {
    cryptoService = CryptoService();
  });

  group('Encrypted Protobuf Pipeline Tests', () {
    test('End-to-end encrypted protobuf text message round-trip', () async {
      // 1. Establish ephemeral keypairs
      final keyPairA = await cryptoService.generateEphemeralKeyPair();
      final keyPairB = await cryptoService.generateEphemeralKeyPair();
      final pubKeyA = await keyPairA.extractPublicKey();
      final pubKeyB = await keyPairB.extractPublicKey();

      final keysA = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: keyPairA,
        remoteEphemeralPublicKeyBytes: pubKeyB.bytes,
      );
      final keysB = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: keyPairB,
        remoteEphemeralPublicKeyBytes: pubKeyA.bytes,
      );

      final messageId = const Uuid().v4();
      final senderId = const Uuid().v4();
      final receiverId = const Uuid().v4();

      // 2. Sender A encodes DomainTextMessage to Protobuf binary
      final domainText = DomainTextMessage(
        messageId: messageId,
        sessionId: keysA.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: senderId,
        receiverId: receiverId,
        content: 'Secure Protobuf Payload Over Mesh',
      );

      final plaintextBytes = codec.encodePlaintext(domainText);

      // 3. Sender A encrypts with ChaCha20-Poly1305 and AAD = UTF8(messageId)
      final encResult = await cryptoService.encryptBytes(
        secretKey: keysA.sendKey,
        sessionSalt: keysA.sessionSalt,
        sequence: 1,
        messageId: messageId,
        plaintextBytes: plaintextBytes,
      );

      final wireEnvelope = DomainEncryptedEnvelope(
        protocolVersion: kCurrentProtocolVersion,
        messageId: messageId,
        sessionId: keysA.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encResult.nonce),
        ciphertext: Uint8List.fromList(encResult.ciphertext),
        mac: Uint8List.fromList(encResult.mac),
      );

      final wireBytes = codec.encodeWireEnvelope(wireEnvelope);

      // 4. Receiver B decodes wire envelope
      final decodedEnvelope = codec.decodeWireEnvelope(wireBytes);
      expect(decodedEnvelope, isA<DomainEncryptedEnvelope>());
      final encInbound = decodedEnvelope as DomainEncryptedEnvelope;

      // 5. Receiver B decrypts ciphertext
      final decryptedPlaintextBytes = await cryptoService.decryptBytes(
        secretKey: keysB.receiveKey,
        nonce: encInbound.nonce,
        ciphertext: encInbound.ciphertext,
        mac: encInbound.mac,
        messageId: encInbound.messageId,
      );

      // 6. Receiver B decodes authenticated Protobuf plaintext
      final decryptedPlaintext = codec.decodePlaintext(decryptedPlaintextBytes);
      expect(decryptedPlaintext, isA<DomainTextMessage>());
      final receivedText = decryptedPlaintext as DomainTextMessage;

      expect(receivedText.messageId, messageId);
      expect(receivedText.content, 'Secure Protobuf Payload Over Mesh');
      expect(receivedText.senderId, senderId);
      expect(receivedText.receiverId, receiverId);
      expect(receivedText.sequence, 1);
    });

    test('ACK Invariant: ackPacketId != originalMessageId, outer/inner IDs match, and AAD is ackPacketId', () async {
      final keyPairA = await cryptoService.generateEphemeralKeyPair();
      final keyPairB = await cryptoService.generateEphemeralKeyPair();
      final pubKeyA = await keyPairA.extractPublicKey();
      final pubKeyB = await keyPairB.extractPublicKey();

      final keysA = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: keyPairA,
        remoteEphemeralPublicKeyBytes: pubKeyB.bytes,
      );
      final keysB = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: keyPairB,
        remoteEphemeralPublicKeyBytes: pubKeyA.bytes,
      );

      final originalTextId = const Uuid().v4();
      final ackPacketId = const Uuid().v4();

      // INVARIANT 1: ackPacketId != originalMessageId
      expect(ackPacketId, isNot(equals(originalTextId)));

      // Construct ACK plaintext
      final ackPlaintext = DomainAckMessage(
        messageId: ackPacketId,
        sessionId: keysB.sessionId,
        sequence: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        senderId: 'receiver-b',
        receiverId: 'sender-a',
        originalMessageId: originalTextId,
        status: DomainDeliveryStatus.delivered,
      );

      final ackPlaintextBytes = codec.encodePlaintext(ackPlaintext);

      // INVARIANT 2: AAD must use the ACK packet's own messageId (ackPacketId)
      final encAck = await cryptoService.encryptBytes(
        secretKey: keysB.sendKey,
        sessionSalt: keysB.sessionSalt,
        sequence: 1,
        messageId: ackPacketId,
        plaintextBytes: ackPlaintextBytes,
      );

      // INVARIANT 3: Outer EncryptedEnvelope.messageId == ackPacketId
      final ackWireEnvelope = DomainEncryptedEnvelope(
        protocolVersion: kCurrentProtocolVersion,
        messageId: ackPacketId,
        sessionId: keysB.sessionId,
        sequence: 1,
        nonce: Uint8List.fromList(encAck.nonce),
        ciphertext: Uint8List.fromList(encAck.ciphertext),
        mac: Uint8List.fromList(encAck.mac),
      );

      final ackWireBytes = codec.encodeWireEnvelope(ackWireEnvelope);

      // Receiver A decodes and decrypts
      final decodedAckEnvelope = codec.decodeWireEnvelope(ackWireBytes) as DomainEncryptedEnvelope;
      expect(decodedAckEnvelope.messageId, ackPacketId);

      // Verify decrypt succeeds with AAD = ackPacketId
      final decryptedAckBytes = await cryptoService.decryptBytes(
        secretKey: keysA.receiveKey,
        nonce: decodedAckEnvelope.nonce,
        ciphertext: decodedAckEnvelope.ciphertext,
        mac: decodedAckEnvelope.mac,
        messageId: decodedAckEnvelope.messageId,
      );

      final decodedAck = codec.decodePlaintext(decryptedAckBytes) as DomainAckMessage;
      expect(decodedAck.messageId, ackPacketId);
      expect(decodedAck.originalMessageId, originalTextId);
      expect(decodedAck.status, DomainDeliveryStatus.delivered);
    });
  });
}
