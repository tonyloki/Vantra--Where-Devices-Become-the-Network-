# VANTRA — Security Architecture

## Phase Status

*   **Current Phase:** Phase 7
*   **Status:** Cryptographic Identity, Trust Management, Peer Blocking, Replay Protection, and Encrypted ACKs completed.

---

## 1. Cryptographic Identity & Trust Model

VANTRA splits device identity into three distinct concepts:
1.  **Display Identity (`displayName`):** User-friendly display name (e.g. `Vantra-4967`), signed during handshake but not unique.
2.  **Logical Identity (`peerId`):** Persistent UUID mapping historical chats in SQLite.
3.  **Cryptographic Identity:** A long-term **Ed25519** signature keypair.
    *   *Identity Private Key:* Ed25519 private-key material is protected using `flutter_secure_storage` and Android Keystore-backed encrypted storage. Never logs private key material or exposes it to SQLite.
    *   *Identity Public Key:* Shared with peers during connection handshakes to verify ownership of a `peerId`.
    *   *Identity Fingerprint:* A SHA-256 hash of the public identity key, displayed in hex format for out-of-band verification.
    *   *First-Contact Trust Model:* Cryptographic signatures prove possession of the advertised identity private key, but first-contact MITM protection depends on authenticating the public key fingerprint:
        ```text
        [New Peer discovered]
                  │
                  ▼
         Status: untrusted (handshake valid, keys stored)
                  │
                  ├─────────► Fingerprint verified out-of-band ──► Status: trusted
                  └─────────► Fingerprint not verified ──────────► MITM Vulnerability remains
        ```

---

## 2. Security State Machine & Blocking Security Invariant

For every active Nearby Connections link, the application executes the following state transitions:

```text
       CONNECTED (Nearby link active)
           │
           ▼
   SECURITY_HANDSHAKE (Identity exchanged, signatures verified)
           │
           ├──────────────────────────┬────────────────────────────┐
           ▼ (Success & Allowed)      ▼ (Distrusted / Blocked)     ▼ (Signature/Ver Failure)
   IDENTITY_VERIFIED          CONNECTION REJECTED           HANDSHAKE_FAILED
           │                          │                            │
           ▼                          ▼                            ▼
      KEY_DERIVED                 DISCONNECT (Abrupt teardown)   DISCONNECT
           │
           ▼
    SECURE (Ready for Protobuf ENCRYPTED_TEXT ciphers)
```

### Blocking Security Invariant
When an `IDENTITY_SECURE` handshake is received:
1.  The long-term Ed25519 signature is verified.
2.  VANTRA resolves the peerId from the local database.
3.  If the resolved peer's `trustState` is `distrusted` (Blocked):
    *   The connection is rejected immediately.
    *   The state transitions to `CONNECTED` -> `SECURITY_HANDSHAKE` -> `DISCONNECT`.
    *   We do not transition to `SECURE` or store session keys.
    *   We call `Transport.disconnect(endpointId)`.
    *   No application-level payloads are accepted or decrypted.
    *   Existing conversation history is preserved in SQLite.

---

## 3. Key Agreement & Session Negotiation

To protect future communications (Perfect Forward Secrecy), VANTRA establishes fresh session keys on every connection:
*   **Algorithm:** Ephemeral Diffie-Hellman over Curve25519 (**X25519**).
*   **Handshake Authentication:** Ephemeral X25519 public keys are signed using the sender's long-term Ed25519 identity key, mitigating active MITM attacks during key exchange.
*   **Key Derivation (KDF):** **HKDF-SHA256** derives separate directional session keys:
    *   `key_A_to_B` (Device A encrypts, Device B decrypts)
    *   `key_B_to_A` (Device B encrypts, Device A decrypts)
    *   *Salt:* Concat of both ephemeral X25519 public keys sorted lexicographically.
    *   *Context Info:* `utf8.encode('VANTRA_KEY_A_TO_B')` and `utf8.encode('VANTRA_KEY_B_TO_A')` respectively.

---

## 4. Message Encryption & Nonce Strategy

All communications over the Nearby Connections transport are encrypted:
*   **Algorithm:** **ChaCha20-Poly1305 AEAD** (Authenticated Encryption with Associated Data).
*   **Associated Data Binding:** The plaintext `messageId` of the packet is bound to the ciphertext as Associated Data. Any modification of `messageId` in transit will cause Poly1305 tag verification to fail, causing decryption to throw an exception.
*   **Counter-Based Nonce Construction:** To guarantee absolute nonce uniqueness under the derived session key, VANTRA constructs the 12-byte (96-bit) AEAD nonce deterministically:
    *   *First 8 bytes (64 bits):* The first 8 bytes of the session key derivation parameter `salt`.
    *   *Last 4 bytes (32 bits):* The big-endian representation of the session's monotonic message `sequence` counter.

---

## 5. Replay Protection

Replay protection is enforced cryptographically per-session using sequence verification:
*   **Monotonic Sequence Counters:** Each secure session maintains a `sendSequence` and a `receiveSequence` counter starting at `1`.
*   **Sequence Integration:** The sequence number is included inside the decrypted `VantraPlaintext` protobuf payload (authenticated and encrypted) so it cannot be altered by an attacker.
*   **Verification Rules:**
    *   The decrypted `sessionId` must match the current active session.
    *   The decrypted `sequence` must be strictly greater than the last successfully processed `receiveSequence`.
    *   If `sequence <= receiveSequence` or the `sessionId` is invalid, the packet is discarded immediately as stale or replayed.
*   **ACK Exemption:** To support retransmissions when the original ACK was lost in transit:
    *   Retransmitted messages carry the **same messageId** but a **new sequence number and nonce** under the current session.
    *   This bypasses replay protection checks, allowing the duplicate message check to locate the duplicate message ID in SQLite, discard the duplicate payload to avoid duplicates, and immediately re-transmit the encrypted ACK to clear the sender's queue.

---

## 6. Key Storage & Database Security Scope

*   **Long-Term Keys:** Stored in Android Keystore via `flutter_secure_storage`.
*   **Session Keys:** Kept strictly in memory. They are destroyed immediately when a peer disconnects or when the application process terminates.
*   **Defensive Recovery:** If secure storage is corrupted or unreadable, VANTRA generates a fresh Ed25519 identity keypair automatically to prevent app crashes.
*   **SQLite Plaintext-at-Rest:** Database security is out of scope for Phase 7. Messages are persisted in plaintext SQLite databases in the application sandbox. Plaintext-at-rest protection (e.g. SQLCipher) is explicitly deferred to later phases.
