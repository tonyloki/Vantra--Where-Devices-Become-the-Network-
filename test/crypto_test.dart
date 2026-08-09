import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/security/canonical_encoder.dart';

void main() {
  late CryptoService cryptoService;

  setUp(() {
    cryptoService = CryptoService();
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
