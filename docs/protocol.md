# VANTRA — Protocol Specifications

## Current Phase Status

*   **Current Phase:** Phase 4
*   **Status:** Secure handshake, versioning, and message wrapping protocol designed.

---

## 1. Protocol Wrappers & Formats

VANTRA wraps payloads in JSON formats. Phase 4 introduces a strict protocol version flag (`v: 1`) on all packets.

### A. Handshake Packet (`IDENTITY_SECURE`)
Exchanged immediately when a Nearby Connections connection updates to `connected`.

```json
{
  "type": "IDENTITY_SECURE",
  "v": 1,
  "peerId": "local-peer-uuid",
  "displayName": "VantraDisplayName",
  "identityPublicKey": "hex-encoded-ed25519-public-key",
  "ephemeralPublicKey": "hex-encoded-x25519-public-key",
  "signature": "hex-encoded-ed25519-signature-over-canonical-bytes"
}
```

#### Canonical Handshake Transcript Bytes (Signed Input)
To ensure signatures are deterministic and unambiguous, the handshake payload must be packed into a binary transcript rather than a delimited string. The bytes are encoded as:

1.  **Domain Separator:** Prefix with `utf8.encode('VANTRA_HANDSHAKE_DOMAIN')` (23 bytes).
2.  **Protocol Version:** `v` mapped to a 4-byte big-endian unsigned integer (uint32).
3.  **Logical Identity (`peerId`):**
    *   2-byte big-endian unsigned integer length of `peerId` string.
    *   UTF-8 bytes of `peerId`.
4.  **Display Identity (`displayName`):**
    *   2-byte big-endian unsigned integer length of `displayName` string.
    *   UTF-8 bytes of `displayName`.
5.  **Long-Term Identity Key (`identityPublicKey`):**
    *   2-byte big-endian unsigned integer length of hex-decoded public key bytes (always 32 bytes).
    *   Raw bytes of `identityPublicKey`.
6.  **Ephemeral Key (`ephemeralPublicKey`):**
    *   2-byte big-endian unsigned integer length of hex-decoded ephemeral public key bytes (always 32 bytes).
    *   Raw bytes of `ephemeralPublicKey`.

The final signature is calculated by taking the SHA-256 hash of these concatenated bytes and signing it using the long-term Ed25519 private key.

---

### B. Encrypted Message Packet (`ENCRYPTED_TEXT`)
Wraps chat message payloads.

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

*   **Associated Data for AEAD:** The UTF-8 bytes of the `messageId` are passed as Associated Data (AD) to prevent metadata swapping or tampering.
*   **Counter-Based Nonce Construction:**
    *   *First 8 bytes (64 bits):* The first 8 bytes of the session key derivation parameter `salt`.
    *   *Last 4 bytes (32 bits):* The big-endian representation of the session's monotonic message `sendSequence` counter.
*   **Decrypted Cleartext JSON Structure:**
    ```json
    {
      "senderId": "sender-peer-uuid",
      "receiverId": "receiver-peer-uuid",
      "text": "Hello, secret world!",
      "timestamp": 1717000000000,
      "seq": 1,
      "sessionId": "hex-encoded-session-id"
    }
    ```

---

## 2. Handshake, Version, & Decryption Failures

1.  **Handshake Validation:** If signature verification fails, the connection is aborted immediately by calling `Transport.disconnect()`.
2.  **Version Negotiation:** Secure peers must reject unsupported or insecure protocol versions. If a peer receives a payload with `v < 1` or an unsupported type, the connection is closed. There is no automatic fallback to the Phase 3 plaintext protocol.
3.  **Decryption Failures:** If the Poly1305 MAC check fails, the message is discarded. The payload is never saved to the SQLite database and is never displayed on the ChatPage UI.
4.  **Sequence / Session Verification Failures:** If the decrypted `seq` is less than or equal to `lastReceiveSequence`, or if `sessionId` does not match the active session, the packet is discarded immediately.
