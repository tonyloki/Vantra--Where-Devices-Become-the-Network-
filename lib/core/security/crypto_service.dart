import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:cryptography/cryptography.dart';
import 'canonical_encoder.dart';
import 'security_session.dart';

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

  /// Computes a signature over the canonical RREP transcript (Phase 16).
  Future<List<int>> signRouteReply({
    required SimpleKeyPair identityKeyPair,
    required String requestId,
    required String sourcePeerId,
    required String destinationPeerId,
  }) async {
    final transcriptBytes = Uint8List.fromList([
      ...utf8.encode('VANTRA_RREP_TRANSCRIPT'),
      ...utf8.encode(requestId),
      ...utf8.encode(sourcePeerId),
      ...utf8.encode(destinationPeerId),
    ]);

    final signature = await _ed25519.sign(
      transcriptBytes,
      keyPair: identityKeyPair,
    );
    return signature.bytes;
  }

  /// Verifies an Ed25519 signature over the canonical RREP transcript (Phase 16).
  Future<bool> verifyRouteReply({
    required List<int> signatureBytes,
    required List<int> identityPublicKeyBytes,
    required String requestId,
    required String sourcePeerId,
    required String destinationPeerId,
  }) async {
    try {
      final transcriptBytes = Uint8List.fromList([
        ...utf8.encode('VANTRA_RREP_TRANSCRIPT'),
        ...utf8.encode(requestId),
        ...utf8.encode(sourcePeerId),
        ...utf8.encode(destinationPeerId),
      ]);

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

  /// Initializes the Double Ratchet state for a SecuritySession
  Future<void> initializeDoubleRatchet({
    required SecuritySession session,
    required SimpleKeyPair handshakeLocalKeyPair,
    required List<int> handshakeRemotePublicKeyBytes,
    required bool isDeviceA,
  }) async {
    session.isDeviceA = isDeviceA;

    // 1. Perform ECDH to get handshake shared secret
    final handshakeSharedSecret = await _x25519.sharedSecretKey(
      keyPair: handshakeLocalKeyPair,
      remotePublicKey: SimplePublicKey(handshakeRemotePublicKeyBytes, type: KeyPairType.x25519),
    );

    final hssData = await handshakeSharedSecret.extract();
    final localDhPub = await handshakeLocalKeyPair.extractPublicKey();

    print('[FORENSIC][RATCHET][INIT_STATE]\n'
        'isDeviceA=$isDeviceA\n'
        'sessionId=${session.sessionId.length}\n'
        'sessionSalt=${session.sessionSalt.length}\n'
        'handshakeLocalPubKeyLength=${localDhPub.bytes.length}\n'
        'handshakeRemotePubKeyLength=${handshakeRemotePublicKeyBytes.length}\n'
        'handshakeSharedSecretLength=${hssData.bytes.length}');

    // 2. Derive initial root key
    final initialRoot = await deriveInitialRootKey(handshakeSharedSecret);
    session.rootKey = initialRoot;
    final handshakeSharedSecretData = await handshakeSharedSecret.extract();
    final hssFp = await computeFingerprint(handshakeSharedSecretData.bytes);
    final irData = await initialRoot.extract();
    final irFp = await computeFingerprint(irData.bytes);
    print('[VANTRA][DR_DIAG] initializeDoubleRatchet: isDeviceA=$isDeviceA, handshakeSharedSecretFingerprint=$hssFp, initialRootFp=$irFp');

    // 3. Initialize DH ratchet state
    final remoteDhPub = SimplePublicKey(handshakeRemotePublicKeyBytes, type: KeyPairType.x25519);
    session.remoteDhPublicKey = remoteDhPub;

    if (isDeviceA) {
      // Alice is Device A: generates new DH key pair and derives sending chain key
      final localDhKeyPair = await generateEphemeralKeyPair();
      session.localDhKeyPair = localDhKeyPair;

      final dhOutput = await computeDH(localDhKeyPair, handshakeRemotePublicKeyBytes);
      final derived = await kdfRK(initialRoot, dhOutput);
      session.rootKey = derived.key;
      session.sendingChainKey = derived.value;
      session.ns = 1;
    } else {
      // Bob is Device B: keeps handshake local key pair as the active DH key pair
      session.localDhKeyPair = handshakeLocalKeyPair;
      session.receivingChainKey = null; // Derived on Bob's first incoming message
      session.ns = 1;
    }
    session.nr = 0;
    session.pn = 0;
  }

  /// Derives initial 32-byte root key from the handshake ECDH shared secret using HKDF-SHA256
  Future<SecretKey> deriveInitialRootKey(SecretKey handshakeSharedSecret, {List<int> nonce = const []}) async {
    // If the nonce is empty, we fall back to a 32-byte zero array (HashLen zeros for SHA-256)
    // to comply with RFC 5869 and prevent IllegalArgumentException: Empty key on Android platform channel.
    final hkdfSalt = nonce.isEmpty ? List<int>.filled(32, 0) : nonce;

    if (hkdfSalt.isEmpty) {
      throw PlatformException(
        code: 'CAUGHT_ERROR',
        message: 'Unexpected error\njava.lang.IllegalArgumentException: Empty key',
      );
    }

    final hssData = await handshakeSharedSecret.extract();
    print('[FORENSIC][RATCHET][HMAC_INPUT]\n'
        'name=hkdf_extract_salt_initial_root\n'
        'keyLength=${hkdfSalt.length}\n'
        'empty=${hkdfSalt.isEmpty}\n'
        'dataLength=${hssData.bytes.length}\n'
        'algorithm=HMAC-SHA256\n'
        'nonceLength=${hkdfSalt.length}');

    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    );
    return hkdf.deriveKey(
      secretKey: handshakeSharedSecret,
      nonce: hkdfSalt,
      info: utf8.encode('VANTRA_DR_INITIAL_ROOT'),
    );
  }

  /// KDF-RK step: derives a new root key and chain key from root key and DH output
  Future<MapEntry<SecretKey, SecretKey>> kdfRK(SecretKey rootKey, SecretKey dhOutput) async {
    final dhData = await dhOutput.extract();
    final dhFp = await computeFingerprint(dhData.bytes);
    final rootData = await rootKey.extract();
    final rootFp = await computeFingerprint(rootData.bytes);

    print('[FORENSIC][RATCHET][HMAC_INPUT]\n'
        'name=kdfRK_dhOutput_salt\n'
        'keyLength=${dhData.bytes.length}\n'
        'empty=${dhData.bytes.isEmpty}\n'
        'dataLength=${rootData.bytes.length}\n'
        'algorithm=HMAC-SHA256\n'
        'rootKeyLength=${rootData.bytes.length}');

    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 64, // 32 bytes next root key + 32 bytes chain key
    );
    final derived = await hkdf.deriveKey(
      secretKey: rootKey,
      nonce: dhData.bytes,
      info: utf8.encode('VANTRA_DR_ROOT_RATCHET'),
    );
    final derivedData = await derived.extract();

    final nextRootKeyBytes = derivedData.bytes.sublist(0, 32);
    final chainKeyBytes = derivedData.bytes.sublist(32, 64);

    final nextRootFp = await computeFingerprint(nextRootKeyBytes);
    final chainKeyFp = await computeFingerprint(chainKeyBytes);
    print('[VANTRA][DR_DIAG] kdfRK: inputRootFp=$rootFp, inputDhFp=$dhFp, nextRootFp=$nextRootFp, chainKeyFp=$chainKeyFp');

    return MapEntry(
      SecretKey(nextRootKeyBytes),
      SecretKey(chainKeyBytes),
    );
  }

  /// KDF-CK step: derives a new chain key and message key from a chain key using HMAC-SHA256
  Future<MapEntry<SecretKey, SecretKey>> kdfCK(SecretKey chainKey) async {
    final hmac = Hmac.sha256();
    final ckData = await chainKey.extract();

    print('[FORENSIC][RATCHET][HMAC_INPUT]\n'
        'name=kdfCK_chainKey_message\n'
        'keyLength=${ckData.bytes.length}\n'
        'empty=${ckData.bytes.isEmpty}\n'
        'dataLength=1\n'
        'algorithm=HMAC-SHA256\n'
        'chainKeyLength=${ckData.bytes.length}');
    
    // Derive message key: HMAC(chainKey, [0x01])
    final msgMac = await hmac.calculateMac(
      const [0x01],
      secretKey: chainKey,
    );
    
    print('[FORENSIC][RATCHET][HMAC_INPUT]\n'
        'name=kdfCK_chainKey_next_chain\n'
        'keyLength=${ckData.bytes.length}\n'
        'empty=${ckData.bytes.isEmpty}\n'
        'dataLength=1\n'
        'algorithm=HMAC-SHA256\n'
        'chainKeyLength=${ckData.bytes.length}');

    // Derive next chain key: HMAC(chainKey, [0x02])
    final nextChainMac = await hmac.calculateMac(
      const [0x02],
      secretKey: chainKey,
    );
    
    return MapEntry(
      SecretKey(nextChainMac.bytes),
      SecretKey(msgMac.bytes),
    );
  }

  /// Computes ECDH shared secret key from a local X25519 keypair and remote X25519 public key bytes
  Future<SecretKey> computeDH(SimpleKeyPair localKeyPair, List<int> remotePublicKeyBytes) async {
    final remotePublicKey = SimplePublicKey(
      remotePublicKeyBytes,
      type: KeyPairType.x25519,
    );
    return _x25519.sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey: remotePublicKey,
    );
  }

  /// Encrypts a message payload using the Double Ratchet state inside a SecuritySession
  Future<EncryptedPayloadResult> encryptWithDoubleRatchet({
    required SecuritySession session,
    required String messageId,
    required Uint8List plaintextBytes,
  }) async {
    if (session.sendingChainKey == null) {
      final sendKeyBytes = await session.sendKey.extractBytes();
      if (sendKeyBytes.isNotEmpty) {
        final encrypted = await encryptBytes(
          secretKey: session.sendKey,
          sessionSalt: session.sessionSalt,
          sequence: session.ns,
          messageId: messageId,
          plaintextBytes: plaintextBytes,
        );
        session.ns++;
        return encrypted;
      }
      throw Exception("No sending chain key derived. Cannot encrypt.");
    }

    // 1. Ratchet sending chain key to get message key
    final derived = await kdfCK(session.sendingChainKey!);
    session.sendingChainKey = derived.key;
    final messageKey = derived.value;
    session.addSentMessageKey(messageId, messageKey);

    final ckData = await session.sendingChainKey!.extract();
    final ckFp = await computeFingerprint(ckData.bytes);
    final msgKeyData = await messageKey.extract();
    final msgKeyFp = await computeFingerprint(msgKeyData.bytes);
    print('[VANTRA][DR_DIAG] encryptWithDoubleRatchet: nextCkFp=$ckFp, derivedMsgKeyFp=$msgKeyFp, sequence=${session.ns}');

    // 2. Encrypt bytes using the derived messageKey
    final sequenceNumber = session.ns;
    session.ns++;

    final encrypted = await encryptBytes(
      secretKey: messageKey,
      sessionSalt: session.sessionSalt,
      sequence: sequenceNumber,
      messageId: messageId,
      plaintextBytes: plaintextBytes,
    );

    return encrypted;
  }

  /// Decrypts a message payload using the Double Ratchet state inside a SecuritySession.
  /// Handles out-of-order skipped message keys caching, DH ratchet rotations, and limits.
  Future<Uint8List> decryptWithDoubleRatchet({
    required SecuritySession session,
    required Uint8List? incomingDhPublicKeyBytes,
    required int incomingSequence,
    required int incomingPreviousChainLength,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List mac,
    required String messageId,
  }) async {
    // 0. Fallback to legacy symmetric decryption if no DH key is provided, or if the incoming key matches the handshake key and receiving chain key is null.
    final recvKeyBytes = await session.receiveKey.extractBytes();
    final bool isHandshakeKey = incomingDhPublicKeyBytes != null &&
        session.remoteDhPublicKey != null &&
        _compareLists(session.remoteDhPublicKey!.bytes, incomingDhPublicKeyBytes);
    if (((incomingDhPublicKeyBytes == null ||
          incomingDhPublicKeyBytes.isEmpty) ||
         (isHandshakeKey && session.receivingChainKey == null)) &&
        recvKeyBytes.isNotEmpty) {
      return decryptBytes(
        secretKey: session.receiveKey,
        nonce: nonce,
        ciphertext: ciphertext,
        mac: mac,
        messageId: messageId,
      );
    }

    // 1. Check if the key is in the skippedMessageKeys cache
    final remotePubHex = incomingDhPublicKeyBytes != null
        ? incomingDhPublicKeyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()
        : session.getRemotePublicKeyHex();
    final cacheKey = "$remotePubHex:$incomingSequence";

    if (session.skippedMessageKeys.containsKey(cacheKey)) {
      final msgKey = session.skippedMessageKeys[cacheKey]!;
      session.skippedMessageKeys.remove(cacheKey);
      session.skippedMessageKeysTimestamps.remove(cacheKey);

      return decryptBytes(
        secretKey: msgKey,
        nonce: nonce,
        ciphertext: ciphertext,
        mac: mac,
        messageId: messageId,
      );
    }

    // 2. Perform DH Ratchet step if incoming DH key differs
    if (incomingDhPublicKeyBytes != null &&
        incomingDhPublicKeyBytes.isNotEmpty &&
        (session.remoteDhPublicKey == null ||
         !_compareLists(session.remoteDhPublicKey!.bytes, incomingDhPublicKeyBytes))) {
      
      // A new DH public key is received. First ratchet skipped keys on the old receiving chain.
      await _skipMessageKeys(session, incomingPreviousChainLength);

      // Perform DH Ratchet
      session.pn = session.ns;
      session.ns = 1;
      session.nr = 0;
      session.remoteDhPublicKey = SimplePublicKey(incomingDhPublicKeyBytes, type: KeyPairType.x25519);

      // Derive new receiving chain key: rootKey, receivingChainKey = KDF_RK(rootKey, DH(localDhKeyPair, remoteDhPublicKey))
      final dhOutputRecv = await computeDH(session.localDhKeyPair!, incomingDhPublicKeyBytes);
      final recvDhData = await dhOutputRecv.extract();
      final recvDhFp = await computeFingerprint(recvDhData.bytes);
      print('[VANTRA][DR_DIAG] Bob decrypt DH: recvDhFp=$recvDhFp');

      final derivedRecv = await kdfRK(session.rootKey!, dhOutputRecv);
      session.rootKey = derivedRecv.key;
      session.receivingChainKey = derivedRecv.value;

      // Generate a NEW local DH keypair
      final newLocalDhKeyPair = await generateEphemeralKeyPair();
      session.localDhKeyPair = newLocalDhKeyPair;

      // Derive new sending chain key: rootKey, sendingChainKey = KDF_RK(rootKey, DH(localDhKeyPair, remoteDhPublicKey))
      final dhOutputSend = await computeDH(newLocalDhKeyPair, incomingDhPublicKeyBytes);
      final derivedSend = await kdfRK(session.rootKey!, dhOutputSend);
      session.rootKey = derivedSend.key;
      session.sendingChainKey = derivedSend.value;
    }

    // 3. Ratchet skipped message keys on the current receiving chain up to the incoming sequence number
    await _skipMessageKeys(session, incomingSequence);

    // 4. Derive message key from the current receiving chain
    if (session.receivingChainKey == null) {
      throw Exception("No receiving chain key derived. Cannot decrypt.");
    }
    final derived = await kdfCK(session.receivingChainKey!);
    session.receivingChainKey = derived.key;
    final messageKey = derived.value;

    final ckData = await session.receivingChainKey!.extract();
    final ckFp = await computeFingerprint(ckData.bytes);
    final msgKeyData = await messageKey.extract();
    final msgKeyFp = await computeFingerprint(msgKeyData.bytes);
    print('[VANTRA][DR_DIAG] decryptWithDoubleRatchet: nextCkFp=$ckFp, derivedMsgKeyFp=$msgKeyFp, sequence=$incomingSequence');

    session.nr++;

    // 5. Decrypt message using message key
    return decryptBytes(
      secretKey: messageKey,
      nonce: nonce,
      ciphertext: ciphertext,
      mac: mac,
      messageId: messageId,
    );
  }

  /// Helper to store skipped message keys in the cache up to a certain sequence number
  Future<void> _skipMessageKeys(SecuritySession session, int untilSequence) async {
    if (session.receivingChainKey == null) return;

    // Resource exhaustion guard: limit maximum skipped keys to 100
    if (untilSequence - (session.nr + 1) > 100) {
      throw Exception("Too many skipped messages: target=$untilSequence, current=${session.nr}");
    }

    while (session.nr + 1 < untilSequence) {
      final derived = await kdfCK(session.receivingChainKey!);
      session.receivingChainKey = derived.key;
      final msgKey = derived.value;

      final remotePubHex = session.getRemotePublicKeyHex();
      final cacheKey = "$remotePubHex:${session.nr + 1}";
      session.addSkippedKey(cacheKey, msgKey);

      session.nr++;
    }
  }

  bool _compareLists(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
