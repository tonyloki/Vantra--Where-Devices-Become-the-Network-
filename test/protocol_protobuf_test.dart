import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:vantra/core/protocol/protocol_exception.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';

void main() {
  const codec = ProtobufCodec();

  group('ProtobufCodec Wire Envelope Tests', () {
    test('Handshake payload round-trip preserves all fields exactly', () {
      final peerId = const Uuid().v4();
      final idKey = Uint8List.fromList(List.generate(32, (i) => i));
      final ephKey = Uint8List.fromList(List.generate(32, (i) => i + 32));
      final signature = Uint8List.fromList(List.generate(64, (i) => (i * 3) % 256));

      final original = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: peerId,
        displayName: 'AliceDevice',
        identityPublicKey: idKey,
        ephemeralPublicKey: ephKey,
        signature: signature,
      );

      final encoded = codec.encodeWireEnvelope(original);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = codec.decodeWireEnvelope(encoded);
      expect(decoded, isA<DomainHandshakePayload>());

      final handshake = decoded as DomainHandshakePayload;
      expect(handshake.protocolVersion, kCurrentProtocolVersion);
      expect(handshake.peerId, peerId);
      expect(handshake.displayName, 'AliceDevice');
      expect(handshake.identityPublicKey, idKey);
      expect(handshake.ephemeralPublicKey, ephKey);
      expect(handshake.signature, signature);
    });

    test('Encrypted envelope round-trip preserves all fields exactly', () {
      final messageId = const Uuid().v4();
      final sessionId = const Uuid().v4();
      final nonce = Uint8List.fromList(List.generate(12, (i) => i));
      final ciphertext = Uint8List.fromList(List.generate(48, (i) => (i * 7) % 256));
      final mac = Uint8List.fromList(List.generate(16, (i) => (i + 10) % 256));

      final original = DomainEncryptedEnvelope(
        protocolVersion: kCurrentProtocolVersion,
        messageId: messageId,
        sessionId: sessionId,
        sequence: 42,
        nonce: nonce,
        ciphertext: ciphertext,
        mac: mac,
      );

      final encoded = codec.encodeWireEnvelope(original);
      final decoded = codec.decodeWireEnvelope(encoded);

      expect(decoded, isA<DomainEncryptedEnvelope>());
      final enc = decoded as DomainEncryptedEnvelope;
      expect(enc.protocolVersion, kCurrentProtocolVersion);
      expect(enc.messageId, messageId);
      expect(enc.sessionId, sessionId);
      expect(enc.sequence, 42);
      expect(enc.nonce, nonce);
      expect(enc.ciphertext, ciphertext);
      expect(enc.mac, mac);
    });

    test('Rejects unsupported protocol versions (v0 and v999)', () {
      final idKey = Uint8List(32);
      final ephKey = Uint8List(32);
      final sig = Uint8List(64);

      final v0Payload = DomainHandshakePayload(
        protocolVersion: 0,
        peerId: 'peer-1',
        displayName: 'Test',
        identityPublicKey: idKey,
        ephemeralPublicKey: ephKey,
        signature: sig,
      );

      final encodedV0 = codec.encodeWireEnvelope(v0Payload);
      expect(() => codec.decodeWireEnvelope(encodedV0), throwsA(isA<ProtocolValidationException>()));

      final v999Payload = DomainHandshakePayload(
        protocolVersion: 999,
        peerId: 'peer-1',
        displayName: 'Test',
        identityPublicKey: idKey,
        ephemeralPublicKey: ephKey,
        signature: sig,
      );

      final encodedV999 = codec.encodeWireEnvelope(v999Payload);
      expect(() => codec.decodeWireEnvelope(encodedV999), throwsA(isA<ProtocolValidationException>()));
    });

    test('Rejects invalid key and signature lengths in handshake', () {
      final invalidKeyPayload = DomainHandshakePayload(
        protocolVersion: 1,
        peerId: 'peer-1',
        displayName: 'Test',
        identityPublicKey: Uint8List(16), // Invalid length (should be 32)
        ephemeralPublicKey: Uint8List(32),
        signature: Uint8List(64),
      );

      final encoded = codec.encodeWireEnvelope(invalidKeyPayload);
      expect(() => codec.decodeWireEnvelope(encoded), throwsA(isA<ProtocolValidationException>()));
    });

    test('Rejects empty or corrupted wire payloads safely', () {
      expect(() => codec.decodeWireEnvelope(Uint8List(0)), throwsA(isA<ProtocolValidationException>()));
      expect(() => codec.decodeWireEnvelope(Uint8List.fromList([0xFF, 0xFF, 0xFF])), throwsA(isA<ProtocolValidationException>()));
    });
  });

  group('ProtobufCodec Plaintext Payload Tests', () {
    test('Text plaintext payload round-trip preserves all fields', () {
      final messageId = const Uuid().v4();
      final sessionId = const Uuid().v4();
      final senderId = const Uuid().v4();
      final receiverId = const Uuid().v4();

      final original = DomainTextMessage(
        messageId: messageId,
        sessionId: sessionId,
        sequence: 1,
        timestampMs: 1786280000000,
        senderId: senderId,
        receiverId: receiverId,
        content: 'Hello Protobuf Wire Protocol!',
      );

      final encoded = codec.encodePlaintext(original);
      final decoded = codec.decodePlaintext(encoded);

      expect(decoded, isA<DomainTextMessage>());
      final text = decoded as DomainTextMessage;
      expect(text.messageId, messageId);
      expect(text.sessionId, sessionId);
      expect(text.sequence, 1);
      expect(text.timestampMs, 1786280000000);
      expect(text.senderId, senderId);
      expect(text.receiverId, receiverId);
      expect(text.content, 'Hello Protobuf Wire Protocol!');
    });

    test('ACK plaintext payload round-trip preserves all fields', () {
      final ackPacketId = const Uuid().v4();
      final originalMessageId = const Uuid().v4();
      final sessionId = const Uuid().v4();

      final original = DomainAckMessage(
        messageId: ackPacketId,
        sessionId: sessionId,
        sequence: 2,
        timestampMs: 1786280001000,
        senderId: 'receiver-peer',
        receiverId: 'sender-peer',
        originalMessageId: originalMessageId,
        status: DomainDeliveryStatus.delivered,
      );

      final encoded = codec.encodePlaintext(original);
      final decoded = codec.decodePlaintext(encoded);

      expect(decoded, isA<DomainAckMessage>());
      final ack = decoded as DomainAckMessage;
      expect(ack.messageId, ackPacketId);
      expect(ack.originalMessageId, originalMessageId);
      expect(ack.status, DomainDeliveryStatus.delivered);
      expect(ack.sequence, 2);
    });

    test('Rejects invalid plaintext sequences (<= 0)', () {
      final invalid = DomainTextMessage(
        messageId: 'msg-1',
        sessionId: 'ses-1',
        sequence: 0, // Invalid
        timestampMs: 100,
        senderId: 's',
        receiverId: 'r',
        content: 'hello',
      );

      final encoded = codec.encodePlaintext(invalid);
      expect(() => codec.decodePlaintext(encoded), throwsA(isA<ProtocolValidationException>()));
    });
  });
}
