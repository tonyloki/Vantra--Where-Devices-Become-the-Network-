import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/security/canonical_encoder.dart';
import 'package:vantra/core/security/security_session.dart';

void main() {
  late CryptoService cryptoService;

  setUp(() {
    cryptoService = CryptoService();
  });

  group('SecuritySession Replay Protection Tests', () {
    late SecuritySession session;

    setUp(() async {
      final algorithm = Chacha20.poly1305Aead();
      final key = await algorithm.newSecretKey();
      session = SecuritySession(
        peerId: 'peer-1',
        endpointId: 'ep-1',
        sessionId: 'session-123',
        sessionSalt: [1, 2, 3, 4],
        sendKey: key,
        receiveKey: key,
        remoteIdentityPublicKey: 'pubkey',
        remoteFingerprint: 'fp',
        receiveSequence: 0,
      );
    });

    test('Sequential packets are accepted', () {
      expect(session.isValidInboundSequence(1, 'session-123'), isTrue);
      session.updateReceiveSequence(1);
      expect(session.isValidInboundSequence(2, 'session-123'), isTrue);
      session.updateReceiveSequence(2);
      expect(session.isValidInboundSequence(3, 'session-123'), isTrue);
      session.updateReceiveSequence(3);
    });

    test('Out-of-order packets inside the 64-packet window are accepted', () {
      // Receive 10, moves receiveSequence to 10
      expect(session.isValidInboundSequence(10, 'session-123'), isTrue);
      session.updateReceiveSequence(10);

      // 8 is less than 10, but inside the window (10 - 64 = -54), so it should be accepted
      expect(session.isValidInboundSequence(8, 'session-123'), isTrue);
      session.updateReceiveSequence(8);

      // 9 is less than 10, inside the window, accepted
      expect(session.isValidInboundSequence(9, 'session-123'), isTrue);
      session.updateReceiveSequence(9);
    });

    test('Duplicate packets are rejected', () {
      expect(session.isValidInboundSequence(5, 'session-123'), isTrue);
      session.updateReceiveSequence(5);

      // Re-receiving 5 must be rejected
      expect(session.isValidInboundSequence(5, 'session-123'), isFalse);
    });

    test('Stale packets outside/at the exact 64-packet window boundary are rejected', () {
      // Receive 100, receiveSequence becomes 100. Replay window: [37, 100] (100 - 64 = 36)
      expect(session.isValidInboundSequence(100, 'session-123'), isTrue);
      session.updateReceiveSequence(100);

      // 36 (exact boundary: receiveSequence - 64) must be rejected
      expect(session.isValidInboundSequence(36, 'session-123'), isFalse);

      // 35 (below boundary) must be rejected
      expect(session.isValidInboundSequence(35, 'session-123'), isFalse);

      // 37 (just inside boundary) should be accepted if never received before
      expect(session.isValidInboundSequence(37, 'session-123'), isTrue);
      session.updateReceiveSequence(37);

      // 37 duplicate must be rejected
      expect(session.isValidInboundSequence(37, 'session-123'), isFalse);
    });
  });

  group('CanonicalEncoder Tests', () {
    test('Encodes deterministic binary transcript with domain separation', () {
      final bytes = CanonicalEncoder.encodeHandshakeTranscript(
        protocolVersion: 1,
        peerId: 'peer-123',
        displayName: 'DeviceA',
        identityPublicKeyBytes: [1, 2, 3, 4],
        ephemeralPublicKeyBytes: [5, 6, 7, 8],
      );

      expect(bytes, isNotEmpty);
      expect(utf8.decode(bytes.sublist(0, 23)), 'VANTRA_HANDSHAKE_DOMAIN');
    });

    test('Validates exact 65535-byte boundary successfully', () {
      final longName = 'A' * 65535;
      final bytes = CanonicalEncoder.encodeHandshakeTranscript(
        protocolVersion: 1,
        peerId: 'peer-123',
        displayName: longName,
        identityPublicKeyBytes: [1, 2, 3, 4],
        ephemeralPublicKeyBytes: [5, 6, 7, 8],
      );
      expect(bytes, isNotEmpty);
    });

    test('Rejects 65536-byte overflow by throwing ArgumentError', () {
      final oversizedName = 'A' * 65536;
      expect(
        () => CanonicalEncoder.encodeHandshakeTranscript(
          protocolVersion: 1,
          peerId: 'peer-123',
          displayName: oversizedName,
          identityPublicKeyBytes: [1, 2, 3, 4],
          ephemeralPublicKeyBytes: [5, 6, 7, 8],
        ),
        throwsArgumentError,
      );
    });
  });

  group('CryptoService Tests', () {
    test('Ed25519 key generation, signing, and verification', () async {
      final keyPair = await cryptoService.generateIdentityKeyPair();
      final pub = await keyPair.extractPublicKey();

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: keyPair,
        protocolVersion: 1,
        peerId: 'peer-abc',
        displayName: 'Alice',
        identityPublicKeyBytes: pub.bytes,
        ephemeralPublicKeyBytes: [10, 20, 30, 40],
      );

      // Verify signature with valid data
      final isValid = await cryptoService.verifyHandshake(
        signatureBytes: sigBytes,
        identityPublicKeyBytes: pub.bytes,
        protocolVersion: 1,
        peerId: 'peer-abc',
        displayName: 'Alice',
        ephemeralPublicKeyBytes: [10, 20, 30, 40],
      );
      expect(isValid, isTrue);

      // Verify signature fails with tampered displayName
      final isTampered = await cryptoService.verifyHandshake(
        signatureBytes: sigBytes,
        identityPublicKeyBytes: pub.bytes,
        protocolVersion: 1,
        peerId: 'peer-abc',
        displayName: 'Mallory',
        ephemeralPublicKeyBytes: [10, 20, 30, 40],
      );
      expect(isTampered, isFalse);
    });

    test('Fingerprint computation produces colon-separated hex format', () async {
      final keyPair = await cryptoService.generateIdentityKeyPair();
      final pub = await keyPair.extractPublicKey();

      final fingerprint = await cryptoService.computeFingerprint(pub.bytes);
      expect(fingerprint, matches(r'^([0-9A-F]{2}:){31}[0-9A-F]{2}$'));
    });

    test('X25519 ECDH agreement & HKDF directional session keys match symmetrically', () async {
      final aliceEphemeral = await cryptoService.generateEphemeralKeyPair();
      final bobEphemeral = await cryptoService.generateEphemeralKeyPair();

      final alicePub = await aliceEphemeral.extractPublicKey();
      final bobPub = await bobEphemeral.extractPublicKey();

      // Alice derives keys
      final aliceKeys = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: aliceEphemeral,
        remoteEphemeralPublicKeyBytes: bobPub.bytes,
      );

      // Bob derives keys
      final bobKeys = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: bobEphemeral,
        remoteEphemeralPublicKeyBytes: alicePub.bytes,
      );

      expect(aliceKeys.sessionId, bobKeys.sessionId);

      final aliceSendBytes = (await aliceKeys.sendKey.extract()).bytes;
      final bobReceiveBytes = (await bobKeys.receiveKey.extract()).bytes;
      expect(aliceSendBytes, bobReceiveBytes);

      final aliceReceiveBytes = (await aliceKeys.receiveKey.extract()).bytes;
      final bobSendBytes = (await bobKeys.sendKey.extract()).bytes;
      expect(aliceReceiveBytes, bobSendBytes);
    });

    test('ChaCha20-Poly1305 AEAD encryption and decryption with counter nonces and AD', () async {
      final algorithm = Chacha20.poly1305Aead();
      final secretKey = await algorithm.newSecretKey();
      final salt = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

      final plaintext = '{"text": "Confidential Message"}';
      final messageId = 'msg-uuid-1';

      final encrypted = await cryptoService.encryptPayload(
        secretKey: secretKey,
        sessionSalt: salt,
        sequence: 1,
        messageId: messageId,
        plaintextJson: plaintext,
      );

      final decrypted = await cryptoService.decryptPayload(
        secretKey: secretKey,
        nonce: encrypted.nonce,
        ciphertext: encrypted.ciphertext,
        mac: encrypted.mac,
        messageId: messageId,
      );

      expect(decrypted, plaintext);

      // Tampered messageId (Associated Data mismatch) throws exception
      expect(
        () => cryptoService.decryptPayload(
          secretKey: secretKey,
          nonce: encrypted.nonce,
          ciphertext: encrypted.ciphertext,
          mac: encrypted.mac,
          messageId: 'tampered-msg-id',
        ),
        throwsException,
      );

      // Tampered ciphertext byte throws exception
      final tamperedCiphertext = List<int>.from(encrypted.ciphertext);
      tamperedCiphertext[0] ^= 0xFF;

      expect(
        () => cryptoService.decryptPayload(
          secretKey: secretKey,
          nonce: encrypted.nonce,
          ciphertext: tamperedCiphertext,
          mac: encrypted.mac,
          messageId: messageId,
        ),
        throwsException,
      );
    });
  });
}
