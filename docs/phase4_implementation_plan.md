# Phase 4: Secure Cryptographic Architecture Implementation Plan

This document details the planned cryptographic security architecture for VANTRA.

---

## 1. Current Architecture Findings (Ground Truth)

1.  **Identity Generation:** `LocalIdentity` is currently generated at startup by `LocalIdentityNotifier` if not found in `SharedPreferences`. The generation logic creates a random UUID for `peerId` and a simple random string `Vantra-XXXX` for `displayName`.
2.  **Storage of logical identity:** The logical `peerId` is stored in plaintext inside `SharedPreferences` under the key `'vantra_peer_id'`.
3.  **Identity Handshake:** When the transport fires `ConnectionStatus.connected`, the local device immediately transmits its `peerId` and `displayName` as a plaintext JSON payload of type `IDENTITY` over `Transport.send()`.
4.  **Display Name Exchange:** Received names are stored in memory and persisted into SQLite via `MessagingRepository.upsertPeer()`.
5.  **Serialization:** `VantraMessage` is serialized to a UTF-8 encoded JSON string and parsed back using standard Dart `jsonEncode`/`jsonDecode`.
6.  **Transport Payload:** Payloads travel through `Transport` as raw `Uint8List` bytes.
7.  **Message Persistence:** Handled by `drift` tables mapping into SQLite. Message status is tracked via an enum mapper.

---

## 2. Selected Cryptographic Packages

We will introduce two official, highly-maintained packages:

### 1. `cryptography` & `cryptography_flutter`
*   **Version:** `cryptography: ^2.9.0`, `cryptography_flutter: ^2.3.4`
*   **Justification:** Provides optimized cryptographic operations, binding to native platforms.
*   **Capabilities & Platform Mappings on Android:**
    *   *Native-Accelerated ciphers:* Standard hashing (SHA-256/512), HMAC, and AES/ChaCha block ciphers are accelerated using native Android `javax.crypto` APIs when supported.
    *   *Pure-Dart execution:* Standard Android Java providers lack built-in support for Curve25519 (Ed25519/X25519) on older SDK targets. Therefore, Ed25519 signature checks and X25519 key agreements are handled by the package's optimized, platform-independent pure-Dart fallback implementation.

### 2. `flutter_secure_storage`
*   **Version:** `flutter_secure_storage: ^9.2.2`
*   **Justification:** Backed by encrypted files wrapped by Android Keystore keys (TEE/SE) on Android to prevent raw extraction.

---

## 3. Rejected Alternatives

*   **`pointycastle`:** Pure-Dart port of Bouncy Castle. Rejected due to manual primitive assembly requirements and lower-level, error-prone developer APIs.
*   **`flutter_sodium`:** Libsodium wrapper. Rejected because it requires platform-specific native binary compilation, complicating project packaging and increasing binary footprints.
*   **`steel_crypt`:** Pointycastle wrapper. Rejected as it lacks Keystore integration and direct native performance optimization.

---

## 4. Identity Architecture

*   **Long-Term Keypair:** VANTRA generates a long-term **Ed25519** signature keypair at initial app setup.
*   **Logical vs Cryptographic ID:** The existing UUID `peerId` remains the database primary key. The Ed25519 public key represents the cryptographic identity.
*   **Fingerprint Calculation:**
    *   `fingerprint = SHA256(identityPublicKey)`
    *   Formatted in hex bytes (e.g. `aa:bb:cc...`) for user comparison.
*   **Storage of Private Key:** The Ed25519 private key bytes are written to `flutter_secure_storage` and never exposed to SQLite or application logs.

---

## 5. Key Storage Architecture

*   **Android Integration:** Ed25519 private-key material is protected using `flutter_secure_storage` and Android Keystore-backed encrypted storage.
*   **Backup Prevention:** To prevent Keystore decryption exceptions on device restores, we will disable backup for secure storage files:
    *   Add `android:allowBackup="false"` to `AndroidManifest.xml`.
*   **Recovery Fallback:** If secure storage fails to load the private key, VANTRA catches the exception and automatically generates a fresh identity keypair.

---

## 6. Trust Model

*   **Wording around key replacement:** Cryptographic signatures prove possession of the advertised identity private key, but first-contact MITM protection still depends on authenticating the public key fingerprint.
*   **Explicit Trust States:**
    *   `untrusted` (default): Handshake succeeded; public key is stored, but fingerprint not verified out-of-band.
    *   `trusted`: User has compared and confirmed the public key fingerprints.
    *   `distrusted`: Blocked peer; connection requests are immediately dropped.
