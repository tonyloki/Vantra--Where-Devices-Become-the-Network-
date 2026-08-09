import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'canonical_encoder.dart';

class DerivedSessionKeys {
  final String sessionId;
  final List<int> sessionSalt;
  final SecretKey sendKey;
  final SecretKey receiveKey;
  final String sharedSecretFingerprint;
  final String keyAtoBFingerprint;
  final String keyBtoAFingerprint;
  final String localSendKeyFingerprint;
  final String localReceiveKeyFingerprint;
  final bool isDeviceA;

  const DerivedSessionKeys({
    required this.sessionId,
    required this.sessionSalt,
    required this.sendKey,
    required this.receiveKey,
    required this.sharedSecretFingerprint,
    required this.keyAtoBFingerprint,
    required this.keyBtoAFingerprint,
    required this.localSendKeyFingerprint,
    required this.localReceiveKeyFingerprint,
    required this.isDeviceA,
  });
}

class EncryptedPayloadResult {
  final List<int> nonce;
  final List<int> ciphertext;
  final List<int> mac;

  const EncryptedPayloadResult({
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });
}

class CryptoService {
  final _ed25519 = Ed25519();
  final _x25519 = X25519();
  final _sha256 = Sha256();
  final _aead = Chacha20.poly1305Aead();

  /// Generates a long-term Ed25519 keypair for cryptographic device identity
  Future<SimpleKeyPair> generateIdentityKeyPair() {
    return _ed25519.newKeyPair();
  }

  /// Restores an Ed25519 keypair from raw private key seed bytes (32 bytes)
  Future<SimpleKeyPair> identityKeyPairFromSeed(List<int> privateKeySeed) {
    return _ed25519.newKeyPairFromSeed(privateKeySeed);
  }

  /// Generates an ephemeral X25519 keypair for session key agreement
  Future<SimpleKeyPair> generateEphemeralKeyPair() {
    return _x25519.newKeyPair();
  }

  /// Calculates a SHA-256 fingerprint from byte content formatted as colon-separated hex (e.g. AA:BB:CC...)
  Future<String> computeFingerprint(List<int> bytes) async {
    final hash = await _sha256.hash(bytes);
    return hash.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  }

  /// Computes a signature over the canonical binary handshake transcript
  Future<List<int>> signHandshake({
    required SimpleKeyPair identityKeyPair,
    required int protocolVersion,
    required String peerId,
    required String displayName,
    required List<int> identityPublicKeyBytes,
    required List<int> ephemeralPublicKeyBytes,
  }) async {
    final transcriptBytes = CanonicalEncoder.encodeHandshakeTranscript(
      protocolVersion: protocolVersion,
      peerId: peerId,
      displayName: displayName,
      identityPublicKeyBytes: identityPublicKeyBytes,
      ephemeralPublicKeyBytes: ephemeralPublicKeyBytes,
    );

    final signature = await _ed25519.sign(
      transcriptBytes,
      keyPair: identityKeyPair,
    );
    return signature.bytes;
  }

  /// Verifies an Ed25519 signature over the canonical binary handshake transcript
  Future<bool> verifyHandshake({
    required List<int> signatureBytes,
    required List<int> identityPublicKeyBytes,
    required int protocolVersion,
    required String peerId,
    required String displayName,
    required List<int> ephemeralPublicKeyBytes,
  }) async {
    try {
      final transcriptBytes = CanonicalEncoder.encodeHandshakeTranscript(
        protocolVersion: protocolVersion,
        peerId: peerId,
        displayName: displayName,
        identityPublicKeyBytes: identityPublicKeyBytes,
        ephemeralPublicKeyBytes: ephemeralPublicKeyBytes,
      );

      final signature = Signature(
        signatureBytes,
        publicKey: SimplePublicKey(identityPublicKeyBytes, type: KeyPairType.ed25519),
      );

      return await _ed25519.verify(
        transcriptBytes,
        signature: signature,
      );
    } catch (_) {
      return false;
    }
  }

  /// Derives directional symmetric keys using ECDH X25519 and HKDF-SHA256.
  /// Deterministically assigns Device A (lexicographically lower ephemeral public key)
  /// and Device B (higher ephemeral public key) so both peers symmetrically agree on directional keys.
  Future<DerivedSessionKeys> deriveSessionKeys({
    required SimpleKeyPair localEphemeralKeyPair,
    required List<int> remoteEphemeralPublicKeyBytes,
  }) async {
    final remoteEphemeralPublicKey = SimplePublicKey(
      remoteEphemeralPublicKeyBytes,
      type: KeyPairType.x25519,
    );

    // 1. Perform X25519 ECDH key agreement
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: localEphemeralKeyPair,
      remotePublicKey: remoteEphemeralPublicKey,
    );

    final localEphemeralPublicKey = await localEphemeralKeyPair.extractPublicKey();
    final localPubBytes = localEphemeralPublicKey.bytes;

    // 2. Compute symmetric salt by lexicographically sorting ephemeral public keys
    final bool isDeviceA = _compareBytes(localPubBytes, remoteEphemeralPublicKeyBytes) <= 0;
    final List<int> sortedFirst = isDeviceA ? localPubBytes : remoteEphemeralPublicKeyBytes;
    final List<int> sortedSecond = isDeviceA ? remoteEphemeralPublicKeyBytes : localPubBytes;

