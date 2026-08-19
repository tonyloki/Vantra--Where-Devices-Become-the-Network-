import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/security/security_session.dart';

void main() {
  late CryptoService cryptoService;

  setUp(() {
    cryptoService = CryptoService();
  });

  group('Double Ratchet State Machine Tests', () {
    test('Initialization & Symmetric Ratchet Step', () async {
      // Generate handshake keypairs
      final keypairA = await cryptoService.generateEphemeralKeyPair();
      final keypairB = await cryptoService.generateEphemeralKeyPair();
      final pubB = await keypairB.extractPublicKey();

      final sessionA = SecuritySession(
        peerId: 'alice',
        endpointId: 'ep_alice',
        sessionId: 'session_123',
        sessionSalt: List.filled(16, 1),
        remoteIdentityPublicKey: 'id_pub_b',
        remoteFingerprint: 'fp_b',
      );

      final sessionB = SecuritySession(
        peerId: 'bob',
        endpointId: 'ep_bob',
        sessionId: 'session_123',
        sessionSalt: List.filled(16, 1),
        remoteIdentityPublicKey: 'id_pub_a',
        remoteFingerprint: 'fp_a',
      );

      // Alice (Device A) and Bob (Device B) perform initial setup
      await cryptoService.initializeDoubleRatchet(
        session: sessionA,
        handshakeLocalKeyPair: keypairA,
        handshakeRemotePublicKeyBytes: pubB.bytes,
        isDeviceA: true,
      );

      final pubA = await keypairA.extractPublicKey();
      await cryptoService.initializeDoubleRatchet(
        session: sessionB,
        handshakeLocalKeyPair: keypairB,
        handshakeRemotePublicKeyBytes: pubA.bytes,
        isDeviceA: false,
      );

      // Alice is ready to send: she has a sendingChainKey and localDhKeyPair
      expect(sessionA.sendingChainKey, isNotNull);
      expect(sessionA.localDhKeyPair, isNotNull);
      expect(sessionA.ns, equals(1));

      // Bob is ready to receive: his receivingChainKey is null initially (derived on first message)
      expect(sessionB.receivingChainKey, isNull);
      expect(sessionB.localDhKeyPair, isNotNull);
      expect(sessionB.nr, equals(0));

      // Perform a symmetric ratchet step (Alice encrypts a message)
      final plaintext = Uint8List.fromList([1, 2, 3, 4]);
      final encrypted = await cryptoService.encryptWithDoubleRatchet(
        session: sessionA,
        messageId: 'msg_1',
        plaintextBytes: plaintext,
      );

      expect(sessionA.ns, equals(2));
      expect(encrypted.ciphertext, isNotEmpty);
    });

    test('DH Ratchet & Roundtrip Message Exchange', () async {
      final keypairA = await cryptoService.generateEphemeralKeyPair();
      final keypairB = await cryptoService.generateEphemeralKeyPair();
      final pubA = await keypairA.extractPublicKey();
      final pubB = await keypairB.extractPublicKey();

      final sessionA = SecuritySession(
        peerId: 'alice',
        endpointId: 'ep_alice',
        sessionId: 'session_123',
        sessionSalt: List.filled(16, 1),
        remoteIdentityPublicKey: 'id_pub_b',
        remoteFingerprint: 'fp_b',
      );

      final sessionB = SecuritySession(
        peerId: 'bob',
        endpointId: 'ep_bob',
        sessionId: 'session_123',
        sessionSalt: List.filled(16, 1),
        remoteIdentityPublicKey: 'id_pub_a',
        remoteFingerprint: 'fp_a',
      );

      await cryptoService.initializeDoubleRatchet(
        session: sessionA,
        handshakeLocalKeyPair: keypairA,
        handshakeRemotePublicKeyBytes: pubB.bytes,
        isDeviceA: true,
      );

      await cryptoService.initializeDoubleRatchet(
        session: sessionB,
        handshakeLocalKeyPair: keypairB,
        handshakeRemotePublicKeyBytes: pubA.bytes,
        isDeviceA: false,
      );

      // --- Alice sends Msg 1 to Bob ---
      final plaintext1 = Uint8List.fromList([7, 8, 9]);
      final encrypted1 = await cryptoService.encryptWithDoubleRatchet(
        session: sessionA,
        messageId: 'msg_1',
        plaintextBytes: plaintext1,
      );

      final localDhPubA1 = await sessionA.localDhKeyPair!.extractPublicKey();

      // Bob decrypts Msg 1
      final decrypted1 = await cryptoService.decryptWithDoubleRatchet(
        session: sessionB,
        incomingDhPublicKeyBytes: Uint8List.fromList(localDhPubA1.bytes),
        incomingSequence: 1,
        incomingPreviousChainLength: 0,
        nonce: Uint8List.fromList(encrypted1.nonce),
        ciphertext: Uint8List.fromList(encrypted1.ciphertext),
        mac: Uint8List.fromList(encrypted1.mac),
        messageId: 'msg_1',
      );

      expect(decrypted1, equals(plaintext1));
      expect(sessionB.nr, equals(1));
      // Bob should have derived a new localDhKeyPair and sendingChainKey now
      expect(sessionB.sendingChainKey, isNotNull);

      // --- Bob responds with Msg 2 to Alice ---
      final plaintext2 = Uint8List.fromList([10, 11, 12, 13]);
      final encrypted2 = await cryptoService.encryptWithDoubleRatchet(
        session: sessionB,
        messageId: 'msg_2',
        plaintextBytes: plaintext2,
      );

      final localDhPubB1 = await sessionB.localDhKeyPair!.extractPublicKey();

      // Alice decrypts Msg 2
      final decrypted2 = await cryptoService.decryptWithDoubleRatchet(
        session: sessionA,
        incomingDhPublicKeyBytes: Uint8List.fromList(localDhPubB1.bytes),
        incomingSequence: 1,
        incomingPreviousChainLength: 0,
        nonce: Uint8List.fromList(encrypted2.nonce),
        ciphertext: Uint8List.fromList(encrypted2.ciphertext),
        mac: Uint8List.fromList(encrypted2.mac),
        messageId: 'msg_2',
      );

      expect(decrypted2, equals(plaintext2));
      expect(sessionA.nr, equals(1));
      expect(sessionA.sendingChainKey, isNotNull);
    });

    test('Out-of-order Message Key Caching (Skipped keys)', () async {
      final keypairA = await cryptoService.generateEphemeralKeyPair();
      final keypairB = await cryptoService.generateEphemeralKeyPair();
      final pubA = await keypairA.extractPublicKey();
      final pubB = await keypairB.extractPublicKey();

      final sessionA = SecuritySession(
        peerId: 'alice',
        endpointId: 'ep_alice',
        sessionId: 'session_123',
        sessionSalt: List.filled(16, 1),
        remoteIdentityPublicKey: 'id_pub_b',
        remoteFingerprint: 'fp_b',
      );

      final sessionB = SecuritySession(
        peerId: 'bob',
        endpointId: 'ep_bob',
        sessionId: 'session_123',
        sessionSalt: List.filled(16, 1),
        remoteIdentityPublicKey: 'id_pub_a',
        remoteFingerprint: 'fp_a',
      );

      await cryptoService.initializeDoubleRatchet(
        session: sessionA,
        handshakeLocalKeyPair: keypairA,
        handshakeRemotePublicKeyBytes: pubB.bytes,
        isDeviceA: true,
      );

      await cryptoService.initializeDoubleRatchet(
        session: sessionB,
        handshakeLocalKeyPair: keypairB,
        handshakeRemotePublicKeyBytes: pubA.bytes,
        isDeviceA: false,
      );

      // Alice sends Msg 1 (seq 1), Msg 2 (seq 2), and Msg 3 (seq 3)
      final pt1 = Uint8List.fromList([1]);
      final pt2 = Uint8List.fromList([2]);
      final pt3 = Uint8List.fromList([3]);

      final enc1 = await cryptoService.encryptWithDoubleRatchet(session: sessionA, messageId: 'm1', plaintextBytes: pt1);
      final enc2 = await cryptoService.encryptWithDoubleRatchet(session: sessionA, messageId: 'm2', plaintextBytes: pt2);
      final enc3 = await cryptoService.encryptWithDoubleRatchet(session: sessionA, messageId: 'm3', plaintextBytes: pt3);

      final localDhPubA1 = await sessionA.localDhKeyPair!.extractPublicKey();

      // Bob receives Msg 3 first (out of order, sequence = 3)
      final dec3 = await cryptoService.decryptWithDoubleRatchet(
        session: sessionB,
        incomingDhPublicKeyBytes: Uint8List.fromList(localDhPubA1.bytes),
        incomingSequence: 3,
        incomingPreviousChainLength: 0,
        nonce: Uint8List.fromList(enc3.nonce),
        ciphertext: Uint8List.fromList(enc3.ciphertext),
        mac: Uint8List.fromList(enc3.mac),
        messageId: 'm3',
      );
      expect(dec3, equals(pt3));
      expect(sessionB.nr, equals(3)); // nr advanced to 3 (seq 1 and 2 skipped)

      // Verify that Bob cached skipped message keys for sequence 1 and 2
      final remotePubHex = sessionB.getRemotePublicKeyHex();
      expect(sessionB.skippedMessageKeys.containsKey("$remotePubHex:1"), isTrue);
      expect(sessionB.skippedMessageKeys.containsKey("$remotePubHex:2"), isTrue);

      // Bob receives Msg 2 (sequence = 2)
      final dec2 = await cryptoService.decryptWithDoubleRatchet(
        session: sessionB,
        incomingDhPublicKeyBytes: Uint8List.fromList(localDhPubA1.bytes),
        incomingSequence: 2,
        incomingPreviousChainLength: 0,
        nonce: Uint8List.fromList(enc2.nonce),
        ciphertext: Uint8List.fromList(enc2.ciphertext),
        mac: Uint8List.fromList(enc2.mac),
        messageId: 'm2',
      );
      expect(dec2, equals(pt2));
      // Key should be removed from cache after use
      expect(sessionB.skippedMessageKeys.containsKey("$remotePubHex:2"), isFalse);

      // Bob receives Msg 1 (sequence = 1)
      final dec1 = await cryptoService.decryptWithDoubleRatchet(
        session: sessionB,
        incomingDhPublicKeyBytes: Uint8List.fromList(localDhPubA1.bytes),
        incomingSequence: 1,
        incomingPreviousChainLength: 0,
        nonce: Uint8List.fromList(enc1.nonce),
        ciphertext: Uint8List.fromList(enc1.ciphertext),
        mac: Uint8List.fromList(enc1.mac),
        messageId: 'm1',
      );
      expect(dec1, equals(pt1));
      expect(sessionB.skippedMessageKeys.containsKey("$remotePubHex:1"), isFalse);
    });

    test('Safety Bounds & Resource Exhaustion (DoS Guard)', () async {
      final keypairA = await cryptoService.generateEphemeralKeyPair();
      final keypairB = await cryptoService.generateEphemeralKeyPair();
      final pubA = await keypairA.extractPublicKey();
      final pubB = await keypairB.extractPublicKey();

      final sessionA = SecuritySession(
        peerId: 'alice',
        endpointId: 'ep_alice',
        sessionId: 'session_123',
        sessionSalt: List.filled(16, 1),
        remoteIdentityPublicKey: 'id_pub_b',
        remoteFingerprint: 'fp_b',
      );

      final sessionB = SecuritySession(
        peerId: 'bob',
        endpointId: 'ep_bob',
        sessionId: 'session_123',
        sessionSalt: List.filled(16, 1),
        remoteIdentityPublicKey: 'id_pub_a',
        remoteFingerprint: 'fp_a',
      );

      await cryptoService.initializeDoubleRatchet(
        session: sessionA,
        handshakeLocalKeyPair: keypairA,
        handshakeRemotePublicKeyBytes: pubB.bytes,
        isDeviceA: true,
      );

      await cryptoService.initializeDoubleRatchet(
        session: sessionB,
        handshakeLocalKeyPair: keypairB,
        handshakeRemotePublicKeyBytes: pubA.bytes,
        isDeviceA: false,
      );

      final plaintext = Uint8List.fromList([1, 2, 3]);
      final encrypted = await cryptoService.encryptWithDoubleRatchet(
        session: sessionA,
        messageId: 'msg_1',
        plaintextBytes: plaintext,
      );

      final localDhPubA1 = await sessionA.localDhKeyPair!.extractPublicKey();

      // If an attacker claims the sequence number is 105 (gap of 105), it should be rejected
      expect(
        () async => await cryptoService.decryptWithDoubleRatchet(
          session: sessionB,
          incomingDhPublicKeyBytes: Uint8List.fromList(localDhPubA1.bytes),
          incomingSequence: 105, // > 100 limit
          incomingPreviousChainLength: 0,
          nonce: Uint8List.fromList(encrypted.nonce),
          ciphertext: Uint8List.fromList(encrypted.ciphertext),
          mac: Uint8List.fromList(encrypted.mac),
          messageId: 'msg_1',
        ),
        throwsA(isException),
      );
    });

    test('Skipped Keys Cache Eviction (Capacity Limit)', () async {
      final session = SecuritySession(
        peerId: 'alice',
        endpointId: 'ep_alice',
        sessionId: 'session_123',
        sessionSalt: List.filled(16, 1),
        remoteIdentityPublicKey: 'id_pub_b',
        remoteFingerprint: 'fp_b',
      );

      // Add 100 keys
      for (var i = 0; i < 100; i++) {
        session.addSkippedKey("key_$i", SecretKey([i]));
      }
      expect(session.skippedMessageKeys.length, equals(100));

      // Adding 101st key should evict the oldest key (key_0)
      session.addSkippedKey("key_100", SecretKey([100]));
      expect(session.skippedMessageKeys.length, equals(100));
      expect(session.skippedMessageKeys.containsKey("key_0"), isFalse);
      expect(session.skippedMessageKeys.containsKey("key_100"), isTrue);
    });
  });
}