*   **MITM Warning:** If the fingerprint is not verified, a MITM vulnerability remains during the initial key exchange.

---

## 7. Secure Handshake (Station-to-Station Variant)

Upon connection, peers exchange public parameters:

1.  **Generate Ephemeral Keys:** Both generate a fresh **X25519** keypair: `ephemeralPriv`, `ephemeralPub`.
2.  **Handshake Payload:** Both send an `IDENTITY_SECURE` packet containing:
    ```json
    {
      "type": "IDENTITY_SECURE",
      "v": 1,
      "peerId": "local-peer-id",
      "displayName": "DisplayName",
      "identityPublicKey": "hex-encoded-ed25519-public-key",
      "ephemeralPublicKey": "hex-encoded-x25519-ephemeral-public-key",
      "signature": "hex-encoded-signature"
    }
    ```
3.  **Deterministic Handshake Transcript (Unambiguous Signed Input):**
    To prevent parsing injection attacks, the signature is computed over a structured binary transcript with explicit domain separation:
    *   `domain_separator`: `utf8.encode('VANTRA_HANDSHAKE_DOMAIN')` (23 bytes)
    *   `protocol_version`: `v` as a 4-byte big-endian unsigned integer (uint32).
    *   `peerId`: 2-byte big-endian length + UTF-8 bytes.
    *   `displayName`: 2-byte big-endian length + UTF-8 bytes.
    *   `identityPublicKey`: 2-byte big-endian length + raw bytes.
    *   `ephemeralPublicKey`: 2-byte big-endian length + raw bytes.
    Both sides hash the concatenated bytes using SHA-256 and sign it using their long-term Ed25519 private key.
4.  **Verification:** Each peer verifies the remote signature using the remote `identityPublicKey`. If verification fails, the connection is closed.

---

## 8. Key Derivation (KDF)

1.  **ECDH calculation:** Both peers perform ECDH using their ephemeral X25519 keys:
    *   `sharedSecret = ECDH(localEphemeralPriv, remoteEphemeralPub)`
2.  **HKDF Derivation:**
    *   Algorithm: **HKDF-SHA256**
    *   Salt: Lexicographically sorted concat of both `ephemeralPub` keys.
    *   **Directional Keys:**
        *   `key_A_to_B` (Derivation Info: `'VANTRA_KEY_A_TO_B'`)
        *   `key_B_to_A` (Derivation Info: `'VANTRA_KEY_B_TO_A'`)

---

## 9. Encrypted Packet Format

Messages are transmitted inside the `ENCRYPTED_TEXT` wrapper:

```json
{
  "type": "ENCRYPTED_TEXT",
  "v": 1,
  "messageId": "unique-message-uuid",
  "nonce": "hex-encoded-12-byte-nonce",
  "ciphertext": "hex-encoded-ciphertext",
  "mac": "hex-encoded-16-byte-poly1305-tag"
}
```

*   **Associated Data:** `messageId` is bound to the cipher block as Associated Data to prevent packet metadata tampering.
*   **Payload plaintext structure (inner decrypted JSON):**
    ```json
    {
      "senderId": "sender-peer-uuid",
      "receiverId": "receiver-peer-uuid",
      "text": "Hello, secret world!",
      "timestamp": 1717000000000,
      "seq": 1,
      "sessionId": "hex-session-id"
    }
    ```

---

## 10. Nonce Strategy

*   **Counter-Based Nonce Construction:** To guarantee absolute nonce uniqueness under the derived session key, VANTRA constructs the 12-byte (96-bit) AEAD nonce deterministically:
    *   *First 8 bytes (64 bits):* The first 8 bytes of the session key derivation parameter `salt`.
    *   *Last 4 bytes (32 bits):* The big-endian representation of the session's monotonic message `sendSequence` counter.
    *   This guarantees that the nonce is unique for every message sent within the current session.

---

## 11. Replay Protection

VANTRA implements explicit authenticated per-session sequencing:
*   **Send Sequence:** Incremented monotonically for every encrypted payload sent.
*   **Receive Sequence:** Tracks the sequence number `seq` of the last successfully decrypted message.
*   **Session ID:** Derived as `SHA256(ephemeralPublicKey_A + ephemeralPublicKey_B)`.
*   **Duplicate/Stale Handling:**
    *   Decrypted payload contains the `sessionId` and `seq` field.
    *   If `sessionId` does not match the active session, the packet is discarded immediately.
    *   If `seq <= lastReceiveSequence`, the packet is discarded as a replay or duplicate.
    *   If valid, `lastReceiveSequence` is updated to `seq`.