    final salt = [...sortedFirst, ...sortedSecond];
    final sessionHash = await _sha256.hash(salt);
    final sessionId = sessionHash.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    // 3. Derive directional keys using HKDF-SHA256
    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    );

    final keyAToB = await hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: salt,
      info: utf8.encode('VANTRA_KEY_A_TO_B'),
    );

    final keyBToA = await hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: salt,
      info: utf8.encode('VANTRA_KEY_B_TO_A'),
    );

    final sendKey = isDeviceA ? keyAToB : keyBToA;
    final receiveKey = isDeviceA ? keyBToA : keyAToB;

    // Diagnostic safe SHA-256 fingerprints (never logging raw key material)
    final sharedSecretData = await sharedSecret.extract();
    final sharedSecretFp = await computeFingerprint(sharedSecretData.bytes);

    final keyAData = await keyAToB.extract();
    final keyAFp = await computeFingerprint(keyAData.bytes);

    final keyBData = await keyBToA.extract();
    final keyBFp = await computeFingerprint(keyBData.bytes);

    final sendData = await sendKey.extract();
    final sendFp = await computeFingerprint(sendData.bytes);

    final receiveData = await receiveKey.extract();
    final receiveFp = await computeFingerprint(receiveData.bytes);

    return DerivedSessionKeys(
      sessionId: sessionId,
      sessionSalt: salt,
      sendKey: sendKey,
      receiveKey: receiveKey,
      sharedSecretFingerprint: sharedSecretFp,
      keyAtoBFingerprint: keyAFp,
      keyBtoAFingerprint: keyBFp,
      localSendKeyFingerprint: sendFp,
      localReceiveKeyFingerprint: receiveFp,
      isDeviceA: isDeviceA,
    );
  }

  /// Constructs a deterministic 12-byte counter-based nonce: first 8 bytes of salt + 4 bytes big-endian sequence
  List<int> constructNonce({
    required List<int> sessionSalt,
    required int sequence,
  }) {
    final nonceBytes = Uint8List(12);
    final prefix = sessionSalt.take(8).toList();
    for (var i = 0; i < 8; i++) {
      nonceBytes[i] = i < prefix.length ? prefix[i] : 0;
    }
    final seqData = ByteData(4)..setUint32(0, sequence, Endian.big);
    nonceBytes.setRange(8, 12, seqData.buffer.asUint8List());
    return nonceBytes;
  }

  /// Encrypts binary payload using ChaCha20-Poly1305 with counter-based nonces and messageId associated data
  Future<EncryptedPayloadResult> encryptBytes({
    required SecretKey secretKey,
    required List<int> sessionSalt,
    required int sequence,
    required String messageId,
    required Uint8List plaintextBytes,
  }) async {
    final nonce = constructNonce(sessionSalt: sessionSalt, sequence: sequence);
    final aad = utf8.encode(messageId);

    final secretBox = await _aead.encrypt(
      plaintextBytes,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
    );

    return EncryptedPayloadResult(
      nonce: secretBox.nonce,
      ciphertext: secretBox.cipherText,
      mac: secretBox.mac.bytes,
    );
  }

  /// Decrypts ciphertext bytes and verifies Poly1305 authentication tag with messageId associated data
  Future<Uint8List> decryptBytes({
    required SecretKey secretKey,
    required List<int> nonce,
    required List<int> ciphertext,
    required List<int> mac,
    required String messageId,
  }) async {
    final aad = utf8.encode(messageId);
    final secretBox = SecretBox(
      ciphertext,
      nonce: nonce,
      mac: Mac(mac),
    );

    final decrypted = await _aead.decrypt(
      secretBox,
      secretKey: secretKey,
      aad: aad,
    );

    return Uint8List.fromList(decrypted);
  }

  /// Legacy helper for encrypting JSON strings
  Future<EncryptedPayloadResult> encryptPayload({
    required SecretKey secretKey,
    required List<int> sessionSalt,
    required int sequence,
    required String messageId,
    required String plaintextJson,
  }) {
    return encryptBytes(
      secretKey: secretKey,
      sessionSalt: sessionSalt,
      sequence: sequence,
      messageId: messageId,
      plaintextBytes: Uint8List.fromList(utf8.encode(plaintextJson)),
    );
  }

  /// Legacy helper for decrypting to UTF-8 strings
  Future<String> decryptPayload({
    required SecretKey secretKey,
    required List<int> nonce,
    required List<int> ciphertext,
    required List<int> mac,
    required String messageId,
  }) async {
    final bytes = await decryptBytes(
      secretKey: secretKey,
      nonce: nonce,
      ciphertext: ciphertext,
      mac: mac,
      messageId: messageId,
    );
    return utf8.decode(bytes);
  }

  int _compareBytes(List<int> a, List<int> b) {
    final len = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      if (a[i] != b[i]) {
        return a[i].compareTo(b[i]);
      }
    }
    return a.length.compareTo(b.length);
  }
}