*   Timestamps are not used for replay protection.

---

## 12. Security State Machine

For every active Nearby Connections link, the application executes the following state transitions:

```text
       CONNECTED (Nearby link active)
           │
           ▼
   SECURITY_HANDSHAKE (Identity exchanged, signatures verified)
           │
           ├──────────────────────────┐
           ▼ (Success)                ▼ (Failure)
   IDENTITY_VERIFIED           HANDSHAKE_FAILED
           │                          │
           ▼                          ▼
      KEY_DERIVED                 DISCONNECT (Abrupt teardown)
           │
           ▼
    SECURE (Ready for ENCRYPTED_TEXT ciphers)
```

*   **No Plaintext Fallback:** If the handshake fails, the state transitions directly to `HANDSHAKE_FAILED` and triggers a transport `disconnect()`.
*   **Strict Cipher Mode:** Plaintext messages (or payloads received before the state reaches `SECURE`) are discarded immediately.

---

## 13. Protocol Downgrade Protection

*   **Version Negotiation:** Secure peers enforce strict protocol version checks. Payloads with `v < 1` or unrecognized types are rejected immediately.
*   **No Fallback:** There is no automatic fallback from the secure protocol to the Phase 3 plaintext protocol. If a secure handshake fails, the transport session is terminated.

---

## 14. Database Migrations

### Drift Peers Table Update (Schema Version 2)
We add columns to the `Peers` table:
*   `publicKey` (`TextColumn`, nullable)
*   `fingerprint` (`TextColumn`, nullable)
*   `trustState` (`IntColumn` mapped to enum, defaults to `untrusted`)
*   `protocolVersion` (`IntColumn`, nullable) for future protocol negotiation.

### Migration Script
```dart
onUpgrade: (m, from, to) async {
  if (from < 2) {
    await m.addColumn(peers, peers.publicKey);
    await m.addColumn(peers, peers.fingerprint);
    await m.addColumn(peers, peers.trustState);
    await m.addColumn(peers, peers.protocolVersion);
  }
}
```
*   Plaintext-at-rest database security is out of scope for Phase 4. Plaintext-at-rest protection (e.g. SQLCipher) is explicitly deferred to later phases. No session keys are stored in the database.

---

## 15. Riverpod Integration

1.  **`LocalIdentityNotifier`:** Reads/generates Ed25519 keys via secure storage during build initialization. Exposes public key and fingerprint.
2.  **`MessagingNotifier`:** Manages ephemeral X25519 session states. Stores derived directional keys in memory-only caches. Destroys keys on disconnect.

---

## 16. Transport Integration

*   Handshake triggers automatically when Nearby Connections triggers `ConnectionStatus.connected`.
*   Incoming text messages are parsed, decrypted, verified via Poly1305, and written to SQLite only after successful verification.

---

## 17. Verification & Test Plan

### Crypto & Identity tests
*   Key generation consistency (private key yields public key).
*   ECDH X25519 agreement matches on both sides.
*   HKDF-SHA256 derives matching directional keys.
*   ChaCha20-Poly1305 encryption/decryption works with counter-based nonces.
*   Tampered ciphertext or modified `messageId` associated data is rejected.
*   Wrong key decryption is rejected.

### Session & Pipeline tests
*   Handshake exchanges keys, validates signatures over canonical transcripts, and derives session keys.
*   Handshake fails if signature is invalid.
*   Disconnect destroys session keys in memory.
*   Reconnection establishes new session keys.
*   Incoming decrypted message is persisted into SQLite.
*   Corrupted packet never reaches SQLite.
*   Replays are blocked via sequence checks.

---

## 18. Physical Device Test Plan

1.  Pair two devices.
2.  Verify fingerprints match out-of-band.
3.  Establish connection (Wi-Fi/Bluetooth, Internet OFF).
4.  Send secure text. Verify decryption and SQLite storage on the recipient.
5.  Disconnect. Reconnect. Verify new session key is derived and old history is loaded.
6.  Inject tampered packet bytes (debug hook). Verify rejection.

---

## 19. Risks and Security Limitations

1.  **Trustless MITM Risk:** Without out-of-band fingerprint verification, a MITM attacker could intercept initial public keys and act as a relay.
2.  **Root/Sandboxed Extraction:** If the device is rooted, SQLite database files are readable since they are stored as plaintext files. Plaintext-at-rest database security is deferred.
